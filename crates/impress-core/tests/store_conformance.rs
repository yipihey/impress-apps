//! `SqliteItemStore` passes the koine store conformance suite
//! (koine docs/plan-koine-store.md D6).
//!
//! This store is the suite's oracle: its cases were written from this file's
//! behaviour and run against it before the memory and directory backends in
//! koine passed them. Running the suite here closes the loop, so a change to
//! this store that moves the port's behaviour fails a named case instead of
//! drifting the other backends. `:memory:` declares neither durable nor
//! shared, so its reopen cases skip loudly; the file-backed instantiation
//! opens one database twice for them.
#![cfg(feature = "sqlite")]

use std::path::{Path, PathBuf};

use impress_core::sqlite_store::SqliteItemStore;
use impress_item::AttributedStore;

fn fresh_db() -> PathBuf {
    let dir = tempfile::tempdir().expect("temp dir");
    let path = dir.path().join("store.sqlite");
    // The suite takes the store by value and has no cleanup hook; the OS
    // temp dir keeps the file. Forgetting the guard keeps the directory.
    std::mem::forget(dir);
    path
}

fn open_at(path: &Path) -> SqliteItemStore {
    SqliteItemStore::open(path).expect("open the store")
}

koine_store_conformance::suite! {
    sqlite => || SqliteItemStore::open_in_memory().expect("open in memory"),
}

koine_store_conformance::suite! {
    sqlite_file => || open_at(&fresh_db()),
    reopen => || {
        let path = fresh_db();
        move || -> Box<dyn AttributedStore> { Box::new(open_at(&path)) }
    },
}
