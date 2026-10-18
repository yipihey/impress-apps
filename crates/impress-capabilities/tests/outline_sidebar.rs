//! The sidebar as verbs, over the suite's SQLite store
//! (docs/plan-l8-sidebar-surface.md, work package A3).
//!
//! `impress-layout-service`'s outline verbs (SB-D1..D5) are koine's; their own
//! tests run over a memory store and a stand-in for the collection kernel.
//! What only this crate can prove is the whole chain over the real thing: the
//! rows counted by `SqliteItemStore`, `outline-rename` / `-move` / `-delete`
//! forwarding to the linked `collection-service_*` kernel and the kernel
//! writing the payload, and the sidebar spec rendering as a `tree` through the
//! surface runtime with the declared reads re-running it on a write.
//!
//! The three cases share ONE process store (`install_store` fixes it for the
//! binary), so each seeds its own library and asserts about its own rows; the
//! Inbox library, which the sidebar treats as unique, is seeded once.
#![cfg(all(feature = "imbib", feature = "kit"))]

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, OnceLock};

use impress_core::item::{ActorKind, Item, ItemId, Priority, Value as ItemValue, Visibility};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_item::reference::{EdgeType, TypedReference};
use impress_service_core::call::call_async_as;
use impress_service_core::pipeline::CallerIdentity;
use impress_surface::SurfaceSpec;
use impress_surface_service::{DefaultExecutor, SessionRegistry, SurfaceStore};
use serde_json::{json, Value};

const HOST: &str = "outline-sidebar-host";
const PUBLICATION_REF: &str = "imbib/bibliography-entry";
const COLLECTION_REF: &str = "imbib/collection";

struct World {
    store: Arc<SqliteItemStore>,
    /// Keeps the store's directory alive for the life of the process.
    _dir: tempfile::TempDir,
}

/// The one process store: SQLite over a temp file, installed as the store
/// every inventory verb (the layout service's rows, the collection kernel)
/// reads, with the process ports (manifest, subtree resolver) registered.
fn world() -> &'static World {
    static WORLD: OnceLock<World> = OnceLock::new();
    WORLD.get_or_init(|| {
        let dir = tempfile::tempdir().expect("tempdir");
        let store = Arc::new(SqliteItemStore::open(&dir.path().join("outline.sqlite")).unwrap());
        impress_store_service::register_process_ports();
        impress_store_service::install_store(store.clone()).expect("install the process store");
        impress_capabilities::force_link();
        // The Inbox library is unique to a store: one, for every case.
        insert(
            &store,
            impress_core::schema::refs::IMBIB_LIBRARY,
            vec![
                ("name", ItemValue::String("Inbox".into())),
                ("is_inbox", ItemValue::Bool(true)),
            ],
            None,
            vec![],
        );
        World { store, _dir: dir }
    })
}

fn insert(
    store: &SqliteItemStore,
    schema: impress_core::SchemaRef,
    payload: Vec<(&str, ItemValue)>,
    parent: Option<ItemId>,
    references: Vec<TypedReference>,
) -> ItemId {
    let now = chrono::Utc::now();
    store
        .insert(Item {
            id: uuid::Uuid::new_v4(),
            schema,
            payload: payload
                .into_iter()
                .map(|(k, v)| (k.to_string(), v))
                .collect(),
            created: now,
            modified: now,
            author: "outline-sidebar-test".into(),
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
            references,
            parent,
            extra: Default::default(),
        })
        .expect("insert")
}

fn library(store: &SqliteItemStore, name: &str) -> ItemId {
    insert(
        store,
        impress_core::schema::refs::IMBIB_LIBRARY,
        vec![
            ("name", ItemValue::String(name.into())),
            ("is_inbox", ItemValue::Bool(false)),
        ],
        None,
        vec![],
    )
}

fn paper(store: &SqliteItemStore, title: &str, library: ItemId) -> ItemId {
    insert(
        store,
        impress_core::schema::refs::IMBIB_BIBLIOGRAPHY_ENTRY,
        vec![("title", ItemValue::String(title.into()))],
        Some(library),
        vec![],
    )
}

/// A collection of `library` filing `members` the way `collection_ops` does:
/// a `Contains` edge from the collection to each member; the envelope parent
/// is the owning library and the tree parent is the payload `parent_id`.
fn collection(
    store: &SqliteItemStore,
    name: &str,
    library: ItemId,
    sort_order: i64,
    members: &[ItemId],
) -> ItemId {
    insert(
        store,
        impress_core::schema::refs::IMBIB_COLLECTION,
        vec![
            ("name", ItemValue::String(name.into())),
            ("sort_order", ItemValue::Int(sort_order)),
        ],
        Some(library),
        members
            .iter()
            .map(|m| TypedReference {
                target: *m,
                edge_type: EdgeType::Contains,
                metadata: None,
            })
            .collect(),
    )
}

async fn call(verb: &str, args: Value) -> Value {
    call_async_as(verb, CallerIdentity::agent("outline-sidebar-test"), args)
        .await
        .unwrap_or_else(|e| panic!("{verb}: {e}"))
}

async fn outline_rows() -> Vec<Value> {
    let answer = call("layout-service_outline-rows", json!({ "app_id": "imbib" })).await;
    assert_eq!(answer["ok"], true, "{answer}");
    answer["rows"].as_array().expect("rows").clone()
}

fn row<'a>(rows: &'a [Value], key: &str) -> &'a Value {
    rows.iter().find(|r| r["id"] == key).unwrap_or_else(|| {
        panic!(
            "no row {key} in {:?}",
            rows.iter().map(|r| &r["id"]).collect::<Vec<_>>()
        )
    })
}

fn payload_of(store: &SqliteItemStore, id: ItemId) -> BTreeMap<String, ItemValue> {
    store.get(id).unwrap().expect("the item exists").payload
}

#[tokio::test]
async fn the_outline_rows_count_what_the_list_shows() {
    let world = world();
    let store = &world.store;
    let lib = library(store, "Counted");
    let first = paper(store, "A dark matter survey", lib);
    paper(store, "A second paper", lib);
    let coll = collection(store, "Dark matter", lib, 0, &[first]);

    let rows = outline_rows().await;

    // The sections are the app's table; the inbox library is not a library row.
    assert_eq!(row(&rows, "section:libraries")["kind"], "section");
    let lib_key = format!("library:{lib}");
    let coll_key = format!("collection:{coll}");

    let lib_row = row(&rows, &lib_key);
    assert_eq!(lib_row["label"], "Counted");
    assert_eq!(lib_row["parent"], "section:libraries");
    assert_eq!(lib_row["kind"], "library");
    assert_eq!(
        lib_row["count"], 2,
        "two papers are in the library: {lib_row}"
    );

    let coll_row = row(&rows, &coll_key);
    assert_eq!(coll_row["label"], "Dark matter");
    assert_eq!(
        coll_row["parent"], lib_key,
        "the collection is nested under its library's key"
    );
    assert_eq!(coll_row["kind"], "collection");
    assert_eq!(coll_row["count"], 1, "one paper is filed in it: {coll_row}");
}

#[tokio::test]
async fn renaming_a_collection_row_reaches_the_kernel() {
    let world = world();
    let store = &world.store;
    let lib = library(store, "Kernel");
    let first = paper(store, "Kept one", lib);
    let second = paper(store, "Kept two", lib);
    let coll = collection(store, "Before", lib, 0, &[first, second]);
    let coll_key = format!("collection:{coll}");
    let lib_key = format!("library:{lib}");

    // Rename: one forwarded `collection-service_rename`, and the payload moved.
    let renamed = call(
        "layout-service_outline-rename",
        json!({ "app_id": "imbib", "key": coll_key, "name": "Renamed" }),
    )
    .await;
    assert_eq!(renamed["ok"], true, "{renamed}");
    let forwarded = renamed["forwarded"].as_array().expect("forwarded");
    assert_eq!(forwarded.len(), 1, "{renamed}");
    assert_eq!(forwarded[0]["verb"], "collection-service_rename");
    assert_eq!(
        payload_of(store, coll).get("name"),
        Some(&ItemValue::String("Renamed".into()))
    );
    let rows = outline_rows().await;
    assert_eq!(row(&rows, &coll_key)["label"], "Renamed");

    // A second collection to nest under, then move the first under it...
    let parent = collection(store, "Parent", lib, 1, &[]);
    let nested = call(
        "layout-service_outline-move",
        json!({ "app_id": "imbib", "keys": [coll_key], "to": format!("collection:{parent}") }),
    )
    .await;
    assert_eq!(nested["ok"], true, "{nested}");
    assert_eq!(
        payload_of(store, coll).get("parent_id"),
        Some(&ItemValue::String(parent.to_string())),
        "the kernel wrote the tree parent"
    );
    let rows = outline_rows().await;
    assert_eq!(
        row(&rows, &coll_key)["parent"],
        format!("collection:{parent}"),
        "the row nests under its new parent"
    );

    // ...and a drop ON a library row is a move to the library's root.
    let rooted = call(
        "layout-service_outline-move",
        json!({ "app_id": "imbib", "keys": [coll_key], "to": lib_key }),
    )
    .await;
    assert_eq!(rooted["ok"], true, "{rooted}");
    assert_eq!(rooted["forwarded"].as_array().unwrap().len(), 1, "{rooted}");
    assert_eq!(
        rooted["forwarded"][0]["verb"],
        "collection-service_reparent"
    );
    let parent_id = payload_of(store, coll).get("parent_id").cloned();
    assert!(
        matches!(parent_id, None | Some(ItemValue::Null)),
        "parent_id is cleared, not set to the library: {parent_id:?}"
    );
    let rows = outline_rows().await;
    assert_eq!(row(&rows, &coll_key)["parent"], lib_key);

    // A library row is refused, naming itself, and nothing was forwarded.
    let refused = call(
        "layout-service_outline-rename",
        json!({ "app_id": "imbib", "key": lib_key, "name": "Nope" }),
    )
    .await;
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["code"], "invalid-argument");
    assert!(refused["forwarded"].as_array().unwrap().is_empty());

    // Delete: the collection goes, its members do not.
    let deleted = call(
        "layout-service_outline-delete",
        json!({ "app_id": "imbib", "keys": [coll_key] }),
    )
    .await;
    assert_eq!(deleted["ok"], true, "{deleted}");
    assert_eq!(deleted["forwarded"][0]["verb"], "collection-service_delete");
    assert!(store.get(coll).unwrap().is_none(), "the collection is gone");
    assert!(store.get(first).unwrap().is_some(), "members survive");
    assert!(store.get(second).unwrap().is_some(), "members survive");
    let rows = outline_rows().await;
    assert!(rows.iter().all(|r| r["id"] != coll_key.as_str()));
    assert_eq!(row(&rows, &lib_key)["count"], 2, "both papers still count");
}

fn tree_node_ids(tree: &Value, out: &mut Vec<String>) {
    match tree {
        Value::Object(map) => {
            if let Some(Value::String(id)) = map.get("id") {
                out.push(id.clone());
            }
            map.values().for_each(|v| tree_node_ids(v, out));
        }
        Value::Array(items) => items.iter().for_each(|v| tree_node_ids(v, out)),
        _ => {}
    }
}

/// The node of the rendered outline tree named `id`, wherever it nests.
fn find_node<'a>(tree: &'a Value, id: &str) -> Option<&'a Value> {
    match tree {
        Value::Object(map) => {
            if map.get("id").and_then(Value::as_str) == Some(id) && map.contains_key("label") {
                return Some(tree);
            }
            map.values().find_map(|v| find_node(v, id))
        }
        Value::Array(items) => items.iter().find_map(|v| find_node(v, id)),
        _ => None,
    }
}

#[tokio::test]
async fn the_sidebar_spec_renders_over_the_suite_store() {
    let world = world();
    let store = &world.store;
    let lib = library(store, "Rendered");
    let first = paper(store, "First", lib);
    let second = paper(store, "Second", lib);
    let coll = collection(store, "Reading", lib, 0, &[first]);
    let coll_key = format!("collection:{coll}");

    // The spec the FFI's `outline_surface_spec_json("imbib", "")` answers
    // (impress-store-ffi is above this crate, so the function it wraps is
    // called here), through the JSON the host stores.
    let spec: SurfaceSpec = serde_json::from_str(
        &serde_json::to_string(&impress_layout_service::outline_surface_spec(
            "imbib",
            &BTreeMap::new(),
        ))
        .unwrap(),
    )
    .expect("the spec reads back");

    let surfaces = SurfaceStore::new(world.store.clone());
    let registry = SessionRegistry::with_manifest(impress_core::pane_query::builtin_manifest());
    let executor = Arc::new(DefaultExecutor::with_store(
        world.store.clone(),
        impress_core::pane_query::builtin_manifest(),
    ));
    let row = surfaces
        .create(
            &spec,
            None,
            &["outline:imbib".to_string()],
            ActorKind::Human,
        )
        .unwrap();
    // The sidebar opens on its sections, as the legacy one does; the user
    // opens a library to see its collections. State is per host.
    let mut open = spec.state["open"].as_array().cloned().expect("seeded open");
    open.push(json!(format!("library:{lib}")));
    surfaces
        .set_state(row.id, HOST, &json!({ "open": open }), ActorKind::Human)
        .unwrap();
    let render = || async {
        let tree = registry
            .with(&surfaces, row.id, HOST, {
                let executor = executor.clone();
                move |rt| Box::pin(async move { Ok(rt.render(executor.as_ref()).await) })
            })
            .await
            .unwrap();
        serde_json::to_value(&tree).unwrap()
    };

    let before = render().await;
    let root = &before["root"];
    assert!(
        root.to_string().contains("\"tree\""),
        "the outline renders as a tree: {root}"
    );
    let mut ids = Vec::new();
    tree_node_ids(&before, &mut ids);
    let ids: BTreeSet<String> = ids.into_iter().collect();
    for wanted in [
        "section:libraries".to_string(),
        format!("library:{lib}"),
        coll_key.clone(),
    ] {
        assert!(
            ids.contains(&wanted),
            "{wanted} is a node of the tree: {ids:?}"
        );
    }
    let node = find_node(&before, &coll_key).expect("the collection node");
    assert_eq!(node["label"], "Reading");
    assert_eq!(node["count"], 1, "{node}");

    // The rows verb declared its reads, so the runtime watches them.
    let watched = registry.watched_refs();
    for declared in [PUBLICATION_REF, COLLECTION_REF] {
        assert!(
            watched.contains(declared),
            "{declared} is watched: {watched:?}"
        );
    }

    // File a second paper into the collection through the kernel, as the
    // sidebar's drop would; the write names the collection kind, which the
    // rows source declared it reads.
    let filed = call(
        "collection-service_add-members",
        json!({
            "binding": "imbib",
            "collection_id": coll.to_string(),
            "item_ids": [second.to_string()],
        }),
    )
    .await;
    assert_eq!(filed["ok"], true, "{filed}");
    let named = BTreeSet::from([COLLECTION_REF.to_string()]);
    assert_eq!(
        registry.invalidate_refs(&named),
        vec![row.id],
        "a write to the collection kind marks the sidebar dirty"
    );

    let after = render().await;
    let node = find_node(&after, &coll_key).expect("the collection node");
    assert_eq!(
        node["count"], 2,
        "the badge moved without a refresh: {node}"
    );
}
