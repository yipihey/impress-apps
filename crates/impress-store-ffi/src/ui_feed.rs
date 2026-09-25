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

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use impress_core::event::{MutationKind, StoreMutation};
use impress_core::item::ItemId;
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

/// How far back each read reaches behind the high-water mark.
///
/// A row's `modified` is the writer's wall clock when it wrote, not commit
/// order: a write that waited on the lock (up to the store's 5 s busy
/// timeout) commits with a timestamp older than one already seen, and a
/// cursor of `modified > mark` never saw it (review RL-L7). Each read reaches
/// this far back and drops what it already reported, by row and revision.
pub(crate) const OVERLAP_MS: i64 = 10_000;

/// What one [`ExternalPoll::check_rows`] found another connection did.
#[derive(Default)]
pub(crate) struct ExternalBatch {
    /// Rows under the prefix written since the last check, each reported
    /// once per revision (`logical_clock`).
    pub(crate) rows: Vec<impress_core::item::Item>,
    /// Rows of the tracked schema that are gone — a hard delete leaves no
    /// row to read, so it is found by diffing ids (see
    /// [`ExternalPoll::track_deletes`]).
    pub(crate) deleted: Vec<ItemId>,
}

/// The external-poll cursor: the last `data_version` seen and the
/// modification high-water mark, so repeated calls to [`Self::check`] only
/// ever report rows some OTHER connection wrote since the previous check.
pub(crate) struct ExternalPoll {
    last_data_version: Option<i64>,
    high_water_mark: i64,
    /// Row → (revision, modified ms) already reported, for the rows inside
    /// the overlap window. Keyed on the revision, not the timestamp: two
    /// writes to one row in one millisecond are two changes.
    reported: HashMap<ItemId, (u64, i64)>,
    /// The schema whose deletes are tracked, and its ids as of the last
    /// successful check.
    tracked: Option<(String, HashSet<ItemId>)>,
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
            reported: HashMap::new(),
            tracked: None,
        }
    }

    /// Also report rows of `schema_ref` that disappear. Baselined now, so a
    /// row deleted before this call is not reported.
    pub(crate) fn track_deletes(mut self, store: &SqliteItemStore, schema_ref: &str) -> Self {
        let ids = ids_of(store, schema_ref).unwrap_or_default();
        self.tracked = Some((schema_ref.to_string(), ids));
        self
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
        let batch = self.check_rows(store, prefix);
        let mut mutations: Vec<StoreMutation> = batch
            .rows
            .into_iter()
            .map(|item| StoreMutation::new(item.id, Some(item.schema), MutationKind::Updated))
            .collect();
        let tracked = self.tracked.as_ref().map(|(schema, _)| schema.clone());
        mutations.extend(
            batch
                .deleted
                .into_iter()
                .map(|id| StoreMutation::new(id, tracked.clone(), MutationKind::Deleted)),
        );
        mutations
    }

    /// [`Self::check`], with the rows themselves — what a feed that must
    /// look at a row's payload (whose layout is this?) reads.
    ///
    /// The cursor advances only once every read succeeded (review RL-L7:
    /// it used to move `data_version` first, so a failed read lost that
    /// change for good); a failure leaves it where it was, and the next
    /// poll reads again.
    pub(crate) fn check_rows(&mut self, store: &SqliteItemStore, prefix: &str) -> ExternalBatch {
        let Ok(dv) = store.data_version() else {
            return ExternalBatch::default();
        };
        if self.last_data_version == Some(dv) {
            return ExternalBatch::default();
        }
        let since = self.high_water_mark - OVERLAP_MS;
        let Ok(items) = store.items_modified_since(prefix, since) else {
            return ExternalBatch::default();
        };
        let deleted = match &self.tracked {
            Some((schema, before)) => match ids_of(store, schema) {
                Ok(now) => {
                    let gone: Vec<ItemId> = before.difference(&now).copied().collect();
                    self.tracked = Some((schema.clone(), now));
                    gone
                }
                Err(_) => return ExternalBatch::default(),
            },
            None => Vec::new(),
        };

        let mut rows = Vec::new();
        for item in items {
            let modified = item.modified.timestamp_millis();
            if self.reported.get(&item.id).map(|(clock, _)| *clock) == Some(item.logical_clock) {
                continue;
            }
            self.reported
                .insert(item.id, (item.logical_clock, modified));
            self.high_water_mark = self.high_water_mark.max(modified);
            rows.push(item);
        }
        let floor = self.high_water_mark - OVERLAP_MS;
        self.reported.retain(|_, (_, modified)| *modified > floor);
        self.last_data_version = Some(dv);
        ExternalBatch { rows, deleted }
    }
}

/// Every id of one schema — a light projection, for delete detection.
fn ids_of(store: &SqliteItemStore, schema_ref: &str) -> Result<HashSet<ItemId>, String> {
    store
        .query_raw(
            "SELECT id FROM items WHERE schema_ref = ?1",
            &[&schema_ref],
            |row| row.get::<_, String>(0),
        )
        .map(|ids| ids.iter().filter_map(|id| id.parse().ok()).collect())
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
    use impress_core::store::ItemStore;

    const SURFACE: &str = "impress/ui/surface@1.0.0";

    fn two_handles() -> (tempfile::TempDir, SqliteItemStore, SqliteItemStore) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("poll.sqlite");
        let a = SqliteItemStore::open(&path).unwrap();
        let b = SqliteItemStore::open(&path).unwrap();
        (dir, a, b)
    }

    fn row(modified: chrono::DateTime<chrono::Utc>) -> Item {
        Item {
            id: uuid::Uuid::new_v4(),
            schema: SURFACE.into(),
            payload: [("title".to_string(), Value::String("x".into()))]
                .into_iter()
                .collect(),
            created: modified,
            modified,
            author: "test".into(),
            author_kind: ActorKind::Agent,
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
        }
    }

    /// Review RL-L7 (2): `modified` is when the writer built the row, not
    /// commit order. A row committed AFTER one already reported, but stamped
    /// before it — a writer that waited on the lock — used to fall under the
    /// cursor and was never seen.
    #[test]
    fn a_row_committed_late_with_an_earlier_timestamp_is_still_seen() {
        let (_dir, watcher, writer) = two_handles();
        let mut poll = ExternalPoll::baseline(&watcher);
        let now = chrono::Utc::now();

        let first = writer.insert(row(now)).unwrap();
        let seen: Vec<ItemId> = poll
            .check_rows(&watcher, "impress/ui/")
            .rows
            .iter()
            .map(|i| i.id)
            .collect();
        assert_eq!(seen, vec![first]);

        let late = writer
            .insert(row(now - chrono::Duration::milliseconds(3_000)))
            .unwrap();
        let seen: Vec<ItemId> = poll
            .check_rows(&watcher, "impress/ui/")
            .rows
            .iter()
            .map(|i| i.id)
            .collect();
        assert_eq!(
            seen,
            vec![late],
            "the late row, and only it — `first` is not reported twice"
        );
    }

    /// Review RL-L7 (3): a hard delete leaves nothing to read, so it was
    /// never reported and the saved-layouts menu stayed stale.
    #[test]
    fn a_hard_delete_of_a_tracked_schema_is_reported() {
        let (_dir, watcher, writer) = two_handles();
        let doomed = writer.insert(row(chrono::Utc::now())).unwrap();
        let mut poll = ExternalPoll::baseline(&watcher).track_deletes(&watcher, SURFACE);
        writer.delete(doomed).unwrap();
        let batch = poll.check_rows(&watcher, "impress/ui/");
        assert_eq!(batch.deleted, vec![doomed]);
        // Reported once.
        writer.insert(row(chrono::Utc::now())).unwrap();
        assert!(poll.check_rows(&watcher, "impress/ui/").deleted.is_empty());
    }
}
