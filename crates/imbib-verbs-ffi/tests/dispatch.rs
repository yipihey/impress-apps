use imbib_verbs_ffi::{dispatch_verb, initialize_verb_store, ImbibVerbStoreError};

#[test]
fn domain_dispatch_uses_the_initialized_workspace_and_refuses_retargeting() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("impress.sqlite");
    let path_text = path.display().to_string();
    initialize_verb_store(path_text.clone()).unwrap();
    initialize_verb_store(path_text).unwrap();
    let other = root.path().join("must-not-open.sqlite");
    assert!(matches!(
        initialize_verb_store(other.display().to_string()),
        Err(ImbibVerbStoreError::DifferentPath)
    ));
    assert!(!other.exists());
    let response = dispatch_verb(
        "imbib-library-service_retention-cleanup".into(),
        "{}".into(),
        r#"{"kind":"system","name":"isolated-test"}"#.into(),
    );
    assert_eq!(response.status, 200, "{}", response.body_json);
    let value: serde_json::Value = serde_json::from_str(&response.body_json).unwrap();
    assert_eq!(value["inbox_removed"], 0);
    assert_eq!(
        imbib_service::store_singleton::default_workspace_dir(),
        root.path()
    );
}
