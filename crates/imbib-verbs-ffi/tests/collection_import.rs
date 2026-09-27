use imbib_verbs_ffi::{dispatch_verb_async, initialize_verb_store};

#[tokio::test]
async fn collection_import_dispatch_files_new_and_existing_papers() {
    let root = tempfile::tempdir().unwrap();
    initialize_verb_store(root.path().join("impress.sqlite").display().to_string()).unwrap();

    let store = imbib_service::store_singleton::store_instance();
    let other = store.create_library("Other".into()).unwrap();
    let target = store.create_library("Target".into()).unwrap();
    let collection = store
        .create_collection("Reading".into(), target.id.clone(), false, None)
        .unwrap();
    let known = "@article{Known2026, title={Known}, doi={10.1/known}}";
    let known_id = store
        .import_bibtex(known.into(), other.id)
        .unwrap()
        .remove(0);

    let result = dispatch_verb_async(
        "imbib-library-service_import-bibtex-into-collection".into(),
        serde_json::json!({
            "bibtex": format!(
                "{known}\n@article{{New2026, title={{New}}, doi={{10.1/new}}}}"
            ),
            "library_id": target.id,
            "collection_id": collection.id,
        })
        .to_string(),
        r#"{"kind":"app","name":"imbib"}"#.into(),
    )
    .await;
    assert_eq!(result.status, 200, "{}", result.body_json);
    let outcome: serde_json::Value = serde_json::from_str(&result.body_json).unwrap();
    assert_eq!(outcome["existing"], serde_json::json!([known_id]));
    assert_eq!(outcome["imported"].as_array().unwrap().len(), 1);
    assert_eq!(outcome["added_to_collection"], 2);

    let members = store
        .list_collection_members(collection.id, "date_added".into(), false, None, None)
        .unwrap();
    assert_eq!(members.len(), 2);
    assert!(members.iter().any(|member| member.id == known_id));
    assert!(members
        .iter()
        .any(|member| member.id == outcome["imported"][0].as_str().unwrap()));
}
