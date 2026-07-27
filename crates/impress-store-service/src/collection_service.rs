//! `CollectionService` — the agent-facing twin of the collection kernel
//! (ADR-0022 D1/D5).
//!
//! One verb set over every collection hierarchy in the suite, parameterized by
//! a `binding` string that names which schema to operate on. The method names,
//! argument names and argument order mirror
//! `impress_store_ffi::SharedStore::collection_*` on purpose: Swift, the CLI
//! and an agent should say the same words for the same operation, because the
//! moment they diverge somebody has to keep a translation table in their head.
//!
//! Everything here delegates to `impress_core::collection_ops`. No logic lives
//! in this layer — it converts strings to bindings, kernel results to result
//! DTOs, and nothing else.

use std::sync::Arc;

use impress_core::collection_migration;
use impress_core::collection_ops::{
    self, CollectionRow, CollectionSchemaBinding, FIGURE_COLLECTION, GENERIC_COLLECTION,
    IMBIB_COLLECTION, MANUSCRIPT_COLLECTION,
};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::StoreError;
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

use crate::store::store_instance;

/// Every accepted `binding` value, in the order a caller should think about
/// them. Listed in error messages so a wrong guess is self-correcting.
pub const BINDING_NAMES: [&str; 4] = ["imbib", "manuscript", "figure", "generic"];

/// Resolve a `binding` argument to a kernel binding.
///
/// Aliases are deliberate: an agent that knows the record kind (`publication`)
/// or the stored schema (`imbib/collection`) should not have to learn a third
/// vocabulary to use the tool.
pub fn binding_for(name: &str) -> Result<CollectionSchemaBinding, String> {
    match name.trim().to_ascii_lowercase().as_str() {
        "imbib" | "publication" | "publications" | "imbib/collection" => Ok(IMBIB_COLLECTION),
        "manuscript" | "manuscripts" | "imprint" | "manuscript-collection" => {
            Ok(MANUSCRIPT_COLLECTION)
        }
        "figure" | "figures" | "implore" | "figure-collection" => Ok(FIGURE_COLLECTION),
        "" | "generic" | "any" | "collection" | "impress" => Ok(GENERIC_COLLECTION),
        other => Err(format!(
            "unknown collection binding '{other}'. Use one of: {}.",
            BINDING_NAMES.join(", ")
        )),
    }
}

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

/// One flat collection row. Build the tree yourself from `parent_id`
/// (`null` = root); the kernel returns a flat list so callers can group,
/// filter and sort it their own way.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CollectionRowDto {
    /// Lowercase UUID string.
    pub id: String,
    pub name: String,
    /// Lowercase UUID of the PARENT COLLECTION, or null for a root. Never the
    /// owning library — that is the envelope parent and a different thing.
    pub parent_id: Option<String>,
    pub sort_order: i64,
    /// Record kind this collection organises ("publication", "manuscript",
    /// "any", …) for schemas that carry one; null for the per-kind schemas.
    pub kind_scope: Option<String>,
}

impl From<CollectionRow> for CollectionRowDto {
    fn from(row: CollectionRow) -> Self {
        Self {
            id: row.id,
            name: row.name,
            parent_id: row.parent_id,
            sort_order: row.sort_order,
            kind_scope: row.kind_scope,
        }
    }
}

/// Result of an operation that returns a single collection.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CollectionResult {
    pub ok: bool,
    pub collection: Option<CollectionRowDto>,
    pub message: String,
}

/// Result of a whole-tree read.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CollectionListResult {
    pub ok: bool,
    pub collections: Vec<CollectionRowDto>,
    pub message: String,
}

/// Result of a membership or delete operation.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CollectionMutationResult {
    pub ok: bool,
    /// How many members were actually added or removed. Zero for `delete`.
    pub applied: u32,
    pub message: String,
}

/// Member counts, aligned index-for-index with the requested ids.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct MemberCountsResult {
    pub ok: bool,
    pub counts: Vec<u32>,
    pub message: String,
}

// --- Schema convergence (ADR-0022 WP G7) -----------------------------------

/// Rows still stored under one legacy collection schema.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct LegacyCountDto {
    /// The legacy `schema_ref` (`imbib/collection`, `manuscript-collection`,
    /// `figure-collection`).
    pub schema_ref: String,
    /// The `kind_scope` these rows take on once migrated.
    pub kind_scope: String,
    pub rows: u64,
}

/// Generic `collection@1.0.0` rows sharing a `kind_scope`.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct KindScopeCountDto {
    /// `"publication"`, `"manuscript"`, `"figure"`, `"any"`, …
    pub kind_scope: String,
    pub rows: u64,
    /// How many of them were produced by a migration. `rows - migrated` were
    /// created natively as `collection@1.0.0` and no rollback will touch them.
    pub migrated: u64,
}

/// Where a store sits on the convergence: the flag, and the actual row counts
/// on both sides of it.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct MigrationStatusResult {
    pub ok: bool,
    /// The `collections.unified` flag. False on every store that has not been
    /// deliberately migrated — which is all of them by default.
    pub migrated: bool,
    pub legacy: Vec<LegacyCountDto>,
    pub generic: Vec<KindScopeCountDto>,
    pub message: String,
}

/// One legacy binding's share of a migration run.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct BindingMigrationDto {
    pub schema_ref: String,
    pub kind_scope: String,
    /// Legacy rows found.
    pub found: u64,
    /// Rows rewritten — equal to `found`, or equal to what the real run WOULD
    /// rewrite when this was a dry run.
    pub rewritten: u64,
    /// Rows an earlier run already converged. Makes a re-run's zero legible.
    pub skipped_already_generic: u64,
}

/// What `migrate` did, or (dry run) would do.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct MigrationReportResult {
    pub ok: bool,
    /// True when nothing was written.
    pub dry_run: bool,
    /// The flag's state BEFORE this run.
    pub was_migrated: bool,
    pub bindings: Vec<BindingMigrationDto>,
    /// Always true: the migration rewrites `schema_ref` and `payload` only.
    /// `Contains` edges and envelope parents are not part of it.
    pub membership_edges_untouched: bool,
    pub message: String,
}

/// Rows restored to one legacy `schema_ref`.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct RollbackCountDto {
    pub schema_ref: String,
    pub restored: u64,
}

/// What `rollback` restored.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct RollbackReportResult {
    pub ok: bool,
    /// Rows restored, per originating legacy `schema_ref`.
    pub restored: Vec<RollbackCountDto>,
    /// Generic rows with no migration provenance: created natively as
    /// `collection@1.0.0`, counted and left alone.
    pub native_generic_untouched: u64,
    pub membership_edges_untouched: bool,
    pub message: String,
}

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

/// Collections and folders across the whole suite, through one verb set.
///
/// Every method takes `binding`, which selects the hierarchy:
/// `"imbib"` (publication collections), `"manuscript"` (imprint folders),
/// `"figure"` (implore folders) or `"generic"` (the mixed-kind
/// `collection@1.0.0` kernel schema, which accepts records of ANY kind).
#[impress_service]
pub trait CollectionService: Send + Sync + 'static {
    /// Every collection in one hierarchy, flat, ordered by `sort_order`.
    ///
    /// `binding` is `imbib` | `manuscript` | `figure` | `generic`. Build the
    /// tree from each row's `parent_id` (null = root). Start here: every other
    /// method takes ids this returns.
    #[impress_method]
    async fn tree(&self, binding: String) -> CollectionListResult;

    /// Create a collection under `parent_id` (null = a new root).
    ///
    /// `kind_scope` is honoured only by the `generic` binding, where it names
    /// the record kind the collection organises ("publication", "manuscript",
    /// "figure", "message", "task") or "any" for a mixed-kind collection; it
    /// defaults to "any". The other bindings ignore it — their schema has no
    /// such field.
    #[impress_method]
    async fn create(
        &self,
        binding: String,
        name: String,
        parent_id: Option<String>,
        kind_scope: Option<String>,
    ) -> CollectionResult;

    /// Rename a collection.
    #[impress_method]
    async fn rename(&self, binding: String, id: String, name: String) -> CollectionResult;

    /// Move a collection under `new_parent_id` (null = make it a root).
    ///
    /// Refuses self-parenting and any move under one of the collection's own
    /// descendants — the cycle check lives in the Rust kernel, so it holds for
    /// every caller rather than only the ones that remembered it.
    #[impress_method]
    async fn reparent(
        &self,
        binding: String,
        id: String,
        new_parent_id: Option<String>,
    ) -> CollectionResult;

    /// Set a collection's position among its siblings. Lower sorts first.
    #[impress_method]
    async fn reorder(&self, binding: String, id: String, sort_order: i64) -> CollectionResult;

    /// Delete a collection. Members are NEVER deleted — only the membership
    /// goes away, so the papers/manuscripts/figures survive. Deleting a
    /// collection that does not exist is an error, not a no-op.
    #[impress_method]
    async fn delete(&self, binding: String, id: String) -> CollectionMutationResult;

    /// File items into a collection. Idempotent per item; returns how many
    /// were applied. A `generic` collection with `kind_scope: "any"` accepts
    /// items of every kind at once.
    #[impress_method]
    async fn add_members(
        &self,
        binding: String,
        collection_id: String,
        item_ids: Vec<String>,
    ) -> CollectionMutationResult;

    /// Remove items from a collection. The items themselves are untouched;
    /// items filed in a DIFFERENT collection are left alone rather than
    /// unfiled. Returns how many were actually removed.
    #[impress_method]
    async fn remove_members(
        &self,
        binding: String,
        collection_id: String,
        item_ids: Vec<String>,
    ) -> CollectionMutationResult;

    /// Member count per collection, aligned index-for-index with
    /// `collection_ids`. Unknown ids count 0 rather than failing the batch, so
    /// a stale id cannot break a whole sidebar refresh.
    #[impress_method]
    async fn member_counts(
        &self,
        binding: String,
        collection_ids: Vec<String>,
    ) -> MemberCountsResult;

    /// Where this store sits on the `collection@1.0.0` convergence
    /// (ADR-0022 WP G7): the `collections.unified` flag, how many rows are
    /// still under each legacy schema, and how many generic rows exist per
    /// `kind_scope`. Read-only and always safe. Start here before `migrate`.
    #[impress_method]
    async fn migration_status(&self) -> MigrationStatusResult;

    /// Converge the three legacy collection schemas onto `collection@1.0.0`.
    ///
    /// **Run with `dry_run: true` first.** A dry run writes NOTHING — not the
    /// rows, not the flag — and reports exactly the counts the real run will
    /// report, so the numbers you see are the numbers you will get.
    ///
    /// The real run rewrites every legacy collection row IN PLACE, keeping its
    /// id, its `Contains` edges and its envelope parent, and sets the flag in
    /// the same transaction. Membership is not rewritten. Every rewritten row
    /// carries its original schema and payload verbatim, so `rollback` is
    /// byte-faithful. Re-running is safe: the second run rewrites zero rows.
    ///
    /// This is a deliberate, human-invoked operation on data users live in.
    #[impress_method]
    async fn migrate(&self, dry_run: bool) -> MigrationReportResult;

    /// Undo `migrate`: restore every migrated collection's original schema and
    /// payload byte-for-byte and clear the flag.
    ///
    /// A REWIND, not a merge. The payload restored is the one the migration
    /// froze, so renames/reorders/moves performed on a migrated collection
    /// AFTER the migration are discarded along with it. Collections created
    /// after the migration carry no provenance, are left strictly alone, and
    /// are reported separately — nothing is deleted, but post-migration edits
    /// to pre-migration rows do not survive. Check `migration_status` first.
    #[impress_method]
    async fn rollback(&self) -> RollbackReportResult;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

/// Store-backed `CollectionService`. `new()` uses the shared store (opened
/// lazily); `with_store` takes an explicit one, which is how tests run against
/// a temp or in-memory database.
#[derive(Clone, Default)]
pub struct DefaultCollectionService {
    store: Option<Arc<SqliteItemStore>>,
}

impl DefaultCollectionService {
    pub fn new() -> Self {
        Self { store: None }
    }

    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self { store: Some(store) }
    }

    fn store(&self) -> Arc<SqliteItemStore> {
        self.store.clone().unwrap_or_else(store_instance)
    }
}

/// Kernel errors carry the diagnosis (`invalid UUID`, `would create a cycle`,
/// `has schema 'x', expected 'y'`); the tool surface just has to not swallow
/// them.
fn describe(err: StoreError) -> String {
    err.to_string()
}

fn row_result(result: Result<CollectionRow, StoreError>, verb: &str) -> CollectionResult {
    match result {
        Ok(row) => CollectionResult {
            ok: true,
            message: format!("{verb} '{}' ({}).", row.name, row.id),
            collection: Some(row.into()),
        },
        Err(e) => CollectionResult {
            ok: false,
            collection: None,
            message: describe(e),
        },
    }
}

/// The structural verbs return the row plus the prior value an undo stack
/// needs (ADR-0022 G2). The agent surface has no undo stack — it reports the
/// row and drops the prior value on the floor, deliberately.
fn mutation_result(
    result: Result<collection_ops::CollectionMutation, StoreError>,
    verb: &str,
) -> CollectionResult {
    row_result(result.map(|m| m.row), verb)
}

/// The membership verbs return the ids they ACTUALLY changed; the tool surface
/// reports how many that was.
fn member_result(result: Result<Vec<String>, StoreError>, verb: &str) -> CollectionMutationResult {
    match result {
        Ok(changed) => CollectionMutationResult {
            ok: true,
            applied: changed.len() as u32,
            message: format!("{verb} {} item(s).", changed.len()),
        },
        Err(e) => CollectionMutationResult {
            ok: false,
            applied: 0,
            message: describe(e),
        },
    }
}

#[async_trait::async_trait]
impl CollectionService for DefaultCollectionService {
    async fn tree(&self, binding: String) -> CollectionListResult {
        let binding = match binding_for(&binding) {
            Ok(b) => b,
            Err(message) => {
                return CollectionListResult {
                    ok: false,
                    collections: vec![],
                    message,
                }
            }
        };
        match collection_ops::list_tree(&self.store(), &binding) {
            Ok(rows) => CollectionListResult {
                ok: true,
                message: format!("{} collection(s).", rows.len()),
                collections: rows.into_iter().map(CollectionRowDto::from).collect(),
            },
            Err(e) => CollectionListResult {
                ok: false,
                collections: vec![],
                message: describe(e),
            },
        }
    }

    async fn create(
        &self,
        binding: String,
        name: String,
        parent_id: Option<String>,
        kind_scope: Option<String>,
    ) -> CollectionResult {
        let binding = match binding_for(&binding) {
            Ok(b) => b,
            Err(message) => {
                return CollectionResult {
                    ok: false,
                    collection: None,
                    message,
                }
            }
        };
        row_result(
            collection_ops::create(
                &self.store(),
                &binding,
                &name,
                parent_id.as_deref(),
                kind_scope.as_deref(),
                // The agent surface always appends with the schema default;
                // explicit positioning is `reorder`'s job here.
                None,
            ),
            "Created",
        )
    }

    async fn rename(&self, binding: String, id: String, name: String) -> CollectionResult {
        let binding = match binding_for(&binding) {
            Ok(b) => b,
            Err(message) => {
                return CollectionResult {
                    ok: false,
                    collection: None,
                    message,
                }
            }
        };
        mutation_result(
            collection_ops::rename(&self.store(), &binding, &id, &name),
            "Renamed to",
        )
    }

    async fn reparent(
        &self,
        binding: String,
        id: String,
        new_parent_id: Option<String>,
    ) -> CollectionResult {
        let binding = match binding_for(&binding) {
            Ok(b) => b,
            Err(message) => {
                return CollectionResult {
                    ok: false,
                    collection: None,
                    message,
                }
            }
        };
        mutation_result(
            collection_ops::reparent(&self.store(), &binding, &id, new_parent_id.as_deref()),
            "Moved",
        )
    }

    async fn reorder(&self, binding: String, id: String, sort_order: i64) -> CollectionResult {
        let binding = match binding_for(&binding) {
            Ok(b) => b,
            Err(message) => {
                return CollectionResult {
                    ok: false,
                    collection: None,
                    message,
                }
            }
        };
        mutation_result(
            collection_ops::reorder(&self.store(), &binding, &id, sort_order),
            "Reordered",
        )
    }

    async fn delete(&self, binding: String, id: String) -> CollectionMutationResult {
        let binding = match binding_for(&binding) {
            Ok(b) => b,
            Err(message) => {
                return CollectionMutationResult {
                    ok: false,
                    applied: 0,
                    message,
                }
            }
        };
        match collection_ops::delete(&self.store(), &binding, &id) {
            Ok(_snapshot) => CollectionMutationResult {
                ok: true,
                applied: 0,
                message: format!("Deleted collection {id}. Its members were not deleted."),
            },
            Err(e) => CollectionMutationResult {
                ok: false,
                applied: 0,
                message: describe(e),
            },
        }
    }

    async fn add_members(
        &self,
        binding: String,
        collection_id: String,
        item_ids: Vec<String>,
    ) -> CollectionMutationResult {
        let binding = match binding_for(&binding) {
            Ok(b) => b,
            Err(message) => {
                return CollectionMutationResult {
                    ok: false,
                    applied: 0,
                    message,
                }
            }
        };
        member_result(
            collection_ops::add_members(&self.store(), &binding, &collection_id, &item_ids),
            "Filed",
        )
    }

    async fn remove_members(
        &self,
        binding: String,
        collection_id: String,
        item_ids: Vec<String>,
    ) -> CollectionMutationResult {
        let binding = match binding_for(&binding) {
            Ok(b) => b,
            Err(message) => {
                return CollectionMutationResult {
                    ok: false,
                    applied: 0,
                    message,
                }
            }
        };
        member_result(
            collection_ops::remove_members(&self.store(), &binding, &collection_id, &item_ids),
            "Removed",
        )
    }

    async fn member_counts(
        &self,
        binding: String,
        collection_ids: Vec<String>,
    ) -> MemberCountsResult {
        let binding = match binding_for(&binding) {
            Ok(b) => b,
            Err(message) => {
                return MemberCountsResult {
                    ok: false,
                    counts: vec![],
                    message,
                }
            }
        };
        match collection_ops::member_counts(&self.store(), &binding, &collection_ids) {
            Ok(counts) => MemberCountsResult {
                ok: true,
                message: format!("Counted {} collection(s).", counts.len()),
                counts,
            },
            Err(e) => MemberCountsResult {
                ok: false,
                counts: vec![],
                message: describe(e),
            },
        }
    }

    async fn migration_status(&self) -> MigrationStatusResult {
        match collection_migration::migration_status(&self.store()) {
            Ok(status) => MigrationStatusResult {
                ok: true,
                message: format!(
                    "collections.unified = {}. {} legacy row(s), {} collection@1.0.0 row(s).",
                    status.migrated,
                    status.legacy_total(),
                    status.generic_total()
                ),
                migrated: status.migrated,
                legacy: status
                    .legacy
                    .into_iter()
                    .map(|c| LegacyCountDto {
                        schema_ref: c.schema_ref.to_string(),
                        kind_scope: c.kind_scope.to_string(),
                        rows: c.rows,
                    })
                    .collect(),
                generic: status
                    .generic
                    .into_iter()
                    .map(|c| KindScopeCountDto {
                        kind_scope: c.kind_scope,
                        rows: c.rows,
                        migrated: c.migrated,
                    })
                    .collect(),
            },
            Err(e) => MigrationStatusResult {
                ok: false,
                migrated: false,
                legacy: vec![],
                generic: vec![],
                message: describe(e),
            },
        }
    }

    async fn migrate(&self, dry_run: bool) -> MigrationReportResult {
        match collection_migration::migrate_collections(&self.store(), dry_run) {
            Ok(report) => MigrationReportResult {
                ok: true,
                message: if report.dry_run {
                    format!(
                        "DRY RUN — nothing written. {} legacy row(s) would be rewritten \
                         onto collection@1.0.0. Re-run with dry_run: false to apply.",
                        report.rewritten()
                    )
                } else {
                    format!(
                        "Rewrote {} legacy row(s) onto collection@1.0.0 and set \
                         collections.unified. Membership was not touched; `rollback` \
                         restores the originals byte-for-byte.",
                        report.rewritten()
                    )
                },
                dry_run: report.dry_run,
                was_migrated: report.was_migrated,
                membership_edges_untouched: report.membership_edges_untouched,
                bindings: report
                    .bindings
                    .into_iter()
                    .map(|b| BindingMigrationDto {
                        schema_ref: b.schema_ref.to_string(),
                        kind_scope: b.kind_scope.to_string(),
                        found: b.found,
                        rewritten: b.rewritten,
                        skipped_already_generic: b.skipped_already_generic,
                    })
                    .collect(),
            },
            Err(e) => MigrationReportResult {
                ok: false,
                dry_run,
                was_migrated: false,
                bindings: vec![],
                membership_edges_untouched: true,
                message: describe(e),
            },
        }
    }

    async fn rollback(&self) -> RollbackReportResult {
        match collection_migration::rollback_collections(&self.store()) {
            Ok(report) => RollbackReportResult {
                ok: true,
                message: format!(
                    "Restored {} row(s) to their original schema and payload; \
                     cleared collections.unified. {} native collection@1.0.0 \
                     row(s) were left alone.",
                    report.restored(),
                    report.native_generic_untouched
                ),
                restored: report
                    .bindings
                    .into_iter()
                    .map(|b| RollbackCountDto {
                        schema_ref: b.schema_ref,
                        restored: b.restored,
                    })
                    .collect(),
                native_generic_untouched: report.native_generic_untouched,
                membership_edges_untouched: report.membership_edges_untouched,
            },
            Err(e) => RollbackReportResult {
                ok: false,
                restored: vec![],
                native_generic_untouched: 0,
                membership_edges_untouched: true,
                message: describe(e),
            },
        }
    }
}

impress_service_impl! {
    service = CollectionService,
    impl = DefaultCollectionService,
    instance = DefaultCollectionService::new,
    methods = [
        tree(binding: String) -> CollectionListResult,
        create(
            binding: String,
            name: String,
            parent_id: Option<String>,
            kind_scope: Option<String>
        ) -> CollectionResult,
        rename(binding: String, id: String, name: String) -> CollectionResult,
        reparent(
            binding: String,
            id: String,
            new_parent_id: Option<String>
        ) -> CollectionResult,
        reorder(binding: String, id: String, sort_order: i64) -> CollectionResult,
        delete(binding: String, id: String) -> CollectionMutationResult,
        add_members(
            binding: String,
            collection_id: String,
            item_ids: Vec<String>
        ) -> CollectionMutationResult,
        remove_members(
            binding: String,
            collection_id: String,
            item_ids: Vec<String>
        ) -> CollectionMutationResult,
        member_counts(binding: String, collection_ids: Vec<String>) -> MemberCountsResult,
        migration_status() -> MigrationStatusResult,
        migrate(dry_run: bool) -> MigrationReportResult,
        rollback() -> RollbackReportResult,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{make_item, test_store};

    fn svc() -> DefaultCollectionService {
        DefaultCollectionService::with_store(test_store())
    }

    #[tokio::test]
    async fn binding_names_and_aliases_resolve() {
        for name in BINDING_NAMES {
            assert!(binding_for(name).is_ok(), "{name} must resolve");
        }
        assert_eq!(
            binding_for("publication").unwrap().schema_ref,
            "imbib/collection"
        );
        assert_eq!(
            binding_for("IMPRINT").unwrap().schema_ref,
            "manuscript-collection"
        );
        assert_eq!(binding_for("any").unwrap().schema_ref, "collection");
        let err = binding_for("mailbox").unwrap_err();
        assert!(
            err.contains("generic"),
            "error must list the options: {err}"
        );
    }

    #[tokio::test]
    async fn unknown_binding_fails_every_method_loudly() {
        let s = svc();
        assert!(!s.tree("mailbox".into()).await.ok);
        assert!(!s.create("mailbox".into(), "X".into(), None, None).await.ok);
        assert!(!s.delete("mailbox".into(), "id".into()).await.ok);
    }

    #[tokio::test]
    async fn create_tree_rename_reorder_reparent_delete_round_trip() {
        let s = svc();

        let root = s
            .create("generic".into(), "Root".into(), None, Some("any".into()))
            .await;
        assert!(root.ok, "{}", root.message);
        let root_id = root.collection.unwrap().id;

        let child = s
            .create(
                "generic".into(),
                "Child".into(),
                Some(root_id.clone()),
                Some("publication".into()),
            )
            .await;
        let child_row = child.collection.expect("child created");
        assert_eq!(child_row.parent_id.as_deref(), Some(root_id.as_str()));
        assert_eq!(child_row.kind_scope.as_deref(), Some("publication"));
        let child_id = child_row.id;

        // tree
        let tree = s.tree("generic".into()).await;
        assert!(tree.ok);
        assert_eq!(tree.collections.len(), 2);

        // rename
        let renamed = s
            .rename("generic".into(), child_id.clone(), "Renamed".into())
            .await;
        assert_eq!(renamed.collection.unwrap().name, "Renamed");

        // reorder
        let reordered = s.reorder("generic".into(), child_id.clone(), 7).await;
        assert_eq!(reordered.collection.unwrap().sort_order, 7);

        // reparent to root, then back
        let unparented = s.reparent("generic".into(), child_id.clone(), None).await;
        assert_eq!(unparented.collection.unwrap().parent_id, None);
        let reparented = s
            .reparent("generic".into(), child_id.clone(), Some(root_id.clone()))
            .await;
        assert_eq!(
            reparented.collection.unwrap().parent_id.as_deref(),
            Some(root_id.as_str())
        );

        // the cycle check reaches the tool surface
        let cycle = s
            .reparent("generic".into(), root_id.clone(), Some(child_id.clone()))
            .await;
        assert!(!cycle.ok);
        assert!(cycle.message.contains("cycle"), "{}", cycle.message);

        // delete
        let deleted = s.delete("generic".into(), child_id.clone()).await;
        assert!(deleted.ok, "{}", deleted.message);
        assert_eq!(s.tree("generic".into()).await.collections.len(), 1);
        assert!(!s.delete("generic".into(), child_id).await.ok);
    }

    #[tokio::test]
    async fn members_are_added_counted_and_removed() {
        let store = test_store();
        let s = DefaultCollectionService::with_store(store.clone());

        let mixed = s
            .create(
                "generic".into(),
                "Grant renewal".into(),
                None,
                Some("any".into()),
            )
            .await
            .collection
            .unwrap()
            .id;
        let empty = s
            .create("generic".into(), "Empty".into(), None, None)
            .await
            .collection
            .unwrap()
            .id;

        let manuscript = make_item(&store, "manuscript");
        let figure = make_item(&store, "figure");

        let added = s
            .add_members(
                "generic".into(),
                mixed.clone(),
                vec![manuscript.clone(), figure.clone()],
            )
            .await;
        assert!(added.ok);
        assert_eq!(added.applied, 2);

        let counts = s
            .member_counts("generic".into(), vec![mixed.clone(), empty.clone()])
            .await;
        assert!(counts.ok);
        assert_eq!(counts.counts, vec![2, 0], "counts align with the ids given");

        let removed = s
            .remove_members("generic".into(), mixed.clone(), vec![figure])
            .await;
        assert_eq!(removed.applied, 1);
        assert_eq!(
            s.member_counts("generic".into(), vec![mixed]).await.counts,
            vec![1]
        );
    }

    #[tokio::test]
    async fn every_binding_round_trips_through_the_service() {
        let store = test_store();
        let s = DefaultCollectionService::with_store(store.clone());

        for binding in BINDING_NAMES {
            let created = s
                .create(binding.into(), format!("{binding} root"), None, None)
                .await;
            assert!(created.ok, "{binding}: {}", created.message);
            let id = created.collection.unwrap().id;

            let child = s
                .create(binding.into(), "child".into(), Some(id.clone()), None)
                .await;
            assert!(child.ok, "{binding}: {}", child.message);

            let tree = s.tree(binding.into()).await;
            assert_eq!(tree.collections.len(), 2, "{binding} tree");

            // Membership works for both mechanics (Contains edge / envelope
            // parent), which is the whole point of the binding abstraction.
            let member = make_item(&store, "manuscript");
            let added = s
                .add_members(binding.into(), id.clone(), vec![member])
                .await;
            assert_eq!(added.applied, 1, "{binding}: {}", added.message);
            assert_eq!(
                s.member_counts(binding.into(), vec![id.clone()])
                    .await
                    .counts,
                vec![1],
                "{binding} member count"
            );
        }
    }

    // --- Schema convergence (ADR-0022 WP G7) -------------------------------

    #[tokio::test]
    async fn migration_status_reports_an_unmigrated_store() {
        let s = svc();
        s.create("imbib".into(), "Reading".into(), None, None).await;
        s.create("manuscript".into(), "Drafts".into(), None, None)
            .await;

        let status = s.migration_status().await;
        assert!(status.ok, "{}", status.message);
        assert!(!status.migrated, "the flag ships OFF");
        assert_eq!(status.legacy.len(), 3, "every legacy binding is enumerated");
        let imbib = status
            .legacy
            .iter()
            .find(|c| c.schema_ref == "imbib/collection")
            .expect("imbib line");
        assert_eq!(imbib.rows, 1);
        assert_eq!(imbib.kind_scope, "publication");
        assert!(status.generic.is_empty());
        assert!(status.message.contains("collections.unified"));
    }

    #[tokio::test]
    async fn migrate_dry_run_then_apply_then_rollback() {
        let store = test_store();
        let s = DefaultCollectionService::with_store(store.clone());

        let root = s
            .create("imbib".into(), "Reading".into(), None, None)
            .await
            .collection
            .unwrap()
            .id;
        s.create("imbib".into(), "Queue".into(), Some(root.clone()), None)
            .await;
        s.create("figure".into(), "Panels".into(), None, None).await;
        let paper = make_item(&store, "imbib/bibliography-entry");
        assert_eq!(
            s.add_members("imbib".into(), root.clone(), vec![paper.clone()])
                .await
                .applied,
            1
        );

        let before = s.tree("imbib".into()).await;

        // Dry run: reports, writes nothing.
        let dry = s.migrate(true).await;
        assert!(dry.ok, "{}", dry.message);
        assert!(dry.dry_run);
        assert!(!dry.was_migrated);
        assert!(dry.membership_edges_untouched);
        assert_eq!(dry.bindings.len(), 3);
        let dry_imbib = dry
            .bindings
            .iter()
            .find(|b| b.schema_ref == "imbib/collection")
            .unwrap();
        assert_eq!(dry_imbib.found, 2);
        assert_eq!(dry_imbib.rewritten, dry_imbib.found);
        assert!(dry.message.contains("DRY RUN"));
        assert!(
            !s.migration_status().await.migrated,
            "a dry run must not set the flag"
        );

        // Apply.
        let real = s.migrate(false).await;
        assert!(real.ok, "{}", real.message);
        assert!(!real.dry_run);
        let counts = |report: &MigrationReportResult| -> Vec<(String, u64, u64, u64)> {
            report
                .bindings
                .iter()
                .map(|b| {
                    (
                        b.schema_ref.clone(),
                        b.found,
                        b.rewritten,
                        b.skipped_already_generic,
                    )
                })
                .collect()
        };
        assert_eq!(
            counts(&real),
            counts(&dry),
            "the dry run predicted the real one, per binding"
        );
        let status = s.migration_status().await;
        assert!(status.migrated);
        assert_eq!(status.legacy.iter().map(|c| c.rows).sum::<u64>(), 0);
        assert_eq!(
            status
                .generic
                .iter()
                .find(|c| c.kind_scope == "publication")
                .unwrap()
                .migrated,
            2
        );

        // The service reads identically through the same binding name.
        let after = s.tree("imbib".into()).await;
        assert_eq!(after.collections.len(), before.collections.len());
        assert_eq!(
            s.member_counts("imbib".into(), vec![root.clone()])
                .await
                .counts,
            vec![1],
            "membership was not rewritten"
        );

        // Re-running is safe.
        let again = s.migrate(false).await;
        assert!(again.was_migrated);
        assert_eq!(again.bindings.iter().map(|b| b.rewritten).sum::<u64>(), 0);
        assert_eq!(
            again
                .bindings
                .iter()
                .find(|b| b.schema_ref == "imbib/collection")
                .unwrap()
                .skipped_already_generic,
            2
        );

        // Rollback.
        let back = s.rollback().await;
        assert!(back.ok, "{}", back.message);
        assert_eq!(back.restored.iter().map(|r| r.restored).sum::<u64>(), 3);
        assert_eq!(back.native_generic_untouched, 0);
        assert!(!s.migration_status().await.migrated);
        assert_eq!(
            s.tree("imbib".into()).await.collections.len(),
            before.collections.len()
        );
    }

    #[tokio::test]
    async fn rollback_leaves_native_generic_collections_alone() {
        let s = svc();
        s.create("imbib".into(), "Reading".into(), None, None).await;
        let native = s
            .create(
                "generic".into(),
                "Grant renewal".into(),
                None,
                Some("any".into()),
            )
            .await
            .collection
            .unwrap()
            .id;

        s.migrate(false).await;
        let back = s.rollback().await;
        assert_eq!(back.restored.iter().map(|r| r.restored).sum::<u64>(), 1);
        assert_eq!(
            back.native_generic_untouched, 1,
            "a natively-created collection@1.0.0 row has no legacy schema to go back to"
        );
        let generic = s.tree("generic".into()).await;
        assert_eq!(generic.collections.len(), 1);
        assert_eq!(generic.collections[0].id, native);
    }

    #[tokio::test]
    async fn a_binding_refuses_another_schemas_collections() {
        let s = svc();
        let generic = s
            .create("generic".into(), "Mixed".into(), None, None)
            .await
            .collection
            .unwrap()
            .id;
        let wrong = s.rename("manuscript".into(), generic, "Nope".into()).await;
        assert!(!wrong.ok);
        assert!(
            wrong.message.contains("manuscript-collection"),
            "{}",
            wrong.message
        );
    }
}
