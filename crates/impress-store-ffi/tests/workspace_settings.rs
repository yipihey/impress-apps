//! The GUI's first store open also anchors file-backed service settings.

use impress_store_ffi::SharedStore;

#[test]
fn settings_open_beside_the_installed_store_before_swift_opens_them() {
    let first = tempfile::tempdir().unwrap();
    let path = first.path().join("impress.sqlite");
    let _store = SharedStore::open(path.display().to_string()).unwrap();
    assert_eq!(impress_store_service::store_path(), path);
    assert_eq!(
        impress_store_service::settings_instance().directory(),
        first.path().join("settings")
    );

    // A secondary handle (review or test store) cannot retarget the app.
    let second = tempfile::tempdir().unwrap();
    let _other =
        SharedStore::open(second.path().join("impress.sqlite").display().to_string()).unwrap();
    assert_eq!(impress_store_service::store_path(), path);
    assert_eq!(
        impress_store_service::settings_instance().directory(),
        first.path().join("settings")
    );
}
