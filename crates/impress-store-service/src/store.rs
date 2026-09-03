//! The shared `impress.sqlite` handle these services run against.
//!
//! Store-generic services are NOT app-gated: they open the store directly and
//! work with every app closed, which is exactly why they belong in their own
//! crate rather than behind one app's HTTP backend.
//!
//! The path resolves the same way `impress-mcp` resolves it — the app-group
//! container — with two escape hatches for embedders and tests:
//!
//! * [`set_store_path`] records a path *without* opening anything, so a host
//!   that parses `--store-path` can point the services at it with zero startup
//!   cost (the store opens lazily on the first tool call);
//! * [`install_store`] injects an already-open store (tests use a temp or
//!   in-memory one, as does anything embedding this crate in-process).
//!
//! Service structs also accept a store directly (`with_store`), which is how
//! the unit tests avoid the singleton entirely.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use impress_core::sqlite_store::SqliteItemStore;

static STORE_PATH: OnceLock<PathBuf> = OnceLock::new();

/// Where the shared store lives when nothing overrides it. The
/// `IMPRESS_STORE_PATH` environment variable wins, then the app-group
/// container path every other consumer in the suite uses.
pub fn default_store_path() -> PathBuf {
    if let Ok(p) = std::env::var("IMPRESS_STORE_PATH") {
        return PathBuf::from(p);
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/impress.sqlite")
}

/// Point the services at `path`, lazily. Call before the first service
/// dispatch; returns `Err` if a path or store was already fixed.
pub fn set_store_path(path: impl AsRef<Path>) -> Result<(), String> {
    STORE_PATH
        .set(path.as_ref().to_path_buf())
        .map_err(|_| "impress store path already set".to_string())
}

/// The path the services will use (or are using).
pub fn store_path() -> PathBuf {
    STORE_PATH.get().cloned().unwrap_or_else(default_store_path)
}

/// Install an already-open store. Returns `Err` if one is already installed
/// (injected here, or opened lazily by an earlier [`store_instance`] call).
pub fn install_store(store: Arc<SqliteItemStore>) -> Result<(), String> {
    GLOBAL.install(store)
}

/// Whether the store [`store_instance`] most recently handed out was the
/// in-memory fallback. Read this right after acquiring, before any operation
/// whose ANSWER must be about the real store — the collections migration
/// refuses to run when it is `true`, because a migration that "succeeds"
/// against an empty substitute is a lie about the user's data (found live: a
/// TCC-blocked open during the first real flip attempt produced `rows: 0`
/// across the board).
pub fn store_is_fallback() -> bool {
    GLOBAL.handed_fallback.load(Ordering::Relaxed)
}

/// How long [`store_instance`] lets `SqliteItemStore::open` run before
/// substituting the fallback for this call.
///
/// `open` is a WRITE path (schema init, migrations, WAL recovery): against
/// the live store with an app writing concurrently it has taken minutes, and
/// MCP stdio dispatch is sequential, so an unbounded open inside the first
/// store-touching tool call would freeze the whole session — the same stall
/// `impress-mcp`'s resource reads already bound with their own 10s deadline.
/// Bounding the OPEN here covers every entry point without putting a blanket
/// deadline on tool calls themselves, which may be legitimately slow
/// (compiles).
const OPEN_DEADLINE: Duration = Duration::from_secs(10);

/// The lazily-opened global and its bookkeeping, held as one value so the
/// open/fallback/retry behaviour is unit-testable without the process-wide
/// statics.
struct StoreCell {
    /// The real store only — a successful open, or an [`install_store`]d
    /// handle. The caching rule: a SUCCESSFUL real open is cached for the
    /// life of the process; the fallback is NEVER cached, so a transiently
    /// busy store (mid-WAL-recovery, a pending TCC prompt) degrades one call
    /// rather than the whole session — the next call retries the real open.
    cache: Mutex<Option<Arc<SqliteItemStore>>>,
    /// Whether the most recent [`StoreCell::acquire`] handed out the
    /// fallback. See [`store_is_fallback`].
    handed_fallback: AtomicBool,
    /// The one shared in-memory substitute, created on first failure. A
    /// single instance rather than a fresh store per failure, so consecutive
    /// degraded calls in a session at least see each other's rows.
    fallback: OnceLock<Arc<SqliteItemStore>>,
}

static GLOBAL: StoreCell = StoreCell::new();

impl StoreCell {
    const fn new() -> Self {
        Self {
            cache: Mutex::new(None),
            handed_fallback: AtomicBool::new(false),
            fallback: OnceLock::new(),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Option<Arc<SqliteItemStore>>> {
        // A panic elsewhere cannot leave the Option half-written — it is only
        // ever replaced whole — so recover from poisoning rather than
        // propagate it.
        self.cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn install(&self, store: Arc<SqliteItemStore>) -> Result<(), String> {
        let mut cached = self.lock();
        if cached.is_some() {
            return Err("impress store already installed".to_string());
        }
        *cached = Some(store);
        Ok(())
    }

    /// Hand out the cached real store, or open `path` within `deadline`, or
    /// degrade to the shared in-memory fallback for this call only.
    fn acquire(&self, path: &Path, deadline: Duration) -> Arc<SqliteItemStore> {
        // The lock is held across the bounded open on purpose: two callers
        // racing the first open would otherwise open the same SQLite file
        // twice; the loser waits at most one more deadline.
        let mut cached = self.lock();
        if let Some(store) = cached.as_ref() {
            // Cached handles are real by construction (the fallback is never
            // cached), so the flag reflects THIS hand-out.
            self.handed_fallback.store(false, Ordering::Relaxed);
            return store.clone();
        }
        let opened = {
            let path = path.to_path_buf();
            with_deadline(deadline, move || {
                SqliteItemStore::open(&path)
                    .map(Arc::new)
                    .map_err(|e| e.to_string())
            })
        };
        match opened {
            Ok(store) => {
                // Cache ONLY a successful real open (see `cache`).
                *cached = Some(store.clone());
                self.handed_fallback.store(false, Ordering::Relaxed);
                store
            }
            Err(e) => {
                eprintln!(
                    "[impress-store-service] could not open the store at {}: {e} \
                     — falling back to an empty in-memory store for this call",
                    path.display()
                );
                self.handed_fallback.store(true, Ordering::Relaxed);
                self.fallback_instance()
            }
        }
    }

    fn fallback_instance(&self) -> Arc<SqliteItemStore> {
        self.fallback
            .get_or_init(|| {
                Arc::new(
                    SqliteItemStore::open_in_memory()
                        .expect("in-memory SqliteItemStore always opens"),
                )
            })
            .clone()
    }
}

/// Run `work` on a worker thread and give up after `deadline`.
///
/// On timeout the thread is left running rather than killed — SQLite is
/// mid-operation and there is no safe way to interrupt it from outside — and
/// whatever it eventually produces is dropped; the NEXT [`store_instance`]
/// call starts a fresh attempt.
fn with_deadline<T: Send + 'static>(
    deadline: Duration,
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(work());
    });
    match rx.recv_timeout(deadline) {
        Ok(result) => result,
        Err(_) => Err(format!(
            "open did not finish within {}s — the store is busy or recovering \
             a large WAL (an app may be writing to it)",
            deadline.as_secs()
        )),
    }
}

/// Get (or lazily open) the shared store.
///
/// The open runs on a worker thread with a [`OPEN_DEADLINE`] bound; on
/// timeout or failure this hands out a private in-memory store rather than
/// stalling or panicking: an MCP tool that answers "no such collection" is
/// recoverable, a server that freezes or aborts mid-session is not. The
/// failure is logged to stderr, which is where every other service in this
/// server logs — and recorded in [`store_is_fallback`], which destiny-grade
/// operations (the collections migration) consult and refuse on. The
/// fallback is never cached, so a later call retries the real open.
pub fn store_instance() -> Arc<SqliteItemStore> {
    GLOBAL.acquire(&store_path(), OPEN_DEADLINE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_successful_open_is_cached_and_reused() {
        let cell = StoreCell::new();
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("ok.sqlite");

        let first = cell.acquire(&path, OPEN_DEADLINE);
        assert!(
            !cell.handed_fallback.load(Ordering::Relaxed),
            "a creatable path must not be reported as fallback"
        );
        let second = cell.acquire(&path, OPEN_DEADLINE);
        assert!(
            Arc::ptr_eq(&first, &second),
            "the second call must reuse the cached open, not reopen"
        );
        assert!(!cell.handed_fallback.load(Ordering::Relaxed));
    }

    #[test]
    fn an_unopenable_path_degrades_this_call_and_the_next_call_retries() {
        let cell = StoreCell::new();
        let dir = tempfile::tempdir().expect("tempdir");
        // A directory cannot be opened as a database file.
        let path = dir.path().join("store.sqlite");
        std::fs::create_dir(&path).expect("create blocking dir");

        let degraded = cell.acquire(&path, OPEN_DEADLINE);
        assert!(
            cell.handed_fallback.load(Ordering::Relaxed),
            "opening a directory must trip the fallback flag"
        );

        // The fallback was NOT cached: once the path becomes openable the
        // very next call hands out the real store — a transiently blocked
        // open degrades one call, not the session.
        std::fs::remove_dir(&path).expect("unblock the path");
        let real = cell.acquire(&path, OPEN_DEADLINE);
        assert!(
            !cell.handed_fallback.load(Ordering::Relaxed),
            "a successful retry must clear the flag"
        );
        assert!(
            !Arc::ptr_eq(&degraded, &real),
            "the retry must open the real store, not re-hand the fallback"
        );

        // And the successful retry IS cached.
        let again = cell.acquire(&path, OPEN_DEADLINE);
        assert!(Arc::ptr_eq(&real, &again));
    }

    #[test]
    fn a_stalled_open_gives_up_at_the_deadline() {
        // The real open cannot be made slow deterministically, so exercise
        // the bounding mechanism itself: a worker that outlives the deadline
        // must yield the timeout error, not block the caller.
        let started = std::time::Instant::now();
        let result: Result<(), String> = with_deadline(Duration::from_millis(50), || {
            std::thread::sleep(Duration::from_secs(5));
            Ok(())
        });
        let message = result.expect_err("a stalled open must time out");
        assert!(message.contains("did not finish"), "{message}");
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "the caller must not wait for the stalled worker"
        );
    }

    #[test]
    fn default_path_honours_the_environment_override() {
        // `default_store_path` is pure with respect to the singletons, so this
        // does not disturb whatever the rest of the suite resolved.
        std::env::set_var(
            "IMPRESS_STORE_PATH",
            "/tmp/impress-store-service-test.sqlite",
        );
        assert_eq!(
            default_store_path(),
            PathBuf::from("/tmp/impress-store-service-test.sqlite")
        );
        std::env::remove_var("IMPRESS_STORE_PATH");
        assert!(default_store_path()
            .to_string_lossy()
            .ends_with("workspace/impress.sqlite"));
    }
}
