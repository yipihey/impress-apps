//! Native FFI initialization must check the open handle, not only a path hint.
use impress_core::sqlite_store::SqliteItemStore;
use impress_store_service::store::{
    install_store, install_store_at, set_store_path, store_instance,
};
use std::sync::Arc;

#[test]
fn a_cached_database_cannot_be_relabelled_as_another_native_workspace() {
    let dir = tempfile::tempdir().unwrap();
    let first_path = dir.path().join("first.sqlite");
    let second_path = dir.path().join("second.sqlite");
    let first = Arc::new(SqliteItemStore::open(&first_path).unwrap());
    let second = Arc::new(SqliteItemStore::open(&second_path).unwrap());
    let memory = Arc::new(SqliteItemStore::open_in_memory().unwrap());
    assert!(install_store_at(memory, &first_path).is_err());
    // Simulates a prior lazy/GUI open before any caller fixed STORE_PATH.
    install_store(first.clone()).unwrap();
    assert!(set_store_path(&second_path).is_err());
    assert!(install_store_at(second, &second_path).is_err());
    let same_file = Arc::new(SqliteItemStore::open(&first_path).unwrap());
    let selected = install_store_at(same_file, &first_path).unwrap();
    assert!(Arc::ptr_eq(&selected, &first));
    assert!(Arc::ptr_eq(&store_instance(), &first));
    assert_eq!(
        selected.database_path().unwrap().canonicalize().unwrap(),
        first_path.canonicalize().unwrap()
    );
}
