//! Registry ↔ manifest parity for impel-core. See
//! `crates/impress-core/tests/schema_ref_manifest.rs` for the rationale.
//!
//! impel WAS the worst case in the suite: its registry said `impel/task`, its
//! kernel wrote `task@1.0.0`, its Swift bridge wrote `impel/task`, and
//! impress-core registered a bare `task` nobody wrote — three spellings per
//! kind, tracked as `knownDivergences` because fixing them needed a data
//! migration over live user stores. WP C4 did that migration
//! (`impress_core::task_schema_migration`) and this test now pins the
//! CONVERGED state: one spelling per kind, and the registry's ids equal the
//! refs the writers emit.

use std::collections::BTreeSet;

#[path = "../../impress-core/tests/support/schema_ref_manifest_support.rs"]
mod manifest;

#[test]
fn impel_core_registry_matches_manifest() {
    let mut registry = impress_core::registry::SchemaRegistry::new();
    impel_core::schemas::register_impel_schemas(&mut registry);

    let registered: BTreeSet<String> = registry.list().iter().map(|s| s.id.clone()).collect();
    let declared = manifest::registry_ids("impel-core");

    manifest::assert_same_set("impel-core", &registered, &declared);
}

#[test]
fn every_registered_id_is_classified() {
    let m = manifest::load();
    let classified = manifest::classified_refs(&m);
    for id in manifest::registry_ids("impel-core") {
        assert!(
            classified.contains(&id),
            "impel-core registers {id:?} but schema-refs.json lists it in \
             neither `canonical` nor `registeredButUnwritten`."
        );
    }
}

/// The kernel's task-store constants are what actually reach `schema_ref`.
/// If one is edited, the manifest must be edited with it — otherwise the
/// call-site lint starts rejecting the kernel's own writes.
#[test]
fn task_store_constants_are_declared_refs() {
    let m = manifest::load();
    let known = manifest::classified_refs(&m)
        .union(&manifest::diverging_refs(&m))
        .cloned()
        .collect::<BTreeSet<_>>();

    for constant in [
        impel_core::TASK_SCHEMA,
        impel_core::AGENT_RUN_SCHEMA,
        impel_core::REVIEW_REQUEST_SCHEMA,
    ] {
        assert!(
            known.contains(constant),
            "impel-core writes rows with schema_ref {constant:?}, which \
             schema-refs.json does not declare. Every ref a writer emits must \
             be declared, or readers have nothing authoritative to copy."
        );
    }
}

/// The C4 invariant, in one assertion: what impel REGISTERS is exactly what
/// impel WRITES. This is the equality whose absence made
/// `SchemaRegistry::validate` a no-op for every task the kernel ever created,
/// and it is cheap enough to assert forever.
#[test]
fn the_registry_and_the_writers_agree() {
    let mut registry = impress_core::registry::SchemaRegistry::new();
    impel_core::schemas::register_impel_schemas(&mut registry);
    let registered: BTreeSet<String> = registry.list().iter().map(|s| s.id.clone()).collect();

    let written: BTreeSet<String> = [impel_core::TASK_SCHEMA, impel_core::AGENT_RUN_SCHEMA]
        .iter()
        .map(|s| s.to_string())
        .collect();

    assert_eq!(
        registered, written,
        "impel registers {registered:?} but writes {written:?}. A registered id \
         nothing writes is a query that returns zero rows forever; a written \
         ref nothing registers is a row nothing can validate."
    );
}

/// The retired spellings stay retired. A resurrected `impel/task` would
/// silently re-open the scheduler gap C4 closed, since `ready_tasks` selects
/// `task@1.0.0` only.
#[test]
fn the_retired_spellings_are_not_registered_again() {
    let mut registry = impress_core::registry::SchemaRegistry::new();
    impel_core::schemas::register_impel_schemas(&mut registry);
    for retired in ["impel/task", "impel/agent-run", "task", "agent-run"] {
        assert!(
            registry.get(retired).is_none(),
            "{retired:?} is back. It was converged onto the versioned ref by WP \
             C4; re-registering it needs a knownDivergences entry and a reason."
        );
    }
}

/// `review-request@1.0.0` is written and validated but registered NOWHERE, so
/// `SchemaRegistry::validate` is a no-op for those rows. Asserted rather than
/// left implicit: it is a real gap, and the assertion is where the next person
/// finds out about it.
#[test]
fn review_request_is_written_but_unregistered() {
    let declared = manifest::registry_ids("impel-core");
    assert!(
        !declared.contains(impel_core::REVIEW_REQUEST_SCHEMA),
        "review-request gained a registration — good; update this test and \
         schema-refs.json's note for `review-request@1.0.0`"
    );
}
