//! Separate test process: the service store is a process-wide OnceLock.

#[test]
fn explicit_store_initialization_selects_settings_workspace() {
    let workspace = tempfile::tempdir().expect("scratch workspace");
    let db_path = workspace.path().join("impress.sqlite");

    // A failed open must not claim the singleton. SQLite cannot open a
    // directory as its database, and the next valid initialization succeeds.
    assert!(
        imbib_service::store_singleton::init_imbib_store(workspace.path().to_path_buf()).is_err()
    );
    imbib_service::store_singleton::init_imbib_store(db_path.clone())
        .expect("initialize scratch store");

    assert_eq!(
        imbib_service::store_singleton::default_workspace_dir(),
        workspace.path()
    );
    assert!(db_path.exists(), "the explicit store was opened");

    let second_path = workspace.path().join("second.sqlite");
    assert!(imbib_service::store_singleton::init_imbib_store(second_path.clone()).is_err());
    assert!(
        !second_path.exists(),
        "rejected init must not open a second store"
    );
    assert_eq!(
        imbib_service::store_singleton::default_workspace_dir(),
        workspace.path()
    );
}
