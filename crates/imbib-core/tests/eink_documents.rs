//! Tier A for what the tablet authored: a notebook inside a collection
//! folder becomes a `@misc` publication there, a PDF copied in by hand
//! adopts the publication whose file it is, a document outside the tree
//! needs a library named, and a mirrored paper the user moved out of the
//! tree is still on the tablet.

use std::sync::Arc;

use imbib_core::eink::import::documents::{
    import_document, list_unmatched, resolve_tablet_path, typed_text_of,
};
use imbib_core::eink::import::{import_annotated_document, ImportRequest};
use imbib_core::eink::{
    run_sync, EinkDeviceConfigInput, ImportDocumentRequest, MockTransport, NoopSink, SyncOptions,
};
use imbib_core::unified::store_api::ImbibStore;
use impress_remarkable::rmdoc::{build_rmdoc, RmdocKind, RmdocSpec, SourceKind};
use impress_remarkable::DownloadKind;

const V5_PAGE: &[u8] =
    include_bytes!("../../impress-remarkable/tests/fixtures/rm/notebook_page_v5.rm");
const CALIBRATION_PDF: &[u8] =
    include_bytes!("../../impress-remarkable/tests/fixtures/calibration/calibration.pdf");

struct Fixture {
    store: Arc<ImbibStore>,
    library: String,
    abel: String,
    cosmology: String,
    device: imbib_core::eink::EinkDeviceConfig,
    library_dir: std::path::PathBuf,
    _temp: tempfile::TempDir,
}

fn fixture() -> Fixture {
    let store = ImbibStore::open_in_memory().unwrap();
    let library = store.create_library("Library".into()).unwrap();
    let abel = store
        .import_bibtex_into(
            "@article{Abel2002, author = {Abel, Tom}, title = {First star}, year = {2002}}".into(),
            library.id.clone(),
            None,
        )
        .unwrap()
        .imported
        .remove(0);
    let cosmology = store
        .create_collection("Cosmology".into(), library.id.clone(), false, None)
        .unwrap();
    let temp = tempfile::tempdir().unwrap();
    let library_dir = temp.path().join("Library-dir");
    std::fs::create_dir_all(library_dir.join("Papers")).unwrap();
    let primary = library_dir.join("Papers/Abel_2002.pdf");
    std::fs::write(&primary, CALIBRATION_PDF).unwrap();
    let sha = imbib_core::eink::paths::sha256_bytes(CALIBRATION_PDF);
    store
        .add_linked_file(
            abel.clone(),
            "Abel_2002.pdf".into(),
            Some(primary.display().to_string()),
            Some("pdf".into()),
            CALIBRATION_PDF.len() as i64,
            Some(sha),
            true,
        )
        .unwrap();
    let row = store
        .eink_configure_device(EinkDeviceConfigInput {
            name: Some("Paper Pro".into()),
            mirror_mode: Some("individual".into()),
            folder_strategy: Some("checklist".into()),
            ..Default::default()
        })
        .unwrap();
    let device = store.eink_device_config(&row.id).unwrap().unwrap();
    Fixture {
        store,
        library: library.id,
        abel,
        cosmology: cosmology.id,
        device,
        library_dir,
        _temp: temp,
    }
}

fn tablet() -> MockTransport {
    let mock = MockTransport::new();
    mock.add_folder("f-imbib", "", "imbib");
    mock.add_folder("f-lib", "f-imbib", "Library");
    mock.add_folder("f-cosmo", "f-lib", "Cosmology");
    mock.add_folder("f-books", "", "Books");
    mock
}

fn notebook_archive(id: &str, name: &str, parent: &str) -> Vec<u8> {
    let spec = RmdocSpec {
        id: id.into(),
        visible_name: name.into(),
        parent: parent.into(),
        last_modified_ms: 1_757_000_000_000,
        kind: RmdocKind::Notebook,
        page_count: None,
        page_files: vec![("page-1".into(), V5_PAGE.to_vec())],
    };
    build_rmdoc(&spec).unwrap()
}

fn pdf_archive(id: &str, name: &str, parent: &str, pdf: &[u8]) -> Vec<u8> {
    let spec = RmdocSpec {
        id: id.into(),
        visible_name: name.into(),
        parent: parent.into(),
        last_modified_ms: 1_757_000_000_000,
        kind: RmdocKind::Document {
            kind: SourceKind::Pdf,
            source: pdf.to_vec(),
        },
        page_count: None,
        page_files: vec![("page-1".into(), V5_PAGE.to_vec())],
    };
    build_rmdoc(&spec).unwrap()
}

#[test]
fn tablet_paths_resolve_to_the_library_and_collection_they_name() {
    let f = fixture();
    let index = imbib_core::eink::collections::CollectionIndex::load(&f.store).unwrap();
    let inside = resolve_tablet_path(
        &index,
        "imbib",
        &["imbib".into(), "library".into(), "COSMOLOGY".into()],
    );
    assert!(inside.in_imbib_tree);
    assert_eq!(inside.library_id.as_deref(), Some(f.library.as_str()));
    assert_eq!(inside.collection_id.as_deref(), Some(f.cosmology.as_str()));

    let library_level = resolve_tablet_path(&index, "imbib", &["imbib".into(), "Library".into()]);
    assert_eq!(
        library_level.library_id.as_deref(),
        Some(f.library.as_str())
    );
    assert_eq!(library_level.collection_id, None);

    let unknown = resolve_tablet_path(
        &index,
        "imbib",
        &["imbib".into(), "Library".into(), "Nope".into()],
    );
    assert_eq!(
        unknown.collection_id, None,
        "an unknown folder resolves to nothing, never to a guess"
    );

    let outside = resolve_tablet_path(&index, "imbib", &["Books".into()]);
    assert!(!outside.in_imbib_tree);
    assert_eq!(outside.library_id, None);
}

#[test]
fn unmatched_lists_what_no_mirror_row_accounts_for_in_tree_first() {
    let f = fixture();
    let mock = tablet();
    mock.add_document("nb-1", "f-cosmo", "Lecture notes", "", 1_757_000_000_000);
    mock.add_document("pdf-1", "f-books", "Some book", "pdf", 1_757_000_000_000);
    mock.add_document("top-1", "", "Quick sketch", "notebook", 1_757_000_000_000);

    // A mirrored paper is not unmatched.
    f.store.eink_mark(None, vec![f.abel.clone()]).unwrap();
    run_sync(&f.store, None, &mock, &NoopSink, SyncOptions::default()).unwrap();

    let unmatched = list_unmatched(&f.store, &f.device, &mock).unwrap();
    let ids: Vec<&str> = unmatched.iter().map(|d| d.remote_id.as_str()).collect();
    assert_eq!(ids, vec!["nb-1", "top-1", "pdf-1"], "{unmatched:?}");
    let notebook = &unmatched[0];
    assert!(notebook.in_imbib_tree);
    assert_eq!(notebook.kind, "notebook");
    assert_eq!(notebook.remote_path, "imbib/Library/Cosmology");
    assert_eq!(notebook.library_id.as_deref(), Some(f.library.as_str()));
    assert_eq!(
        notebook.collection_id.as_deref(),
        Some(f.cosmology.as_str())
    );
    let book = unmatched.iter().find(|d| d.remote_id == "pdf-1").unwrap();
    assert!(!book.in_imbib_tree);
    assert_eq!(book.kind, "pdf");
    assert_eq!(book.remote_path, "Books");
    assert_eq!(book.library_id, None);
}

#[test]
fn a_notebook_in_a_collection_folder_becomes_a_misc_publication_there() {
    let f = fixture();
    let mock = tablet();
    mock.add_document("nb-1", "f-cosmo", "Lecture notes", "", 1_757_000_000_000);
    mock.set_download(
        "nb-1",
        DownloadKind::Rmdoc,
        notebook_archive("nb-1", "Lecture notes", "f-cosmo"),
    );
    mock.set_download("nb-1", DownloadKind::Pdf, CALIBRATION_PDF.to_vec());

    let outcome = import_document(
        &f.store,
        &f.device,
        &mock,
        &ImportDocumentRequest {
            remote_id: "nb-1".into(),
            library_dir: Some(f.library_dir.clone()),
            ..Default::default()
        },
    )
    .unwrap();
    let publication = outcome.publication_id.clone().expect("a publication");
    assert!(!outcome.adopted_existing);
    let detail = f
        .store
        .get_publication_detail(publication.clone())
        .unwrap()
        .unwrap();
    assert_eq!(detail.entry_type, "misc");
    assert_eq!(
        detail.fields.get("title").map(String::as_str),
        Some("Lecture notes")
    );
    assert_eq!(detail.fields.get("year").map(String::as_str), Some("2025"));
    assert!(
        detail.cite_key.starts_with("remarkable-nb1"),
        "{}",
        detail.cite_key
    );
    let collections = f.store.eink_collection_ids_for(&publication).unwrap();
    assert_eq!(
        collections,
        vec![f.cosmology.clone()],
        "filed by its folder"
    );

    // The rendition is the one file, remembered as tablet-born.
    let files = f.store.list_linked_files(publication.clone()).unwrap();
    assert_eq!(files.len(), 1, "{files:?}");
    let file = &files[0];
    assert!(file.is_pdf);
    assert_eq!(file.source_remote_id.as_deref(), Some("nb-1"));
    assert_eq!(file.filename, "reMarkable_2025_LectureNotes.pdf");
    let on_disk = f
        .store
        .resolve_linked_file(file.id.clone())
        .unwrap()
        .unwrap();
    assert_eq!(std::fs::read(&on_disk).unwrap(), CALIBRATION_PDF);

    // The mirror row makes it a mirrored paper from now on.
    let row = f
        .store
        .eink_mirror_for_publication(None, publication.clone())
        .unwrap()
        .unwrap();
    assert_eq!(row.state, "uploaded");
    assert_eq!(row.remote_id.as_deref(), Some("nb-1"));
    assert_eq!(row.remote_path.as_deref(), Some("imbib/Library/Cosmology"));
    assert_eq!(row.imported_modified_ms, Some(1_757_000_000_000));
    assert_eq!(row.annotated_file_id, None, "a notebook has no variant");
    assert_eq!(outcome.mirror_id.as_deref(), Some(row.id.as_str()));

    // The strokes came in as rows on that file.
    assert!(outcome.annotations_created > 0, "{:?}", outcome.trace);
    let rows = f
        .store
        .eink_annotations_for_publication(publication.clone())
        .unwrap();
    assert_eq!(rows.len() as u32, outcome.annotations_created);
    assert!(rows.iter().all(|r| r.linked_file_id == file.id));
    assert_eq!(
        outcome.ink_pending_ocr as usize,
        rows.iter().filter(|r| r.annotation_type == "ink").count()
    );

    // It is no longer unmatched, and a sync sees it as an ordinary mirrored paper.
    assert!(list_unmatched(&f.store, &f.device, &mock)
        .unwrap()
        .is_empty());
    let report = run_sync(&f.store, None, &mock, &NoopSink, SyncOptions::default()).unwrap();
    assert_eq!(report.summary.unchanged, 1, "{:?}", report.trace);
    assert!(report.uploaded.is_empty());
    assert_eq!(row.state, "uploaded");
}

#[test]
fn a_re_import_refreshes_a_tablet_born_primary_in_place() {
    let f = fixture();
    let mock = tablet();
    mock.add_document("nb-1", "f-cosmo", "Lecture notes", "", 1_757_000_000_000);
    mock.set_download(
        "nb-1",
        DownloadKind::Rmdoc,
        notebook_archive("nb-1", "Lecture notes", "f-cosmo"),
    );
    mock.set_download("nb-1", DownloadKind::Pdf, CALIBRATION_PDF.to_vec());
    let outcome = import_document(
        &f.store,
        &f.device,
        &mock,
        &ImportDocumentRequest {
            remote_id: "nb-1".into(),
            library_dir: Some(f.library_dir.clone()),
            ..Default::default()
        },
    )
    .unwrap();
    let publication = outcome.publication_id.unwrap();
    let file_id = outcome.linked_file_id.unwrap();
    let mirror_id = outcome.mirror_id.unwrap();

    // More handwriting: the tablet renders a new PDF.
    let mut newer = CALIBRATION_PDF.to_vec();
    newer.extend_from_slice(b"\n% more ink\n");
    let rendered = f.library_dir.join("rendered-2.pdf");
    std::fs::write(&rendered, &newer).unwrap();
    let archive_path = f.library_dir.join("nb-1.rmdoc");
    std::fs::write(
        &archive_path,
        notebook_archive("nb-1", "Lecture notes", "f-cosmo"),
    )
    .unwrap();
    let filename = f
        .store
        .get_linked_file(file_id.clone())
        .unwrap()
        .unwrap()
        .filename;
    let request = ImportRequest {
        device: &f.device,
        mirror_id: &mirror_id,
        publication_id: &publication,
        library_dir: &f.library_dir,
        primary_file: Some((file_id.clone(), filename)),
        remote_id: "nb-1",
        remote_name: "Lecture notes",
        remote_modified_ms: 1_757_000_100_000,
        rendered_pdf: &rendered,
        rmdoc: Some(&archive_path),
    };
    let again = import_annotated_document(&f.store, &request).unwrap();
    assert_eq!(again.annotated_file_id, None, "no variant for a notebook");
    let sha = imbib_core::eink::paths::sha256_bytes(&newer);
    assert_eq!(again.primary_sha256.as_deref(), Some(sha.as_str()));
    let files = f.store.list_linked_files(publication.clone()).unwrap();
    assert_eq!(files.len(), 1, "still one file: {files:?}");
    assert_eq!(files[0].sha256.as_deref(), Some(sha.as_str()));
    assert_eq!(files[0].source_remote_modified_ms, Some(1_757_000_100_000));
    let on_disk = f.store.resolve_linked_file(file_id).unwrap().unwrap();
    assert_eq!(std::fs::read(on_disk).unwrap(), newer);
    assert_eq!(
        again.updated as usize, outcome.annotations_created as usize,
        "same strokes: rows updated, none duplicated"
    );
    assert_eq!(again.created, 0);
}

#[test]
fn a_hand_copied_pdf_adopts_the_publication_whose_file_it_is() {
    let f = fixture();
    let mock = tablet();
    mock.add_document(
        "pdf-1",
        "f-cosmo",
        "First star (copied by hand)",
        "pdf",
        1_757_000_000_000,
    );
    mock.set_download(
        "pdf-1",
        DownloadKind::Rmdoc,
        pdf_archive(
            "pdf-1",
            "First star (copied by hand)",
            "f-cosmo",
            CALIBRATION_PDF,
        ),
    );
    let outcome = import_document(
        &f.store,
        &f.device,
        &mock,
        &ImportDocumentRequest {
            remote_id: "pdf-1".into(),
            library_dir: Some(f.library_dir.clone()),
            ..Default::default()
        },
    )
    .unwrap();
    assert!(outcome.adopted_existing, "{:?}", outcome.trace);
    assert_eq!(outcome.publication_id.as_deref(), Some(f.abel.as_str()));
    assert_eq!(
        f.store.eink_collection_ids_for(&f.abel).unwrap(),
        vec![f.cosmology.clone()],
        "filed into the folder's collection"
    );
    let files = f.store.list_linked_files(f.abel.clone()).unwrap();
    assert_eq!(files.len(), 2, "primary + the rendition variant: {files:?}");
    let variant = files
        .iter()
        .find(|r| r.role.as_deref() == Some("eink-annotated"))
        .unwrap();
    assert_eq!(variant.source_remote_id.as_deref(), Some("pdf-1"));
    let row = f
        .store
        .eink_mirror_for_publication(None, f.abel.clone())
        .unwrap()
        .unwrap();
    assert_eq!(row.state, "uploaded");
    assert_eq!(row.remote_id.as_deref(), Some("pdf-1"));
    assert_eq!(row.annotated_file_id.as_deref(), Some(variant.id.as_str()));
    assert!(outcome.annotations_created > 0);

    // Importing it twice is refused: the row now accounts for it.
    let twice = import_document(
        &f.store,
        &f.device,
        &mock,
        &ImportDocumentRequest {
            remote_id: "pdf-1".into(),
            library_dir: Some(f.library_dir.clone()),
            ..Default::default()
        },
    );
    assert!(twice.is_err());
}

#[test]
fn an_unknown_pdf_becomes_a_new_publication_and_a_document_elsewhere_needs_a_library() {
    let f = fixture();
    let mock = tablet();
    let other_pdf = b"%PDF-1.4\n1 0 obj << /Type /Page /MediaBox [0 0 595 842] >> endobj\n%%EOF\n";
    mock.add_document("pdf-2", "f-books", "Some book", "pdf", 1_757_000_000_000);
    mock.set_download(
        "pdf-2",
        DownloadKind::Rmdoc,
        pdf_archive("pdf-2", "Some book", "f-books", other_pdf),
    );
    let needs_library = import_document(
        &f.store,
        &f.device,
        &mock,
        &ImportDocumentRequest {
            remote_id: "pdf-2".into(),
            library_dir: Some(f.library_dir.clone()),
            ..Default::default()
        },
    );
    assert!(
        needs_library.is_err(),
        "outside the tree the library must be named"
    );

    let outcome = import_document(
        &f.store,
        &f.device,
        &mock,
        &ImportDocumentRequest {
            remote_id: "pdf-2".into(),
            library_id: Some(f.library.clone()),
            collection_id: Some(f.cosmology.clone()),
            library_dir: Some(f.library_dir.clone()),
            ..Default::default()
        },
    )
    .unwrap();
    assert!(!outcome.adopted_existing);
    let publication = outcome.publication_id.unwrap();
    assert_ne!(publication, f.abel);
    let detail = f
        .store
        .get_publication_detail(publication.clone())
        .unwrap()
        .unwrap();
    assert_eq!(
        detail.fields.get("title").map(String::as_str),
        Some("Some book")
    );
    assert_eq!(
        f.store.eink_collection_ids_for(&publication).unwrap(),
        vec![f.cosmology.clone()]
    );
    let files = f.store.list_linked_files(publication.clone()).unwrap();
    let primary = files
        .iter()
        .find(|r| r.role.as_deref() != Some("eink-annotated"))
        .unwrap();
    assert_eq!(primary.file_type.as_deref(), Some("pdf"));
    assert_eq!(
        primary.sha256.as_deref(),
        Some(imbib_core::eink::paths::sha256_bytes(other_pdf).as_str())
    );
    let row = f
        .store
        .eink_mirror_for_publication(None, publication)
        .unwrap()
        .unwrap();
    assert_eq!(row.remote_path.as_deref(), Some("Books"));
}

#[test]
fn a_notebook_can_come_in_as_a_note_artifact_instead() {
    let f = fixture();
    let mock = tablet();
    mock.add_document("top-1", "", "Quick sketch", "", 1_757_000_000_000);
    mock.set_download(
        "top-1",
        DownloadKind::Rmdoc,
        notebook_archive("top-1", "Quick sketch", ""),
    );
    let outcome = import_document(
        &f.store,
        &f.device,
        &mock,
        &ImportDocumentRequest {
            remote_id: "top-1".into(),
            as_kind: "note".into(),
            library_dir: Some(f.library_dir.clone()),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(outcome.publication_id, None);
    let artifact = f
        .store
        .get_artifact(outcome.artifact_id.clone().unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(artifact.title, "Quick sketch");
    assert!(artifact
        .notes
        .unwrap_or_default()
        .contains("Rendered from the reMarkable"));
    // A note leaves no mirror row: the document stays offered.
    assert_eq!(list_unmatched(&f.store, &f.device, &mock).unwrap().len(), 1);
    let bad = import_document(
        &f.store,
        &f.device,
        &mock,
        &ImportDocumentRequest {
            remote_id: "top-1".into(),
            as_kind: "poem".into(),
            library_dir: Some(f.library_dir.clone()),
            ..Default::default()
        },
    );
    assert!(bad.is_err());
}

#[test]
fn a_mirrored_paper_moved_out_of_the_tree_is_followed_not_tombstoned() {
    let f = fixture();
    let mock = tablet();
    f.store.eink_mark(None, vec![f.abel.clone()]).unwrap();
    run_sync(&f.store, None, &mock, &NoopSink, SyncOptions::default()).unwrap();
    let row = f
        .store
        .eink_mirror_for_publication(None, f.abel.clone())
        .unwrap()
        .unwrap();
    let remote = row.remote_id.unwrap();
    mock.move_document(&remote, "f-books");

    let report = run_sync(&f.store, None, &mock, &NoopSink, SyncOptions::default()).unwrap();
    assert_eq!(report.summary.removed, 0, "{:?}", report.trace);
    let row = f
        .store
        .eink_mirror_for_publication(None, f.abel.clone())
        .unwrap()
        .unwrap();
    assert_eq!(row.state, "uploaded");
    assert_eq!(row.remote_parent_id.as_deref(), Some("f-books"));
    assert_eq!(row.remote_path.as_deref(), Some("Books"));
}

#[test]
fn typed_text_is_collected_per_page() {
    let bytes = notebook_archive("nb-1", "Lecture notes", "");
    let archive = impress_remarkable::rmdoc::parse_rmdoc(&bytes).unwrap();
    // The firmware-2 fixture page carries strokes, no typed text.
    assert_eq!(typed_text_of(&archive), "");
}
