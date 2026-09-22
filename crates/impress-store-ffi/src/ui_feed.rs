//! The piece `layout.rs`'s and `surface.rs`'s invalidation feeds share.
//!
//! Both `SharedLayout` and `SharedSurface` hold exactly one background thread
//! of their own (see `layout.rs`'s module docs on why: a named multi-thread
//! runtime and a dedicated `std::thread` per object, matching the shape
//! `ai_registry::runtime()` established here first). What they watch and what
//! they do with a batch differ — a pane-invalidation set is matched against
//! the live layout tree's compiled queries, a changed-surface set against
//! `impress/ui/surface*` rows' own ids — so the debounce/startup-grace state
//! machine stays owned by each feed. What does NOT differ, and is genuinely
//! one definition, is ADR-0033 D6's cross-process piece: "did some OTHER
//! connection write a row under this prefix since I last looked, and which
//! rows" — [`ExternalPoll`] is that, and [`Feed`] is the six-line
//! start/stop/`Drop` shape both objects otherwise repeat verbatim.
//!
//! See `layout.rs`'s module docs ("Liveness across processes (ADR-0033 D6)")
//! for the full reasoning; this module only factors the mechanism, not the
//! explanation.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use impress_core::event::{MutationKind, StoreMutation};
use impress_core::sqlite_store::SqliteItemStore;

/// How often a feed's inner loop wakes to check for a quiet burst or a
/// version change. Shorter than the default debounce, so a burst is flushed
/// one poll after it ends rather than one debounce late.
pub(crate) const POLL: Duration = Duration::from_millis(10);

/// Default debounce window before a burst of mutations is delivered as one
/// batch.
pub(crate) const DEFAULT_DEBOUNCE_MS: u64 = 50;

/// A burst that never goes quiet is flushed anyway after this many debounce
/// windows, so a continuous writer cannot starve the listener.
pub(crate) const MAX_BURST_DEBOUNCES: u32 = 10;

/// Default interval between polls of [`SqliteItemStore::data_version`] for
/// the cross-process invalidation path (ADR-0033 D6). `PRAGMA data_version`
/// is a per-connection counter with no I/O beyond the pragma itself, so
/// polling it at this cadence is cheap; 250 ms keeps a chat-driven write
/// visible in well under a second.
pub(crate) const EXTERNAL_POLL_MS: u64 = 250;

/// Schema-ref prefix `layout.rs`'s feed watches: the agent-facing surface a
/// standalone chat process is expected to write to (layout, and — from work
/// package S4 — capability surfaces under `impress/ui/surface@1.0.0`).
/// `surface.rs`'s own feed narrows this further to `impress/ui/surface`
/// (excluding `impress/ui/layout`/`impress/ui/preset`) rather than reusing
/// this constant, since it only ever cares about surface rows.
pub(crate) const EXTERNAL_UI_PREFIX: &str = "impress/ui/";

// ─── Feed: the start/stop/Drop shape ────────────────────────────────────

/// A running background thread with a cooperative stop flag. Both
/// `SharedLayout` and `SharedSurface` hold one of these behind a
/// `Mutex<Option<Feed>>`, spawning their OWN thread (each with its own
/// listener type and matching logic) but sharing this shutdown dance rather
/// than each reimplementing it.
pub(crate) struct Feed {
    pub(crate) running: Arc<AtomicBool>,
    pub(crate) join: Option<std::thread::JoinHandle<()>>,
}

impl Feed {
    pub(crate) fn stop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

// ─── ExternalPoll: the ADR-0033 D6 cross-process check ──────────────────

/// The external-poll cursor: the last `data_version` seen and the
/// modification high-water mark, so repeated calls to [`Self::check`] only
/// ever report rows some OTHER connection wrote since the previous check.
pub(crate) struct ExternalPoll {
    last_data_version: Option<i64>,
    high_water_mark: i64,
}

impl ExternalPoll {
    /// Baselined against `store`'s CURRENT `data_version` and "now": a row
    /// already in the file when a feed subscribes is not replayed as an
    /// external write — only rows written from this point on are (see
    /// `layout.rs`'s module docs for why both feeds start where they do).
    pub(crate) fn baseline(store: &SqliteItemStore) -> Self {
        ExternalPoll {
            last_data_version: store.data_version().ok(),
            high_water_mark: chrono::Utc::now().timestamp_millis(),
        }
    }

    /// If `data_version` has moved since the last call, the rows under
    /// `prefix` another connection wrote since the high-water mark, folded
    /// into [`StoreMutation`]s the same way an in-process write would
    /// arrive. `Updated` stands in for Created/Updated/Deleted — see
    /// `layout.rs`'s module docs: the distinction is not observable from a
    /// plain read, and `Invalidation::is_affected_by` matches all three
    /// identically. Empty when nothing moved or nothing new matched
    /// `prefix`.
    pub(crate) fn check(&mut self, store: &SqliteItemStore, prefix: &str) -> Vec<StoreMutation> {
        let Ok(dv) = store.data_version() else {
            return Vec::new();
        };
        if self.last_data_version == Some(dv) {
            return Vec::new();
        }
        self.last_data_version = Some(dv);
        let Ok(items) = store.items_modified_since(prefix, self.high_water_mark) else {
            return Vec::new();
        };
        let mut mutations = Vec::with_capacity(items.len());
        for item in items {
            let modified_ms = item.modified.timestamp_millis();
            if modified_ms > self.high_water_mark {
                self.high_water_mark = modified_ms;
            }
            mutations.push(StoreMutation::new(
                item.id,
                Some(item.schema),
                MutationKind::Updated,
            ));
        }
        mutations
    }
}
