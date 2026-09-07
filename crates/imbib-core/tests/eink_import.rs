//! The import half, Tier A: a real firmware-2 page inside a synthetic
//! archive, an in-memory store, a temp library folder.

use std::path::PathBuf;
use std::sync::Arc;

use imbib_core::eink::import::{import_annotated_document, ImportRequest};
use imbib_core::eink::{EinkDeviceConfig, EinkDeviceConfigInput};
use imbib_core::unified::store_api::ImbibStore;
use impress_remarkable::rmdoc::{build_rmdoc, RmdocKind, RmdocSpec, SourceKind};

const V5_PAGE: &[u8] =
    include_bytes!("../../impress-remarkable/tests/fixtures/rm/notebook_page_v5.rm");
const CALIBRATION_PDF: &[u8] =
    include_bytes!("../../impress-remarkable/tests/fixtures/calibration/calibration.pdf");

struct Fixture {
    store: Arc<ImbibStore>,
    publication: String,
    primary_file: (String, String),
    device: EinkDeviceConfig,
    library_dir: PathBuf,
    rendered_pdf: PathBuf,
    _temp: tempfile::TempDir,
}

fn fixture() -> Fixture {
    let store = ImbibStore::open_in_memory().unwrap();
    let library = store.create_library("Library".into()).unwrap();
    let publication = store
        .import_bibtex_into(
            "@article{Abel2002, author = {Abel, Tom}, title = {First star}, year = {2002}}".into(),
            library.id.clone(),
            None,
        )
        .unwrap()
        .imported
        .remove(0);
    let temp = tempfile::tempdir().unwrap();
    let library_dir = temp.path().join("Library-dir");
    std::fs::create_dir_all(library_dir.join("Papers")).unwrap();
    let primary = library_dir.join("Papers/Abel_2002.pdf");
    std::fs::write(&primary, CALIBRATION_PDF).unwrap();
    let file = store
        .add_linked_file(
            publication.clone(),
            "Abel_2002.pdf".into(),
            Some(primary.display().to_string()),
            Some("pdf".into()),
            CALIBRATION_PDF.len() as i64,
            None,
            true,
        )
        .unwrap();
    let rendered_pdf = temp.path().join("rendered.pdf");
    std::fs::write(&rendered_pdf, CALIBRATION_PDF).unwrap();
    let row = store
        .eink_configure_device(EinkDeviceConfigInput {
            name: Some("Paper Pro".into()),
            ..Default::default()
        })
        .unwrap();
    let device = store.eink_device_config(&row.id).unwrap().unwrap();
    Fixture {
        store,
        publication,
        primary_file: (file.id, "Abel_2002.pdf".into()),
        device,
        library_dir,
        rendered_pdf,
        _temp: temp,
    }
}

fn archive(dir: &std::path::Path, pages: Vec<(String, Vec<u8>)>) -> PathBuf {
    let spec = RmdocSpec {
        id: "remote-1".into(),
        visible_name: "Abel 2002 – First star".into(),
        parent: String::new(),
        last_modified_ms: 1_757_000_000_000,
        kind: RmdocKind::Document {
            kind: SourceKind::Pdf,
            source: CALIBRATION_PDF.to_vec(),
        },
        page_count: None,
        page_files: pages,
    };
    let path = dir.join("remote-1.rmdoc");
    std::fs::write(&path, build_rmdoc(&spec).unwrap()).unwrap();
    path
}

fn request<'a>(
    f: &'a Fixture,
    rmdoc: Option<&'a std::path::Path>,
    modified_ms: i64,
) -> ImportRequest<'a> {
    ImportRequest {
        device: &f.device,
        mirror_id: "mirror-1",
        publication_id: &f.publication,
        library_dir: &f.library_dir,
        primary_file: Some(f.primary_file.clone()),
        remote_id: "remote-1",
        remote_name: "Abel 2002 – First star",
        remote_modified_ms: modified_ms,
        rendered_pdf: &f.rendered_pdf,
        rmdoc,
    }
}

#[test]
fn the_variant_is_added_once_and_replaced_in_place() {
    let f = fixture();
    let first = import_annotated_document(&f.store, &request(&f, None, 1)).unwrap();
    let variant_id = first.annotated_file_id.clone().unwrap();
    let files = f.store.list_linked_files(f.publication.clone()).unwrap();
    assert_eq!(files.len(), 2);
    let variant = files.iter().find(|r| r.id == variant_id).unwrap();
    assert_eq!(variant.role.as_deref(), Some("eink-annotated"));
    assert_eq!(
        variant.display_name.as_deref(),
        Some("reMarkable — annotated")
    );
    assert_eq!(variant.filename, "Abel_2002 (reMarkable).pdf");
    assert_eq!(variant.source_remote_id.as_deref(), Some("remote-1"));
    assert!(variant.is_pdf && variant.is_locally_materialized);
    assert!(f
        .library_dir
        .join("Papers/Abel_2002 (reMarkable).pdf")
        .is_file());
    let sha_before = variant.sha256.clone();

    // A changed rendition replaces the bytes, not the row.
    std::fs::write(&f.rendered_pdf, b"%PDF-1.4 changed\n").unwrap();
    let second = import_annotated_document(&f.store, &request(&f, None, 2)).unwrap();
    assert_eq!(
        second.annotated_file_id.as_deref(),
        Some(variant_id.as_str())
    );
    let files = f.store.list_linked_files(f.publication.clone()).unwrap();
    assert_eq!(files.len(), 2, "still two files");
    let variant = files.iter().find(|r| r.id == variant_id).unwrap();
    assert_ne!(variant.sha256, sha_before);
    assert_eq!(variant.source_remote_modified_ms, Some(2));
    assert_eq!(
        std::fs::read(f.library_dir.join("Papers/Abel_2002 (reMarkable).pdf")).unwrap(),
        b"%PDF-1.4 changed\n"
    );
}

#[test]
fn ink_from_a_real_page_becomes_rows_that_reimport_updates_not_duplicates() {
    let f = fixture();
    let rmdoc = archive(&f.library_dir, vec![("page-a".into(), V5_PAGE.to_vec())]);
    let first = import_annotated_document(&f.store, &request(&f, Some(&rmdoc), 1)).unwrap();
    assert!(first.created > 0, "{first:?}");
    assert_eq!(first.updated, 0);
    assert_eq!(
        first.ink_pending_ocr, first.created,
        "every ink group waits for OCR"
    );
    let rows = f
        .store
        .eink_annotations_for_publication(f.publication.clone())
        .unwrap();
    assert_eq!(rows.len() as u32, first.created);
    for row in &rows {
        assert_eq!(row.annotation_type, "ink");
        assert_eq!(row.author_name.as_deref(), Some("reMarkable"));
        assert_eq!(row.source.as_deref(), Some("remarkable"));
        assert_eq!(row.source_remote_id.as_deref(), Some("remote-1"));
        assert_eq!(row.source_page_id.as_deref(), Some("page-a"));
        assert_eq!(
            row.linked_file_id, f.primary_file.0,
            "rows attach to the primary file"
        );
        assert!(row
            .bounds_json
            .as_deref()
            .is_some_and(|b| b.starts_with("{\"x\":")));
        let image = f.library_dir.join(row.image_path.as_deref().unwrap());
        assert!(image.is_file(), "{}", image.display());
        assert!(row.ocr_confidence.is_none());
    }
    let ids_before: Vec<String> = rows.iter().map(|r| r.id.clone()).collect();

    // OCR fills one row; the same import again keeps it.
    let jobs = f
        .store
        .eink_pending_ocr(Some(f.publication.clone()))
        .unwrap();
    assert_eq!(jobs.len() as u32, first.created);
    assert!(std::path::Path::new(&jobs[0].image_path).is_file());
    f.store
        .eink_complete_ocr(jobs[0].annotation_id.clone(), Some("hello".into()), 0.9)
        .unwrap();
    let second = import_annotated_document(&f.store, &request(&f, Some(&rmdoc), 2)).unwrap();
    assert_eq!(second.created, 0);
    assert_eq!(second.updated, first.created);
    assert_eq!(second.deleted, 0);
    let rows = f
        .store
        .eink_annotations_for_publication(f.publication.clone())
        .unwrap();
    let ids_after: Vec<String> = rows.iter().map(|r| r.id.clone()).collect();
    assert_eq!(ids_before, ids_after, "stable ids");
    let kept = rows.iter().find(|r| r.id == jobs[0].annotation_id).unwrap();
    assert_eq!(
        kept.contents.as_deref(),
        Some("hello"),
        "OCR text survives an unchanged re-import"
    );
    assert_eq!(kept.ocr_confidence, Some(0.9));
    assert_eq!(
        f.store
            .eink_pending_ocr(Some(f.publication.clone()))
            .unwrap()
            .len() as u32,
        first.created - 1
    );

    // Notes: appended once per snapshot.
    assert!(f
        .store
        .eink_append_notes(f.publication.clone(), false)
        .unwrap());
    let detail = f
        .store
        .get_publication_detail(f.publication.clone())
        .unwrap()
        .unwrap();
    let note = detail.fields.get("note").cloned().unwrap_or_default();
    assert!(note.contains("## reMarkable notes"), "{note}");
    assert!(note.contains("(handwritten, OCR 0.90) — hello"), "{note}");
    assert!(
        !f.store
            .eink_append_notes(f.publication.clone(), false)
            .unwrap(),
        "same snapshot: no-op"
    );
    assert!(
        f.store
            .eink_append_notes(f.publication.clone(), true)
            .unwrap(),
        "forced: appended again"
    );

    // The tablet page emptied: rows and images go.
    let empty = archive(&f.library_dir, vec![]);
    let third = import_annotated_document(&f.store, &request(&f, Some(&empty), 3)).unwrap();
    assert_eq!(third.deleted, first.created);
    assert!(f
        .store
        .eink_annotations_for_publication(f.publication.clone())
        .unwrap()
        .is_empty());
    assert!(f.store.eink_pending_ocr(None).unwrap().is_empty());
}
