//! Construction safety must not turn old or newer-writer data into unreadable rows.

use impress_core::{schema::refs, SchemaRef};
use std::collections::BTreeSet;

#[test]
fn generated_vocabulary_equals_the_manifest() {
    let manifest: serde_json::Value =
        serde_json::from_str(include_str!("../../../schema-refs.json")).unwrap();
    let declared: BTreeSet<_> = manifest["canonical"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    let generated: BTreeSet<_> = refs::ALL.iter().map(SchemaRef::as_str).collect();
    assert_eq!(generated, declared);
    assert_eq!(refs::ALL.len(), generated.len());
    for schema in refs::ALL {
        assert_eq!(schema.as_str().parse::<SchemaRef>().unwrap(), *schema);
        assert_eq!(serde_json::to_value(schema).unwrap(), schema.as_str());
    }
}

#[test]
fn dynamic_names_are_exact_and_have_no_namespace_or_version_fallback() {
    for misspelling in [
        "manuscript-sectoin",
        "manuscript-section@1.0.0",
        "task",
        "Imbib/library",
    ] {
        assert!(
            misspelling.parse::<SchemaRef>().is_err(),
            "accepted {misspelling}"
        );
    }
    assert_eq!(
        "imbib/library".parse::<SchemaRef>().unwrap(),
        refs::IMBIB_LIBRARY
    );
}

#[cfg(feature = "sqlite")]
#[test]
fn opaque_persisted_names_survive_read_query_and_serialization() {
    use impress_core::{ItemQuery, ItemStore, SqliteItemStore};
    // An older row or a row synced from a newer writer is wire data, not a
    // declaration of another suite kind. Never add it to the manifest.
    let spelling = "fixture/future-schema@9.0.0";
    assert!(spelling.parse::<SchemaRef>().is_err());
    let opaque: SchemaRef = serde_json::from_value(serde_json::json!(spelling)).unwrap();
    let store = SqliteItemStore::open_in_memory().unwrap();
    let id = uuid::Uuid::new_v4();
    store
        .upsert_payload(id, opaque.clone(), Default::default())
        .unwrap();
    let row = store.get(id).unwrap().unwrap();
    assert_eq!(row.schema, opaque);
    assert_eq!(serde_json::to_value(&row).unwrap()["schema"], spelling);
    let rows = store
        .query(&ItemQuery {
            schema: Some(opaque),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].id, id);
}
