//! Getting a paper's PDF in Rust, so the web host, the CLI, MCP and a daemon
//! can fetch one with no app running (the app's `download-pdfs` asks the
//! running Swift app).
//!
//! `fetch-pdf` tries, in order: arXiv (`https://arxiv.org/pdf/<id>`), the
//! publisher's URL for the DOI when a publisher rule constructs one
//! (`imbib_core::publishers`, what `parsers-service_resolve-publisher-pdf`
//! reports), and the record's own `url` when it names a PDF. A download
//! counts only when it is a PDF: it starts `%PDF-`, is more than a
//! kilobyte, and was not served as HTML — a paywall's login page arrives
//! with status 200. The file is written where the app keeps a library's
//! files (`<library>/Papers/Author_Year_Title.pdf`, the app's naming) and
//! linked to the paper as the app links one, so the app, the card's
//! "Local PDF" link and the e-ink mirror all find it.

use std::path::{Path, PathBuf};

use impress_service_core::async_trait;
use impress_service_core::pipeline::context::report_refusal;
use impress_service_core::refusal::codes;
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

use imbib_core::eink::paths;
use imbib_core::files::naming::{generate_filename, FilenameOptions};

use crate::backend::library_service_instance;
use crate::library_service::PublicationDetailRecord;
use crate::store_singleton::store_instance;

/// The largest PDF this will write (a scanned book is under this).
const MAX_BYTES: usize = 200 * 1024 * 1024;

/// What one `fetch-pdf` did.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct PdfFetch {
    /// True when the paper now has a local PDF.
    pub ok: bool,
    /// True when it already had one and nothing was fetched.
    pub already: bool,
    /// The PDF's file name.
    pub filename: String,
    /// The linked file's id (what `/api/blob/<id>/<filename>` serves).
    pub linked_file_id: String,
    /// Where it came from.
    pub source_url: String,
    /// Its size in bytes.
    pub bytes: u64,
    /// Why there is no PDF, when there is none: each place tried and what
    /// it answered.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub problem: Option<String>,
}

#[impress_service]
pub trait ImbibPdfService: Send + Sync + 'static {
    /// Get a paper's PDF and keep it with the library's files: from arXiv,
    /// else from the publisher's URL for its DOI, else from the record's own
    /// PDF URL. Only a real PDF is kept (a paywall's HTML page is refused).
    /// A paper that already has a local PDF is answered `already` and
    /// nothing is fetched. Runs without the app.
    #[impress_method(safety = external, effects(reads = ["imbib/bibliography-entry", "imbib/linked-file", "imbib/library", "imbib/tag-definition", "imbib/collection"], writes = ["imbib/linked-file"], reach = [network, fs]))]
    #[impress_example(
        name = "unknown-paper",
        args = r#"{"id":"5c000000-0000-4000-8000-0000000000fb"}"#
    )]
    async fn fetch_pdf(&self, id: String) -> PdfFetch;
}

#[derive(Default, Clone, Copy)]
pub struct DefaultImbibPdfService;

#[async_trait::async_trait]
impl ImbibPdfService for DefaultImbibPdfService {
    async fn fetch_pdf(&self, id: String) -> PdfFetch {
        let Some(detail) = library_service_instance()
            .get_publication_detail(id.clone())
            .await
        else {
            report_refusal(codes::NOT_FOUND, format!("fetch_pdf: no paper {id}"));
            return PdfFetch {
                problem: Some("no such paper".into()),
                ..Default::default()
            };
        };
        if let Some(local) = local_pdf(&detail) {
            return local;
        }
        let candidates = candidates(&detail.fields);
        if candidates.is_empty() {
            return PdfFetch {
                problem: Some("no arXiv id, no DOI a publisher rule knows, and no PDF url".into()),
                ..Default::default()
            };
        }
        tracing::info!(
            target: "pdf",
            "fetch_pdf {id}: mutation requested: trying {}",
            candidates.join(", ")
        );
        let mut tried = Vec::new();
        for url in candidates {
            match download(&url).await {
                Ok(bytes) => return keep(&detail, &url, bytes).await,
                Err(why) => {
                    tracing::info!(target: "pdf", "fetch_pdf {id}: {url}: {why}");
                    tried.push(format!("{url}: {why}"));
                }
            }
        }
        PdfFetch {
            problem: Some(tried.join("; ")),
            ..Default::default()
        }
    }
}

/// The paper's PDF on this Mac, when it has one.
fn local_pdf(detail: &PublicationDetailRecord) -> Option<PdfFetch> {
    let store = store_instance();
    detail
        .linked_files
        .iter()
        .filter(|f| f.is_pdf && f.is_locally_materialized)
        .find(|f| matches!(store.resolve_linked_file(f.id.clone()), Ok(Some(_))))
        .map(|f| PdfFetch {
            ok: true,
            already: true,
            filename: f.filename.clone(),
            linked_file_id: f.id.clone(),
            bytes: f.file_size.max(0) as u64,
            ..Default::default()
        })
}

/// Where the PDF may be, best first.
fn candidates(fields: &std::collections::HashMap<String, String>) -> Vec<String> {
    let field = |k: &str| {
        fields
            .get(k)
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
    };
    let mut out = Vec::new();
    if let Some(arxiv) = field("arxiv_id").or_else(|| field("eprint")) {
        let arxiv = arxiv
            .trim_start_matches("arXiv:")
            .trim_start_matches("arxiv:");
        out.push(format!("https://arxiv.org/pdf/{arxiv}"));
    }
    if let Some(doi) = field("doi") {
        if let Some(url) =
            imbib_core::publishers::rule_for_doi(&doi).and_then(|rule| rule.construct_pdf_url(&doi))
        {
            out.push(url);
        }
    }
    if let Some(url) =
        field("url").filter(|u| u.starts_with("http") && u.to_lowercase().ends_with(".pdf"))
    {
        out.push(url);
    }
    out.dedup();
    out
}

/// The bytes at `url`, when they are a PDF.
async fn download(url: &str) -> Result<Vec<u8>, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .user_agent(concat!(
            "imbib/",
            env!("CARGO_PKG_VERSION"),
            " (impress; pdf)"
        ))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client.get(url).send().await.map_err(|e| e.to_string())?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    let html = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.contains("html"));
    let bytes = response.bytes().await.map_err(|e| e.to_string())?;
    pdf_or_why(&bytes, html).map(|_| bytes.to_vec())
}

/// Whether `bytes` are a PDF worth keeping; why not, when not.
fn pdf_or_why(bytes: &[u8], served_as_html: bool) -> Result<(), String> {
    if served_as_html {
        return Err("served an HTML page, not a PDF (a paywall or a landing page)".into());
    }
    if bytes.len() > MAX_BYTES {
        return Err(format!("{} bytes is more than this keeps", bytes.len()));
    }
    if bytes.len() < 1024 {
        return Err(format!("only {} bytes", bytes.len()));
    }
    if !bytes.starts_with(b"%PDF-") {
        return Err("does not start %PDF-".into());
    }
    Ok(())
}

/// Write the PDF beside the library's other files and link it.
async fn keep(detail: &PublicationDetailRecord, url: &str, bytes: Vec<u8>) -> PdfFetch {
    let detail = detail.clone();
    let url = url.to_string();
    tokio::task::spawn_blocking(move || keep_blocking(&detail, &url, &bytes))
        .await
        .unwrap_or_else(|e| Err(e.to_string()))
        .unwrap_or_else(|why| {
            report_refusal(codes::VERB_FAILED, format!("fetch_pdf: {why}"));
            PdfFetch {
                problem: Some(why),
                ..Default::default()
            }
        })
}

fn keep_blocking(
    detail: &PublicationDetailRecord,
    url: &str,
    bytes: &[u8],
) -> Result<PdfFetch, String> {
    let library = detail
        .library_ids
        .first()
        .cloned()
        .ok_or("the paper is in no library")?;
    let home = paths::user_home().ok_or("no home directory")?;
    let library_dir = paths::library_dir_for_write(&library, &home);
    let papers = library_dir.join("Papers");
    std::fs::create_dir_all(&papers).map_err(|e| format!("{}: {e}", papers.display()))?;
    let family = detail
        .authors
        .first()
        .map(|a| a.family_name.clone())
        .unwrap_or_default();
    let year = detail
        .fields
        .get("year")
        .and_then(|y| y.trim().parse::<i32>().ok());
    let title = detail.fields.get("title").cloned().unwrap_or_default();
    let name = generate_filename(&family, year, &title, &FilenameOptions::default());
    let destination = free_path(&papers, &name);
    let temp = destination.with_extension("pdf.tmp");
    std::fs::write(&temp, bytes).map_err(|e| format!("{}: {e}", temp.display()))?;
    std::fs::rename(&temp, &destination).map_err(|e| format!("{}: {e}", destination.display()))?;
    let filename = destination
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or(name);
    let store = store_instance();
    let row = store
        .add_linked_file(
            detail.id.clone(),
            filename.clone(),
            Some(paths::relative_or_absolute(&library_dir, &destination)),
            Some("pdf".into()),
            bytes.len() as i64,
            Some(paths::sha256_bytes(bytes)),
            true,
        )
        .map_err(|e| e.to_string())?;
    tracing::info!(
        target: "pdf",
        "fetch_pdf {}: save: {} bytes from {url} as {}",
        detail.id,
        bytes.len(),
        destination.display()
    );
    Ok(PdfFetch {
        ok: true,
        already: false,
        filename,
        linked_file_id: row.id,
        source_url: url.to_string(),
        bytes: bytes.len() as u64,
        problem: None,
    })
}

/// `name` in `dir`, or `stem-2.pdf`, `stem-3.pdf`, … when taken.
fn free_path(dir: &Path, name: &str) -> PathBuf {
    let first = dir.join(name);
    if !first.exists() {
        return first;
    }
    let (stem, ext) = name
        .rsplit_once('.')
        .map(|(s, e)| (s.to_string(), format!(".{e}")))
        .unwrap_or((name.to_string(), String::new()));
    (2..)
        .map(|n| dir.join(format!("{stem}-{n}{ext}")))
        .find(|p| !p.exists())
        .expect("an unbounded range finds a free name")
}

impress_service_impl! {
    service = ImbibPdfService,
    safety = external,
    since = "0.1.0",
    effects = {
        reads: ["imbib/bibliography-entry", "imbib/linked-file", "imbib/library", "imbib/tag-definition", "imbib/collection"],
        writes: ["imbib/linked-file"],
        reach: [network, fs],
    },
    impl = DefaultImbibPdfService,
    instance = || DefaultImbibPdfService,
    methods = [
        /// Get a paper's PDF from arXiv, its publisher or its own URL, and keep it with the library's files.
        fetch_pdf(
            /// The paper's UUID.
            id: String
        ) -> PdfFetch,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_real_pdf_is_kept() {
        let pdf = [b"%PDF-1.7\n".as_slice(), &[b'x'; 2048]].concat();
        assert!(pdf_or_why(&pdf, false).is_ok());
        assert!(pdf_or_why(&pdf, true).unwrap_err().contains("HTML"));
        assert!(pdf_or_why(b"%PDF-1.7 tiny", false)
            .unwrap_err()
            .contains("bytes"));
        let page = [b"<!doctype html>".as_slice(), &[b'x'; 2048]].concat();
        assert!(pdf_or_why(&page, false).unwrap_err().contains("%PDF-"));
    }

    #[test]
    fn a_taken_name_gets_a_number() {
        let dir = std::env::temp_dir().join(format!("imbib-pdf-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(free_path(&dir, "A_2024_B.pdf"), dir.join("A_2024_B.pdf"));
        std::fs::write(dir.join("A_2024_B.pdf"), b"x").unwrap();
        assert_eq!(free_path(&dir, "A_2024_B.pdf"), dir.join("A_2024_B-2.pdf"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn arxiv_comes_first_then_the_publisher_then_the_record_url() {
        let mut fields = std::collections::HashMap::new();
        fields.insert("arxiv_id".to_string(), "2402.03626".to_string());
        fields.insert(
            "url".to_string(),
            "https://example.org/paper.pdf".to_string(),
        );
        let urls = candidates(&fields);
        assert_eq!(
            urls.first().map(String::as_str),
            Some("https://arxiv.org/pdf/2402.03626")
        );
        assert_eq!(
            urls.last().map(String::as_str),
            Some("https://example.org/paper.pdf")
        );
        assert!(candidates(&Default::default()).is_empty());
    }
}
