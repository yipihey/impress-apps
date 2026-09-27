//! The store spy: what a verb actually read and wrote (ADR-0036 D1, plan
//! self-reflective-layer E1/E2).
//!
//! A declaration on a `VerbDescriptor` (`effects = { reads, writes, reach }`)
//! is only as true as whoever wrote it, and the plan's static walk showed a
//! reading of the code cannot verify one (table EF-1). This module records
//! the record kinds every `SqliteItemStore` call touches while a recorder is
//! on, so a Tier A test can run a verb's examples and assert
//! `observed ⊆ declared`. It is compiled only under the `effects-spy` feature,
//! which `crates/impress-capabilities` enables for its tests and nothing
//! else does; without it the store has no hook and no cost.
//!
//! What is recorded, and from where:
//! - **reads** — `get` (the row's kind), `query`/`count` (the query's
//!   `schema` when it names one, else the kinds of the rows returned, else
//!   [`ANY`] because a schemaless count touches every kind), `neighbors`
//!   (the rows' kinds);
//! - **writes** — the mutation feed ([`crate::sqlite_store::SqliteItemStore::emit_mutation`],
//!   which every write already goes through): the mutation's `schema_ref`,
//!   or [`ANY`] when the store could not determine it; `Created` and
//!   `Deleted` also land in `inserted`/`deleted`.
//!
//! The recorder is process-wide (one `Mutex<Option<Observed>>`), because the
//! services reach the store through singletons the test cannot thread a
//! wrapper into. That is fine for a test that runs one verb at a time; it is
//! not a per-call attribution mechanism — the call log (L1) is.

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use crate::item::ItemId;

/// The kind recorded when the store touched rows whose kind it could not
/// name: a schemaless `count`, an empty schemaless `query`, a mutation whose
/// row was already gone. A declaration covers it only with `any(…)`.
pub const ANY: &str = "*";

/// What one recording window saw.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Observed {
    pub reads: BTreeSet<String>,
    pub writes: BTreeSet<String>,
    pub inserted: Vec<ItemId>,
    pub deleted: Vec<ItemId>,
}

static ACTIVE: AtomicBool = AtomicBool::new(false);
static RECORDER: Mutex<Option<Observed>> = Mutex::new(None);

/// Start recording. A window already open is replaced (its contents are
/// discarded), so a test that forgot to `stop` cannot leak into the next.
pub fn start() {
    let mut guard = RECORDER.lock().unwrap_or_else(|e| e.into_inner());
    *guard = Some(Observed::default());
    ACTIVE.store(true, Ordering::SeqCst);
}

/// Stop recording and return what was seen since [`start`]. Empty when no
/// window was open.
pub fn stop() -> Observed {
    ACTIVE.store(false, Ordering::SeqCst);
    let mut guard = RECORDER.lock().unwrap_or_else(|e| e.into_inner());
    guard.take().unwrap_or_default()
}

/// Whether a window is open — the one branch every hook pays.
#[inline]
pub fn is_recording() -> bool {
    ACTIVE.load(Ordering::Relaxed)
}

fn with(f: impl FnOnce(&mut Observed)) {
    if !is_recording() {
        return;
    }
    let mut guard = RECORDER.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(observed) = guard.as_mut() {
        f(observed);
    }
}

/// A read of `kind` (`None` → [`ANY`]).
pub fn note_read(kind: Option<&str>) {
    with(|o| {
        o.reads.insert(kind.unwrap_or(ANY).to_string());
    });
}

/// A read whose kinds are those of the rows it returned; no rows and no
/// schema means the store looked at every kind.
pub fn note_read_rows<'a>(schema: Option<&str>, rows: impl Iterator<Item = &'a str>) {
    with(|o| {
        if let Some(kind) = schema {
            o.reads.insert(kind.to_string());
            return;
        }
        let mut any = false;
        for kind in rows {
            any = true;
            o.reads.insert(kind.to_string());
        }
        if !any {
            o.reads.insert(ANY.to_string());
        }
    });
}

/// A write to `kind` (`None` → [`ANY`]), with the row id when it was created
/// or deleted.
pub fn note_write(kind: Option<&str>, id: ItemId, created: bool, deleted: bool) {
    with(|o| {
        o.writes.insert(kind.unwrap_or(ANY).to_string());
        if created {
            o.inserted.push(id);
        }
        if deleted {
            o.deleted.push(id);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_window_records_reads_and_writes_and_closes_clean() {
        assert!(!is_recording());
        note_read(Some("dropped-before-start"));
        start();
        note_read(Some("manuscript"));
        note_read_rows(None, ["figure", "figure"].into_iter());
        note_read_rows(None, std::iter::empty());
        let id = ItemId::new_v4();
        note_write(Some("manuscript"), id, true, false);
        note_write(None, id, false, true);
        let seen = stop();
        assert_eq!(
            seen.reads.iter().map(String::as_str).collect::<Vec<_>>(),
            vec![ANY, "figure", "manuscript"]
        );
        assert_eq!(
            seen.writes.iter().map(String::as_str).collect::<Vec<_>>(),
            vec![ANY, "manuscript"]
        );
        assert_eq!(seen.inserted, vec![id]);
        assert_eq!(seen.deleted, vec![id]);
        assert!(!is_recording());
        assert_eq!(stop(), Observed::default(), "a closed window is empty");
    }
}
