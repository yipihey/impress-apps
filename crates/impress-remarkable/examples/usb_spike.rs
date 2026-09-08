//! P0 spike against a plugged-in tablet: capture real listings as fixtures,
//! pull one document as an archive, and find out whether the firmware
//! honours the id and parent inside an uploaded `.rmdoc` — the one way the
//! USB web interface could let imbib create folders and file documents
//! deterministically.
//!
//!   cargo run -p impress-remarkable --example usb_spike -- capture <out-dir>
//!   cargo run -p impress-remarkable --example usb_spike -- download <id> <out-dir>
//!   cargo run -p impress-remarkable --example usb_spike -- spike-folder [parent-id]
//!   cargo run -p impress-remarkable --example usb_spike -- spike-doc <parent-id> <pdf>
//!   cargo run -p impress-remarkable --example usb_spike -- plain <parent-id> <pdf>
//!
//! `IMPRESS_RM_URL` overrides the base URL (default http://10.11.99.1).
//! Everything it uploads is named `imbib-spike…` so it is easy to delete on
//! the tablet afterwards.

use std::path::PathBuf;

use impress_remarkable::blocking;
use impress_remarkable::rmdoc::{build_rmdoc, RmdocKind, RmdocSpec, SourceKind};
use impress_remarkable::usb_web::DownloadKind;
use impress_remarkable::DocumentKind;

fn base_url() -> String {
    std::env::var("IMPRESS_RM_URL")
        .unwrap_or_else(|_| impress_remarkable::usb_web::DEFAULT_BASE_URL.to_string())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn print_listing(label: &str, entries: &[impress_remarkable::RemarkableDocument]) {
    println!("--- {label}: {} entries", entries.len());
    for e in entries {
        println!(
            "  {:<9} {:<36} parent={:<36} {:<9} {}",
            match e.kind {
                DocumentKind::Folder => "folder",
                DocumentKind::Document => "document",
                DocumentKind::Unknown => "?",
            },
            e.id,
            if e.parent.is_empty() {
                "(root)"
            } else {
                e.parent.as_str()
            },
            e.file_type,
            e.visible_name
        );
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let url = base_url();
    if !blocking::usb_reachable(&url) {
        eprintln!("{url} is not reachable — plug the tablet in and turn on Settings → Storage → USB web interface");
        std::process::exit(2);
    }
    match args.first().map(String::as_str) {
        Some("capture") => {
            let out = PathBuf::from(args.get(1).expect("out-dir"));
            std::fs::create_dir_all(&out).unwrap();
            let raw = reqwest::blocking::get(format!("{url}/documents/"))
                .unwrap()
                .text()
                .unwrap();
            std::fs::write(out.join("root_listing.json"), &raw).unwrap();
            let root = blocking::usb_list_documents(&url).unwrap();
            print_listing("root", &root);
            if let Some(folder) = root.iter().find(|e| e.kind == DocumentKind::Folder) {
                let raw = reqwest::blocking::get(format!("{url}/documents/{}", folder.id))
                    .unwrap()
                    .text()
                    .unwrap();
                std::fs::write(out.join("folder_listing.json"), &raw).unwrap();
                let entries = blocking::usb_list_folder(&url, Some(&folder.id)).unwrap();
                print_listing(&format!("folder {}", folder.visible_name), &entries);
            }
            println!("wrote fixtures to {}", out.display());
        }
        Some("download") => {
            let id = args.get(1).expect("id");
            let out = PathBuf::from(args.get(2).expect("out-dir"));
            let archive =
                blocking::usb_download_document_as(&url, id, DownloadKind::Rmdoc, &out).unwrap();
            let pdf =
                blocking::usb_download_document_as(&url, id, DownloadKind::Pdf, &out).unwrap();
            println!("wrote {} and {}", archive.display(), pdf.display());
            let parsed = impress_remarkable::rmdoc::read_rmdoc(&archive).unwrap();
            println!(
                "archive {}: {:?} type={} fileType={} pages={} source={:?} other={:?}",
                parsed.id,
                parsed.metadata.visible_name,
                parsed.metadata.kind,
                parsed.content.file_type,
                parsed.pages.len(),
                parsed.source.as_ref().map(|s| (s.kind, s.bytes.len())),
                parsed.other_entries
            );
            for page in &parsed.pages {
                println!(
                    "  page {} id={} rm={} redirect={:?}",
                    page.index,
                    page.page_id,
                    page.rm_bytes.as_ref().map(|b| b.len()).unwrap_or(0),
                    page.redirect_pdf_index
                );
            }
            println!(
                "zoomMode={:?} orientation={:?} customZoomScale={}",
                parsed.content.zoom_mode,
                parsed.content.orientation,
                parsed.content.custom_zoom_scale
            );
        }
        Some("spike-folder") => {
            let parent = args.get(1).cloned().unwrap_or_default();
            let id = uuid::Uuid::new_v4().to_string();
            let spec = RmdocSpec {
                id: id.clone(),
                visible_name: "imbib-spike-folder".into(),
                parent: parent.clone(),
                last_modified_ms: now_ms(),
                kind: RmdocKind::Folder,
                page_count: None,
                page_files: Vec::new(),
            };
            let dir = tempfile::tempdir().unwrap();
            let file = dir.path().join("imbib-spike-folder.rmdoc");
            std::fs::write(&file, build_rmdoc(&spec).unwrap()).unwrap();
            println!("uploading folder archive with id {id} parent={parent:?} …");
            let target = if parent.is_empty() {
                None
            } else {
                Some(parent.as_str())
            };
            let receipt =
                blocking::usb_upload_document_into(&url, target, &file, "imbib-spike-folder.rmdoc");
            println!("receipt: {receipt:?}");
            let listing = blocking::usb_list_folder(&url, target).unwrap();
            print_listing("after", &listing);
            match listing.iter().find(|e| e.visible_name == "imbib-spike-folder") {
                Some(e) => println!(
                    "RESULT: entry appeared as {:?} with id {} (ours: {}) → folder creation via rmdoc: {}",
                    e.kind,
                    e.id,
                    id,
                    if e.kind == DocumentKind::Folder { "GO" } else { "NO-GO (became a document)" }
                ),
                None => println!("RESULT: nothing named imbib-spike-folder appeared → NO-GO"),
            }
        }
        Some("spike-doc") => {
            let parent = args.get(1).expect("parent-id").clone();
            let pdf = std::fs::read(args.get(2).expect("pdf path")).unwrap();
            let id = uuid::Uuid::new_v4().to_string();
            let spec = RmdocSpec {
                id: id.clone(),
                // Deliberately different from the filename stem, so the
                // listing shows which one the firmware used.
                visible_name: "imbib-spike-doc (name from archive)".into(),
                parent: parent.clone(),
                last_modified_ms: now_ms(),
                kind: RmdocKind::Document {
                    kind: SourceKind::Pdf,
                    source: pdf,
                },
                page_count: Some(1),
                page_files: Vec::new(),
            };
            let dir = tempfile::tempdir().unwrap();
            let file = dir.path().join("imbib-spike-doc.rmdoc");
            std::fs::write(&file, build_rmdoc(&spec).unwrap()).unwrap();
            println!(
                "uploading document archive with id {id} parent={parent} AFTER LISTING THE ROOT …"
            );
            // Deliberately list the root, not the parent: if the entry still
            // lands in `parent`, the archive's own parent field is honoured.
            let receipt =
                blocking::usb_upload_document_into(&url, None, &file, "imbib-spike-doc.rmdoc");
            println!("receipt (root listing): {receipt:?}");
            let in_parent = blocking::usb_list_folder(&url, Some(&parent)).unwrap();
            print_listing("parent folder after", &in_parent);
            match in_parent.iter().find(|e| e.visible_name.starts_with("imbib-spike-doc")) {
                Some(e) => println!("RESULT: landed in parent with id {} (ours: {}) → parent honoured: GO; id honoured: {}", e.id, id, e.id == id),
                None => println!("RESULT: not in parent → the archive's parent is ignored (NO-GO for placement by parent)"),
            }
        }
        Some("plain") => {
            let parent = args.get(1).expect("parent-id").clone();
            let path = PathBuf::from(args.get(2).expect("pdf path"));
            // `IMPRESS_RM_UPLOAD_NAME` overrides the upload filename, e.g. to
            // learn whether an extension-less name is accepted and kept.
            let upload_name = std::env::var("IMPRESS_RM_UPLOAD_NAME")
                .unwrap_or_else(|_| "imbib-spike-plain.pdf".into());
            let receipt =
                blocking::usb_upload_document_into(&url, Some(&parent), &path, &upload_name);
            println!("receipt: {receipt:?}");
            let listing = blocking::usb_list_folder(&url, Some(&parent)).unwrap();
            print_listing("parent folder after", &listing);
            println!(
                "RESULT: look for 'imbib-spike-plain' above — the name should be the filename stem"
            );
        }
        _ => {
            eprintln!("usage: usb_spike capture <out-dir> | download <id> <out-dir> | spike-folder [parent-id] | spike-doc <parent-id> <pdf> | plain <parent-id> <pdf>");
            std::process::exit(1);
        }
    }
}
