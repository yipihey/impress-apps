//! The USB web interface against a scripted HTTP server.
//!
//! Pins the three facts the engine depends on: names come from the tablet's
//! `VissibleName` key, an upload is preceded and followed by a listing of
//! the target folder (which is how the server knows where to file it), and
//! the receipt carries the id that appeared.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use impress_remarkable::usb_web::{
    download_document_as, list_folder, reachable, upload_document_into, DownloadKind,
};
use impress_remarkable::{DocumentKind, Error};

const ROOT: &str = r#"[
 {"ID":"f1","VisibleName":"imbib","VissibleName":"imbib","Parent":"","Type":"CollectionType","ModifiedClient":"2026-09-01T10:00:00.000Z","Bookmarked":false,"CurrentPage":0,"fileType":""},
 {"ID":"d0","VisibleName":"Old paper","VissibleName":"Old paper","Parent":"","Type":"DocumentType","ModifiedClient":"2026-08-01T10:00:00.000Z","Bookmarked":false,"CurrentPage":3,"fileType":"pdf"}
]"#;

const FOLDER_BEFORE: &str = r#"[
 {"ID":"d1","VissibleName":"Abel 2002 – First star","Parent":"f1","Type":"DocumentType","ModifiedClient":"2026-09-02T10:00:00.000Z","Bookmarked":false,"CurrentPage":0,"fileType":"pdf"}
]"#;

const FOLDER_AFTER: &str = r#"[
 {"ID":"d2","VissibleName":"Bryan 2014 – Enzo","Parent":"f1","Type":"DocumentType","ModifiedClient":"2026-09-07T12:00:00.000Z","Bookmarked":false,"CurrentPage":0,"fileType":"pdf"},
 {"ID":"d1","VissibleName":"Abel 2002 – First star","Parent":"f1","Type":"DocumentType","ModifiedClient":"2026-09-02T10:00:00.000Z","Bookmarked":false,"CurrentPage":0,"fileType":"pdf"}
]"#;

#[tokio::test]
async fn names_come_from_the_tablets_misspelled_key() {
    let mut server = mockito::Server::new_async().await;
    let _root = server
        .mock("GET", "/documents/")
        .with_header("content-type", "application/json")
        .with_body(ROOT)
        .create_async()
        .await;

    let entries = list_folder(&server.url(), None).await.unwrap();
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].visible_name, "imbib", "newest first");
    assert_eq!(entries[0].kind, DocumentKind::Folder);
    assert_eq!(entries[1].visible_name, "Old paper");
    assert!(entries[1].is_pdf());
}

#[tokio::test]
async fn an_upload_lists_the_folder_before_and_after_and_reports_the_new_id() {
    let mut server = mockito::Server::new_async().await;
    let calls: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let listings = Arc::new(AtomicUsize::new(0));

    let calls_for_list = Arc::clone(&calls);
    let listings_for_list = Arc::clone(&listings);
    let _folder = server
        .mock("GET", "/documents/f1")
        .with_header("content-type", "application/json")
        .with_body_from_request(move |_request| {
            calls_for_list.lock().unwrap().push("list".into());
            let n = listings_for_list.fetch_add(1, Ordering::SeqCst);
            if n == 0 { FOLDER_BEFORE } else { FOLDER_AFTER }
                .as_bytes()
                .to_vec()
        })
        .expect(2)
        .create_async()
        .await;

    let calls_for_upload = Arc::clone(&calls);
    let _upload = server
        .mock("POST", "/upload")
        .match_header(
            "content-type",
            mockito::Matcher::Regex("multipart/form-data.*".into()),
        )
        .match_body(mockito::Matcher::AllOf(vec![
            mockito::Matcher::Regex(r#"name="file"; filename="Bryan 2014 – Enzo.pdf""#.into()),
            mockito::Matcher::Regex("Content-Type: application/pdf".into()),
            mockito::Matcher::Regex("%PDF-1.4".into()),
        ]))
        .with_status(201)
        .with_body_from_request(move |_request| {
            calls_for_upload.lock().unwrap().push("upload".into());
            Vec::new()
        })
        .expect(1)
        .create_async()
        .await;

    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("source.pdf");
    std::fs::write(&file, b"%PDF-1.4\n%%EOF\n").unwrap();

    let receipt = upload_document_into(&server.url(), Some("f1"), &file, "Bryan 2014 – Enzo.pdf")
        .await
        .unwrap();

    assert_eq!(receipt.id.as_deref(), Some("d2"));
    assert_eq!(receipt.parent, "f1");
    assert_eq!(receipt.visible_name, "Bryan 2014 – Enzo");
    assert_eq!(
        *calls.lock().unwrap(),
        vec!["list", "upload", "list"],
        "the listing before the POST is what tells the tablet where to file it"
    );
}

#[tokio::test]
async fn an_upload_that_lands_elsewhere_is_reported_not_recorded() {
    let mut server = mockito::Server::new_async().await;
    let listings = Arc::new(AtomicUsize::new(0));
    let listings_for_list = Arc::clone(&listings);
    let _folder = server
        .mock("GET", "/documents/f1")
        .with_body_from_request(move |_| {
            let n = listings_for_list.fetch_add(1, Ordering::SeqCst);
            if n == 0 {
                FOLDER_BEFORE.as_bytes().to_vec()
            } else {
                // The new entry shows up, but the tablet filed it at the root.
                FOLDER_AFTER
                    .replace(
                        r#""Parent":"f1","Type":"DocumentType","ModifiedClient":"2026-09-07"#,
                        r#""Parent":"","Type":"DocumentType","ModifiedClient":"2026-09-07"#,
                    )
                    .into_bytes()
            }
        })
        .create_async()
        .await;
    let _upload = server
        .mock("POST", "/upload")
        .with_status(201)
        .create_async()
        .await;

    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("source.pdf");
    std::fs::write(&file, b"%PDF-1.4\n").unwrap();

    let error = upload_document_into(&server.url(), Some("f1"), &file, "Bryan 2014 – Enzo.pdf")
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Misplaced { .. }), "{error}");
}

#[tokio::test]
async fn an_epub_is_sent_with_its_own_mime_type() {
    let mut server = mockito::Server::new_async().await;
    let _root = server
        .mock("GET", "/documents/")
        .with_body("[]")
        .expect(2)
        .create_async()
        .await;
    let _upload = server
        .mock("POST", "/upload")
        .match_body(mockito::Matcher::Regex(
            "Content-Type: application/epub\\+zip".into(),
        ))
        .with_status(201)
        .create_async()
        .await;
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("book.epub");
    std::fs::write(&file, b"PK").unwrap();

    let receipt = upload_document_into(&server.url(), None, &file, "Book.epub")
        .await
        .unwrap();
    assert_eq!(
        receipt.id, None,
        "nothing new appeared, so no id is claimed"
    );
    assert_eq!(receipt.parent, "");
}

#[tokio::test]
async fn renditions_are_downloaded_under_their_own_extension() {
    let mut server = mockito::Server::new_async().await;
    let _rmdoc = server
        .mock("GET", "/download/d1/rmdoc")
        .with_body(b"PK\x03\x04archive")
        .create_async()
        .await;
    let _pdf = server
        .mock("GET", "/download/d1/pdf")
        .with_body(b"%PDF-1.7 rendered")
        .create_async()
        .await;
    let _missing = server
        .mock("GET", "/download/nope/pdf")
        .with_status(404)
        .create_async()
        .await;

    let dir = tempfile::tempdir().unwrap();
    let archive = download_document_as(&server.url(), "d1", DownloadKind::Rmdoc, dir.path())
        .await
        .unwrap();
    assert_eq!(archive.file_name().unwrap(), "d1.rmdoc");
    let pdf = download_document_as(&server.url(), "d1", DownloadKind::Pdf, dir.path())
        .await
        .unwrap();
    assert_eq!(pdf.file_name().unwrap(), "d1.pdf");
    assert_eq!(std::fs::read(&pdf).unwrap(), b"%PDF-1.7 rendered");
    assert!(matches!(
        download_document_as(&server.url(), "nope", DownloadKind::Pdf, dir.path()).await,
        Err(Error::DocumentNotFound { .. })
    ));
}

#[tokio::test]
async fn reachability_is_a_connect_not_a_request() {
    let server = mockito::Server::new_async().await;
    assert!(reachable(&server.url(), std::time::Duration::from_secs(2)).await);
    // A port nothing listens on answers "no" within the timeout.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    assert!(
        !reachable(
            &format!("http://127.0.0.1:{port}"),
            std::time::Duration::from_millis(500)
        )
        .await
    );
}
