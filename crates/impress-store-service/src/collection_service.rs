//! `CollectionService` — the agent-facing twin of the collection kernel
//! (ADR-0022 D1/D5), now koine's.
//!
//! The twelve `collection-service_*` verbs, their DTOs and the default
//! deployment live in `koine-collections` (`koine_collections::service`),
//! over the store port; they register from koine's inventory, once. This
//! module re-exports them, so every `impress_store_service::collection_service`
//! path still resolves, and adds what is impress's:
//!
//! * the three app bindings (`imbib`, `manuscript`, `figure`, with the aliases
//!   the verbs always accepted) registered under their names;
//! * the SQLite implementation of the `migration-status`, `migrate` and
//!   `rollback` verbs ([`SqliteCollectionMigration`], over
//!   `impress_core::collection_migration`), which a store with a
//!   transactional rewrite of its own can offer and a koine host does not;
//! * [`sqlite_service`], a service over an explicit `SqliteItemStore` with
//!   both of the above, which is how the tests here run against a private
//!   database.
//!
//! [`register`] installs the first two for the process. It is idempotent and
//! `register_process_ports` calls it, so a host that registered its ports
//! already has them.

use std::sync::Arc;

use impress_core::collection_migration;
use impress_core::collection_ops::{FIGURE_COLLECTION, IMBIB_COLLECTION, MANUSCRIPT_COLLECTION};
use impress_core::sqlite_store::SqliteItemStore;
pub use koine_collections::service::*;

use crate::store::store_instance;

/// The primary names `binding` accepts, in the order the verbs always listed
/// them. (`koine_collections::service::binding_names` is the live list.)
pub const BINDING_NAMES: [&str; 4] = ["imbib", "manuscript", "figure", "generic"];

/// Register impress's collection bindings and its SQLite migration with the
/// verbs, once per process.
pub fn register() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(register_now);
}

fn register_now() {
    register_binding(
        &["imbib", "publication", "publications", "imbib/collection"],
        IMBIB_COLLECTION,
    );
    register_binding(
        &[
            "manuscript",
            "manuscripts",
            "imprint",
            "manuscript-collection",
        ],
        MANUSCRIPT_COLLECTION,
    );
    register_binding(
        &["figure", "figures", "implore", "figure-collection"],
        FIGURE_COLLECTION,
    );
    set_migration(Arc::new(SqliteCollectionMigration::process()));
}

/// A `CollectionService` over an explicit store, with impress's bindings and
/// the SQLite migration run against that same store.
pub fn sqlite_service(store: Arc<SqliteItemStore>) -> DefaultCollectionService {
    register();
    DefaultCollectionService::with_store(store.clone())
        .with_migration(Arc::new(SqliteCollectionMigration::with_store(store)))
}

/// The convergence verbs over `impress_core::collection_migration`.
pub struct SqliteCollectionMigration {
    store: Option<Arc<SqliteItemStore>>,
}

impl SqliteCollectionMigration {
    /// Run against the process's shared store, opened lazily.
    pub fn process() -> Self {
        Self { store: None }
    }

    /// Run against `store`.
    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self { store: Some(store) }
    }

    /// The store for MIGRATION verbs, which must never run against the
    /// in-memory fallback: a migrate that "succeeds" on an empty substitute
    /// reports success about data it never saw. An injected store (tests,
    /// embedding apps) is always trusted; only the lazily-opened global is
    /// checked. Found live on the first real flip attempt — a TCC-blocked
    /// open yielded `rows: 0` everywhere from a store that was not the
    /// user's.
    fn migration_store(&self) -> Result<Arc<SqliteItemStore>, String> {
        if let Some(store) = self.store.clone() {
            return Ok(store);
        }
        let store = store_instance();
        if crate::store::store_is_fallback() {
            return Err(format!(
                "REFUSING to run a migration verb: the real store at {} could not \
                 be opened and the service substituted an empty in-memory store. \
                 Fix access first (close apps holding the store; grant the \
                 terminal Full Disk Access for the app-group container) and re-run.",
                crate::store::store_path().display()
            ));
        }
        Ok(store)
    }
}

/// The `migrate` refusal shape, shared so the guard cannot drift from the DTO.
fn migration_report_refusal(message: String, dry_run: bool) -> MigrationReportResult {
    MigrationReportResult {
        ok: false,
        dry_run,
        was_migrated: false,
        bindings: vec![],
        membership_edges_untouched: true,
        message,
    }
}

impl CollectionMigration for SqliteCollectionMigration {
    fn status(&self) -> MigrationStatusResult {
        let store = match self.migration_store() {
            Ok(s) => s,
            Err(message) => {
                return MigrationStatusResult {
                    ok: false,
                    migrated: false,
                    legacy: vec![],
                    generic: vec![],
                    message,
                }
            }
        };
        match collection_migration::migration_status(&store) {
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
                message: e.to_string(),
            },
        }
    }

    fn migrate(&self, dry_run: bool) -> MigrationReportResult {
        let store = match self.migration_store() {
            Ok(s) => s,
            Err(message) => return migration_report_refusal(message, dry_run),
        };
        match collection_migration::migrate_collections(&store, dry_run) {
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
                message: e.to_string(),
            },
        }
    }

    fn rollback(&self) -> RollbackReportResult {
        let store = match self.migration_store() {
            Ok(s) => s,
            Err(message) => {
                return RollbackReportResult {
                    ok: false,
                    restored: vec![],
                    native_generic_untouched: 0,
                    membership_edges_untouched: true,
                    message,
                }
            }
        };
        match collection_migration::rollback_collections(&store) {
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
                message: e.to_string(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{make_item, test_store};

    fn svc() -> DefaultCollectionService {
        sqlite_service(test_store())
    }

    #[tokio::test]
    async fn binding_names_and_aliases_resolve() {
        register();
        for name in BINDING_NAMES {
            assert!(binding_for(name).is_ok(), "{name} must resolve");
        }
        assert_eq!(
            binding_for("publication").unwrap().schema_ref.as_str(),
            "imbib/collection"
        );
        assert_eq!(
            binding_for("IMPRINT").unwrap().schema_ref.as_str(),
            "manuscript-collection"
        );
        assert_eq!(
            binding_for("any").unwrap().schema_ref.as_str(),
            "collection"
        );
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
        let s = sqlite_service(store.clone());

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
        let s = sqlite_service(store.clone());

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
        let s = sqlite_service(store.clone());

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
