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
    create_task_dag, PassReport, Scheduler, SchedulerConfig, SpawnRule, TaskStoreApi, TASK_SCHEMA,
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

/// Tasks already spawned for this entry? (idempotency guard)
/// Whether a non-terminal `throughline-sync` task is already operating on
/// this throughline item. Unlike `already_spawned` (once-ever semantics for
/// enrichment), throughlines sync repeatedly over a document's life — the
/// gate is only against CONCURRENT open tasks, and doubles as the loop's
/// per-document debounce.
fn has_open_sync_task(store: &SqliteItemStore, throughline_id: uuid::Uuid) -> bool {
    let q = ItemQuery {
        schema: Some(TASK_SCHEMA.into()),
        predicates: vec![Predicate::HasReference(
            EdgeType::OperatesOn,
            throughline_id,
        )],
        limit: Some(16),
        ..Default::default()
    };
    let tasks = ItemStore::query(store, &q).unwrap_or_default();
    tasks.iter().any(|t| {
        matches!(t.payload.get("state"),
                 Some(impress_core::item::Value::String(s))
                     if s == "pending" || s == "running")
    })
}

/// Cross-process trigger detection for throughline sync: manuscript
/// sections MODIFIED since the watermark (edits arrive as operations from
/// the imprint app process, invisible to the in-process bus).
fn scan_modified_sections(store: &SqliteItemStore, since_ms: i64) -> Vec<impress_core::item::Item> {
    let q = ItemQuery {
        schema: Some(MANUSCRIPT_SECTION_SCHEMA.into()),
        predicates: vec![Predicate::Gte(
            "modified".into(),
            impress_core::item::Value::Int(since_ms),
        )],
        limit: Some(64),
        ..Default::default()
    };
    ItemStore::query(store, &q).unwrap_or_default()
}

fn already_spawned(store: &SqliteItemStore, entry_id: uuid::Uuid) -> bool {
    let q = ItemQuery {
        schema: Some(TASK_SCHEMA.into()),
        predicates: vec![Predicate::HasReference(EdgeType::OperatesOn, entry_id)],
        limit: Some(1),
        ..Default::default()
    };
    matches!(ItemStore::count(store, &q), Ok(n) if n > 0)
}

/// Cross-process trigger detection: the in-process event bus can't see
/// inserts made by OTHER processes (imbib), so each loop also scans for
/// entries created since the watermark. `already_spawned` makes the
/// overlap harmless.
fn scan_new_entries(store: &SqliteItemStore, since_ms: i64) -> Vec<impress_core::item::Item> {
    let q = ItemQuery {
        schema: Some(BIBLIOGRAPHY_ENTRY_SCHEMA.into()),
        predicates: vec![Predicate::Gte(
            "created".into(),
            impress_core::item::Value::Int(since_ms),
        )],
        limit: Some(64),
        ..Default::default()
    };
    ItemStore::query(store, &q).unwrap_or_default()
}

async fn publish_worker_status(
    status: &Arc<RwLock<WorkerStatusSnapshot>>,
    workspace: &std::path::Path,
    mutate: impl FnOnce(&mut WorkerStatusSnapshot),
) {
    let mut status = status.write().await;
    mutate(&mut status);
    status.heartbeat_at_ms = chrono::Utc::now().timestamp_millis();
    if let Err(error) = write_worker_status(workspace, &status) {
        eprintln!("impel-taskd: publish worker status failed: {error}");
    }
}

fn accumulate_pass(status: &mut WorkerStatusSnapshot, report: &PassReport) {
    status.last_pass_at_ms = Some(chrono::Utc::now().timestamp_millis());
    status.last_error = None;
    status.acquired_total += report.acquired as u64;
    status.completed_total += report.completed as u64;
    status.suspended_total += report.suspended as u64;
    status.retried_total += report.retried as u64;
    status.failed_total += report.failed as u64;
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
    publish_worker_status(&worker_status, &workspace, |_| {}).await;
    let heartbeat_status = worker_status.clone();
    let heartbeat_workspace = workspace.clone();
    let heartbeat_task = tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(WORKER_HEARTBEAT_INTERVAL_SECS)).await;
            publish_worker_status(&heartbeat_status, &heartbeat_workspace, |_| {}).await;
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
            Ok(adapter) => executor = executor.with_tool_adapter(Arc::new(adapter)),
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
    let classifier: Arc<dyn impel_enrichment::Classifier> =
        match impel_enrichment::LlmClassifier::from_env() {
            Some(llm) => {
                eprintln!("impel-taskd: classifier = {}", llm.model_id());
                Arc::new(llm)
            }
            None => {
                eprintln!("impel-taskd: classifier = heuristic-v1 (set IMPEL_LLM_* for LLM)");
                Arc::new(HeuristicClassifier::default_vocabulary())
            }
        };
    scheduler.register(Arc::new(KeywordTagExecutor::new(
        classifier,
        args.confidence_threshold,
    )));
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
        publish_worker_status(&worker_status, &workspace, |status| {
            status.state = WorkerLifecycleState::Settling;
        })
        .await;
        tokio::time::sleep(Duration::from_secs(delay)).await;
    }

    let rule = EnrichmentSpawnRule;
    let tl_rule = ThroughlineSpawnRule;
    // Watermark for the cross-process scan (ms since epoch). A generous
    // slack window guards against clock skew and the insert-vs-startup
    // race; `already_spawned` makes re-scanning the overlap free.
    //
    // NO BACKFILL BURST. The enrichment trigger only started matching real
    // rows on 2026-07-29 (BIBLIOGRAPHY_ENTRY_SCHEMA had been a spelling
    // nothing wrote), so the obvious worry is that the first run over an
    // existing library spawns two tasks per entry — thousands of them. It
    // does not, and the bound is this watermark: with the default
    // `backfill_hours == 0` it starts at `now - SCAN_SLACK_MS`, and
    // `scan_new_entries` filters `created >= watermark` against the INTEGER
    // `items.created` column (ms, same units), so entries created before the
    // last 60 seconds are never selected. Existing libraries are invisible to
    // the scan; only genuinely new inserts spawn. Backfilling is opt-in via
    // `--backfill H`, itself bounded to 64 entries per poll pass by the query
    // limit and made idempotent by `already_spawned` (once-ever per entry).
    // Touching the live store additionally requires `--enable`. If you widen
    // any of those, re-do this arithmetic.
    //
    // NO SPELLING-MIGRATION BURST EITHER. WP C4 converged `impel/task` onto
    // `task@1.0.0`, which is the ref `ready_tasks` selects — so rows impel's
    // Swift bridge mirrors into the shared store became visible to the
    // scheduler for the first time. They are NOT acquired: `ready_tasks` also
    // requires a non-empty payload `task_kind` (the executor dispatch key), and
    // a mirror row carries none because impel's own orchestrator runs it. Run
    // `impress_core::task_schema_migration::migrate_task_spellings(store, true)`
    // — a dry run — to see the count before flipping anything; its
    // `newly_schedulable` is exactly what the next pass here will acquire, and
    // `batch: 8` per `--poll` interval bounds the drain either way.
    const SCAN_SLACK_MS: i64 = 60_000;
    let mut watermark_ms = chrono::Utc::now().timestamp_millis()
        - (args.backfill_hours as i64) * 3_600_000
        - SCAN_SLACK_MS;
    // Throughline sync watches section MODIFICATIONS (not creations) and
    // never backfills — pre-daemon drift is picked up on the next edit.
    let mut tl_watermark_ms = chrono::Utc::now().timestamp_millis() - SCAN_SLACK_MS;
    eprintln!(
        "impel-taskd: running (dry_run={}, once={}, poll={}s, backfill={}h)",
        args.dry_run, args.once, args.poll_secs, args.backfill_hours
    );
    publish_worker_status(&worker_status, &workspace, |status| {
        status.state = WorkerLifecycleState::Ready;
    })
    .await;

    loop {
        // Cross-process pass: entries created since the watermark. The
        // in-process bus below covers same-process inserts with less lag.
        let scanned = scan_new_entries(&store, watermark_ms);
        let mut trigger_items: Vec<impress_core::item::Item> = scanned;
        for item in &trigger_items {
            // Advance the watermark but keep the slack window trailing it.
            watermark_ms = watermark_ms.max(item.created.timestamp_millis() - SCAN_SLACK_MS);
        }

        // Drain in-process trigger events into the same list.
        loop {
            match events.try_recv() {
                Ok(ItemEvent::Created(item)) => trigger_items.push(*item),
                Ok(_) => {}
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    eprintln!("impel-taskd: event bus disconnected; exiting");
                    heartbeat_task.abort();
                    publish_worker_status(&worker_status, &workspace, |status| {
                        status.state = WorkerLifecycleState::Failed;
                        status.last_error = Some("store event bus disconnected".into());
                    })
                    .await;
                    return;
                }
            }
        }

        // Spawn DAGs for new triggers.
        for item in trigger_items {
            if already_spawned(&store, item.id) {
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
                        match create_task_dag(store.as_ref() as &dyn TaskStoreApi, &specs, ACTOR) {
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

        // ── Throughline sync triggers (ADR-0016) ───────────────────────
        // Sections modified since the watermark. The spawn rule's first
        // act is the D1 opt-in gate (one keyed get), so this scan costs
        // nothing for documents without a throughline. `has_open_sync_task`
        // debounces concurrent spawns per document.
        let tl_scanned = scan_modified_sections(&store, tl_watermark_ms);
        for section in tl_scanned {
            tl_watermark_ms =
                tl_watermark_ms.max(section.modified.timestamp_millis() - SCAN_SLACK_MS);
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
                        match create_task_dag(store.as_ref() as &dyn TaskStoreApi, &specs, ACTOR) {
                            Ok(ids) => eprintln!(
                                "impel-taskd: spawned throughline-sync for doc {doc_id}: {ids:?}"
                            ),
                            Err(e) => {
                                eprintln!("impel-taskd: throughline spawn failed for {doc_id}: {e}")
                            }
                        }
                    }
                }
                Ok(_) => {}
                Err(e) => eprintln!("impel-taskd: throughline rule error for {doc_id}: {e}"),
            }
        }

        // ── Memory kernel sweeps (ADR-0028 D7/D8) ──────────────────────
        // Not a scan: the spawner reads the completed task chain for its own
        // watermark and spawns at most one task of each kind. Both gates off
        // (the default) makes this two `if`s and no query at all.
        //
        // Log-and-continue, like every other rule in this loop: a planning
        // failure must not take down a pass that still has enrichment and
        // throughline work to do.
        if !args.dry_run {
            match plan_memory_tasks(&store, chrono::Utc::now().timestamp_millis(), &memory_plan) {
                Ok(ids) if !ids.is_empty() => {
                    eprintln!("impel-taskd: spawned {} memory task(s): {ids:?}", ids.len())
                }
                Ok(_) => {}
                Err(e) => eprintln!("impel-taskd: memory planning failed: {e}"),
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
            publish_worker_status(&worker_status, &workspace, |status| {
                status.last_pass_at_ms = Some(chrono::Utc::now().timestamp_millis());
            })
            .await;
        } else {
            match scheduler.run_once().await {
                Ok(r) => {
                    if r.acquired + r.completed + r.suspended + r.resumed + r.retried + r.failed > 0
                    {
                        eprintln!(
                            "impel-taskd: pass acquired={} completed={} suspended={} resumed={} retried={} failed={}",
                            r.acquired, r.completed, r.suspended, r.resumed, r.retried, r.failed
                        );
                    }
                    publish_worker_status(&worker_status, &workspace, |status| {
                        accumulate_pass(status, &r);
                    })
                    .await;
                }
                Err(e) => {
                    eprintln!("impel-taskd: scheduler pass failed: {e}");
                    publish_worker_status(&worker_status, &workspace, |status| {
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
            publish_worker_status(&worker_status, &workspace, |status| {
                status.state = WorkerLifecycleState::Stopping;
            })
            .await;
            return;
        }
        tokio::time::sleep(Duration::from_secs(args.poll_secs)).await;
    }
}
