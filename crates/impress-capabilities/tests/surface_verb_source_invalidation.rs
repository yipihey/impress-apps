//! EF-4 / RS-S2 (E3): a `verb` source re-runs on a write to its declared read.
//!
//! It was a case of `impress-surface-service`'s `tests/coherence.rs` until that
//! crate moved to koine (docs/plan-koine-host.md K3b): the verb it drives,
//! `imbib-library-service_count-publications`, is imbib's, and its store is
//! `imbib_service::store_singleton`'s own `ImbibStore` over a SQLite file, which
//! a koine crate cannot name. The test needs the real inventory's own
//! declaration of what the verb reads (no test double), so it runs here, where
//! `imbib-service` is linked.
#![cfg(feature = "imbib")]

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use impress_core::item::{ActorKind, Item, ItemId, Priority, Value as ItemValue, Visibility};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_surface::SurfaceSpec;
use impress_surface_service::{DefaultExecutor, SessionRegistry, SurfaceStore};
use serde_json::{json, Value};

const HOST: &str = "coherence-host";
const PUBLICATION_REF: &str = "imbib/bibliography-entry";

fn spec(value: Value) -> SurfaceSpec {
    serde_json::from_value(value).expect("fixture spec parses")
}

fn tree_json(tree: &impress_surface::RenderTree) -> String {
    serde_json::to_string(tree).unwrap()
}

fn insert_paper(store: &SqliteItemStore, title: &str) -> ItemId {
    let mut payload = BTreeMap::new();
    payload.insert("title".to_string(), ItemValue::String(title.to_string()));
    let now = chrono::Utc::now();
    store
        .insert(Item {
            id: uuid::Uuid::new_v4(),
            schema: impress_core::schema::refs::IMBIB_BIBLIOGRAPHY_ENTRY,
            payload,
            created: now,
            modified: now,
            author: "test".into(),
            author_kind: ActorKind::Human,
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
        })
        .unwrap()
}

/// `imbib-library-service_count-publications` is linked (`imbib-service`,
/// force-linked below) and declares `effects(reads = ["imbib/bibliography-entry"])`
/// (`docs/verb-effects.md`) — no test double, the real inventory's own
/// declaration.
#[allow(unused_imports)]
use imbib_service::library_service as _force_link_imbib_library_service;

fn count_publications_spec() -> SurfaceSpec {
    spec(json!({
        "surface": "1.0",
        "name": "Publication count",
        "state": {},
        "sources": {
            "count": { "verb": "imbib-library-service_count-publications", "args": {} }
        },
        "root": { "column": [
            { "text": "{{source.count}}", "id": "count" }
        ] }
    }))
}

/// The Tier A proof named in the plan's E3 row: a `verb` source over a verb
/// that reads `imbib/bibliography-entry` (`imbib-library-service_count-publications`,
/// `triage-service_set-starred`'s sibling verb on the same kind) re-renders
/// after a write to that kind — closing EF-4/RS-S2. Before the fix, a `verb`
/// source's declared reads were not folded into `query_refs`/`invalidate_sources`
/// at all, so `invalidate_refs` never marked this surface and this test failed
/// (the count source was never asked again).
#[tokio::test]
async fn a_verb_source_reruns_on_a_write_to_its_declared_read() {
    // `imbib-library-service_count-publications` runs through the linked
    // INVENTORY (`call_verb`), against `imbib_service::store_singleton`'s
    // OWN process-wide `ImbibStore` (not `impress_store_service`'s, and not
    // injectable by `Arc` — only by path). It wraps `SqliteItemStore` over
    // the same file format, so opening this test's `surfaces`/`store` at a
    // real temp-file path and pointing the imbib singleton at the SAME path
    // (`init_imbib_store`) gives both handles the same rows, the same way
    // `interleaved_writers_on_two_connections_never_share_a_seq` (below)
    // opens two connections on one file. This is the only caller of
    // `init_imbib_store` in this test binary.
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("e3-verb-source.sqlite");
    let store = Arc::new(SqliteItemStore::open(&path).unwrap());
    let surfaces = SurfaceStore::new(store.clone());
    let registry = SessionRegistry::with_manifest(impress_core::pane_query::builtin_manifest());
    let executor = Arc::new(DefaultExecutor::with_store(
        store.clone(),
        impress_core::pane_query::builtin_manifest(),
    ));
    imbib_service::store_singleton::init_imbib_store(path)
        .expect("init the imbib store singleton at this test's path (something else already did)");
    insert_paper(&store, "A dark matter survey");
    let row = surfaces
        .create(&count_publications_spec(), None, &[], ActorKind::Agent)
        .unwrap();

    let before = registry
        .with(&surfaces, row.id, HOST, {
            let executor = executor.clone();
            move |rt| Box::pin(async move { Ok(rt.render(executor.as_ref()).await) })
        })
        .await
        .unwrap();
    assert!(
        tree_json(&before).contains("\"text\":\"1\""),
        "expected one publication: {before:?}"
    );

    // The runtime now watches the verb's declared read.
    assert_eq!(
        registry.watched_refs(),
        BTreeSet::from([PUBLICATION_REF.to_string()])
    );

    // A second paper is written; the write feed names the kind the verb
    // declared it reads.
    insert_paper(&store, "A second paper");
    let named = BTreeSet::from([PUBLICATION_REF.to_string()]);
    assert_eq!(
        registry.invalidate_refs(&named),
        vec![row.id],
        "the write to the verb's declared read should mark this surface dirty"
    );

    let after = registry
        .with(&surfaces, row.id, HOST, {
            let executor = executor.clone();
            move |rt| Box::pin(async move { Ok(rt.render(executor.as_ref()).await) })
        })
        .await
        .unwrap();
    assert!(
        tree_json(&after).contains("\"text\":\"2\""),
        "the verb source should have re-run and now show two publications: {after:?}"
    );
}
