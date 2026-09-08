//! impel-taskd — the live task scheduler daemon (ADR-0015).
//!
//! Watches the shared impress-core store for new `imbib/bibliography-entry`
//! items (broadcast event bus, schema-filtered), spawns the enrichment DAG
//! via `EnrichmentSpawnRule`, and drives the ADR-0005 §6 scheduler loop
//! with the `impel-enrichment` executors.
//!
//! It also runs the ADR-0028 D7 memory sweeps — embedding backfill and
//! agent-run consolidation — which are unlike the rules above in that they have
//! no trigger item: `impel_memory::plan_memory_tasks` reads its own watermark
//! off the chain of completed tasks. Both are OFF unless `IMPRESS_MEMORY_EMBED`
//! / `IMPRESS_MEMORY_CONSOLIDATE` say otherwise, so a deploy carrying them
//! changes no behavior until switched on.
//!
//! Safety posture:
//! - Touching the LIVE group-container store requires the explicit
//!   `--enable` flag; otherwise the daemon refuses and explains itself.
//! - `--workspace <dir>` points at an alternate workspace (its
//!   `impress.sqlite` is created if absent) — the testing path.
//! - `--dry-run` observes and logs but never writes.
//! - The live store gets a start delay (default 90 s — the CLAUDE.md
//!   startup-settling guard); workspace runs default to 0.
//!
//! Signing: like impress-mcp, the release binary must be codesigned with
//! a team identity + the group-container entitlement to read the live
//! store (see sign.sh; Full Disk Access may additionally be required).

use std::path::PathBuf;
use std::sync::mpsc::TryRecvError;
use std::sync::Arc;
use std::time::Duration;

use imbib_core::enrichment::priority::SourcePriority;
use impel_core::{
    create_task_dag_from, PassReport, Scheduler, SchedulerConfig, SpawnProvenance, SpawnRule,
    TaskStoreApi, TASK_SCHEMA,
};
use impel_enrichment::classify::{Classifier, HeuristicClassifier};
use impel_enrichment::metadata_resolve::ConfiguredSource;
use impel_enrichment::{
    EnrichmentSpawnRule, KeywordTagExecutor, MetadataResolveExecutor, BIBLIOGRAPHY_ENTRY_SCHEMA,
};
use impel_memory::{
    plan_memory_tasks, EmbedBackfillExecutor, MemoryConsolidationExecutor, MemoryPlanConfig,
};
use impel_throughline::{
    ProposalDrafter, TemplateDrafter, ThroughlineSpawnRule, ThroughlineSyncExecutor,
    MANUSCRIPT_SECTION_SCHEMA,
};
use impress_ai::{
    write_worker_status, AiStore, AiTitleTaskExecutor, FileBlobStore, OmlxClient, OmlxTaskExecutor,
    WebResearchProvider, WorkerLease, WorkerLifecycleState, WorkerStatusSnapshot,
    WORKER_HEARTBEAT_INTERVAL_SECS,
};
use impress_ai_tools::ImpressToolAdapter;
use impress_core::event::ItemEvent;
use impress_core::item::ActorKind;
use impress_core::query::{ItemQuery, Predicate};
use impress_core::reference::EdgeType;
use impress_core::sqlite_store::{SqliteItemStore, StoreConfig};
use impress_core::store::ItemStore;
use impress_sources::arxiv::ArxivSource;
use impress_sources::crossref::CrossrefSource;
use impress_sources::openalex::OpenAlexSource;
use tokio::sync::RwLock;

const ACTOR: &str = "impel-taskd";

struct Args {
    workspace: Option<PathBuf>,
    enable_live: bool,
    dry_run: bool,
    once: bool,
    start_delay: Option<u64>,
    poll_secs: u64,
    confidence_threshold: f64,
    backfill_hours: u64,
}

fn parse_args() -> Args {
    let mut args = Args {
        workspace: None,
        enable_live: false,
        dry_run: false,
        once: false,
        start_delay: None,
        poll_secs: 5,
        confidence_threshold: 0.5,
        backfill_hours: 0,
    };
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--workspace" => args.workspace = it.next().map(PathBuf::from),
            "--enable" => args.enable_live = true,
            "--dry-run" => args.dry_run = true,
            "--once" => args.once = true,
            "--start-delay" => {
                args.start_delay = it.next().and_then(|v| v.parse().ok());
            }
            "--poll" => {
                if let Some(v) = it.next().and_then(|v| v.parse().ok()) {
                    args.poll_secs = v;
                }
            }
            "--confidence" => {
                if let Some(v) = it.next().and_then(|v| v.parse().ok()) {
                    args.confidence_threshold = v;
                }
            }
            "--backfill" => {
                if let Some(v) = it.next().and_then(|v| v.parse().ok()) {
                    args.backfill_hours = v;
                }
            }
            "--help" | "-h" => {
                eprintln!(
                    "impel-taskd — impress task scheduler daemon\n\
                     \n\
                     USAGE: impel-taskd [--workspace DIR | --enable] [--dry-run] [--once]\n\
                            [--start-delay SECS] [--poll SECS] [--confidence F]\n\
                     \n\
                     --workspace DIR   use DIR/impress.sqlite (testing; created if absent)\n\
                     --enable          allow the LIVE group-container store (required for it)\n\
                     --dry-run         observe + log; never write\n\
                     --once            one scheduler pass, then exit\n\
                     --start-delay S   delay before first pass (default: 90 live, 0 workspace)\n\
                     --poll S          scheduler poll interval (default 5)\n\
                     --confidence F    keyword-tag review threshold (default 0.5)\n\
                     --backfill H      also spawn for entries created in the last H hours"
                );
                std::process::exit(0);
            }
            other => {
                eprintln!("impel-taskd: unknown argument '{other}' (see --help)");
                std::process::exit(2);
            }
        }
    }
    args
}

fn live_store_path() -> PathBuf {
    std::env::var_os("IMPRESS_STORE_PATH")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("HOME")
                .filter(|home| !home.is_empty())
                .map(PathBuf::from)
                .or_else(dirs::home_dir)
                .expect("home directory")
                .join(
                    "Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/impress.sqlite",
                )
        })
}

fn open_store(args: &Args) -> (Arc<SqliteItemStore>, PathBuf) {
    let path = match &args.workspace {
        Some(dir) => {
            std::fs::create_dir_all(dir).expect("create workspace dir");
            dir.join("impress.sqlite")
        }
        None => {
            if !args.enable_live {
                eprintln!(
                    "impel-taskd: refusing to touch the LIVE store without --enable.\n\
                     Use --workspace DIR for testing, or pass --enable deliberately."
                );
                std::process::exit(2);
            }
            live_store_path()
        }
    };
    eprintln!("impel-taskd: store = {}", path.display());
    let config = StoreConfig {
        author: ACTOR.to_string(),
        author_kind: ActorKind::Agent,
        ..StoreConfig::default()
    };
    let store = Arc::new(
        SqliteItemStore::open_with_config(&path, config)
            .unwrap_or_else(|e| panic!("open store {}: {e}", path.display())),
    );
    (store, path)
}

/// How long after a terminally-FAILED enrichment DAG an entry becomes
/// eligible for a fresh spawn. The old guard counted "any task ever"
/// (Failed included), so a paper whose enrichment failed during a network
/// outage was never enriched again; its own doc said "one entry is
/// ENRICHED once" while the code latched on attempted-once.
const RESPAWN_COOLOFF_MS: i64 = 24 * 3_600_000;

/// Should the enrichment DAG be spawned for this entry?
///
/// - Any non-terminal or DONE task for the entry → no (enriched, running,
///   or queued already).
/// - Only failed/cancelled tasks → yes, once the newest is older than
///   [`RESPAWN_COOLOFF_MS`] (a bogus-DOI entry retries daily, not per
///   pass).
/// - A query ERROR → no, loudly. The old guard mapped errors to "not
///   spawned", so one transient store error duplicated whole DAGs.
fn should_spawn_enrichment(store: &SqliteItemStore, entry_id: uuid::Uuid) -> bool {
    let q = ItemQuery {
        schema: Some(TASK_SCHEMA.into()),
        predicates: vec![Predicate::HasReference(EdgeType::OperatesOn, entry_id)],
        sort: vec![impress_core::query::SortDescriptor {
            field: "modified".into(),
            ascending: false,
        }],
        limit: Some(16),
        include_tags: false,
        include_references: false,
        ..Default::default()
    };
    let tasks = match ItemStore::query(store, &q) {
        Ok(tasks) => tasks,
        Err(e) => {
            eprintln!("impel-taskd: spawn-guard query failed for {entry_id}: {e}");
            return false;
        }
    };
    if tasks.is_empty() {
        return true;
    }
    let mut newest_terminal_ms = 0_i64;
    for t in &tasks {
        let state = match t.payload.get("state") {
            Some(impress_core::item::Value::String(s)) => s.as_str(),
            _ => "",
        };
        match state {
            "failed" | "cancelled" => {
                newest_terminal_ms = newest_terminal_ms.max(t.modified.timestamp_millis());
            }
            // pending/queued/running/done/completed — or anything
            // unparseable, which a respawn would only duplicate.
            _ => return false,
        }
    }
    chrono::Utc::now().timestamp_millis() - newest_terminal_ms >= RESPAWN_COOLOFF_MS
}

/// Whether a non-terminal `throughline-sync` task is already operating on
/// this throughline item — the per-document debounce. The state filter
/// runs IN SQL: the old shape fetched an arbitrary (unordered) 16 rows
/// and checked client-side, so once a long-lived document accumulated >16
/// terminal sync tasks the open one could fall outside the page and every
/// edit spawned a duplicate concurrent sync (each opening its own review).
fn has_open_sync_task(store: &SqliteItemStore, throughline_id: uuid::Uuid) -> bool {
    use impress_core::item::Value;
    let q = ItemQuery {
        schema: Some(TASK_SCHEMA.into()),
        predicates: vec![
            Predicate::HasReference(EdgeType::OperatesOn, throughline_id),
            Predicate::In(
                "payload.state".into(),
                vec![
                    Value::String("pending".into()),
                    Value::String("queued".into()),
                    Value::String("running".into()),
                ],
            ),
        ],
        limit: Some(1),
        ..Default::default()
    };
    match ItemStore::count(store, &q) {
        Ok(n) => n > 0,
        Err(e) => {
            eprintln!("impel-taskd: sync-debounce query failed for {throughline_id}: {e}");
            true // fail CLOSED: never double-spawn on a store error
        }
    }
}

/// Cross-process trigger detection for throughline sync: manuscript
/// sections MODIFIED since the cursor (edits arrive as operations from
/// the imprint app process, invisible to the in-process bus). Keyset on
/// `(modified, id)` with a real ORDER BY, so any burst pages through
/// instead of wedging on a value-keyed watermark.
fn scan_modified_sections(
    store: &SqliteItemStore,
    after_modified_ms: i64,
    after_id: &str,
) -> Vec<impress_core::item::Item> {
    use impress_core::item::Value;
    use impress_core::query::SortDescriptor;
    let q = ItemQuery {
        schema: Some(MANUSCRIPT_SECTION_SCHEMA.into()),
        predicates: vec![Predicate::Or(vec![
            Predicate::Gt("modified".into(), Value::Int(after_modified_ms)),
            Predicate::And(vec![
                Predicate::Eq("modified".into(), Value::Int(after_modified_ms)),
                Predicate::Gt("id".into(), Value::String(after_id.into())),
            ]),
        ])],
        sort: vec![
            SortDescriptor {
                field: "modified".into(),
                ascending: true,
            },
            SortDescriptor {
                field: "id".into(),
                ascending: true,
            },
        ],
        limit: Some(64),
        include_tags: false,
        include_references: false,
        ..Default::default()
    };
    match ItemStore::query(store, &q) {
        Ok(items) => items,
        Err(e) => {
            eprintln!("impel-taskd: section scan failed: {e}");
            Vec::new()
        }
    }
}

/// The daemon's persisted scan cursors (beside the worker status file).
/// Plain text, versioned; a stale or missing file is harmless — the spawn
/// guard dedupes any replay, and a fresh start re-anchors at the current
/// max rowid.
struct ScanCursors {
    /// Last-seen items ROWID for the bibliography-entry trigger scan.
    /// Rowid — not `created`, not the HLC clock — because both timestamp
    /// keys are preserved verbatim on CloudKit sync-apply (ADR-0007), so
    /// an entry synced from another device arrives "in the past" and a
    /// timestamp watermark never selects it. Rowid is local arrival order.
    entries_rowid: i64,
    /// Keyset cursor for the manuscript-section modification scan.
    sections_modified_ms: i64,
    sections_last_id: String,
}

impl ScanCursors {
    fn path(workspace: &std::path::Path) -> PathBuf {
        impress_ai::worker_runtime_directory(workspace).join("impel-taskd.cursors.v1")
    }

    fn load(workspace: &std::path::Path) -> Option<Self> {
        let text = std::fs::read_to_string(Self::path(workspace)).ok()?;
        let mut parts = text.split_whitespace();
        Some(Self {
            entries_rowid: parts.next()?.parse().ok()?,
            sections_modified_ms: parts.next()?.parse().ok()?,
            sections_last_id: parts.next().unwrap_or("").to_string(),
        })
    }

    /// Best-effort, no fsync: losing the last write only replays a page
    /// through the idempotent spawn guards.
    fn save(&self, workspace: &std::path::Path) {
        let path = Self::path(workspace);
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(
            &path,
            format!(
                "{} {} {}",
                self.entries_rowid, self.sections_modified_ms, self.sections_last_id
            ),
        );
    }
}

/// Days an unresolved review-request may sit before the daemon resolves it
/// as `"expired"` (freeing its suspended task to complete without the
/// proposed action). 0 disables. The review queue is a capacity-bounded
/// checkpoint, not an archive: 1,018 reviews had accumulated unanswered
/// when this was added — ADR-0028 D11 called the pileup out at 546.
fn review_expiry_days() -> i64 {
    std::env::var("IMPEL_REVIEW_EXPIRY_DAYS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(7)
}

/// Resolve unresolved reviews older than the expiry window. Returns how
/// many were expired this sweep (capped, so one sweep never stalls a pass
/// for long — the hourly cadence drains any backlog within a day).
fn expire_stale_reviews(store: &SqliteItemStore, expiry_days: i64, cap: usize) -> usize {
    use impress_core::item::{ActorKind, Value};
    use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
    if expiry_days <= 0 {
        return 0;
    }
    let cutoff = chrono::Utc::now().timestamp_millis() - expiry_days * 86_400_000;
    let mut expired = 0;
    let mut offset = 0;
    while expired < cap {
        let q = ItemQuery {
            schema: Some(impel_core::REVIEW_REQUEST_SCHEMA.into()),
            predicates: vec![Predicate::Lt("created".into(), Value::Int(cutoff))],
            sort: vec![impress_core::query::SortDescriptor {
                field: "created".into(),
                ascending: true,
            }],
            limit: Some(200),
            offset: Some(offset),
            include_tags: false,
            include_references: false,
            ..Default::default()
        };
        let page = match ItemStore::query(store, &q) {
            Ok(page) => page,
            Err(e) => {
                eprintln!("impel-taskd: review-expiry query failed: {e}");
                break;
            }
        };
        let page_len = page.len();
        for review in page {
            let resolved = matches!(review.payload.get("resolution"),
                                    Some(Value::String(s)) if !s.is_empty());
            if resolved {
                continue;
            }
            let write = |field: &str, value: &str| OperationSpec {
                target_id: review.id,
                op_type: OperationType::SetPayload(field.into(), Value::String(value.into())),
                intent: OperationIntent::Routine,
                reason: Some("review expired unanswered".into()),
                batch_id: None,
                author: "impel-taskd/expiry".into(),
                author_kind: ActorKind::Agent,
                retention: RetentionTier::Durable,
            };
            match store.apply_operation_batch(vec![
                write("resolution", "expired"),
                write("resolved_by", "impel-taskd/expiry"),
            ]) {
                Ok(_) => expired += 1,
                Err(e) => eprintln!("impel-taskd: review expiry write failed: {e}"),
            }
            if expired >= cap {
                break;
            }
        }
        if page_len < 200 {
            break;
        }
        offset += 200;
    }
    expired
}

/// One-shot startup heal for the pre-propagation era: pending tasks whose
/// `DependsOn` target terminally failed can never become ready (the
/// readiness SQL blocks on any dep not done) — they sat as invisible
/// zombies. The scheduler now cancels dependents at failure time; this
/// sweeps the strands that already exist.
fn cancel_stranded_dependents(store: &SqliteItemStore) -> usize {
    use impress_core::item::Value;
    use impress_core::task::TaskState;
    let q = ItemQuery {
        schema: Some(TASK_SCHEMA.into()),
        predicates: vec![Predicate::Eq(
            "payload.state".into(),
            Value::String("pending".into()),
        )],
        include_tags: false,
        include_references: true,
        ..Default::default()
    };
    let pending = match ItemStore::query(store, &q) {
        Ok(pending) => pending,
        Err(e) => {
            eprintln!("impel-taskd: stranded-dependent scan failed: {e}");
            return 0;
        }
    };
    let mut cancelled = 0;
    for task in pending {
        let stranded = task
            .references
            .iter()
            .filter(|r| r.edge_type == EdgeType::DependsOn)
            .any(|r| match ItemStore::get(store, r.target) {
                Ok(Some(dep)) => matches!(dep.payload.get("state"),
                                          Some(Value::String(s))
                                              if s == "failed" || s == "cancelled"),
                _ => false,
            });
        if stranded
            && TaskStoreApi::transition(store, task.id, TaskState::Cancelled, ACTOR, None).is_ok()
        {
            cancelled += 1;
        }
    }
    cancelled
}

async fn publish_worker_status(
    status: &Arc<RwLock<WorkerStatusSnapshot>>,
    workspace: &std::path::Path,
    durable: bool,
    mutate: impl FnOnce(&mut WorkerStatusSnapshot),
) {
    let mut status = status.write().await;
    mutate(&mut status);
    status.heartbeat_at_ms = chrono::Utc::now().timestamp_millis();
    // Heartbeats and per-pass publishes use the fast (no-fsync) writer:
    // at two 5s cadences the durable variant was ~34,560 F_FULLFSYNC
    // device flushes a day on the store's own volume. Lifecycle state
    // changes stay durable.
    let result = if durable {
        write_worker_status(workspace, &status)
    } else {
        impress_ai::write_worker_status_fast(workspace, &status)
    };
    if let Err(error) = result {
        eprintln!("impel-taskd: publish worker status failed: {error}");
    }
}

fn accumulate_pass(status: &mut WorkerStatusSnapshot, report: &PassReport) {
    status.last_pass_at_ms = Some(chrono::Utc::now().timestamp_millis());
    status.last_error = None;
    status.acquired_total += report.acquired as u64;
    status.completed_total += report.completed as u64;
    // GAUGE: the current suspended backlog, not a running sum — summing a
    // per-pass re-count of the standing population inflated this by the
    // whole backlog every 5 seconds.
    status.suspended_total = report.suspended as u64;
    status.retried_total += report.retried as u64;
    status.failed_total += report.failed as u64;
    status.resumed_total += report.resumed as u64;
    status.deferred_total += report.deferred as u64;
    status.adopted_total += report.adopted as u64;
    status.cancelled_total += report.cancelled as u64;
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() {
    let args = parse_args();
    let (store, store_path) = open_store(&args);
    let workspace = store_path
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."))
        .to_path_buf();
    let _worker_lease = WorkerLease::acquire(&workspace).unwrap_or_else(|error| {
        eprintln!("impel-taskd: worker lease unavailable: {error}");
        std::process::exit(3);
    });
    let now_ms = chrono::Utc::now().timestamp_millis();
    let worker_status = Arc::new(RwLock::new(WorkerStatusSnapshot::new(
        uuid::Uuid::new_v4().to_string(),
        std::process::id(),
        now_ms,
        args.poll_secs,
        "local-omlx".into(),
    )));
    publish_worker_status(&worker_status, &workspace, true, |_| {}).await;
    let heartbeat_status = worker_status.clone();
    let heartbeat_workspace = workspace.clone();
    let heartbeat_task = tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(WORKER_HEARTBEAT_INTERVAL_SECS)).await;
            publish_worker_status(&heartbeat_status, &heartbeat_workspace, false, |_| {}).await;
        }
    });

    // Executors: credential-free sources by default; ADS joins when a
    // token is supplied (IMPEL_ADS_TOKEN).
    let mut sources = vec![
        ConfiguredSource {
            plugin: Arc::new(ArxivSource::new()),
            credentials: None,
        },
        ConfiguredSource {
            plugin: Arc::new(CrossrefSource::new()),
            credentials: std::env::var("IMPEL_CROSSREF_EMAIL").ok(),
        },
        ConfiguredSource {
            plugin: Arc::new(OpenAlexSource::new()),
            credentials: None,
        },
    ];
    if let Ok(token) = std::env::var("IMPEL_ADS_TOKEN") {
        sources.insert(
            0,
            ConfiguredSource {
                plugin: Arc::new(impress_sources::ads::AdsSource::new()),
                credentials: Some(token),
            },
        );
    }

    let mut scheduler = Scheduler::new(
        store.clone(),
        SchedulerConfig {
            actor: ACTOR.into(),
            batch: 8,
            start_delay: Duration::ZERO, // we manage the delay ourselves below
            poll_interval: Duration::from_secs(args.poll_secs),
            retry_base_ms: SchedulerConfig::default().retry_base_ms,
        },
    );
    if !args.dry_run {
        // Offline-first counsel: iOS can sync a queued `impress.ai.respond`
        // task; this Mac/server consumes it whenever oMLX becomes reachable.
        let ai_store = Arc::new(AiStore::from_store(store.clone(), ACTOR));
        let blob_root = store_path
            .parent()
            .unwrap_or_else(|| std::path::Path::new("."))
            .join("blobs");
        let blob_store = Arc::new(
            FileBlobStore::open(&blob_root)
                .unwrap_or_else(|e| panic!("open blob store {}: {e}", blob_root.display())),
        );
        let omlx_url = std::env::var("IMPRESS_OMLX_URL")
            .unwrap_or_else(|_| impress_ai::omlx::DEFAULT_URL.into());
        let omlx_key = std::env::var("IMPRESS_OMLX_API_KEY").ok();
        let omlx = OmlxClient::with_endpoint_id(omlx_url, omlx_key, "local-omlx")
            .expect("configure oMLX client");
        let title_executor = AiTitleTaskExecutor::new(ai_store.clone(), omlx.clone());
        let mut executor = OmlxTaskExecutor::new(ai_store, omlx, blob_store);
        match ImpressToolAdapter::probe().await {
            Ok(adapter) => {
                let adapter = Arc::new(adapter);
                executor = executor.with_tool_adapter(adapter.clone());
                // Reachability is LIVE: re-probe every 5 minutes so apps
                // launched after daemon start bring their tools online
                // (the old one-shot probe froze the surface for the
                // daemon's whole life).
                tokio::spawn(async move {
                    loop {
                        tokio::time::sleep(Duration::from_secs(300)).await;
                        if let Err(error) = adapter.refresh().await {
                            eprintln!("impel-taskd: tool reachability refresh failed: {error}");
                        }
                    }
                });
            }
            Err(error) => eprintln!("impel-taskd: Impress tool adapter unavailable: {error}"),
        }
        match WebResearchProvider::new() {
            Ok(provider) => executor = executor.with_research_provider(Arc::new(provider)),
            Err(error) => eprintln!("impel-taskd: web research provider unavailable: {error}"),
        }
        scheduler.register(Arc::new(executor));
        scheduler.register(Arc::new(title_executor));
    }
    scheduler.register(Arc::new(MetadataResolveExecutor::new(
        sources,
        SourcePriority::default(),
    )));
    // LLM classifier when IMPEL_LLM_{PROVIDER,MODEL,API_KEY} are set;
    // deterministic heuristic otherwise.
    // The keyword table also stands BEHIND the LLM: when the provider cannot
    // be reached at all, a deterministic verdict recorded under `heuristic-v1`
    // beats both an outage-shaped retry loop and the empty tag set that used to
    // be written under the LLM's own name. `None` when the heuristic already IS
    // the classifier — there is nothing to fall back to.
    let (classifier, fallback): (Arc<dyn Classifier>, Option<Arc<dyn Classifier>>) =
        match impel_enrichment::LlmClassifier::from_env() {
            Some(llm) => {
                eprintln!(
                    "impel-taskd: classifier = {} (fallback heuristic-v1)",
                    llm.model_id()
                );
                (
                    Arc::new(llm),
                    Some(Arc::new(HeuristicClassifier::default_vocabulary())),
                )
            }
            None => {
                eprintln!("impel-taskd: classifier = heuristic-v1 (set IMPEL_LLM_* for LLM)");
                (Arc::new(HeuristicClassifier::default_vocabulary()), None)
            }
        };
    scheduler.register(Arc::new(
        KeywordTagExecutor::new(classifier, args.confidence_threshold).with_fallback(fallback),
    ));
    // Throughline sync (ADR-0016). LLM drafter when IMPEL_LLM_* are set
    // (carries the D6 authority-split contract in its system prompt);
    // deterministic TemplateDrafter otherwise — the review checkpoint
    // carries the drift context either way.
    let drafter: Box<dyn impel_throughline::ProposalDrafter> =
        match impel_throughline::LlmDrafter::from_env() {
            Some(llm) => {
                eprintln!("impel-taskd: throughline drafter = {}", llm.model_id());
                Box::new(llm)
            }
            None => {
                eprintln!(
                    "impel-taskd: throughline drafter = template/v1 (set IMPEL_LLM_* for LLM)"
                );
                Box::new(TemplateDrafter)
            }
        };
    scheduler.register(Arc::new(ThroughlineSyncExecutor::new(drafter)));

    // Memory kernel (ADR-0028 D7). Both executors are gated on env so a deploy
    // of this daemon is inert until switched on deliberately: the embed
    // backfill loads a ~100MB model on first real work, and consolidation
    // writes memory rows the whole suite then recalls.
    //
    // The config is read ONCE, here, and the same value gates registration and
    // planning. Re-reading the environment per pass would let a gate flip
    // mid-run and leave the spawner planning tasks for an executor that was
    // never registered — which the scheduler treats as a misconfiguration and
    // escalates, per task, forever.
    let memory_plan = MemoryPlanConfig::from_env();
    if memory_plan.embed_enabled {
        scheduler.register(Arc::new(EmbedBackfillExecutor::new(store.clone())));
        eprintln!(
            "impel-taskd: memory embed backfill ON (model {})",
            memory_plan.model
        );
    } else {
        eprintln!(
            "impel-taskd: memory embed backfill off (set {}=1)",
            impel_memory::spawn::EMBED_ENV
        );
    }
    if memory_plan.consolidate_enabled {
        use impel_memory::ClaimDistiller as _;
        let distiller: Option<Arc<dyn impel_memory::ClaimDistiller>> =
            match impel_memory::LlmDistiller::from_env() {
                Some(distiller) => {
                    eprintln!(
                        "impel-taskd: memory consolidation ON (deterministic + LLM claim tier: {})",
                        distiller.model_id()
                    );
                    Some(Arc::new(distiller))
                }
                None => {
                    eprintln!(
                        "impel-taskd: memory consolidation ON (deterministic tier; set IMPEL_LLM_PROVIDER/MODEL/API_KEY for the claim tier)"
                    );
                    None
                }
            };
        scheduler.register(Arc::new(
            MemoryConsolidationExecutor::new(store.clone()).with_claim_distiller(distiller),
        ));
    } else {
        eprintln!(
            "impel-taskd: memory consolidation off (set {}=1)",
            impel_memory::spawn::CONSOLIDATE_ENV
        );
    }
    if args.dry_run && (memory_plan.embed_enabled || memory_plan.consolidate_enabled) {
        // Said once at startup rather than every poll: planning a memory sweep
        // IS the write (the task item carries its own window), so unlike the
        // spawn rules above there is nothing for --dry-run to describe.
        eprintln!("impel-taskd[dry]: memory sweeps are not planned in dry-run mode");
    }

    // Subscribe BEFORE the start delay so no Created events are missed.
    let events = ItemStore::subscribe(
        store.as_ref(),
        ItemQuery {
            schema: Some(BIBLIOGRAPHY_ENTRY_SCHEMA.into()),
            ..Default::default()
        },
    )
    .expect("subscribe");

    let delay = args
        .start_delay
        .unwrap_or(if args.workspace.is_some() { 0 } else { 90 });
    if delay > 0 {
        eprintln!("impel-taskd: start delay {delay}s (startup-settling guard)");
        publish_worker_status(&worker_status, &workspace, true, |status| {
            status.state = WorkerLifecycleState::Settling;
        })
        .await;
        tokio::time::sleep(Duration::from_secs(delay)).await;
    }

    let rule = EnrichmentSpawnRule;
    let tl_rule = ThroughlineSpawnRule;

    // ── Scan cursors (persisted; see ScanCursors) ──────────────────────
    //
    // NO BACKFILL BURST, still: with the default `backfill_hours == 0` a
    // fresh cursor anchors at the CURRENT max rowid, so existing libraries
    // are invisible to the scan and only genuinely new arrivals spawn.
    // Backfilling is opt-in via `--backfill H` (cursor anchored just before
    // the first entry created inside the window) and pages through at 64
    // rows per pass — a burst of ANY size drains, because the rowid keyset
    // paginates instead of re-selecting the same value-keyed window.
    // `should_spawn_enrichment` keeps every replay idempotent. Touching the
    // live store additionally requires `--enable`.
    //
    // NO SPELLING-MIGRATION BURST EITHER. WP C4 converged `impel/task` onto
    // `task@1.0.0`, which is the ref `ready_tasks` selects — so rows impel's
    // Swift bridge mirrors into the shared store became visible to the
    // scheduler for the first time. They are NOT acquired: `ready_tasks` also
    // requires a non-empty payload `task_kind` (the executor dispatch key), and
    // a mirror row carries none because impel's own orchestrator runs it.
    let mut cursors = match ScanCursors::load(&workspace) {
        Some(c) => c,
        None => {
            let entries_rowid = if args.backfill_hours > 0 {
                let cutoff = chrono::Utc::now().timestamp_millis()
                    - (args.backfill_hours as i64) * 3_600_000;
                store
                    .rowid_before_created(BIBLIOGRAPHY_ENTRY_SCHEMA, cutoff)
                    .unwrap_or(0)
            } else {
                store.max_rowid().unwrap_or(0)
            };
            ScanCursors {
                entries_rowid,
                // Throughline sync watches section MODIFICATIONS and never
                // backfills — pre-daemon drift is picked up on the next
                // edit. Small slack for the insert-vs-startup race.
                sections_modified_ms: chrono::Utc::now().timestamp_millis() - 60_000,
                sections_last_id: String::new(),
            }
        }
    };

    // One-shot heal: cancel pending tasks stranded behind terminally
    // failed dependencies from before failure propagation existed.
    if !args.dry_run {
        let healed = cancel_stranded_dependents(&store);
        if healed > 0 {
            eprintln!(
                "impel-taskd: cancelled {healed} task(s) stranded behind failed dependencies"
            );
        }
    }

    let expiry_days = review_expiry_days();
    let mut last_expiry_sweep = std::time::Instant::now() - Duration::from_secs(3600);
    let mut last_generation: i64 = -1;
    let mut last_report: Option<PassReport> = None;
    eprintln!(
        "impel-taskd: running (dry_run={}, once={}, poll={}s, backfill={}h, review_expiry={}d, entries_cursor={})",
        args.dry_run, args.once, args.poll_secs, args.backfill_hours, expiry_days,
        cursors.entries_rowid
    );
    publish_worker_status(&worker_status, &workspace, true, |status| {
        status.state = WorkerLifecycleState::Ready;
    })
    .await;

    loop {
        // ── Generation probe ───────────────────────────────────────────
        // Every store mutation inserts at least an operation row, so an
        // unchanged max rowid means the scans below cannot find anything
        // new — skip them. (The scheduler pass still runs: retry backoff
        // eligibility moves with TIME, not with store writes.)
        let generation = store.max_rowid().unwrap_or(-1);
        let store_changed = generation != last_generation || generation < 0;
        last_generation = generation;

        // Drain in-process trigger events (same-process inserts, less lag
        // than the scan).
        let mut trigger_items: Vec<impress_core::item::Item> = Vec::new();
        loop {
            match events.try_recv() {
                Ok(ItemEvent::Created(item)) => trigger_items.push(*item),
                Ok(_) => {}
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    eprintln!("impel-taskd: event bus disconnected; exiting");
                    heartbeat_task.abort();
                    publish_worker_status(&worker_status, &workspace, true, |status| {
                        status.state = WorkerLifecycleState::Failed;
                        status.last_error = Some("store event bus disconnected".into());
                    })
                    .await;
                    return;
                }
            }
        }

        if store_changed || !trigger_items.is_empty() {
            // ── Cross-process entry scan (rowid keyset) ────────────────
            match store.items_arrived_after(BIBLIOGRAPHY_ENTRY_SCHEMA, cursors.entries_rowid, 64) {
                Ok(page) => {
                    for (rowid, item) in page {
                        cursors.entries_rowid = cursors.entries_rowid.max(rowid);
                        trigger_items.push(item);
                    }
                }
                Err(e) => eprintln!("impel-taskd: entry scan failed: {e}"),
            }

            // Spawn DAGs for new triggers.
            for item in trigger_items {
                if !should_spawn_enrichment(&store, item.id) {
                    continue;
                }
                match rule.spawn(&item, store.as_ref() as &dyn TaskStoreApi).await {
                    Ok(specs) if !specs.is_empty() => {
                        if args.dry_run {
                            eprintln!(
                                "impel-taskd[dry]: would spawn {} task(s) for {}",
                                specs.len(),
                                item.id
                            );
                        } else {
                            match create_task_dag_from(
                                store.as_ref() as &dyn TaskStoreApi,
                                &specs,
                                ACTOR,
                                Some(&SpawnProvenance {
                                    rule_id: rule.rule_id().into(),
                                    trigger: Some(item.id),
                                }),
                            ) {
                                Ok(ids) => eprintln!(
                                    "impel-taskd: spawned {} task(s) for {}: {ids:?}",
                                    ids.len(),
                                    item.id
                                ),
                                Err(e) => {
                                    eprintln!("impel-taskd: spawn failed for {}: {e}", item.id)
                                }
                            }
                        }
                    }
                    Ok(_) => {}
                    Err(e) => eprintln!("impel-taskd: rule error for {}: {e}", item.id),
                }
            }

            // ── Throughline sync triggers (ADR-0016) ───────────────────
            // Sections modified since the cursor. The spawn rule's first
            // act is the D1 opt-in gate (one keyed get), so this scan
            // costs nothing for documents without a throughline.
            // `has_open_sync_task` debounces concurrent spawns per
            // document.
            let tl_scanned = scan_modified_sections(
                &store,
                cursors.sections_modified_ms,
                &cursors.sections_last_id,
            );
            for section in tl_scanned {
                cursors.sections_modified_ms = section.modified.timestamp_millis();
                cursors.sections_last_id = section.id.to_string();
                let Some(impress_core::item::Value::String(doc_str)) =
                    section.payload.get("document_id")
                else {
                    continue;
                };
                let Ok(doc_id) = doc_str.parse::<uuid::Uuid>() else {
                    continue;
                };
                let tl_id = imprint_service::ThroughlineStore::item_id(doc_id);
                if has_open_sync_task(&store, tl_id) {
                    continue;
                }
                match tl_rule
                    .spawn(&section, store.as_ref() as &dyn TaskStoreApi)
                    .await
                {
                    Ok(specs) if !specs.is_empty() => {
                        if args.dry_run {
                            eprintln!(
                                "impel-taskd[dry]: would spawn throughline-sync for doc {doc_id}"
                            );
                        } else {
                            match create_task_dag_from(
                                store.as_ref() as &dyn TaskStoreApi,
                                &specs,
                                ACTOR,
                                // Trigger is the edited SECTION; the task
                                // operates on the throughline. Recording
                                // both is what makes "why did this run?"
                                // answerable.
                                Some(&SpawnProvenance {
                                    rule_id: tl_rule.rule_id().into(),
                                    trigger: Some(section.id),
                                }),
                            ) {
                                Ok(ids) => eprintln!(
                                    "impel-taskd: spawned throughline-sync for doc {doc_id}: {ids:?}"
                                ),
                                Err(e) => eprintln!(
                                    "impel-taskd: throughline spawn failed for {doc_id}: {e}"
                                ),
                            }
                        }
                    }
                    Ok(_) => {}
                    Err(e) => eprintln!("impel-taskd: throughline rule error for {doc_id}: {e}"),
                }
            }
            cursors.save(&workspace);

            // ── Memory kernel sweeps (ADR-0028 D7/D8) ──────────────────
            // Not a scan: the spawner reads the completed task chain for
            // its own watermark and spawns at most one task of each kind.
            //
            // Log-and-continue, like every other rule in this loop: a
            // planning failure must not take down a pass that still has
            // enrichment and throughline work to do.
            if !args.dry_run {
                match plan_memory_tasks(&store, chrono::Utc::now().timestamp_millis(), &memory_plan)
                {
                    Ok(ids) if !ids.is_empty() => {
                        eprintln!("impel-taskd: spawned {} memory task(s): {ids:?}", ids.len())
                    }
                    Ok(_) => {}
                    Err(e) => eprintln!("impel-taskd: memory planning failed: {e}"),
                }
            }
        }

        // ── Review expiry (hourly) ─────────────────────────────────────
        // The checkpoint queue is capacity-bounded, not an archive: an
        // unanswered review eventually resolves as "expired" and its
        // suspended task completes without the proposed action.
        if !args.dry_run && last_expiry_sweep.elapsed() >= Duration::from_secs(3600) {
            last_expiry_sweep = std::time::Instant::now();
            let expired = expire_stale_reviews(&store, expiry_days, 500);
            if expired > 0 {
                eprintln!("impel-taskd: expired {expired} unanswered review(s) (> {expiry_days}d)");
            }
        }

        // One scheduler pass.
        if args.dry_run {
            match TaskStoreApi::ready_tasks(store.as_ref(), 8) {
                Ok(ready) if !ready.is_empty() => {
                    eprintln!("impel-taskd[dry]: {} task(s) ready", ready.len())
                }
                Ok(_) => {}
                Err(e) => eprintln!("impel-taskd[dry]: ready query failed: {e}"),
            }
            publish_worker_status(&worker_status, &workspace, false, |status| {
                status.last_pass_at_ms = Some(chrono::Utc::now().timestamp_millis());
            })
            .await;
        } else {
            match scheduler.run_once().await {
                Ok(r) => {
                    // Log on CHANGE, not on any-nonzero: a standing
                    // suspended backlog made every idle pass "nonzero" and
                    // grew the log by an identical line every 5 seconds
                    // (35 MB before this was fixed).
                    if last_report.as_ref() != Some(&r) {
                        eprintln!(
                            "impel-taskd[{}]: pass acquired={} completed={} suspended={} resumed={} retried={} failed={} deferred={} adopted={} cancelled={}",
                            chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ"),
                            r.acquired, r.completed, r.suspended, r.resumed, r.retried,
                            r.failed, r.deferred, r.adopted, r.cancelled
                        );
                    }
                    publish_worker_status(&worker_status, &workspace, false, |status| {
                        accumulate_pass(status, &r);
                    })
                    .await;
                    last_report = Some(r);
                }
                Err(e) => {
                    eprintln!("impel-taskd: scheduler pass failed: {e}");
                    last_report = None;
                    publish_worker_status(&worker_status, &workspace, false, |status| {
                        status.last_pass_at_ms = Some(chrono::Utc::now().timestamp_millis());
                        status.last_error = Some(e.to_string());
                    })
                    .await;
                }
            }
        }

        if args.once {
            eprintln!("impel-taskd: --once pass complete; exiting");
            heartbeat_task.abort();
            publish_worker_status(&worker_status, &workspace, true, |status| {
                status.state = WorkerLifecycleState::Stopping;
            })
            .await;
            return;
        }
        tokio::time::sleep(Duration::from_secs(args.poll_secs)).await;
    }
}
