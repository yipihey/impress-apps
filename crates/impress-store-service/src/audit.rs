//! The call log's sink for this suite: koine-notebook's (docs/plan-koine-kit-moves.md
//! KM10), the one writer of `core/verb-call@1.0.0`, over the shared
//! `impress.sqlite` store opened lazily on the writer's first record. A call
//! that ran on a scoped store (a test's, a scenario's scratch store) is
//! recorded in that store. A record that would land in the in-memory
//! stand-in for a store that could not be opened is dropped and counted.
//!
//! Installed by construction: the [`Installer`] below is an `inventory`
//! submission the pipeline runs once before its first call, so any process
//! that links this crate records its calls without an init call anyone has
//! to remember.

use std::sync::Arc;
use std::time::Duration;

use impress_core::store::AttributedStore;
use impress_service_core::pipeline::audit as pipeline_audit;
use impress_service_core::pipeline::Installer;

/// The channel's bound: records beyond it are dropped and counted.
pub const CHANNEL_CAPACITY: usize = koine_notebook::sink::CHANNEL_CAP;

/// Why [`flush`] did not drain.
#[derive(Debug, PartialEq, Eq)]
pub enum FlushError {
    TimedOut,
    WriterDisconnected,
}

impl std::fmt::Display for FlushError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::TimedOut => formatter.write_str("timed out waiting for audit writer"),
            Self::WriterDisconnected => formatter.write_str("audit writer disconnected"),
        }
    }
}

impl std::error::Error for FlushError {}

fn stat(name: &str) -> u64 {
    koine_notebook::health()[name].as_u64().unwrap_or(0)
}

/// Records dropped for a full channel (or with no store to keep them).
pub fn dropped() -> u64 {
    stat("dropped")
}

/// Rows the writer has written.
pub fn written() -> u64 {
    stat("written")
}

/// Rows the store refused.
pub fn failed() -> u64 {
    stat("failed")
}

/// The writer's counters, as `history-service_health` reports them.
pub fn health() -> serde_json::Value {
    koine_notebook::health()
}

/// The shared store, unless it is the in-memory stand-in (whose rows vanish
/// with the process).
fn suite_store() -> Option<Arc<dyn AttributedStore>> {
    let store = crate::store::store_instance();
    if crate::store::is_fallback_store(&store) {
        return None;
    }
    Some(store)
}

/// This device's name for the records' `host`.
fn host_name() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("HOST"))
        .unwrap_or_else(|_| "impress".to_string())
}

/// Install the sink once per process. Idempotent; the pipeline calls it
/// through the [`Installer`] below, and an embedder may call it directly.
pub fn install() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        if pipeline_audit::has_sink() {
            return;
        }
        let config = koine_notebook::SinkConfig {
            // The suite's log is compacted by its own maintenance, not
            // pruned by count.
            keep: 0,
            ..koine_notebook::SinkConfig::new(host_name(), "impress", env!("CARGO_PKG_VERSION"))
        };
        koine_notebook::install_with(suite_store, config);
    });
}

impress_service_core::inventory::submit! {
    Installer {
        name: "impress-store-service::audit",
        install,
    }
}

/// Block until every record handed to the sink so far is written. Used by
/// tests and CLIs after mutating verbs.
pub fn flush() -> Result<(), FlushError> {
    pipeline_audit::flush(Duration::from_secs(5)).map_err(|_| FlushError::TimedOut)
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::item::{ActorKind, Item, Priority, Visibility};
    use impress_core::sqlite_store::SqliteItemStore;
    use impress_core::store::ItemStore;
    use impress_service_core::pipeline::{self, Call};
    use impress_service_core::VerbDescriptor;

    fn item(store: &SqliteItemStore) -> uuid::Uuid {
        let now = chrono::Utc::now();
        let id = uuid::Uuid::new_v4();
        store
            .insert(Item {
                id,
                schema: impress_core::schema::refs::MANUSCRIPT,
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

        flush().expect("audit flush");
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
        flush().expect("audit flush");

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
        flush().expect("audit flush");
        let rows = store
            .count(&impress_core::query::ItemQuery {
                schema: Some(impress_core::schemas::VERB_CALL_SCHEMA),
                ..Default::default()
            })
            .expect("count");
        if std::env::var("IMPRESS_CALL_LOG").as_deref() != Ok("all") {
            assert_eq!(rows, 0);
        }
    }
}
