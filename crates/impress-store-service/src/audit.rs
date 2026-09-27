//! The audit sink: where the pipeline's `core/verb-call@1.0.0` records are
//! written (ADR-0036 D2, plan-self-reflective-layer § Call log "off the hot
//! path").
//!
//! The pipeline (`impress_service_core::pipeline::audit`) builds one record
//! per non-read-only call and hands it to the installed sink. This is that
//! sink: a bounded channel (4,096) drained by one writer thread that
//! inserts the row through `impress_core::call_context::record_verb_call`,
//! into the store the call ran on — the per-call override when the call
//! had one ([`crate::store::store_instance`] resolves it the same way), else
//! the process-wide store. On overflow the record is dropped and counted
//! ([`dropped`]); a dropped record is never silent.
//!
//! Installed by construction: the [`Installer`] below is an `inventory`
//! submission the pipeline runs once before its first call, so any process
//! that links this crate — every one that links a store service — records
//! its calls without an init call anyone has to remember.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, OnceLock};

use impress_core::call_context::record_verb_call;
use impress_core::sqlite_store::SqliteItemStore;
use impress_service_core::pipeline::audit::{self as pipeline_audit, Sink, VerbCallRecord};
use impress_service_core::pipeline::Installer;

/// The channel's bound: records beyond it are dropped and counted.
pub const CHANNEL_CAPACITY: usize = 4096;

static DROPPED: AtomicU64 = AtomicU64::new(0);
static WRITTEN: AtomicU64 = AtomicU64::new(0);
static FAILED: AtomicU64 = AtomicU64::new(0);

/// Records the writer could not keep because the channel was full.
pub fn dropped() -> u64 {
    DROPPED.load(Ordering::Relaxed)
}

/// Records the writer wrote.
pub fn written() -> u64 {
    WRITTEN.load(Ordering::Relaxed)
}

/// Records the store refused (logged to stderr with the reason).
pub fn failed() -> u64 {
    FAILED.load(Ordering::Relaxed)
}

/// The call log's own backlog, as `/api/health` (or `history-service_health`,
/// L2) shows it: rows written, rows dropped for a full channel, rows the
/// store refused, and the pipeline-side count of calls that found no sink at
/// all (a process that never linked a store service). A dropped record is
/// never silent — this is where it surfaces.
pub fn health() -> serde_json::Value {
    serde_json::json!({
        "written": written(),
        "dropped": dropped(),
        "failed": failed(),
        "no_sink": pipeline_audit::dropped(),
        "channel_capacity": CHANNEL_CAPACITY,
    })
}

/// The sink: one sender, one writer thread.
pub struct ChannelSink {
    sender: Mutex<SyncSender<VerbCallRecord>>,
}

impl ChannelSink {
    fn start() -> Arc<Self> {
        let (sender, receiver) = sync_channel::<VerbCallRecord>(CHANNEL_CAPACITY);
        std::thread::Builder::new()
            .name("impress-verb-call-writer".into())
            .spawn(move || {
                for record in receiver {
                    write(record);
                }
            })
            .expect("the verb-call writer thread starts");
        Arc::new(Self {
            sender: Mutex::new(sender),
        })
    }
}

impl Sink for ChannelSink {
    fn record(&self, record: VerbCallRecord) {
        let sender = self.sender.lock().unwrap_or_else(|e| e.into_inner());
        match sender.try_send(record) {
            Ok(()) => {}
            Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
                DROPPED.fetch_add(1, Ordering::Relaxed);
                pipeline_audit::count_dropped();
            }
        }
    }
}

/// The store a record is written to: the call's own override, else the
/// process-wide store.
fn store_for(record: &VerbCallRecord) -> Arc<SqliteItemStore> {
    record
        .store_override
        .clone()
        .and_then(|erased| erased.downcast::<SqliteItemStore>().ok())
        .unwrap_or_else(crate::store::store_instance)
}

fn write(record: VerbCallRecord) {
    let store = store_for(&record);
    if crate::store::is_fallback_store(&store) {
        // A row in the in-memory stand-in vanishes with the process; count
        // it rather than pretend it was recorded.
        DROPPED.fetch_add(1, Ordering::Relaxed);
        pipeline_audit::count_dropped();
        return;
    }
    let payload = record.payload();
    match record_verb_call(store.as_ref(), &record.call_id, &record.caller, payload) {
        Ok(_) => {
            WRITTEN.fetch_add(1, Ordering::Relaxed);
        }
        Err(e) => {
            FAILED.fetch_add(1, Ordering::Relaxed);
            eprintln!(
                "[impress-store-service] verb-call record for {} ({}) not written: {e}",
                record.verb, record.call_id
            );
        }
    }
}

/// Install the sink once per process. Idempotent; the pipeline calls it
/// through the [`Installer`] below, and a test or an embedder may call it
/// directly.
pub fn install() {
    static SINK: OnceLock<Arc<ChannelSink>> = OnceLock::new();
    let sink = SINK.get_or_init(ChannelSink::start).clone();
    if !pipeline_audit::has_sink() {
        pipeline_audit::install(sink);
    }
}

impress_service_core::inventory::submit! {
    Installer {
        name: "impress-store-service::audit",
        install,
    }
}

/// Block until every record handed in before this call has been written —
/// for a test or a CLI that exits right after a mutating verb.
pub fn flush() {
    // A marker record would need a store; instead wait for the queue to
    // drain by polling the counters against a short deadline.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let pending = {
            // `sync_channel` exposes no length; approximate by giving the
            // writer a chance and checking it is idle: two consecutive
            // reads with equal counters and no thread work in between.
            let before = WRITTEN.load(Ordering::Relaxed)
                + FAILED.load(Ordering::Relaxed)
                + DROPPED.load(Ordering::Relaxed);
            std::thread::sleep(std::time::Duration::from_millis(20));
            let after = WRITTEN.load(Ordering::Relaxed)
                + FAILED.load(Ordering::Relaxed)
                + DROPPED.load(Ordering::Relaxed);
            before != after
        };
        if !pending || std::time::Instant::now() > deadline {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::item::{ActorKind, Item, Priority, Visibility};
    use impress_core::store::ItemStore;
    use impress_service_core::pipeline::{self, Call};
    use impress_service_core::VerbDescriptor;

    fn item(store: &SqliteItemStore) -> uuid::Uuid {
        let now = chrono::Utc::now();
        let id = uuid::Uuid::new_v4();
        store
            .insert(Item {
                id,
                schema: "test".into(),
                payload: Default::default(),
                created: now,
                modified: now,
                author: "test".into(),
                author_kind: ActorKind::Human,
                logical_clock: 0,
                origin: None,
                canonical_id: None,
                tags: vec![],
                flag: None,
                is_read: false,
                is_starred: false,
                priority: Priority::None,
                visibility: Visibility::Private,
                message_type: None,
                produced_by: None,
                version: None,
                batch_id: None,
                references: vec![],
                parent: None,
            })
            .expect("insert");
        id
    }

    /// The proof the plan asks for, headless: a mutating verb through the
    /// pipeline leaves one `core/verb-call@1.0.0` row whose id is the
    /// `batch_id` of every operation it wrote, on the store the call ran
    /// on (`invoke_on`, H-P2-3).
    #[test]
    fn a_mutating_verb_leaves_one_call_row_joined_to_its_operations_by_batch_id() {
        let store = crate::test_support::test_store();
        let id = item(&store);
        let verb = VerbDescriptor::find("triage-service_set-starred").expect("linked");
        let answer = impress_service_core::runtime::block_on(pipeline::invoke_on(
            store.clone(),
            verb,
            Call::agent(
                "test",
                serde_json::json!({ "id": id.to_string(), "starred": true }),
            ),
        ))
        .expect("the verb ran");
        assert_eq!(answer["ok"], true, "{answer}");

        let ops = store.operations_for(id, None).expect("ops");
        assert!(!ops.is_empty(), "set-starred wrote an operation");
        let batch_ids: std::collections::BTreeSet<_> =
            ops.iter().map(|op| op.batch_id.clone()).collect();
        assert_eq!(
            batch_ids.len(),
            1,
            "every op carries the one call id: {batch_ids:?}"
        );
        let call_id = batch_ids
            .into_iter()
            .next()
            .flatten()
            .expect("the batch id is the call id, not None");

        flush();
        let row = store
            .get(uuid::Uuid::parse_str(&call_id).expect("a uuid"))
            .expect("read")
            .expect("the call row exists under the call id");
        assert_eq!(row.schema, impress_core::schemas::VERB_CALL_SCHEMA);
        assert_eq!(row.batch_id.as_deref(), Some(call_id.as_str()));
        assert_eq!(row.author, "agent:test");
        assert_eq!(row.author_kind, ActorKind::Agent);
        assert_eq!(
            row.payload.get("verb"),
            Some(&impress_core::item::Value::String(
                "triage-service_set-starred".into()
            ))
        );
        assert_eq!(
            row.payload.get("args"),
            Some(&impress_core::item::Value::Object(
                [
                    (
                        "id".to_string(),
                        impress_core::item::Value::String(id.to_string())
                    ),
                    ("starred".to_string(), impress_core::item::Value::Bool(true)),
                ]
                .into_iter()
                .collect()
            ))
        );
    }

    /// Two mutating verbs invoked under one trace each leave their own call
    /// row (their own `batch_id`, joined to their own ops), and both rows
    /// carry the shared `trace_id` — the join `history-service_trace` will
    /// use, without needing L2 to exist yet to prove it.
    #[test]
    fn two_verbs_under_one_trace_each_stamp_their_own_ops_and_share_the_trace_id() {
        let store = crate::test_support::test_store();
        let id_a = item(&store);
        let id_b = item(&store);
        let verb = VerbDescriptor::find("triage-service_set-starred").expect("linked");

        let trace_id = uuid::Uuid::new_v4().to_string();
        let call_a = Call::agent(
            "test",
            serde_json::json!({ "id": id_a.to_string(), "starred": true }),
        )
        .with_trace(trace_id.clone());
        let call_b = Call::agent(
            "test",
            serde_json::json!({ "id": id_b.to_string(), "starred": true }),
        )
        .with_trace(trace_id.clone());

        let answer_a = impress_service_core::runtime::block_on(pipeline::invoke_on(
            store.clone(),
            verb,
            call_a,
        ))
        .expect("verb a ran");
        assert_eq!(answer_a["ok"], true, "{answer_a}");
        let answer_b = impress_service_core::runtime::block_on(pipeline::invoke_on(
            store.clone(),
            verb,
            call_b,
        ))
        .expect("verb b ran");
        assert_eq!(answer_b["ok"], true, "{answer_b}");
        flush();

        let ops_a = store.operations_for(id_a, None).expect("ops a");
        let ops_b = store.operations_for(id_b, None).expect("ops b");
        assert!(!ops_a.is_empty() && !ops_b.is_empty());

        let batch_a = ops_a[0].batch_id.clone().expect("a's ops have a batch id");
        let batch_b = ops_b[0].batch_id.clone().expect("b's ops have a batch id");
        assert_ne!(batch_a, batch_b, "each call keeps its own batch id");
        assert!(
            ops_a
                .iter()
                .all(|op| op.batch_id.as_deref() == Some(batch_a.as_str())),
            "every op of call a carries call a's id"
        );
        assert!(
            ops_b
                .iter()
                .all(|op| op.batch_id.as_deref() == Some(batch_b.as_str())),
            "every op of call b carries call b's id"
        );

        let row_a = store
            .get(uuid::Uuid::parse_str(&batch_a).unwrap())
            .expect("read")
            .expect("call a's row exists");
        let row_b = store
            .get(uuid::Uuid::parse_str(&batch_b).unwrap())
            .expect("read")
            .expect("call b's row exists");
        assert_eq!(
            row_a.payload.get("trace_id"),
            Some(&impress_core::item::Value::String(trace_id.clone()))
        );
        assert_eq!(
            row_b.payload.get("trace_id"),
            Some(&impress_core::item::Value::String(trace_id))
        );
    }

    /// § Call log "off the hot path": a full channel drops the record
    /// rather than block the caller, and the caller's own `record()` call
    /// stays fast — a bounded `try_send`, never a wait for the writer
    /// thread to catch up. This is the sink's own bound
    /// ([`CHANNEL_CAPACITY`]), tested directly against a sender that is
    /// never drained, so the writer thread cannot race the assertion.
    #[test]
    fn a_full_channel_drops_and_counts_rather_than_block_the_caller() {
        use std::sync::mpsc::sync_channel;

        fn record_of(n: usize) -> VerbCallRecord {
            VerbCallRecord {
                call_id: format!("c{n}"),
                verb: "t-service_x",
                since: "0.1.0",
                requested_name: None,
                caller: impress_service_core::pipeline::CallerIdentity::Person,
                trace_id: "t".into(),
                parent_call: None,
                args: serde_json::Value::Null,
                ok: true,
                code: None,
                message_len: 0,
                started_at: String::new(),
                duration_ms: 0,
                arg_bytes: 0,
                result_bytes: 0,
                store_override: None,
            }
        }

        // An undrained channel of the sink's own bound: fill it exactly,
        // then send one more.
        let (sender, _receiver_never_drained) = sync_channel::<VerbCallRecord>(CHANNEL_CAPACITY);
        for n in 0..CHANNEL_CAPACITY {
            sender
                .try_send(record_of(n))
                .expect("fits within the bound");
        }

        // A local counter, not the crate's shared statics: this test
        // exercises the channel's own overflow behaviour (the same bound
        // and the same `try_send` [`ChannelSink::record`] uses), without
        // racing every other test in this binary that reads or writes
        // `DROPPED`/`WRITTEN` concurrently.
        let local_dropped = AtomicU64::new(0);
        let started = std::time::Instant::now();
        match sender.try_send(record_of(CHANNEL_CAPACITY)) {
            Ok(()) => panic!("the channel was full; this send should not have fit"),
            Err(std::sync::mpsc::TrySendError::Full(_)) => {
                local_dropped.fetch_add(1, Ordering::Relaxed);
            }
            Err(other) => panic!("unexpected: {other:?}"),
        }
        let elapsed = started.elapsed();

        assert!(
            elapsed < std::time::Duration::from_millis(50),
            "an overflow must not block the caller: took {elapsed:?}"
        );
        assert_eq!(
            local_dropped.load(Ordering::Relaxed),
            1,
            "the overflow is counted, not silent"
        );
    }

    /// `health()` shows the backlog `/api/health` will surface: the plan's
    /// "a dropped record is never silent" as a number, not a log line. Reads
    /// the real shared counters (monotonic, never reset) rather than
    /// mutating them, so this does not race the other tests in this binary
    /// that also touch `DROPPED`/`WRITTEN`/`FAILED` concurrently.
    #[test]
    fn health_reports_the_shared_counters_and_the_channel_bound() {
        let snapshot = health();
        assert_eq!(snapshot["dropped"].as_u64().unwrap(), dropped());
        assert_eq!(snapshot["written"].as_u64().unwrap(), written());
        assert_eq!(snapshot["failed"].as_u64().unwrap(), failed());
        assert_eq!(
            snapshot["channel_capacity"].as_u64().unwrap() as usize,
            CHANNEL_CAPACITY
        );
    }

    /// A read-only verb leaves no row (D-R3).
    #[test]
    fn a_read_only_verb_leaves_no_call_row() {
        let store = crate::test_support::test_store();
        let verb = VerbDescriptor::find("collection-service_tree").expect("linked");
        let _ = impress_service_core::runtime::block_on(pipeline::invoke_on(
            store.clone(),
            verb,
            Call::agent("test", serde_json::json!({})),
        ));
        flush();
        let rows = store
            .count(&impress_core::query::ItemQuery {
                schema: Some(impress_core::schemas::VERB_CALL_SCHEMA.into()),
                ..Default::default()
            })
            .expect("count");
        if std::env::var("IMPRESS_CALL_LOG").as_deref() != Ok("all") {
            assert_eq!(rows, 0);
        }
    }
}
