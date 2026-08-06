use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use impress_ai::{migrate_localmodels, AiStore, FileBlobStore, OmlxClient};
use impress_ai_http::{router, AiHttpState};
use impress_core::item::ActorKind;
use impress_core::sqlite_store::WalCheckpointMode;

#[tokio::main]
async fn main() {
    let access_token = std::env::var("IMPRESS_AI_ACCESS_TOKEN")
        .expect("IMPRESS_AI_ACCESS_TOKEN is required (minimum 24 characters)");
    let bind: SocketAddr = std::env::var("IMPRESS_AI_BIND")
        .unwrap_or_else(|_| "127.0.0.1:23125".into())
        .parse()
        .expect("IMPRESS_AI_BIND must be a socket address");
    let store_path = std::env::var_os("IMPRESS_STORE_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(default_store_path);
    let blob_path = store_path
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."))
        .join("blobs");
    let ai = Arc::new(
        AiStore::open(&store_path, "impress-ai-http", ActorKind::Agent)
            .unwrap_or_else(|error| panic!("open {}: {error}", store_path.display())),
    );
    let blobs = Arc::new(
        FileBlobStore::open(&blob_path)
            .unwrap_or_else(|error| panic!("open {}: {error}", blob_path.display())),
    );
    if let Some(source) = std::env::var_os("IMPRESS_LOCALMODELS_IMPORT").map(PathBuf::from) {
        let report = migrate_localmodels(ai.shared_store(), blobs.as_ref(), &source, false)
            .unwrap_or_else(|error| panic!("import {}: {error}", source.display()));
        eprintln!(
            "impress-ai-server: LocalModels import discovered={} imported={} unchanged={} changed={} failed={}",
            report.discovered,
            report.imported,
            report.skipped_unchanged,
            report.changed_after_import,
            report.failed
        );
        if std::env::var("IMPRESS_LOCALMODELS_IMPORT_ONLY").as_deref() == Ok("1") {
            return;
        }
    }
    let omlx_url =
        std::env::var("IMPRESS_OMLX_URL").unwrap_or_else(|_| impress_ai::omlx::DEFAULT_URL.into());
    let omlx_key = std::env::var("IMPRESS_OMLX_API_KEY").ok();
    let omlx = OmlxClient::with_endpoint_id(omlx_url, omlx_key, "local-omlx")
        .expect("configure oMLX client");
    // WAL maintenance (2026-08-05 incident): this daemon is the suite's
    // always-on process, so it OWNS the checkpoint cadence. Every process's
    // passive auto-checkpoints yield to the fleet's pooled readers, so
    // without an explicit owner the shared WAL grows unbounded (it reached
    // 13.5 GB), and any post-crash opener then rebuilds the wal-index over
    // the whole file — the suite-wide silent hang. A truncating checkpoint
    // every five minutes keeps the file near zero; when readers are busy the
    // attempt reports incomplete and the next tick retries.
    let maintenance_store = ai.shared_store();
    // Operation compaction window (days). Compactable routine ops older than
    // this fold into durable watermark snapshots (ADR-0006); the last window
    // of fine-grained history is always kept. 0 disables compaction.
    let compact_window_days: u32 = std::env::var("IMPRESS_COMPACT_WINDOW_DAYS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(30);
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(300));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        // Daily compaction, expressed in 5-minute ticks; the first tick also
        // compacts so a fresh deploy converges without waiting a day.
        const COMPACT_EVERY_TICKS: u64 = 288;
        let mut tick: u64 = 0;
        let mut did_vacuum = false;
        loop {
            ticker.tick().await;

            if compact_window_days > 0 && tick.is_multiple_of(COMPACT_EVERY_TICKS) {
                // Demote-then-compact. Demotion (durable system-routine ops →
                // compactable) is idempotent and cheap once the 2026-08-06
                // backlog is gone, but it stays in the cadence: apps built
                // against the old impress-core keep minting durable routine
                // churn until their frameworks rebuild, and compaction can
                // only fold what is marked compactable.
                let store = maintenance_store.clone();
                match tokio::task::spawn_blocking(move || store.demote_routine_operations()).await {
                    Ok(Ok(0)) => {}
                    Ok(Ok(demoted)) => {
                        eprintln!("impress-ai-server: demoted {demoted} routine ops to compactable")
                    }
                    Ok(Err(error)) => {
                        eprintln!("impress-ai-server: routine-op demotion failed: {error}")
                    }
                    Err(join_error) => {
                        eprintln!("impress-ai-server: demotion task failed: {join_error}")
                    }
                }

                let store = maintenance_store.clone();
                let compacted = tokio::task::spawn_blocking(move || {
                    store.compact_operations(compact_window_days)
                })
                .await;
                match compacted {
                    Ok(Ok(removed)) if removed > 0 => eprintln!(
                        "impress-ai-server: compacted {removed} operations \
                         (window {compact_window_days}d)"
                    ),
                    Ok(Ok(_)) => {}
                    Ok(Err(error)) => {
                        eprintln!("impress-ai-server: operation compaction failed: {error}")
                    }
                    Err(join_error) => {
                        eprintln!("impress-ai-server: compaction task failed: {join_error}")
                    }
                }
            }
            tick += 1;

            let store = maintenance_store.clone();
            let checkpoint = tokio::task::spawn_blocking(move || {
                store.checkpoint_wal(WalCheckpointMode::Truncate)
            })
            .await;
            match checkpoint {
                Ok(Ok(outcome)) if outcome.completed => {
                    if outcome.total_frames > 0 {
                        eprintln!(
                            "impress-ai-server: WAL checkpoint truncated {} frames",
                            outcome.checkpointed_frames
                        );
                    }
                }
                Ok(Ok(outcome)) => eprintln!(
                    "impress-ai-server: WAL checkpoint incomplete ({} of {} frames) — will retry",
                    outcome.checkpointed_frames, outcome.total_frames
                ),
                Ok(Err(error)) => {
                    eprintln!("impress-ai-server: WAL checkpoint failed: {error}")
                }
                Err(join_error) => {
                    eprintln!("impress-ai-server: WAL checkpoint task failed: {join_error}")
                }
            }

            // Reclaim disk after mass deletion: when compaction (or any other
            // writer) has left a substantial freelist, VACUUM once per
            // process run. 100k pages ≈ 400 MB — small stores never trigger
            // this; the 2026-08-06 recovery (22M+ compacted ops) does.
            if !did_vacuum {
                let store = maintenance_store.clone();
                let free = tokio::task::spawn_blocking(move || store.freelist_pages())
                    .await
                    .ok()
                    .and_then(Result::ok)
                    .unwrap_or(0);
                if free > 100_000 {
                    did_vacuum = true;
                    eprintln!(
                        "impress-ai-server: VACUUM starting ({} free pages to reclaim)",
                        free
                    );
                    let store = maintenance_store.clone();
                    let vacuumed = tokio::task::spawn_blocking(move || store.vacuum()).await;
                    match vacuumed {
                        Ok(Ok(())) => eprintln!("impress-ai-server: VACUUM complete"),
                        Ok(Err(error)) => eprintln!("impress-ai-server: VACUUM failed: {error}"),
                        Err(join_error) => {
                            eprintln!("impress-ai-server: VACUUM task failed: {join_error}")
                        }
                    }
                }
            }
        }
    });

    let state = AiHttpState::new(ai, omlx, blobs, access_token).expect("configure HTTP state");
    let listener = tokio::net::TcpListener::bind(bind)
        .await
        .unwrap_or_else(|error| panic!("bind {bind}: {error}"));
    eprintln!("impress-ai-server: listening on http://{bind}");
    axum::serve(listener, router(state))
        .await
        .expect("serve Impress AI HTTP adapter");
}

fn default_store_path() -> PathBuf {
    host_home_dir()
        .expect("home directory")
        .join("Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/impress.sqlite")
}

fn host_home_dir() -> Option<PathBuf> {
    // `dirs::home_dir()` follows NSHomeDirectory on macOS, which resolves to
    // the app container for a sandboxed helper. launchd preserves the login
    // user's HOME and that is the base of the shared app-group directory.
    std::env::var_os("HOME")
        .filter(|home| !home.is_empty())
        .map(PathBuf::from)
        .or_else(dirs::home_dir)
}
