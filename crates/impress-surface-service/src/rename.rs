//! The rename pass (plan-verb-pipeline-and-transport.md P3b): rewrites verb
//! names in every stored `impress/ui/surface@1.0.0` spec against a
//! [`RenameTable`](impress_service_core::lifecycle::RenameTable), once per
//! table version.
//!
//! # Where a verb or view kind is named in a spec
//!
//! Table LC (plan-verb-pipeline-and-transport.md § Lifecycle measurements)
//! names four sites: `sources.*.verb` ([`impress_surface::spec::Source::Verb`]),
//! `call.verb` ([`impress_surface::spec::Action::Call`]), `open.view_kind`
//! ([`impress_surface::spec::Action::Open`]) — all rewritten here — and
//! `params[].kind`, which is a **record schema** kind (`"publication"`), not
//! a verb or a view kind, and is out of this pass's scope.
//!
//! This pass rewrites the spec's own JSON rather than walking the typed
//! [`impress_surface::spec::SurfaceSpec`] tree: `verb` and `view_kind` are
//! keys that appear only at those three sites in the vocabulary
//! (`docs/plan-agent-surfaces.md`, "The vocabulary (normative)"), so a plain
//! recursive walk of the stored JSON finds every one of them without a
//! second, mutable tree-walker alongside `impress_surface::spec`'s existing
//! read-only ones (`handler_pointers`, `walk_with_pointers`) — which return
//! `&Action`/`&Node`, not `&mut`, because nothing before this pass ever
//! needed to rewrite a spec in place.
//!
//! # System rows and user rows, the same way
//!
//! Exactly [`impress_layout_service::rename`]'s reasoning: a rename rewrites
//! every row that names the old verb, however it was authored, and nothing
//! is lost because [`crate::store::SurfaceStore::update`] is the same
//! attributed, `Durable` + `Editorial` write path a real `surface_update`
//! call makes — the previous spec text stays in the operation log.
//!
//! # Running once per version
//!
//! Same mechanism as the layout-service pass: the highest applied
//! [`RenameTable::version`](impress_service_core::lifecycle::RenameTable::version)
//! is recorded in `store_metadata` under [`MARKER_KEY`], via
//! [`impress_core::sqlite_store::SqliteItemStore::get_store_metadata`] /
//! `set_store_metadata`, so a second run of an already-applied table is a
//! no-op.

use std::sync::Arc;

use impress_core::item::ActorKind;
use impress_core::sqlite_store::SqliteItemStore;
use impress_service_core::lifecycle::{RenameTable, RenameVisitor};
use impress_service_core::Refusal;
use impress_surface::spec::SurfaceSpec;

use crate::store::{Result, SurfaceStore};

/// The `store_metadata` key this pass records its applied version under.
pub const MARKER_KEY: &str = "lifecycle.rename.surface-service";

/// What one run of [`RenamePass::run`] did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RenameReport {
    pub surfaces_visited: usize,
    pub surfaces_rewritten: usize,
}

/// The surface-service rename pass — the
/// [`RenameVisitor`](impress_service_core::lifecycle::RenameVisitor)
/// implementation this crate's one stored document kind (a surface spec)
/// provides. See `impress_service_core::lifecycle`'s module docs for the
/// H-P3-1 note this mirrors: a later workflow or scenario document kind adds
/// its own implementation elsewhere, without this one changing.
pub struct RenamePass {
    store: SurfaceStore,
}

impl RenameVisitor for RenamePass {
    fn kind(&self) -> &'static str {
        "surface"
    }
}

impl RenamePass {
    pub fn new(store: Arc<SqliteItemStore>) -> Self {
        Self {
            store: SurfaceStore::new(store),
        }
    }

    /// Run `table` against this store if it has not already been applied at
    /// this version or later. Call once, at store open or service start.
    pub fn run_if_needed(&self, table: &RenameTable) -> Result<RenameReport> {
        if table.is_empty() {
            return Ok(RenameReport::default());
        }
        if self.applied_version()?.is_some_and(|v| v >= table.version) {
            return Ok(RenameReport::default());
        }
        let report = self.run(table)?;
        self.record_version(table.version)?;
        Ok(report)
    }

    /// Run `table` unconditionally, ignoring the recorded version. What the
    /// tests call directly, and what [`Self::run_if_needed`] calls once it
    /// has decided the table is not already applied.
    pub fn run(&self, table: &RenameTable) -> Result<RenameReport> {
        let mut report = RenameReport::default();
        for row in self.store.list()? {
            report.surfaces_visited += 1;
            let mut json: serde_json::Value = serde_json::from_str(&row.spec_text)
                .map_err(|e| Refusal::store(format!("surface {} spec: {e}", row.id)))?;
            let mut changed = false;
            rewrite_json(&mut json, table, row.id, &mut changed);
            if !changed {
                continue;
            }
            let spec: SurfaceSpec = serde_json::from_value(json).map_err(|e| {
                Refusal::store(format!("surface {} spec after rename: {e}", row.id))
            })?;
            self.store
                .update(row.id, &spec, None, None, ActorKind::System)?;
            report.surfaces_rewritten += 1;
        }
        if report.surfaces_rewritten > 0 {
            log::info!(
                target: "surface",
                "rename pass v{}: rewrote {} surface row(s)",
                table.version,
                report.surfaces_rewritten
            );
        }
        Ok(report)
    }

    fn applied_version(&self) -> Result<Option<u32>> {
        Ok(self
            .store
            .store()
            .get_store_metadata(MARKER_KEY)
            .map_err(|e| Refusal::store(format!("read rename marker: {e}")))?
            .and_then(|v| v.parse::<u32>().ok()))
    }

    fn record_version(&self, version: u32) -> Result<()> {
        self.store
            .store()
            .set_store_metadata(MARKER_KEY, &version.to_string())
            .map_err(|e| Refusal::store(format!("write rename marker: {e}")))
    }
}

/// Recursively rewrite every `verb` and `view_kind` string key against
/// `table`. `verb` covers both `sources.*.verb` (a [`Source::Verb`]) and
/// `call.verb` (an [`Action::Call`]) — both spell the field the same way,
/// which is exactly why one walk finds both. `view_kind` covers `open`
/// actions. See the module docs for why a blind key match is the right
/// amount of machinery for this vocabulary.
///
/// [`Source::Verb`]: impress_surface::spec::Source::Verb
/// [`Action::Call`]: impress_surface::spec::Action::Call
fn rewrite_json(
    value: &mut serde_json::Value,
    table: &RenameTable,
    surface: impress_core::item::ItemId,
    changed: &mut bool,
) {
    match value {
        serde_json::Value::Object(map) => {
            if let Some(new_verb) = map
                .get("verb")
                .and_then(|v| v.as_str())
                .and_then(|old| table.rename_verb(old))
            {
                log::info!(
                    target: "surface",
                    "rename pass v{}: surface {} verb '{}' -> '{new_verb}'",
                    table.version,
                    surface,
                    map.get("verb").and_then(|v| v.as_str()).unwrap_or_default(),
                );
                map.insert(
                    "verb".to_string(),
                    serde_json::Value::String(new_verb.to_string()),
                );
                *changed = true;
            }
            if let Some(new_kind) = map
                .get("view_kind")
                .and_then(|v| v.as_str())
                .and_then(|old| table.rename_view_kind(old))
            {
                log::info!(
                    target: "surface",
                    "rename pass v{}: surface {} view kind '{}' -> '{new_kind}'",
                    table.version,
                    surface,
                    map.get("view_kind").and_then(|v| v.as_str()).unwrap_or_default(),
                );
                map.insert(
                    "view_kind".to_string(),
                    serde_json::Value::String(new_kind.to_string()),
                );
                *changed = true;
            }
            for v in map.values_mut() {
                rewrite_json(v, table, surface, changed);
            }
        }
        serde_json::Value::Array(items) => {
            for v in items.iter_mut() {
                rewrite_json(v, table, surface, changed);
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use impress_core::item::ActorKind;
    use impress_core::sqlite_store::SqliteItemStore;
    use impress_service_core::lifecycle::RenameTable;
    use impress_surface::spec::SurfaceSpec;

    use super::*;

    /// A rename table used only by these tests — the shipped one stays
    /// empty (docs/plan-verb-pipeline-and-transport.md P3b).
    const TEST_TABLE: RenameTable = RenameTable {
        version: 1,
        verbs: &[("triage-service_a", "triage-service_b")],
        view_kinds: &[],
    };

    fn scratch_store() -> Arc<SqliteItemStore> {
        Arc::new(SqliteItemStore::open_in_memory().expect("scratch store"))
    }

    fn spec_naming(verb: &str) -> SurfaceSpec {
        let json = format!(
            r#"{{
                "surface": "1.0",
                "name": "test surface",
                "sources": {{
                    "s": {{ "verb": "{verb}", "args": {{}} }}
                }},
                "root": {{ "column": [] }}
            }}"#
        );
        serde_json::from_str(&json).expect("valid spec")
    }

    #[test]
    fn a_seeded_surface_naming_verb_a_is_rewritten_to_b() {
        let store = scratch_store();
        let surfaces = SurfaceStore::new(store.clone());
        let spec = spec_naming("triage-service_a");
        let row = surfaces
            .create(&spec, None, &[], ActorKind::System)
            .expect("create");

        let pass = RenamePass::new(store);
        let report = pass.run(&TEST_TABLE).expect("run");
        assert_eq!(report.surfaces_rewritten, 1);

        let reloaded = surfaces.get(row.id).expect("get").expect("row exists");
        match reloaded.spec.sources.get("s") {
            Some(impress_surface::spec::Source::Verb { verb, .. }) => {
                assert_eq!(verb, "triage-service_b");
            }
            other => panic!("expected a Verb source, got {other:?}"),
        }
    }

    #[test]
    fn running_twice_is_a_no_op() {
        let store = scratch_store();
        let surfaces = SurfaceStore::new(store.clone());
        let spec = spec_naming("triage-service_a");
        surfaces
            .create(&spec, None, &[], ActorKind::System)
            .expect("create");

        let pass = RenamePass::new(store);
        let first = pass.run_if_needed(&TEST_TABLE).expect("first run");
        assert_eq!(first.surfaces_rewritten, 1);

        let second = pass.run_if_needed(&TEST_TABLE).expect("second run");
        assert_eq!(second, RenameReport::default());
    }

    #[test]
    fn an_empty_table_is_a_no_op() {
        let store = scratch_store();
        let pass = RenamePass::new(store);
        let empty = RenameTable {
            version: 1,
            verbs: &[],
            view_kinds: &[],
        };
        let report = pass.run_if_needed(&empty).expect("run");
        assert_eq!(report, RenameReport::default());
    }

    #[test]
    fn a_surface_naming_neither_old_verb_is_left_alone() {
        let store = scratch_store();
        let surfaces = SurfaceStore::new(store.clone());
        let spec = spec_naming("unrelated-service_verb");
        surfaces
            .create(&spec, None, &[], ActorKind::System)
            .expect("create");

        let pass = RenamePass::new(store);
        let report = pass.run(&TEST_TABLE).expect("run");
        assert_eq!(report.surfaces_visited, 1);
        assert_eq!(report.surfaces_rewritten, 0);
    }
}
