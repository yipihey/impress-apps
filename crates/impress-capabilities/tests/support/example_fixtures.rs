//! Scratch fixtures shared by the Tier A correctness and effects-spy binaries.
//!
//! Each process owns its store, settings, files and compile cache. Fixture setup
//! and persisted readback happen outside the effects window, so neither can be
//! credited as an effect of the example under test.
use impress_core::collection_ops::{self, IMBIB_COLLECTION};
use impress_core::item::{ActorKind, Item, ItemId, Priority, Value as ItemValue, Visibility};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_service_core::{Example, VerbDescriptor};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

#[path = "g3_documents.rs"]
mod g3_documents;
#[path = "g3_layout.rs"]
mod g3_layout;
#[cfg(feature = "memory")]
#[path = "g3_memory.rs"]
mod g3_memory;
#[path = "g3_store_registry.rs"]
mod g3_store_registry;

struct Scratch {
    root: PathBuf,
    store: Arc<SqliteItemStore>,
}

fn scratch() -> &'static Scratch {
    static SCRATCH: OnceLock<Scratch> = OnceLock::new();
    SCRATCH.get_or_init(|| {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("impress-examples-{}-{stamp}", std::process::id()));
        std::fs::create_dir(&root).expect("new owned example directory");
        let path = root.join("impress.sqlite");
        // Before any service singleton can initialize. Never repurpose HOME.
        std::env::set_var("IMPRESS_STORE_PATH", &path);
        std::env::set_var("IMBIB_STORE_PATH", &path);
        std::env::set_var("IMPRESS_WORKSPACE", &root);
        std::env::set_var(
            "IMPRESS_DEVICE_ID",
            format!("examples-{}-{stamp}", std::process::id()),
        );
        std::env::set_var("IMPRINT_COMPILE_CACHE_DIR", root.join("compile-cache"));
        std::env::set_var("IMPRINT_WORKSPACE_ROOT", root.join("imprint"));
        std::env::set_var("IMPRESS_EMBEDDINGS_PATH", root.join("embeddings.sqlite"));
        std::env::set_var("IMPRESS_MEMORY_VECTORS", "0");
        let store = Arc::new(SqliteItemStore::open(&path).expect("open owned example store"));
        impress_store_service::install_store(store.clone()).expect("install example store");
        impress_store_service::set_settings_workspace(&root).expect("isolate settings files");
        impress_store_service::set_source_asset_root(root.join("assets"))
            .expect("isolate source assets");
        impress_store_service::set_source_cache_root(root.join("source-cache"))
            .expect("isolate source cache");
        seed_legacy(&store);
        eprintln!("Owned example workspace: {}", root.display());
        Scratch { root, store }
    })
}

pub fn store() -> Arc<SqliteItemStore> {
    scratch().store.clone()
}
pub fn root() -> &'static Path {
    &scratch().root
}

pub async fn prepare(
    verb: &VerbDescriptor,
    example: &Example,
    store: &Arc<SqliteItemStore>,
) -> Result<Value, String> {
    g3_store_registry::prepare(verb.name, example.name, store, root()).await?;
    g3_documents::prepare(verb.name, example.name, store, root()).await?;
    g3_layout::prepare(verb.name, example.name, store, root()).await?;
    #[cfg(feature = "memory")]
    g3_memory::prepare(verb.name, example.name, store, root()).await?;
    let args = resolve_fixture_paths(example.args_value(), root())?;
    // A documented negative example may deliberately omit a required field.
    // It must still go through the pipeline and match its asserted refusal.
    let expects_refusal = example
        .expect
        .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
        .is_some_and(|expected| expected.get("ok").and_then(Value::as_bool) == Some(false));
    if !expects_refusal {
        validate_schema(&(verb.input_schema)(), &args)
            .map_err(|error| format!("{} example {} input: {error}", verb.name, example.name))?;
    }
    Ok(args)
}

pub fn verify(
    verb: &VerbDescriptor,
    example: &Example,
    store: &Arc<SqliteItemStore>,
    args: &Value,
    result: &Value,
) -> Result<(), String> {
    if [
        "settings-service_",
        "source-service_",
        "manuscript-collab-service_",
    ]
    .iter()
    .any(|prefix| verb.name.starts_with(prefix))
    {
        g3_store_registry::verify(verb.name, example.name, store, args, result)?;
    }
    g3_documents::verify(verb.name, example.name, store, args, result)?;
    g3_layout::verify(verb.name, example.name, store, args, result)?;
    #[cfg(feature = "memory")]
    g3_memory::verify(verb.name, example.name, store, args, result)?;
    if verb.name == "imbib-library-service_import-bibtex-into-collection" {
        verify_bibtex_collection_example(result, store, args)?;
    }
    Ok(())
}

/// Only this documented prefix is expanded. Surface `{{state...}}` strings
/// and all other literal text pass through unchanged; a path cannot escape
/// the runner-owned root by using absolute components or `..`.
fn resolve_fixture_paths(value: Value, root: &Path) -> Result<Value, String> {
    match value {
        Value::String(text) if text.starts_with("{{fixture.root}}") => {
            let suffix = text
                .strip_prefix("{{fixture.root}}")
                .expect("matched prefix");
            if !suffix.is_empty() && !suffix.starts_with('/') {
                return Err("fixture root must end at a path component boundary".into());
            }
            let relative = Path::new(suffix.strip_prefix('/').unwrap_or(suffix));
            if relative.components().any(|component| {
                !matches!(
                    component,
                    std::path::Component::Normal(_) | std::path::Component::CurDir
                )
            }) {
                return Err("fixture path escapes the owned workspace".into());
            }
            Ok(Value::String(
                root.join(relative).to_string_lossy().into_owned(),
            ))
        }
        Value::String(text) if text.starts_with("{{fixture.") => {
            Err(format!("unknown example fixture token: {text}"))
        }
        Value::Array(values) => values
            .into_iter()
            .map(|item| resolve_fixture_paths(item, root))
            .collect::<Result<Vec<_>, _>>()
            .map(Value::Array),
        Value::Object(values) => values
            .into_iter()
            .map(|(key, item)| Ok((key, resolve_fixture_paths(item, root)?)))
            .collect::<Result<serde_json::Map<_, _>, String>>()
            .map(Value::Object),
        other => Ok(other),
    }
}

#[cfg(test)]
mod fixture_path_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn paths_expand_only_inside_owned_root() {
        let root = Path::new("/tmp/owned-example");
        assert_eq!(
            resolve_fixture_paths(
                json!({"path":"{{fixture.root}}/documents/readme.md", "bind":"{{state.value}}"}),
                root
            )
            .unwrap(),
            json!({"path":"/tmp/owned-example/documents/readme.md", "bind":"{{state.value}}"})
        );
        for text in [
            "{{fixture.root}}/../outside",
            "{{fixture.root}}//outside",
            "{{fixture.root}}suffix",
            "{{fixture.unknown}}",
        ] {
            assert!(
                resolve_fixture_paths(json!(text), root).is_err(),
                "accepted {text}"
            );
        }
    }
}

/// No external schema resolution: examples only use the descriptor's bundled schema.
pub fn validate_schema(schema: &Value, instance: &Value) -> Result<(), String> {
    struct NoExternal;
    impl jsonschema::Retrieve for NoExternal {
        fn retrieve(
            &self,
            _uri: &jsonschema::Uri<String>,
        ) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
            Err("external schema references are forbidden in example tests".into())
        }
    }
    let validator = jsonschema::options()
        .with_retriever(NoExternal)
        .build(schema)
        .map_err(|error| format!("invalid descriptor schema: {error}"))?;
    validator
        .validate(instance)
        .map_err(|error| format!("schema mismatch at {}: {error}", error.instance_path))
}

fn seed_legacy(store: &SqliteItemStore) {
    // The BibTeX-to-collection example must import into real parents.
    // Seed deterministic IDs before the spy opens its window: these
    // fixtures are not writes of the verb being measured.
    let library_id =
        ItemId::parse_str("56000000-0000-4000-8000-000000000041").expect("effects library id");
    let collection_id =
        ItemId::parse_str("56000000-0000-4000-8000-000000000042").expect("effects collection id");
    let mut library = seed_item(library_id, "imbib/library", None);
    library
        .payload
        .insert("name".into(), ItemValue::String("Effects library".into()));
    library
        .payload
        .insert("is_default".into(), ItemValue::Bool(false));
    library
        .payload
        .insert("is_inbox".into(), ItemValue::Bool(false));
    library
        .payload
        .insert("is_system".into(), ItemValue::Bool(false));
    store.insert(library).expect("seed effects library");
    let mut collection = seed_item(collection_id, "imbib/collection", Some(library_id));
    collection.payload.insert(
        "name".into(),
        ItemValue::String("Effects collection".into()),
    );
    collection
        .payload
        .insert("is_smart".into(), ItemValue::Bool(false));
    collection
        .payload
        .insert("sort_order".into(), ItemValue::Int(0));
    store.insert(collection).expect("seed effects collection");
    // S3 needs a recorded session before it can write a scenario.
    // Seed outside the spy window: this fixture is not an effect
    // of the verb being measured. Record stores its harmless list
    // step for review; it does not execute that step.
    impress_core::call_context::record_verb_call(
        store,
        "56000000-0000-4000-8000-000000000003",
        &impress_service_core::pipeline::CallerIdentity::Person,
        serde_json::json!({
            "trace_id": "scenario-record-example",
            "started_at": "2026-09-27T00:00:00.000Z",
            "verb": "impress-scenario-service_scenario-list",
            "args": {}, "args_replayable": true,
            "result_ids": {}, "result_ids_truncated": false,
            "ok": true, "code": null,
        })
        .as_object()
        .unwrap()
        .clone(),
    )
    .expect("seed S3 recording example");
}

fn seed_item(id: ItemId, schema: &str, parent: Option<ItemId>) -> Item {
    Item {
        id,
        schema: schema.parse().expect("declared effects fixture schema"),
        payload: BTreeMap::new(),
        created: std::time::SystemTime::UNIX_EPOCH.into(),
        modified: std::time::SystemTime::UNIX_EPOCH.into(),
        author: "system:effects-fixture".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent,
    }
}

pub fn verify_bibtex_collection_example(
    result: &Value,
    store: &SqliteItemStore,
    args: &Value,
) -> Result<(), String> {
    let imported = result["imported"]
        .as_array()
        .ok_or("BibTeX import omitted imported IDs")?;
    if imported.len() != 1
        || result["existing"] != serde_json::json!([])
        || result["added_to_collection"] != 1
    {
        return Err(format!(
            "BibTeX import did not create and file one paper: {result}"
        ));
    }
    let paper_id_text = imported[0]
        .as_str()
        .ok_or("BibTeX import ID is not a string")?;
    let paper_id = ItemId::parse_str(paper_id_text).map_err(|e| e.to_string())?;
    let paper = store
        .get(paper_id)
        .map_err(|e| e.to_string())?
        .ok_or("imported paper was not saved")?;
    let library_id_text = args["library_id"]
        .as_str()
        .ok_or("example omitted library_id")?;
    let library_id = ItemId::parse_str(library_id_text).map_err(|e| e.to_string())?;
    if paper.schema != impress_core::schema::refs::IMBIB_BIBLIOGRAPHY_ENTRY
        || paper.parent != Some(library_id)
        || paper.payload.get("title") != Some(&ItemValue::String("P5b Effects Paper".into()))
    {
        return Err(format!(
            "imported paper did not read back as expected: {paper:?}"
        ));
    }
    let collection_id = args["collection_id"]
        .as_str()
        .ok_or("example omitted collection_id")?;
    let members = collection_ops::list_members(store, &IMBIB_COLLECTION, collection_id)
        .map_err(|e| e.to_string())?;
    if members.len() != 1 || members[0].id != paper_id {
        return Err(format!(
            "imported paper is absent from the collection: {members:?}"
        ));
    }
    Ok(())
}
