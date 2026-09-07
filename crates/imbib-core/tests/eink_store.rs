//! The e-ink rows: devices, marks, and the list-row marker.

use imbib_core::eink::{EinkDeviceConfigInput, MirrorState};
use imbib_core::unified::store_api::ImbibStore;
use impress_core::item::Value;
use std::sync::Arc;

const BIBTEX: &str = r#"
@article{Abel2002, author = {Abel, Tom and Bryan, Greg}, title = {The Formation of the First Star}, year = {2002}, journal = {Science}}
@article{Bryan2014, author = {Bryan, Greg}, title = {Enzo}, year = {2014}, journal = {ApJS}}
"#;

fn store_with_two_papers() -> (Arc<ImbibStore>, String, Vec<String>, tempfile::TempDir) {
    let store = ImbibStore::open_in_memory().unwrap();
    let library = store.create_library("Library".into()).unwrap();
    let outcome = store
        .import_bibtex_into(BIBTEX.into(), library.id.clone(), None)
        .unwrap();
    let mut ids = outcome.imported;
    ids.sort_by_key(|id| store.get_publication(id.clone()).unwrap().unwrap().cite_key);
    let temp = tempfile::tempdir().unwrap();
    let pdf = temp.path().join("abel.pdf");
    std::fs::write(&pdf, b"%PDF-1.4 abel\n").unwrap();
    store
        .add_linked_file(
            ids[0].clone(),
            "abel.pdf".into(),
            Some(pdf.display().to_string()),
            Some("pdf".into()),
            14,
            Some("abc".into()),
            true,
        )
        .unwrap();
    (store, library.id, ids, temp)
}

fn individual_device(store: &ImbibStore) -> String {
    store
        .eink_configure_device(EinkDeviceConfigInput {
            name: Some("Paper Pro".into()),
            ..Default::default()
        })
        .unwrap()
        .id
}

fn state_of(store: &ImbibStore, library: &str, publication: &str) -> Option<String> {
    store
        .query_publications(library.into(), "title".into(), true, None, None)
        .unwrap()
        .into_iter()
        .find(|row| row.id == publication)
        .unwrap()
        .eink_state
}

#[test]
fn devices_are_created_updated_and_removed() {
    let store = ImbibStore::open_in_memory().unwrap();
    assert!(store.eink_devices().unwrap().is_empty());
    assert_eq!(store.eink_status().unwrap().default_device_id, None);

    let device = store
        .eink_configure_device(EinkDeviceConfigInput {
            name: Some("  Paper Pro ".into()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(device.name, "Paper Pro");
    assert_eq!(device.transport, "usb-web");
    assert_eq!(device.base_url, "http://10.11.99.1");
    assert_eq!(device.mirror_mode, "individual");
    assert_eq!(device.root_folder_name, "imbib");
    assert_eq!(device.folder_strategy, "checklist");
    assert!(device.mirror_collections && device.include_library_level && device.enabled);

    let updated = store
        .eink_configure_device(EinkDeviceConfigInput {
            id: Some(device.id.clone()),
            mirror_mode: Some("all".into()),
            base_url: Some("http://10.11.99.1/".into()),
            import_ink: Some(false),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(updated.id, device.id);
    assert_eq!(updated.mirror_mode, "all");
    assert_eq!(
        updated.base_url, "http://10.11.99.1",
        "trailing slash trimmed"
    );
    assert!(!updated.import_ink);
    assert_eq!(
        updated.name, "Paper Pro",
        "untouched fields survive a partial update"
    );

    for bad in [
        EinkDeviceConfigInput {
            id: Some(device.id.clone()),
            mirror_mode: Some("some".into()),
            ..Default::default()
        },
        EinkDeviceConfigInput {
            id: Some(device.id.clone()),
            root_folder_name: Some("a/b".into()),
            ..Default::default()
        },
        EinkDeviceConfigInput {
            id: Some(device.id.clone()),
            base_url: Some("10.11.99.1".into()),
            ..Default::default()
        },
        EinkDeviceConfigInput {
            id: Some(device.id.clone()),
            transport: Some("cloud".into()),
            ..Default::default()
        },
    ] {
        assert!(store.eink_configure_device(bad).is_err());
    }

    assert_eq!(store.eink_devices().unwrap().len(), 1);
    assert_eq!(
        store.eink_status().unwrap().default_device_id.as_deref(),
        Some(device.id.as_str())
    );
    store.eink_remove_device(device.id.clone()).unwrap();
    assert!(store.eink_devices().unwrap().is_empty());
}

#[test]
fn marking_creates_rows_and_the_marker_shows_only_in_individual_mode() {
    let (store, library, ids, _temp) = store_with_two_papers();
    let (abel, bryan) = (ids[0].clone(), ids[1].clone());
    assert_eq!(
        state_of(&store, &library, &abel),
        None,
        "no device: no marker"
    );

    let device = individual_device(&store);
    let outcome = store
        .eink_mark(None, vec![abel.clone(), bryan.clone(), "not-a-uuid".into()])
        .unwrap();
    assert_eq!(outcome.device_id, device);
    assert_eq!(outcome.changed, vec![abel.clone(), bryan.clone()]);
    assert_eq!(outcome.unchanged, vec!["not-a-uuid".to_string()]);
    assert_eq!(
        outcome.awaiting_source,
        vec![bryan.clone()],
        "Bryan has no PDF"
    );

    assert_eq!(state_of(&store, &library, &abel).as_deref(), Some("queued"));
    assert_eq!(
        state_of(&store, &library, &bryan).as_deref(),
        Some("awaiting_source")
    );

    let waiting = store.eink_awaiting_source(None).unwrap();
    assert_eq!(waiting.len(), 1);
    assert_eq!(waiting[0].cite_key, "Bryan2014");
    assert_eq!(waiting[0].publication_id, bryan);

    let counts = store.eink_status().unwrap().counts;
    assert_eq!((counts.queued, counts.awaiting_source), (1, 1));

    // Marking again changes nothing.
    let again = store.eink_mark(None, vec![abel.clone()]).unwrap();
    assert!(again.changed.is_empty());
    assert_eq!(again.unchanged, vec![abel.clone()]);

    // Mirror-all mode: the marker disappears, the rows stay.
    store
        .eink_configure_device(EinkDeviceConfigInput {
            id: Some(device.clone()),
            mirror_mode: Some("all".into()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(state_of(&store, &library, &abel), None);
    assert_eq!(store.eink_list_mirrored(None, None).unwrap().len(), 2);
    store
        .eink_configure_device(EinkDeviceConfigInput {
            id: Some(device.clone()),
            mirror_mode: Some("individual".into()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(state_of(&store, &library, &abel).as_deref(), Some("queued"));

    // Un-marking a paper that never reached the tablet deletes its row.
    let unmark = store
        .eink_unmark(None, vec![abel.clone(), bryan.clone()])
        .unwrap();
    assert_eq!(unmark.changed.len(), 2);
    assert_eq!(state_of(&store, &library, &abel), None);
    assert!(store.eink_list_mirrored(None, None).unwrap().is_empty());
}

#[test]
fn unmarking_an_uploaded_row_leaves_a_tombstone_and_remarking_revives_it() {
    let (store, library, ids, _temp) = store_with_two_papers();
    let abel = ids[0].clone();
    let device = individual_device(&store);
    let row = store
        .eink_insert_mirror(
            &device,
            &abel,
            true,
            MirrorState::Uploaded,
            vec![
                ("remote_id", Value::String("tablet-1".into())),
                ("uploaded_sha256", Value::String("abc".into())),
            ],
        )
        .unwrap();
    assert_eq!(
        state_of(&store, &library, &abel).as_deref(),
        Some("uploaded")
    );

    store.eink_unmark(None, vec![abel.clone()]).unwrap();
    let tombstone = store
        .eink_mirror_for_publication(None, abel.clone())
        .unwrap()
        .expect("the row survives: the tablet copy cannot be deleted over USB");
    assert_eq!(tombstone.id, row.id);
    assert_eq!(tombstone.state, "unmarked");
    assert!(!tombstone.marked);
    assert_eq!(
        state_of(&store, &library, &abel),
        None,
        "no marker for an un-marked paper"
    );
    assert_eq!(store.eink_status().unwrap().counts.unmarked, 1);

    store.eink_mark(None, vec![abel.clone()]).unwrap();
    let revived = store
        .eink_mirror_for_publication(None, abel.clone())
        .unwrap()
        .unwrap();
    assert_eq!(revived.state, "uploaded");
    assert!(revived.marked);

    // A copy the user deleted on the tablet is re-sent only when asked.
    store
        .eink_update_mirror(
            &row.id,
            vec![("state", Some(Value::String("removed_on_device".into())))],
        )
        .unwrap();
    store.eink_mark(None, vec![abel.clone()]).unwrap();
    let resend = store
        .eink_mirror_for_publication(None, abel.clone())
        .unwrap()
        .unwrap();
    assert!(resend.resend, "re-marking a removed copy asks for it back");
    assert!(store
        .eink_resend(vec![row.id.clone(), "not-a-uuid".into()])
        .is_err());
    assert_eq!(store.eink_resend(vec![row.id.clone()]).unwrap(), 1);
}

#[test]
fn the_marker_context_notices_a_device_written_through_another_handle() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("store.sqlite").display().to_string();
    let reader = ImbibStore::open(path.clone()).unwrap();
    let writer = ImbibStore::open(path).unwrap();

    let library = writer.create_library("Library".into()).unwrap();
    let ids = writer
        .import_bibtex_into(BIBTEX.into(), library.id.clone(), None)
        .unwrap()
        .imported;
    let abel = ids[0].clone();

    // The reader queried before any device existed and cached "none".
    assert_eq!(state_of(&reader, &library.id, &abel), None);

    writer
        .eink_configure_device(EinkDeviceConfigInput {
            name: Some("Paper Pro".into()),
            ..Default::default()
        })
        .unwrap();
    writer.eink_mark(None, vec![abel.clone()]).unwrap();

    assert_eq!(
        state_of(&reader, &library.id, &abel).as_deref(),
        Some("awaiting_source"),
        "the fingerprint of the device rows changed, so the cache was refreshed"
    );
}

#[test]
fn orphaned_rows_are_collected_and_legacy_markers_counted() {
    let (store, _library, ids, _temp) = store_with_two_papers();
    let abel = ids[0].clone();
    individual_device(&store);
    store.eink_mark(None, vec![abel.clone()]).unwrap();
    assert_eq!(store.eink_legacy_marker_rows().unwrap(), 0);

    store.delete_item(abel.clone()).unwrap();
    assert_eq!(store.eink_gc_orphans().unwrap(), 1);
    assert!(store.eink_list_mirrored(None, None).unwrap().is_empty());
}

#[test]
fn a_linked_file_resolves_to_its_absolute_path() {
    let (store, _library, ids, temp) = store_with_two_papers();
    let files = store.list_linked_files(ids[0].clone()).unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].file_type.as_deref(), Some("pdf"));
    assert_eq!(files[0].sha256.as_deref(), Some("abc"));
    assert_eq!(files[0].display_name.as_deref(), Some("abel"));
    assert_eq!(files[0].mime_type.as_deref(), Some("application/pdf"));
    assert_eq!(files[0].role, None);
    let resolved = store.resolve_linked_file(files[0].id.clone()).unwrap();
    assert_eq!(
        resolved,
        Some(temp.path().join("abel.pdf").display().to_string())
    );
    let source = store.eink_local_source(ids[0].clone()).unwrap().unwrap();
    assert_eq!(source.kind, "pdf");
    assert_eq!(store.eink_local_source(ids[1].clone()).unwrap(), None);
}
