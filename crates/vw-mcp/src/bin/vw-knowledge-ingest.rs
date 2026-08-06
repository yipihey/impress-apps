//! Import a page-addressable OCR index into the reusable Impress source graph.
//!
//! The importer does not infer repair rules. It creates an immutable source
//! asset, one extraction run, and a citation-linked searchable content chunk
//! per nonblank page. All identities derive from source bytes and extraction
//! settings, so repeating the command is idempotent.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
use impress_core::source::normalized_text_hash;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_service_core::runtime::block_on;
use impress_store_service::{
    ContentChunkInput, DefaultSourceService, ExtractedTextRegionInput, ExtractionRunInput,
    NormalizedRectInput, SourceCitationInput, SourceLocatorInput, SourceService,
};
use rusqlite::{Connection, OpenFlags};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use uuid::Uuid;

const INGEST_NAMESPACE: Uuid = Uuid::from_u128(0x1313eb44_a61b_43e7_9fd9_5bc35cbf185f);

#[derive(Debug)]
struct Args {
    store_path: PathBuf,
    source_pdf: PathBuf,
    ocr_index: PathBuf,
    title: String,
    source_url: Option<String>,
    source_class: String,
    publisher: String,
    extractor_version: Option<String>,
}

#[derive(Debug)]
struct OcrPage {
    page: u32,
    section_hint: String,
    text: String,
    mean_confidence: f64,
    regions: Vec<LayoutObservation>,
}

#[derive(Debug, Deserialize)]
struct LayoutObservation {
    text: String,
    confidence: Option<f64>,
    #[serde(rename = "boundingBox")]
    bounding_box: LayoutBox,
}

#[derive(Debug, Deserialize)]
struct LayoutBox {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = parse_args()?;
    let source_pdf = args.source_pdf.canonicalize()?;
    let ocr_index = args.ocr_index.canonicalize()?;
    let source_hash = sha256_file(&source_pdf)?;
    let source_size = source_pdf.metadata()?.len();
    let connection = Connection::open_with_flags(&ocr_index, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let metadata = read_metadata(&connection)?;
    let indexed_hash = metadata
        .get("source_sha256")
        .ok_or("OCR index has no source_sha256")?;
    if indexed_hash != &source_hash {
        return Err(format!(
            "OCR index source hash {indexed_hash} does not match PDF {source_hash}"
        )
        .into());
    }
    let pages = read_pages(&connection)?;
    let source_pages: usize = metadata
        .get("source_pages")
        .ok_or("OCR index has no source_pages")?
        .parse()?;
    if pages.len() != source_pages {
        return Err(format!(
            "OCR index is incomplete: {} of {source_pages} pages",
            pages.len()
        )
        .into());
    }

    if let Some(parent) = args.store_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let store = Arc::new(SqliteItemStore::open(&args.store_path)?);
    let source_id = Uuid::new_v5(
        &INGEST_NAMESPACE,
        format!("source:{source_hash}").as_bytes(),
    );
    put_source_asset(
        &store,
        source_id,
        &args,
        &source_pdf,
        &source_hash,
        source_size,
    )?;

    let extractor = metadata
        .get("engine")
        .cloned()
        .unwrap_or_else(|| "tesseract".into());
    let extractor_version = args
        .extractor_version
        .clone()
        .or_else(|| metadata.get("engine_version").cloned())
        .ok_or("OCR index has no engine_version; pass --extractor-version")?;
    let profile = metadata.get("profile").cloned().unwrap_or_else(|| {
        let dpi = metadata.get("dpi").map(String::as_str).unwrap_or("unknown");
        let language = metadata
            .get("language")
            .map(String::as_str)
            .unwrap_or("unknown");
        let psm = metadata.get("psm").map(String::as_str).unwrap_or("unknown");
        format!("page-ocr;dpi={dpi};language={language};psm={psm}")
    });
    let extraction_id = Uuid::new_v5(
        &INGEST_NAMESPACE,
        format!("extraction:{source_id}:{extractor}:{extractor_version}:{profile}").as_bytes(),
    );
    let nonblank: Vec<&OcrPage> = pages
        .iter()
        .filter(|page| !page.text.trim().is_empty())
        .collect();
    let chunk_ids: Vec<Uuid> = nonblank
        .iter()
        .map(|page| chunk_id(source_id, extraction_id, page))
        .collect();
    let citation_ids: Vec<Uuid> = nonblank
        .iter()
        .map(|page| citation_id(source_id, extraction_id, page.page))
        .collect();
    let output_hash = extraction_output_hash(&nonblank);
    let below_70 = nonblank
        .iter()
        .filter(|page| page.mean_confidence < 70.0)
        .count();
    let blank = pages.len() - nonblank.len();
    let built_at = metadata
        .get("built_at")
        .cloned()
        .unwrap_or_else(|| chrono::Utc::now().to_rfc3339());
    let service = DefaultSourceService::with_store(store.clone());
    ensure_ok(block_on(service.put_extraction_run(ExtractionRunInput {
        id: extraction_id.to_string(),
        source_item_id: source_id.to_string(),
        source_content_hash: source_hash.clone(),
        extractor,
        extractor_version,
        profile,
        started_at: built_at.clone(),
        completed_at: Some(built_at),
        output_content_hash: Some(output_hash),
        warnings: vec![
            "OCR text is extracted evidence and is not executable diagnostic knowledge until reviewed and cited.".into(),
            format!("{blank} blank page(s) omitted from content chunks."),
            format!("{below_70} nonblank page(s) have mean OCR confidence below 70."),
            metadata
                .get("layout")
                .map(|layout| format!("OCR layout derivative retained as {layout}."))
                .unwrap_or_else(|| "OCR index contains no retained layout geometry.".into()),
        ],
        produced_item_ids: citation_ids
            .iter()
            .chain(chunk_ids.iter())
            .map(ToString::to_string)
            .collect(),
    })))?;

    for (ordinal, ((page, citation_id), chunk_id)) in nonblank
        .iter()
        .zip(citation_ids.iter())
        .zip(chunk_ids.iter())
        .enumerate()
    {
        let section_path = page
            .section_hint
            .split(" | ")
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .collect();
        let locator = SourceLocatorInput {
            page_index: Some(page.page.saturating_sub(1)),
            page_label: Some(page.page.to_string()),
            region: None,
            char_start: None,
            char_end: None,
            section_path,
            figure_label: None,
            table_label: None,
        };
        ensure_ok(block_on(service.put_citation(SourceCitationInput {
            id: citation_id.to_string(),
            source_item_id: source_id.to_string(),
            source_content_hash: source_hash.clone(),
            extraction_run_id: Some(extraction_id.to_string()),
            locator: locator.clone(),
            quote: None,
            quote_hash: None,
            title: Some(format!("{}, PDF page {}", args.title, page.page)),
        })))?;
        ensure_ok(block_on(
            service.put_content_chunk(ContentChunkInput {
                id: chunk_id.to_string(),
                source_item_id: source_id.to_string(),
                extraction_run_id: extraction_id.to_string(),
                citation_id: Some(citation_id.to_string()),
                ordinal: ordinal as u32,
                text: page.text.clone(),
                content_hash: normalized_text_hash(&page.text),
                locator,
                regions: page
                    .regions
                    .iter()
                    .filter_map(|region| {
                        normalized_region(&region.bounding_box).map(|normalized| {
                            ExtractedTextRegionInput {
                                text: region.text.clone(),
                                confidence: region.confidence,
                                region: normalized,
                            }
                        })
                    })
                    .collect(),
            }),
        ))?;
    }

    println!(
        "Imported '{}' as source {}: {} searchable pages, {} blank pages, extraction {}",
        args.title,
        source_id,
        nonblank.len(),
        blank,
        extraction_id
    );
    Ok(())
}

fn parse_args() -> Result<Args, Box<dyn std::error::Error>> {
    let mut values = std::env::args().skip(1);
    let mut map = BTreeMap::new();
    while let Some(key) = values.next() {
        if key == "--help" || key == "-h" {
            println!(concat!(
                "vw-knowledge-ingest --store-path DB --source-pdf FILE ",
                "--ocr-index INDEX.sqlite3 --title TITLE --source-class CLASS ",
                "--publisher NAME [--extractor-version VERSION] [--source-url URL]"
            ));
            std::process::exit(0);
        }
        if !key.starts_with("--") {
            return Err(format!("unexpected argument: {key}").into());
        }
        let value = values
            .next()
            .ok_or_else(|| format!("{key} requires a value"))?;
        map.insert(key, value);
    }
    let required = |map: &mut BTreeMap<String, String>, key: &str| {
        map.remove(key).ok_or_else(|| format!("missing {key}"))
    };
    let store_path = PathBuf::from(required(&mut map, "--store-path")?);
    let source_pdf = PathBuf::from(required(&mut map, "--source-pdf")?);
    let ocr_index = PathBuf::from(required(&mut map, "--ocr-index")?);
    let title = required(&mut map, "--title")?;
    let source_class = required(&mut map, "--source-class")?;
    let publisher = required(&mut map, "--publisher")?;
    let extractor_version = map.remove("--extractor-version");
    let source_url = map.remove("--source-url");
    if let Some(unknown) = map.keys().next() {
        return Err(format!("unknown argument: {unknown}").into());
    }
    Ok(Args {
        store_path,
        source_pdf,
        ocr_index,
        title,
        source_url,
        source_class,
        publisher,
        extractor_version,
    })
}

fn read_metadata(connection: &Connection) -> rusqlite::Result<BTreeMap<String, String>> {
    let mut statement = connection.prepare("SELECT key, value FROM metadata ORDER BY key")?;
    let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
    rows.collect()
}

fn read_pages(connection: &Connection) -> Result<Vec<OcrPage>, Box<dyn std::error::Error>> {
    let has_layout = {
        let mut statement = connection.prepare("PRAGMA table_info(pages)")?;
        let columns = statement.query_map([], |row| row.get::<_, String>(1))?;
        columns
            .collect::<rusqlite::Result<Vec<_>>>()?
            .iter()
            .any(|column| column == "layout_json")
    };
    let layout_expression = if has_layout { "layout_json" } else { "'[]'" };
    let mut statement = connection.prepare(&format!(
        "SELECT pdf_page, section_hint, text, mean_confidence, {layout_expression} \
         FROM pages ORDER BY pdf_page"
    ))?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, u32>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, f64>(3)?,
            row.get::<_, String>(4)?,
        ))
    })?;
    let mut pages = Vec::new();
    for row in rows {
        let (page, section_hint, text, mean_confidence, layout_json) = row?;
        pages.push(OcrPage {
            page,
            section_hint,
            text,
            mean_confidence,
            regions: serde_json::from_str(&layout_json)?,
        });
    }
    Ok(pages)
}

fn normalized_region(region: &LayoutBox) -> Option<NormalizedRectInput> {
    if region.x.is_finite()
        && region.y.is_finite()
        && region.width.is_finite()
        && region.height.is_finite()
        && region.x >= 0.0
        && region.y >= 0.0
        && region.width > 0.0
        && region.height > 0.0
        && region.x + region.width <= 1.0
        && region.y + region.height <= 1.0
    {
        return Some(NormalizedRectInput {
            x: region.x,
            y: region.y,
            width: region.width,
            height: region.height,
        });
    }
    let x = region.x.clamp(0.0, 1.0);
    let y = region.y.clamp(0.0, 1.0);
    let max_x = (region.x + region.width).clamp(0.0, 1.0);
    let max_y = (region.y + region.height).clamp(0.0, 1.0);
    let width = max_x - x;
    let height = max_y - y;
    (x.is_finite()
        && y.is_finite()
        && width.is_finite()
        && height.is_finite()
        && width > 0.0
        && height > 0.0)
        .then_some(NormalizedRectInput {
            x,
            y,
            width,
            height,
        })
}

fn put_source_asset(
    store: &SqliteItemStore,
    id: Uuid,
    args: &Args,
    source_pdf: &Path,
    source_hash: &str,
    source_size: u64,
) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(existing) = store.get(id)? {
        let existing_hash = existing
            .payload
            .get("file_hash")
            .and_then(|value| match value {
                Value::String(value) => Some(value.as_str()),
                _ => None,
            });
        if existing.schema == "impress/artifact/general" && existing_hash == Some(source_hash) {
            return Ok(());
        }
        return Err(format!("source item {id} already exists with different content").into());
    }
    let mut payload = BTreeMap::from([
        ("title".into(), Value::String(args.title.clone())),
        (
            "artifact_subtype".into(),
            Value::String(args.source_class.clone()),
        ),
        (
            "file_name".into(),
            Value::String(
                source_pdf
                    .file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or("source.pdf")
                    .into(),
            ),
        ),
        ("file_hash".into(), Value::String(source_hash.into())),
        ("file_size".into(), Value::Int(source_size as i64)),
        (
            "file_mime_type".into(),
            Value::String("application/pdf".into()),
        ),
        (
            "capture_context".into(),
            Value::String("vw-knowledge-ingest".into()),
        ),
        (
            "original_author".into(),
            Value::String(args.publisher.clone()),
        ),
        (
            "notes".into(),
            Value::String(format!(
                "Local source path: {}. Admission state: extracted/unreviewed.",
                source_pdf.display()
            )),
        ),
    ]);
    if let Some(url) = &args.source_url {
        payload.insert("source_url".into(), Value::String(url.clone()));
    }
    let now = chrono::Utc::now();
    store.insert(Item {
        id,
        schema: "impress/artifact/general".into(),
        payload,
        created: now,
        modified: now,
        author: "vw-knowledge-ingest".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![
            "vw/knowledge-source".into(),
            format!("vw/source-class/{}", args.source_class),
        ],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: Some("1.0.0".into()),
        batch_id: None,
        references: vec![],
        parent: None,
    })?;
    Ok(())
}

fn chunk_id(source_id: Uuid, extraction_id: Uuid, page: &OcrPage) -> Uuid {
    Uuid::new_v5(
        &INGEST_NAMESPACE,
        format!(
            "chunk:{source_id}:{extraction_id}:{}:{}",
            page.page,
            normalized_text_hash(&page.text)
        )
        .as_bytes(),
    )
}

fn citation_id(source_id: Uuid, extraction_id: Uuid, page: u32) -> Uuid {
    Uuid::new_v5(
        &INGEST_NAMESPACE,
        format!("citation:{source_id}:{extraction_id}:{page}").as_bytes(),
    )
}

fn extraction_output_hash(pages: &[&OcrPage]) -> String {
    let mut hasher = Sha256::new();
    for page in pages {
        hasher.update(page.page.to_be_bytes());
        hasher.update(normalized_text_hash(&page.text).as_bytes());
    }
    format!("{:x}", hasher.finalize())
}

fn sha256_file(path: &Path) -> Result<String, std::io::Error> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 1024 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn ensure_ok(
    result: impress_store_service::SourceRecordResult,
) -> Result<(), Box<dyn std::error::Error>> {
    if result.ok {
        Ok(())
    } else {
        Err(result.message.into())
    }
}
