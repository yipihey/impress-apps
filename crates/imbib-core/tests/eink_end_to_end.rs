//! Tier A for the mirror engine: an in-memory store, a scripted tablet, and
//! every rule the plan names, end to end through `run_sync`.

use std::sync::{Arc, Mutex};

use imbib_core::eink::apply::{
    run_sync, EinkImportSink, ImportHandoff, ImportOutcome, SyncOptions,
};
use imbib_core::eink::{EinkDeviceConfigInput, EinkError, MockTransport, NoopSink};
use imbib_core::unified::store_api::ImbibStore;
use impress_remarkable::DocumentKind;

const BIBTEX: &str = r#"
@article{Abel2002, author = {Abel, Tom and Bryan, Greg and Norman, Michael}, title = {The Formation of the First Star in the Universe}, year = {2002}, journal = {Science}}
@article{Bryan2014, author = {Bryan, Greg and Norman, Michael}, title = {Enzo: An Adaptive Mesh Refinement Code}, year = {2014}, journal = {ApJS}}
@article{Norman2020, author = {Norman, Michael}, title = {No PDF Yet}, year = {2020}, journal = {Nowhere}}
"#;

struct Fixture {
    store: Arc<ImbibStore>,
    library: String,
    abel: String,
    bryan: String,
    norman: String,
    cosmology: String,
    reionization: String,
    device: String,
    _temp: tempfile::TempDir,
    temp_path: std::path::PathBuf,
}

fn fixture(mirror_mode: &str, folder_strategy: &str) -> Fixture {
    let store = ImbibStore::open_in_memory().unwrap();
    let library = store.create_library("Library".into()).unwrap();
    let imported = store
        .import_bibtex_into(BIBTEX.into(), library.id.clone(), None)
        .unwrap()
        .imported;
    let by_key = |key: &str| {
        imported
            .iter()
            .find(|id| {
                store
                    .get_publication((*id).clone())
                    .unwrap()
                    .unwrap()
                    .cite_key
                    == key
            })
            .unwrap()
            .clone()
    };
    let (abel, bryan, norman) = (
        by_key("Abel2002"),
        by_key("Bryan2014"),
        by_key("Norman2020"),
    );

    let temp = tempfile::tempdir().unwrap();
    for (id, name) in [(&abel, "abel.pdf"), (&bryan, "bryan.pdf")] {
        let path = temp.path().join(name);
        std::fs::write(&path, format!("%PDF-1.4 {name}\n")).unwrap();
        store
            .add_linked_file(
                id.clone(),
                name.into(),
                Some(path.display().to_string()),
                Some("pdf".into()),
                20,
                Some(format!("sha-{name}")),
                true,
            )
            .unwrap();
    }

    let cosmology = store
        .create_collection("Cosmology".into(), library.id.clone(), false, None)
        .unwrap();
    let reionization = store
        .create_collection("Reionization".into(), library.id.clone(), false, None)
        .unwrap();
    store
        .update_field(
            reionization.id.clone(),
            "parent_id".into(),
            Some(cosmology.id.clone()),
        )
        .unwrap();
    store
        .add_to_collection(vec![abel.clone()], reionization.id.clone())
        .unwrap();
    store
        .add_to_collection(vec![bryan.clone()], cosmology.id.clone())
        .unwrap();

    let device = store
        .eink_configure_device(EinkDeviceConfigInput {
            name: Some("Paper Pro".into()),
            mirror_mode: Some(mirror_mode.into()),
            folder_strategy: Some(folder_strategy.into()),
            ..Default::default()
        })
        .unwrap();

    Fixture {
        store,
        library: library.id,
        abel,
        bryan,
        norman,
        cosmology: cosmology.id,
        reionization: reionization.id,
        device: device.id,
        temp_path: temp.path().to_path_buf(),
        _temp: temp,
    }
}

fn tablet_with_full_tree() -> MockTransport {
    let mock = MockTransport::new();
    mock.add_folder("f-imbib", "", "imbib");
    mock.add_folder("f-lib", "f-imbib", "Library");
    mock.add_folder("f-cosmo", "f-lib", "Cosmology");
    mock.add_folder("f-reion", "f-cosmo", "Reionization");
    mock
}

fn state_of(f: &Fixture, publication: &str) -> Option<String> {
    f.store
        .query_publications(f.library.clone(), "title".into(), true, None, None)
        .unwrap()
        .into_iter()
        .find(|row| row.id == publication)
        .unwrap()
        .eink_state
}

fn sync(f: &Fixture, mock: &MockTransport) -> imbib_core::eink::EinkSyncReport {
    run_sync(&f.store, None, mock, &NoopSink, SyncOptions::default()).unwrap()
}

#[test]
fn individual_mode_uploads_marked_papers_into_their_collection_folders() {
    let f = fixture("individual", "checklist");
    let mock = tablet_with_full_tree();
    f.store.eink_mark(None, vec![f.abel.clone()]).unwrap();
    assert_eq!(state_of(&f, &f.abel).as_deref(), Some("queued"));

    let report = sync(&f, &mock);
    assert_eq!(report.uploaded, vec![f.abel.clone()], "{:?}", report.trace);
    assert!(report.failed.is_empty());
    assert!(report.folder_needs.is_empty());

    let doc = mock
        .find_by_name("Abel 2002 – The Formation of the First Star in the Universe")
        .expect("named from author, year and title");
    assert_eq!(
        doc.parent, "f-reion",
        "filed under imbib/Library/Cosmology/Reionization"
    );
    assert_eq!(doc.kind, DocumentKind::Document);
    assert!(
        mock.calls.lock().unwrap().iter().any(|c| c
            == "upload:f-reion:Abel 2002 – The Formation of the First Star in the Universe.rmdoc"),
        "uploads are wrapped in an archive so the tablet keeps the exact name: {:?}",
        mock.calls.lock().unwrap()
    );

    let row = f
        .store
        .eink_mirror_for_publication(None, f.abel.clone())
        .unwrap()
        .unwrap();
    assert_eq!(row.state, "uploaded");
    assert_eq!(row.remote_id.as_deref(), Some(doc.id.as_str()));
    assert_eq!(
        row.remote_path.as_deref(),
        Some("imbib/Library/Cosmology/Reionization")
    );
    assert_eq!(row.uploaded_sha256.as_deref(), Some("sha-abel.pdf"));
    assert_eq!(state_of(&f, &f.abel).as_deref(), Some("uploaded"));
    assert_eq!(state_of(&f, &f.bryan), None, "unmarked papers show nothing");

    let device = f.store.eink_get_device(f.device.clone()).unwrap().unwrap();
    assert!(device.last_sync_at_ms.is_some());
    assert!(device.sync_started_at_ms.is_none(), "the lock is released");

    // A second sync changes nothing and uploads nothing.
    mock.calls.lock().unwrap().clear();
    let again = sync(&f, &mock);
    assert!(again.uploaded.is_empty());
    assert_eq!(again.summary.unchanged, 1);
    assert!(!mock
        .calls
        .lock()
        .unwrap()
        .iter()
        .any(|c| c.starts_with("upload:")));
}

#[test]
fn a_missing_folder_holds_the_paper_and_the_checklist_names_every_level() {
    let f = fixture("individual", "checklist");
    let mock = MockTransport::new();
    mock.add_folder("f-imbib", "", "imbib");
    mock.add_folder("f-lib", "f-imbib", "Library");
    f.store.eink_mark(None, vec![f.abel.clone()]).unwrap();

    let report = sync(&f, &mock);
    assert!(report.uploaded.is_empty());
    let needs: Vec<String> = report.folder_needs.iter().map(|n| n.display()).collect();
    assert_eq!(
        needs,
        vec![
            "imbib/Library/Cosmology",
            "imbib/Library/Cosmology/Reionization"
        ],
        "parents first"
    );
    assert_eq!(report.folder_needs[0].parent_id.as_deref(), Some("f-lib"));
    assert_eq!(state_of(&f, &f.abel).as_deref(), Some("awaiting_folder"));

    // The user creates the folders on the tablet; the next sync uploads.
    mock.add_folder("f-cosmo", "f-lib", "Cosmology");
    mock.add_folder("f-reion", "f-cosmo", "Reionization");
    let report = sync(&f, &mock);
    assert_eq!(report.uploaded, vec![f.abel.clone()]);
    assert!(report.folder_needs.is_empty());
    assert_eq!(state_of(&f, &f.abel).as_deref(), Some("uploaded"));
}

#[test]
fn the_rmdoc_strategy_creates_the_folders_itself() {
    let f = fixture("individual", "rmdoc");
    let mock = MockTransport::new();
    f.store.eink_mark(None, vec![f.abel.clone()]).unwrap();

    let report = sync(&f, &mock);
    assert_eq!(
        report.folders_created,
        vec![
            "imbib",
            "imbib/Library",
            "imbib/Library/Cosmology",
            "imbib/Library/Cosmology/Reionization"
        ],
        "{:?}",
        report.trace
    );
    assert_eq!(report.uploaded, vec![f.abel.clone()]);
    let folders: Vec<_> = mock
        .entries()
        .into_iter()
        .filter(|e| e.kind == DocumentKind::Folder)
        .collect();
    assert_eq!(folders.len(), 4);
    let reion = folders
        .iter()
        .find(|e| e.visible_name == "Reionization")
        .unwrap();
    let doc = mock
        .find_by_name("Abel 2002 – The Formation of the First Star in the Universe")
        .unwrap();
    assert_eq!(doc.parent, reion.id);
    assert!(report.folder_needs.is_empty());
}

#[test]
fn no_source_waits_in_individual_mode_and_is_skipped_in_mirror_all() {
    let f = fixture("individual", "checklist");
    let mock = tablet_with_full_tree();
    let outcome = f.store.eink_mark(None, vec![f.norman.clone()]).unwrap();
    assert_eq!(outcome.awaiting_source, vec![f.norman.clone()]);
    let report = sync(&f, &mock);
    assert_eq!(report.summary.awaiting_source, 1);
    assert!(report.uploaded.is_empty());
    assert_eq!(state_of(&f, &f.norman).as_deref(), Some("awaiting_source"));

    // Mirror everything: both papers with a PDF go, Norman is counted, no
    // marker anywhere.
    f.store
        .eink_configure_device(EinkDeviceConfigInput {
            id: Some(f.device.clone()),
            mirror_mode: Some("all".into()),
            ..Default::default()
        })
        .unwrap();
    let report = sync(&f, &mock);
    let mut uploaded = report.uploaded.clone();
    uploaded.sort();
    let mut expected = vec![f.abel.clone(), f.bryan.clone()];
    expected.sort();
    assert_eq!(uploaded, expected, "{:?}", report.trace);
    assert_eq!(
        report.summary.skipped_no_source, 0,
        "Norman is marked, so waits rather than skips"
    );
    assert_eq!(report.summary.awaiting_source, 1);
    assert_eq!(
        mock.find_by_name("Bryan 2014 – Enzo- An Adaptive Mesh Refinement Code")
            .unwrap()
            .parent,
        "f-cosmo"
    );
    assert_eq!(state_of(&f, &f.abel), None, "mirror-all shows no marker");
    assert_eq!(state_of(&f, &f.bryan), None);

    // Once the PDF arrives, the waiting paper goes too.
    let path = f.temp_path.join("norman.pdf");
    std::fs::write(&path, b"%PDF-1.4 norman\n").unwrap();
    f.store
        .add_linked_file(
            f.norman.clone(),
            "norman.pdf".into(),
            Some(path.display().to_string()),
            Some("pdf".into()),
            16,
            None,
            true,
        )
        .unwrap();
    let report = sync(&f, &mock);
    assert_eq!(report.uploaded, vec![f.norman.clone()]);
    let row = f
        .store
        .eink_mirror_for_publication(None, f.norman.clone())
        .unwrap()
        .unwrap();
    assert_eq!(
        row.uploaded_sha256.as_deref().map(|s| s.len()),
        Some(64),
        "hashed at upload time"
    );
    assert_eq!(
        row.remote_path.as_deref(),
        Some("imbib/Library"),
        "no collection → the library folder"
    );
}

#[test]
fn an_edited_file_goes_stale_a_deleted_copy_is_a_tombstone_and_resend_sends_again() {
    let f = fixture("individual", "checklist");
    let mock = tablet_with_full_tree();
    f.store.eink_mark(None, vec![f.abel.clone()]).unwrap();
    sync(&f, &mock);
    let row = f
        .store
        .eink_mirror_for_publication(None, f.abel.clone())
        .unwrap()
        .unwrap();
    let first_remote = row.remote_id.clone().unwrap();

    // The store records a new hash for the file (a re-import in imbib).
    let file = f.store.list_linked_files(f.abel.clone()).unwrap().remove(0);
    f.store
        .update_field(file.id.clone(), "sha256".into(), Some("sha-abel-v2".into()))
        .unwrap();
    let report = sync(&f, &mock);
    assert_eq!(report.summary.stale, 1);
    assert!(report.uploaded.is_empty(), "never re-sent on its own");
    assert_eq!(state_of(&f, &f.abel).as_deref(), Some("stale"));

    // The user deletes the copy on the tablet.
    mock.remove(&first_remote);
    let report = sync(&f, &mock);
    assert_eq!(report.summary.removed, 1);
    assert_eq!(state_of(&f, &f.abel).as_deref(), Some("removed_on_device"));
    let report = sync(&f, &mock);
    assert!(
        report.uploaded.is_empty(),
        "a tombstone is never re-uploaded by itself"
    );

    // Asking for it again sends a fresh copy.
    f.store.eink_resend(vec![row.id.clone()]).unwrap();
    let report = sync(&f, &mock);
    assert_eq!(report.uploaded, vec![f.abel.clone()]);
    let row = f
        .store
        .eink_mirror_for_publication(None, f.abel.clone())
        .unwrap()
        .unwrap();
    assert_eq!(row.state, "uploaded");
    assert_ne!(row.remote_id.as_deref(), Some(first_remote.as_str()));
    assert!(!row.resend);
}

#[test]
fn a_failed_upload_is_recorded_and_retried_next_time() {
    let f = fixture("individual", "checklist");
    let mock = tablet_with_full_tree();
    f.store.eink_mark(None, vec![f.abel.clone()]).unwrap();
    mock.fail_next_upload("tablet said 500");
    let report = sync(&f, &mock);
    assert_eq!(report.failed, vec![f.abel.clone()]);
    let row = f
        .store
        .eink_mirror_for_publication(None, f.abel.clone())
        .unwrap()
        .unwrap();
    assert_eq!(row.state, "failed");
    assert_eq!(row.attempts, 1);
    assert_eq!(row.last_error.as_deref(), Some("tablet said 500"));
    assert_eq!(state_of(&f, &f.abel).as_deref(), Some("failed"));

    let report = sync(&f, &mock);
    assert_eq!(report.uploaded, vec![f.abel.clone()]);
    let row = f
        .store
        .eink_mirror_for_publication(None, f.abel.clone())
        .unwrap()
        .unwrap();
    assert_eq!(row.state, "uploaded");
    assert_eq!(row.last_error, None);
}

#[test]
fn a_misfiled_upload_is_not_recorded_under_the_wrong_folder() {
    let f = fixture("individual", "checklist");
    let mock = tablet_with_full_tree();
    mock.misfile_uploads
        .store(true, std::sync::atomic::Ordering::SeqCst);
    f.store.eink_mark(None, vec![f.abel.clone()]).unwrap();
    let report = sync(&f, &mock);
    assert_eq!(report.failed, vec![f.abel.clone()]);
    let row = f
        .store
        .eink_mirror_for_publication(None, f.abel.clone())
        .unwrap()
        .unwrap();
    assert_eq!(row.state, "failed");
    assert!(row.remote_id.is_none());
    assert!(row.last_error.unwrap().contains("instead of"));
}

#[test]
fn name_collisions_get_a_citekey_suffix() {
    let f = fixture("individual", "checklist");
    let mock = tablet_with_full_tree();
    // A second paper that would carry the same name, in the same folder.
    let twin = f
        .store
        .import_bibtex_into(
            "@article{Abel2002b, author = {Abel, Tom}, title = {The Formation of the First Star in the Universe}, year = {2002}}".into(),
            f.library.clone(),
            Some(f.reionization.clone()),
        )
        .unwrap()
        .imported
        .remove(0);
    let path = f.temp_path.join("twin.pdf");
    std::fs::write(&path, b"%PDF-1.4 twin\n").unwrap();
    f.store
        .add_linked_file(
            twin.clone(),
            "twin.pdf".into(),
            Some(path.display().to_string()),
            Some("pdf".into()),
            14,
            None,
            true,
        )
        .unwrap();
    f.store
        .eink_mark(None, vec![f.abel.clone(), twin.clone()])
        .unwrap();

    let report = sync(&f, &mock);
    assert_eq!(report.uploaded.len(), 2, "{:?}", report.trace);
    let names: Vec<String> = mock
        .entries()
        .into_iter()
        .filter(|e| e.kind == DocumentKind::Document)
        .map(|e| e.visible_name)
        .collect();
    assert!(
        names.contains(&"Abel 2002 – The Formation of the First Star in the Universe".to_string())
    );
    assert!(
        names
            .iter()
            .any(|n| n.ends_with("[Abel2002]") || n.ends_with("[Abel2002b]")),
        "{names:?}"
    );
    assert!(!f.cosmology.is_empty());
}

struct RecordingSink(Mutex<Vec<ImportHandoff>>);

impl EinkImportSink for RecordingSink {
    fn ingest(
        &self,
        _store: &ImbibStore,
        handoff: &ImportHandoff,
    ) -> Result<ImportOutcome, EinkError> {
        self.0.lock().unwrap().push(handoff.clone());
        Ok(ImportOutcome {
            annotated_file_id: Some("variant-1".into()),
            created: 2,
            ..Default::default()
        })
    }
}

#[test]
fn a_changed_tablet_copy_is_imported_once() {
    let f = fixture("individual", "checklist");
    let mock = tablet_with_full_tree();
    f.store.eink_mark(None, vec![f.abel.clone()]).unwrap();
    sync(&f, &mock);
    let row = f
        .store
        .eink_mirror_for_publication(None, f.abel.clone())
        .unwrap()
        .unwrap();
    let remote = row.remote_id.clone().unwrap();

    // The user writes on it well after the upload.
    let later = row.uploaded_at_ms.unwrap() + 5 * 60 * 1000;
    mock.touch(&remote, later);
    let sink = RecordingSink(Mutex::new(Vec::new()));
    let downloads = tempfile::tempdir().unwrap();
    let options = SyncOptions {
        import: true,
        download_root: Some(downloads.path().to_path_buf()),
        ..Default::default()
    };
    let report = run_sync(&f.store, None, &mock, &sink, options.clone()).unwrap();
    assert_eq!(report.imports.len(), 1, "{:?}", report.trace);
    let imported = &report.imports[0];
    assert_eq!(imported.remote_id, remote);
    assert!(imported.annotated_pdf.contains(&format!("/{remote}/")));
    assert!(std::path::Path::new(&imported.annotated_pdf).is_file());
    assert!(
        imported.rmdoc.is_some(),
        "the archive comes along for the structured import"
    );
    assert_eq!(imported.annotated_file_id.as_deref(), Some("variant-1"));
    assert_eq!(sink.0.lock().unwrap().len(), 1);
    assert_eq!(sink.0.lock().unwrap()[0].remote_modified_ms, later);

    let row = f
        .store
        .eink_mirror_for_publication(None, f.abel.clone())
        .unwrap()
        .unwrap();
    assert_eq!(row.imported_modified_ms, Some(later));
    assert_eq!(row.annotated_file_id.as_deref(), Some("variant-1"));
    assert_eq!(f.store.eink_status().unwrap().counts.new_annotations, 0);

    // Nothing changed since: no second import.
    let report = run_sync(&f.store, None, &mock, &sink, options).unwrap();
    assert!(report.imports.is_empty());
    assert_eq!(sink.0.lock().unwrap().len(), 1);

    // Without import enabled, the change is only counted.
    mock.touch(&remote, later + 1000);
    let report = sync(&f, &mock);
    assert_eq!(report.pending_imports, 1);
    assert_eq!(f.store.eink_status().unwrap().counts.new_annotations, 1);
}

#[test]
fn an_unplugged_tablet_does_nothing_and_a_dry_run_writes_nothing() {
    let f = fixture("individual", "checklist");
    let mock = tablet_with_full_tree();
    f.store.eink_mark(None, vec![f.abel.clone()]).unwrap();

    mock.set_reachable(false);
    let report = sync(&f, &mock);
    assert!(!report.reachable);
    assert_eq!(state_of(&f, &f.abel).as_deref(), Some("queued"));

    mock.set_reachable(true);
    let report = run_sync(
        &f.store,
        None,
        &mock,
        &NoopSink,
        SyncOptions {
            dry_run: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert!(report.dry_run);
    assert_eq!(report.summary.to_upload, 1);
    assert!(report.uploaded.is_empty());
    assert_eq!(state_of(&f, &f.abel).as_deref(), Some("queued"));
    assert!(mock
        .entries()
        .iter()
        .all(|e| e.kind == DocumentKind::Folder));

    // A device id that does not exist is an error, not a silent no-op.
    assert!(run_sync(
        &f.store,
        Some("00000000-0000-0000-0000-000000000000"),
        &mock,
        &NoopSink,
        SyncOptions::default()
    )
    .is_err());
}
