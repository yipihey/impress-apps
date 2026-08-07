//! Semantic writes and reads for immutable source provenance records.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;

use base64::Engine;
use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
use impress_core::query::{ItemQuery, Predicate};
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::schemas::{
    CONTENT_CHUNK_SCHEMA, EXTRACTION_RUN_SCHEMA, FIGURE_REGION_SCHEMA, SOURCE_CITATION_SCHEMA,
};
use impress_core::source::{
    ContentChunk, ExtractedTextRegion, ExtractionRun, FigureRegionEvidence, FigureRegionProvenance,
    FigureRegionStatus, NormalizedRect, SourceCitation, SourceLocator,
};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_service_core::async_trait;
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::source_assets::{
    crop_page, render_page, source_asset_root, source_cache_root, source_pdf_path,
    verify_source_pdf, FigureCropSpec, DEFAULT_FIGURE_DPI, DEFAULT_PAGE_DPI,
};
use crate::store::store_instance;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct NormalizedRectInput {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl DefaultSourceService {
    fn render_page_result(
        &self,
        source_item_id: &str,
        page_index: Option<u32>,
        page_label: Option<&str>,
        dpi: u32,
        format: &str,
    ) -> PageImageResult {
        if page_index.is_some() == page_label.is_some() {
            return page_failure(
                "invalid_request",
                "provide exactly one of page_index or page_label",
            );
        }
        let source_id = match Uuid::parse_str(source_item_id) {
            Ok(id) => id,
            Err(error) => return page_failure("invalid_source", &error.to_string()),
        };
        let store = self.store();
        let asset = match source_asset(&store, &self.asset_root(), source_id) {
            Ok(value) => value,
            Err(error) => return page_failure("source_unavailable", &error),
        };
        let (index, label) = match resolve_page(&store, source_id, page_index, page_label) {
            Ok(value) => value,
            Err(error) => return page_failure("page_not_found", &error),
        };
        let rendered = match render_page(
            &self.asset_root(),
            &self.cache_root(),
            &asset.hash,
            index,
            dpi,
            format,
        ) {
            Ok(value) => value,
            Err(error) => return page_failure("render_failed", &error),
        };
        let (run_id, extraction_version) = page_extraction_metadata(&store, source_id, index);
        PageImageResult {
            ok: true,
            status: "resolved".into(),
            message: format!("Rendered {}, PDF page {}.", asset.title, label),
            metadata: Some(PageImageMetadata {
                source_item_id: source_id.to_string(),
                source_title: asset.title,
                page_index: index,
                page_label: label,
                source_content_hash: asset.hash,
                extraction_run_id: run_id.map(|id| id.to_string()),
                extraction_version,
                mime_type: "image/png".into(),
                pixel_width: rendered.width,
                pixel_height: rendered.height,
                resolution_dpi: dpi,
                cache_hit: rendered.cache_hit,
            }),
            mcp_content: vec![image_block(rendered.png)],
        }
    }

    fn figure_page_fallback(
        &self,
        source_id: Uuid,
        page_index: Option<u32>,
        figure_label: &str,
        status: &str,
        dpi: u32,
        format: &str,
    ) -> FigureImageResult {
        let fallback_arguments = page_index.map(|page| {
            serde_json::json!({
                "source_item_id": source_id.to_string(), "page_index": page,
                "page_label": null, "resolution_dpi": dpi, "format": format,
            })
        });
        let Some(page_index) = page_index else {
            return FigureImageResult {
                ok: false,
                status: status.into(),
                message: format!("{figure_label} has no unique stored region or page."),
                metadata: None,
                fallback_tool: Some("source-service_get-page-image".into()),
                fallback_arguments,
                mcp_content: vec![],
            };
        };
        let page =
            self.render_page_result(&source_id.to_string(), Some(page_index), None, dpi, format);
        let Some(page_metadata) = page.metadata else {
            return FigureImageResult {
                ok: false,
                status: status.into(),
                message: format!(
                    "{figure_label} is {status}; complete-page fallback also failed: {}",
                    page.message
                ),
                metadata: None,
                fallback_tool: Some("source-service_get-page-image".into()),
                fallback_arguments,
                mcp_content: vec![],
            };
        };
        FigureImageResult {
            ok: true,
            status: status.into(),
            message: format!("No trustworthy crop was selected for {figure_label}; returned the complete cited page instead."),
            metadata: Some(FigureImageMetadata {
                figure_label: figure_label.into(), caption_text: None,
                source_item_id: page_metadata.source_item_id,
                source_title: page_metadata.source_title,
                page_index: page_metadata.page_index,
                page_label: page_metadata.page_label,
                image_region: None, caption_region: None, normalized_crop: None, pixel_crop: None,
                source_content_hash: page_metadata.source_content_hash,
                extraction_run_id: page_metadata.extraction_run_id,
                extraction_version: page_metadata.extraction_version,
                crop_status: status.into(), returned_image_kind: "page_fallback".into(),
                mime_type: page_metadata.mime_type,
                pixel_width: page_metadata.pixel_width, pixel_height: page_metadata.pixel_height,
                resolution_dpi: page_metadata.resolution_dpi, cache_hit: page_metadata.cache_hit,
            }),
            fallback_tool: Some("source-service_get-page-image".into()),
            fallback_arguments,
            mcp_content: page.mcp_content,
        }
    }
}

#[derive(Debug)]
struct SourceAssetInfo {
    title: String,
    hash: String,
}

fn source_asset(
    store: &SqliteItemStore,
    root: &std::path::Path,
    id: Uuid,
) -> Result<SourceAssetInfo, String> {
    let item = store
        .get(id)
        .map_err(|error| error.to_string())?
        .ok_or("source item not found")?;
    if item.visibility != Visibility::Private {
        return Err("source is outside the private knowledge boundary".into());
    }
    let string = |name: &str| match item.payload.get(name) {
        Some(Value::String(value)) => Some(value.clone()),
        _ => None,
    };
    if string("file_mime_type").as_deref() != Some("application/pdf") {
        return Err("source item is not an immutable PDF asset".into());
    }
    let hash = string("file_hash").ok_or("source item has no file_hash")?;
    crate::source_assets::validate_sha256(&hash)?;
    let path = source_pdf_path(root, &hash)?;
    verify_source_pdf(&path, &hash)?;
    Ok(SourceAssetInfo {
        title: string("title").unwrap_or_else(|| "Untitled source".into()),
        hash,
    })
}

fn resolve_page(
    store: &SqliteItemStore,
    source_id: Uuid,
    page_index: Option<u32>,
    page_label: Option<&str>,
) -> Result<(u32, String), String> {
    let mappings = page_mappings(store, source_id)?;
    if let Some(index) = page_index {
        let label = mappings
            .iter()
            .find(|(mapped, _)| *mapped == index)
            .map(|(_, label)| label.clone())
            .unwrap_or_else(|| (index + 1).to_string());
        return Ok((index, label));
    }
    let label = page_label.ok_or("page selector is missing")?;
    let indexes = mappings
        .iter()
        .filter(|(_, candidate)| candidate == label)
        .map(|(index, _)| *index)
        .collect::<BTreeSet<_>>();
    match indexes.len() {
        0 => Err(format!(
            "displayed page label {label:?} is not present in source evidence"
        )),
        1 => Ok((*indexes.iter().next().expect("one index"), label.into())),
        _ => Err(format!("displayed page label {label:?} is ambiguous")),
    }
}

fn page_mappings(store: &SqliteItemStore, source_id: Uuid) -> Result<Vec<(u32, String)>, String> {
    let mut mappings = Vec::new();
    for schema in [
        CONTENT_CHUNK_SCHEMA,
        SOURCE_CITATION_SCHEMA,
        FIGURE_REGION_SCHEMA,
    ] {
        let items = store
            .query(&ItemQuery {
                schema: Some(schema.into()),
                predicates: vec![Predicate::HasParent(source_id)],
                include_tags: false,
                include_references: false,
                ..Default::default()
            })
            .map_err(|error| error.to_string())?;
        for item in items {
            let Some(data) = item
                .payload
                .get("data")
                .and_then(|value| serde_json::to_value(value).ok())
            else {
                continue;
            };
            let pair = if schema == CONTENT_CHUNK_SCHEMA {
                serde_json::from_value::<ContentChunk>(data)
                    .ok()
                    .and_then(|value| value.locator.page_index.zip(value.locator.page_label))
            } else if schema == SOURCE_CITATION_SCHEMA {
                serde_json::from_value::<SourceCitation>(data)
                    .ok()
                    .and_then(|value| value.locator.page_index.zip(value.locator.page_label))
            } else {
                serde_json::from_value::<FigureRegionEvidence>(data)
                    .ok()
                    .map(|value| (value.page_index, value.page_label))
            };
            if let Some(pair) = pair {
                mappings.push(pair);
            }
        }
    }
    Ok(mappings)
}

fn figure_regions(
    store: &SqliteItemStore,
    source_id: Uuid,
) -> Result<Vec<FigureRegionEvidence>, String> {
    store
        .query(&ItemQuery {
            schema: Some(FIGURE_REGION_SCHEMA.into()),
            predicates: vec![Predicate::HasParent(source_id)],
            include_tags: false,
            include_references: false,
            ..Default::default()
        })
        .map_err(|error| error.to_string())
        .map(|items| {
            items
                .into_iter()
                .filter_map(|item| {
                    item.payload
                        .get("data")
                        .and_then(|value| serde_json::to_value(value).ok())
                        .and_then(|value| serde_json::from_value(value).ok())
                })
                .collect()
        })
}

fn evidence_availability(
    service: &DefaultSourceService,
    source_id: Uuid,
    page: Option<u32>,
) -> EvidenceAvailability {
    let store = service.store();
    let figures = figure_regions(&store, source_id)
        .unwrap_or_default()
        .into_iter()
        .filter(|figure| page.is_none_or(|page| page == figure.page_index))
        .map(|figure| FigureEvidenceSummary {
            label: figure.figure_label,
            page_label: figure.page_label,
            caption: figure.caption_text,
            image_available: figure.image_region.is_some()
                && figure.status != FigureRegionStatus::Ambiguous,
            crop_status: match figure.status {
                FigureRegionStatus::Extracted => "extracted",
                FigureRegionStatus::Curated => "curated",
                FigureRegionStatus::Ambiguous => "ambiguous",
            }
            .into(),
        })
        .collect();
    let page_image_available = source_asset_available(&store, &service.asset_root(), source_id);
    EvidenceAvailability {
        figures,
        page_image_available,
    }
}

fn source_asset_available(store: &SqliteItemStore, root: &std::path::Path, id: Uuid) -> bool {
    store
        .get(id)
        .ok()
        .flatten()
        .filter(|item| item.visibility == Visibility::Private)
        .and_then(|item| {
            let is_pdf = item
                .payload
                .get("file_mime_type")
                .is_some_and(|value| match value {
                    Value::String(value) => value == "application/pdf",
                    _ => false,
                });
            let hash = item.payload.get("file_hash").and_then(|value| match value {
                Value::String(value) => Some(value.clone()),
                _ => None,
            });
            is_pdf.then_some(hash).flatten()
        })
        .and_then(|hash| source_pdf_path(root, &hash).ok())
        .is_some_and(|path| path.is_file())
}

fn attach_evidence(
    service: &DefaultSourceService,
    record: &mut serde_json::Value,
    source_id: Uuid,
    page: Option<u32>,
) {
    if let Some(object) = record.as_object_mut() {
        if let Ok(evidence) = serde_json::to_value(evidence_availability(service, source_id, page))
        {
            object.insert("evidence".into(), evidence);
        }
    }
}

fn normalized_to_pixel(rect: NormalizedRect, width: u32, height: u32) -> PixelRect {
    let x = (rect.x * f64::from(width)).floor() as u32;
    let y = ((1.0 - rect.y - rect.height) * f64::from(height)).floor() as u32;
    let right = ((rect.x + rect.width) * f64::from(width)).ceil() as u32;
    let bottom = ((1.0 - rect.y) * f64::from(height)).ceil() as u32;
    PixelRect {
        x,
        y,
        width: right.saturating_sub(x).min(width.saturating_sub(x)),
        height: bottom.saturating_sub(y).min(height.saturating_sub(y)),
    }
}

fn union_optional(a: Option<NormalizedRect>, b: Option<NormalizedRect>) -> Option<NormalizedRect> {
    match (a, b) {
        (Some(a), Some(b)) => {
            let x = a.x.min(b.x);
            let y = a.y.min(b.y);
            Some(NormalizedRect {
                x,
                y,
                width: (a.x + a.width).max(b.x + b.width) - x,
                height: (a.y + a.height).max(b.y + b.height) - y,
            })
        }
        (Some(value), None) | (None, Some(value)) => Some(value),
        (None, None) => None,
    }
}

fn rect_input(rect: NormalizedRect) -> NormalizedRectInput {
    NormalizedRectInput {
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height,
    }
}

fn image_block(bytes: Vec<u8>) -> McpImageBlock {
    McpImageBlock {
        kind: "image".into(),
        data: base64::engine::general_purpose::STANDARD.encode(bytes),
        mime_type: "image/png".into(),
    }
}

fn load_record<T: serde::de::DeserializeOwned>(
    store: &SqliteItemStore,
    id: Uuid,
    schema: &str,
) -> Result<T, String> {
    let item = store
        .get(id)
        .map_err(|error| error.to_string())?
        .ok_or("record not found")?;
    if item.schema != schema {
        return Err(format!("record is not {schema}"));
    }
    item.payload
        .get("data")
        .and_then(|value| serde_json::to_value(value).ok())
        .and_then(|value| serde_json::from_value(value).ok())
        .ok_or("record data is malformed".into())
}

fn extraction_metadata(store: &SqliteItemStore, id: Option<Uuid>) -> Option<String> {
    id.and_then(|id| load_record::<ExtractionRun>(store, id, EXTRACTION_RUN_SCHEMA).ok())
        .map(|run| {
            format!(
                "{}:{}:{}",
                run.extractor, run.extractor_version, run.profile
            )
        })
}

fn page_extraction_metadata(
    store: &SqliteItemStore,
    source: Uuid,
    page: u32,
) -> (Option<Uuid>, Option<String>) {
    let mut run = store
        .query(&ItemQuery {
            schema: Some(CONTENT_CHUNK_SCHEMA.into()),
            predicates: vec![Predicate::HasParent(source)],
            include_tags: false,
            include_references: false,
            ..Default::default()
        })
        .ok()
        .and_then(|items| {
            items
                .into_iter()
                .filter_map(|item| {
                    item.payload
                        .get("data")
                        .and_then(|value| serde_json::to_value(value).ok())
                        .and_then(|value| serde_json::from_value::<ContentChunk>(value).ok())
                })
                .find(|chunk| chunk.locator.page_index == Some(page))
        })
        .map(|chunk| chunk.extraction_run_id);
    if run.is_none() {
        run = store
            .query(&ItemQuery {
                schema: Some(SOURCE_CITATION_SCHEMA.into()),
                predicates: vec![Predicate::HasParent(source)],
                include_tags: false,
                include_references: false,
                ..Default::default()
            })
            .ok()
            .and_then(|items| {
                items
                    .into_iter()
                    .filter_map(|item| {
                        item.payload
                            .get("data")
                            .and_then(|value| serde_json::to_value(value).ok())
                            .and_then(|value| serde_json::from_value::<SourceCitation>(value).ok())
                    })
                    .find(|citation| citation.locator.page_index == Some(page))
            })
            .and_then(|citation| citation.extraction_run_id);
    }
    (run, extraction_metadata(store, run))
}

fn labels_equal(a: &str, b: &str) -> bool {
    a.split_whitespace()
        .collect::<String>()
        .eq_ignore_ascii_case(&b.split_whitespace().collect::<String>())
}

fn page_failure(status: &str, message: &str) -> PageImageResult {
    PageImageResult {
        ok: false,
        status: status.into(),
        message: message.into(),
        metadata: None,
        mcp_content: vec![],
    }
}

fn figure_failure(status: &str, message: &str) -> FigureImageResult {
    FigureImageResult {
        ok: false,
        status: status.into(),
        message: message.into(),
        metadata: None,
        fallback_tool: None,
        fallback_arguments: None,
        mcp_content: vec![],
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct SourceLocatorInput {
    pub page_index: Option<u32>,
    pub page_label: Option<String>,
    pub region: Option<NormalizedRectInput>,
    pub char_start: Option<u64>,
    pub char_end: Option<u64>,
    #[serde(default)]
    pub section_path: Vec<String>,
    pub figure_label: Option<String>,
    pub table_label: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct SourceCitationInput {
    pub id: String,
    pub source_item_id: String,
    pub source_content_hash: String,
    pub extraction_run_id: Option<String>,
    pub locator: SourceLocatorInput,
    pub quote: Option<String>,
    pub quote_hash: Option<String>,
    pub title: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ExtractionRunInput {
    pub id: String,
    pub source_item_id: String,
    pub source_content_hash: String,
    pub extractor: String,
    pub extractor_version: String,
    pub profile: String,
    pub started_at: String,
    pub completed_at: Option<String>,
    pub output_content_hash: Option<String>,
    #[serde(default)]
    pub warnings: Vec<String>,
    #[serde(default)]
    pub produced_item_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ContentChunkInput {
    pub id: String,
    pub source_item_id: String,
    pub extraction_run_id: String,
    pub citation_id: Option<String>,
    pub ordinal: u32,
    pub text: String,
    pub content_hash: String,
    pub locator: SourceLocatorInput,
    #[serde(default)]
    pub regions: Vec<ExtractedTextRegionInput>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ExtractedTextRegionInput {
    pub text: String,
    pub confidence: Option<f64>,
    pub region: NormalizedRectInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum FigureRegionStatusInput {
    Extracted,
    Curated,
    Ambiguous,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FigureRegionProvenanceInput {
    Automatic {
        extractor: String,
        extractor_version: String,
    },
    ManualCorrection {
        curator: String,
        corrected_at: String,
        supersedes: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct FigureRegionInput {
    pub id: String,
    pub source_item_id: String,
    pub source_content_hash: String,
    pub extraction_run_id: Option<String>,
    pub page_index: u32,
    pub page_label: String,
    pub figure_label: String,
    pub caption_text: Option<String>,
    pub image_region: Option<NormalizedRectInput>,
    pub caption_region: Option<NormalizedRectInput>,
    pub status: FigureRegionStatusInput,
    pub provenance: FigureRegionProvenanceInput,
    #[serde(default)]
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct FigureEvidenceSummary {
    pub label: String,
    pub page_label: String,
    pub caption: Option<String>,
    pub image_available: bool,
    pub crop_status: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct EvidenceAvailability {
    pub figures: Vec<FigureEvidenceSummary>,
    pub page_image_available: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct PixelRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct PageImageMetadata {
    pub source_item_id: String,
    pub source_title: String,
    pub page_index: u32,
    pub page_label: String,
    pub source_content_hash: String,
    pub extraction_run_id: Option<String>,
    pub extraction_version: Option<String>,
    pub mime_type: String,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub resolution_dpi: u32,
    pub cache_hit: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct McpImageBlock {
    #[serde(rename = "type")]
    pub kind: String,
    pub data: String,
    #[serde(rename = "mimeType")]
    pub mime_type: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct PageImageResult {
    pub ok: bool,
    pub status: String,
    pub message: String,
    pub metadata: Option<PageImageMetadata>,
    #[serde(
        rename = "_mcp_content",
        default,
        skip_serializing_if = "Vec::is_empty"
    )]
    pub mcp_content: Vec<McpImageBlock>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct FigureImageMetadata {
    pub figure_label: String,
    pub caption_text: Option<String>,
    pub source_item_id: String,
    pub source_title: String,
    pub page_index: u32,
    pub page_label: String,
    pub image_region: Option<NormalizedRectInput>,
    pub caption_region: Option<NormalizedRectInput>,
    pub normalized_crop: Option<NormalizedRectInput>,
    pub pixel_crop: Option<PixelRect>,
    pub source_content_hash: String,
    pub extraction_run_id: Option<String>,
    pub extraction_version: Option<String>,
    pub crop_status: String,
    pub returned_image_kind: String,
    pub mime_type: String,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub resolution_dpi: u32,
    pub cache_hit: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct FigureImageResult {
    pub ok: bool,
    pub status: String,
    pub message: String,
    pub metadata: Option<FigureImageMetadata>,
    pub fallback_tool: Option<String>,
    pub fallback_arguments: Option<serde_json::Value>,
    #[serde(
        rename = "_mcp_content",
        default,
        skip_serializing_if = "Vec::is_empty"
    )]
    pub mcp_content: Vec<McpImageBlock>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct SourceRecordResult {
    pub ok: bool,
    pub id: String,
    pub record: Option<serde_json::Value>,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ContentChunkSearchHit {
    pub chunk_id: String,
    pub citation_id: Option<String>,
    pub source_item_id: String,
    /// Display title resolved from the source asset when available.
    pub source_title: Option<String>,
    pub extraction_run_id: String,
    pub page_index: Option<u32>,
    pub page_label: Option<String>,
    pub section_path: Vec<String>,
    pub figure_label: Option<String>,
    pub table_label: Option<String>,
    /// A bounded FTS excerpt. Resolve `citation_id` for the exact source
    /// locator; extracted page text is intentionally not returned wholesale.
    pub excerpt: String,
    /// BM25 rank; lower values are more relevant.
    pub rank: f64,
    pub figures: Vec<FigureEvidenceSummary>,
    pub page_image_available: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ContentChunkSearchResult {
    pub ok: bool,
    pub hits: Vec<ContentChunkSearchHit>,
    pub message: String,
}

struct PutOptions<'a> {
    source_item_id: Uuid,
    extraction_run_id: Option<Uuid>,
    expected_source_hash: Option<&'a str>,
    indexed_text: Option<&'a str>,
    extra_reference: Option<TypedReference>,
}

#[impress_service]
pub trait SourceService: Send + Sync + 'static {
    /// Store an immutable structured citation after validating source hashes,
    /// page/range/region coordinates, and referenced source/extraction items.
    /// Repeating identical content is a no-op; conflicting content is refused.
    #[impress_method]
    async fn put_citation(&self, citation: SourceCitationInput) -> SourceRecordResult;

    /// Resolve one structured citation by UUID, including exact locator and
    /// immutable source hash.
    #[impress_method]
    async fn get_citation(&self, citation_id: String) -> SourceRecordResult;

    /// Store immutable extractor/OCR identity, input hash, output hash,
    /// warnings, and products for one derivation.
    #[impress_method]
    async fn put_extraction_run(&self, run: ExtractionRunInput) -> SourceRecordResult;

    /// Store one immutable domain-neutral text chunk with source locator and
    /// extraction lineage.
    #[impress_method]
    async fn put_content_chunk(&self, chunk: ContentChunkInput) -> SourceRecordResult;

    /// Store immutable automatic layout evidence or a provenance-preserving
    /// manual figure-boundary correction. Available only in curation profiles.
    #[impress_method]
    async fn put_figure_region(&self, figure: FigureRegionInput) -> SourceRecordResult;

    /// Resolve one selected search hit. Search stays compact; this operation
    /// returns the complete extracted chunk and its citation link on demand.
    #[impress_method]
    async fn get_content_chunk(&self, chunk_id: String) -> SourceRecordResult;

    /// Search extracted source text while preserving page/figure/table
    /// locators and extraction lineage. An optional source UUID confines the
    /// results to one asset; pass null to search all ingested sources.
    #[impress_method]
    async fn search_content_chunks(
        &self,
        query: String,
        source_item_id: Option<String>,
        limit: u32,
    ) -> ContentChunkSearchResult;

    /// Render one complete cited PDF page as MCP image content. Identify the
    /// page by zero-based physical index or displayed label, never by a path.
    #[impress_method]
    async fn get_page_image(
        &self,
        source_item_id: String,
        page_index: Option<u32>,
        page_label: Option<String>,
        resolution_dpi: Option<u32>,
        format: Option<String>,
    ) -> PageImageResult;

    /// Resolve a stored figure boundary and return its crop as MCP image
    /// content. Use this for a cited figure; use get-page-image for context.
    /// Uncertain boundaries return the complete page as an explicit fallback.
    #[impress_method]
    async fn get_figure_image(
        &self,
        citation_id: Option<String>,
        source_item_id: Option<String>,
        figure_label: String,
        padding: Option<u32>,
        resolution_dpi: Option<u32>,
        include_caption: Option<bool>,
        format: Option<String>,
    ) -> FigureImageResult;
}

#[derive(Clone, Default)]
pub struct DefaultSourceService {
    store: Option<Arc<SqliteItemStore>>,
    asset_root: Option<PathBuf>,
    cache_root: Option<PathBuf>,
}

impl DefaultSourceService {
    pub fn new() -> Self {
        Self {
            store: None,
            asset_root: None,
            cache_root: None,
        }
    }

    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self {
            store: Some(store),
            asset_root: None,
            cache_root: None,
        }
    }

    pub fn with_store_and_roots(
        store: Arc<SqliteItemStore>,
        asset_root: PathBuf,
        cache_root: PathBuf,
    ) -> Self {
        Self {
            store: Some(store),
            asset_root: Some(asset_root),
            cache_root: Some(cache_root),
        }
    }

    fn store(&self) -> Arc<SqliteItemStore> {
        self.store.clone().unwrap_or_else(store_instance)
    }

    fn asset_root(&self) -> PathBuf {
        self.asset_root.clone().unwrap_or_else(source_asset_root)
    }

    fn cache_root(&self) -> PathBuf {
        self.cache_root.clone().unwrap_or_else(source_cache_root)
    }

    fn put<T: Serialize>(
        &self,
        id: Uuid,
        schema: &str,
        value: &T,
        options: PutOptions<'_>,
    ) -> SourceRecordResult {
        let json = match serde_json::to_value(value) {
            Ok(json) => json,
            Err(error) => return failed(id, error.to_string()),
        };
        let data: Value = match serde_json::from_value(json.clone()) {
            Ok(data) => data,
            Err(error) => return failed(id, error.to_string()),
        };
        let store = self.store();
        match store.get(id) {
            Ok(Some(existing)) => {
                let existing_json = existing
                    .payload
                    .get("data")
                    .and_then(|data| serde_json::to_value(data).ok());
                if existing.schema == schema && existing_json.as_ref() == Some(&json) {
                    return SourceRecordResult {
                        ok: true,
                        id: id.to_string(),
                        record: Some(json),
                        message: "Identical immutable record already exists.".into(),
                    };
                }
                return failed(
                    id,
                    "immutable record id already exists with different content",
                );
            }
            Ok(None) => {}
            Err(error) => return failed(id, error.to_string()),
        }
        if !matches!(store.get(options.source_item_id), Ok(Some(_))) {
            return failed(id, "source_item_id does not resolve");
        }
        if let Some(extraction_id) = options.extraction_run_id {
            match store.get(extraction_id) {
                Ok(Some(item)) if item.schema == EXTRACTION_RUN_SCHEMA => {
                    let Some(data) = item.payload.get("data") else {
                        return failed(id, "extraction run has no data payload");
                    };
                    let run: ExtractionRun = match serde_json::to_value(data)
                        .ok()
                        .and_then(|value| serde_json::from_value(value).ok())
                    {
                        Some(run) => run,
                        None => return failed(id, "extraction run data is malformed"),
                    };
                    if run.source_item_id != options.source_item_id {
                        return failed(id, "extraction run belongs to a different source");
                    }
                    if options
                        .expected_source_hash
                        .is_some_and(|expected| expected != run.source_content_hash)
                    {
                        return failed(id, "source_content_hash does not match the extraction run");
                    }
                }
                _ => {
                    return failed(
                        id,
                        "extraction_run_id does not resolve to an extraction run",
                    )
                }
            }
        }
        let mut references = vec![TypedReference {
            target: options.source_item_id,
            edge_type: EdgeType::References,
            metadata: None,
        }];
        if let Some(extraction_id) = options.extraction_run_id {
            references.push(TypedReference {
                target: extraction_id,
                edge_type: EdgeType::DerivedFrom,
                metadata: None,
            });
        }
        if let Some(reference) = options.extra_reference {
            references.push(reference);
        }
        let mut payload = BTreeMap::from([
            ("title".into(), Value::String(schema.into())),
            ("data".into(), data),
        ]);
        if let Some(text) = options.indexed_text {
            payload.insert("body".into(), Value::String(text.into()));
        }
        let now = chrono::Utc::now();
        let item = Item {
            id,
            schema: schema.into(),
            payload,
            created: now,
            modified: now,
            author: "impress-source-service".into(),
            author_kind: ActorKind::System,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::Normal,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: options.extraction_run_id,
            version: Some("1.0.0".into()),
            batch_id: None,
            references,
            parent: Some(options.source_item_id),
        };
        match store.insert(item) {
            Ok(_) => SourceRecordResult {
                ok: true,
                id: id.to_string(),
                record: Some(json),
                message: "Stored immutable source record.".into(),
            },
            Err(error) => failed(id, error.to_string()),
        }
    }
}

#[async_trait::async_trait]
impl SourceService for DefaultSourceService {
    async fn put_citation(&self, input: SourceCitationInput) -> SourceRecordResult {
        let citation = match citation_from_input(input) {
            Ok(citation) => citation,
            Err((id, error)) => return failed_string(id, error),
        };
        if let Err(error) = citation.validate() {
            return failed(citation.id, error.to_string());
        }
        self.put(
            citation.id,
            SOURCE_CITATION_SCHEMA,
            &citation,
            PutOptions {
                source_item_id: citation.source_item_id,
                extraction_run_id: citation.extraction_run_id,
                expected_source_hash: Some(&citation.source_content_hash),
                indexed_text: None,
                extra_reference: None,
            },
        )
    }

    async fn get_citation(&self, citation_id: String) -> SourceRecordResult {
        let id = match Uuid::parse_str(&citation_id) {
            Ok(id) => id,
            Err(error) => return failed_string(citation_id, error.to_string()),
        };
        match self.store().get(id) {
            Ok(Some(item)) if item.schema == SOURCE_CITATION_SCHEMA => {
                match item
                    .payload
                    .get("data")
                    .and_then(|data| serde_json::to_value(data).ok())
                {
                    Some(mut record) => {
                        if let Ok(citation) =
                            serde_json::from_value::<SourceCitation>(record.clone())
                        {
                            attach_evidence(
                                self,
                                &mut record,
                                citation.source_item_id,
                                citation.locator.page_index,
                            );
                        }
                        SourceRecordResult {
                            ok: true,
                            id: id.to_string(),
                            record: Some(record),
                            message: "Resolved citation.".into(),
                        }
                    }
                    None => failed(id, "citation has no data payload"),
                }
            }
            Ok(Some(_)) => failed(id, "item is not a source citation"),
            Ok(None) => failed(id, "citation not found"),
            Err(error) => failed(id, error.to_string()),
        }
    }

    async fn put_extraction_run(&self, input: ExtractionRunInput) -> SourceRecordResult {
        let run = match extraction_from_input(input) {
            Ok(run) => run,
            Err((id, error)) => return failed_string(id, error),
        };
        if let Err(error) = run.validate() {
            return failed(run.id, error.to_string());
        }
        self.put(
            run.id,
            EXTRACTION_RUN_SCHEMA,
            &run,
            PutOptions {
                source_item_id: run.source_item_id,
                extraction_run_id: None,
                expected_source_hash: None,
                indexed_text: None,
                extra_reference: None,
            },
        )
    }

    async fn put_content_chunk(&self, input: ContentChunkInput) -> SourceRecordResult {
        let chunk = match chunk_from_input(input) {
            Ok(chunk) => chunk,
            Err((id, error)) => return failed_string(id, error),
        };
        if let Err(error) = chunk.validate() {
            return failed(chunk.id, error.to_string());
        }
        if let Some(citation_id) = chunk.citation_id {
            let citation = match self.store().get(citation_id) {
                Ok(Some(item)) if item.schema == SOURCE_CITATION_SCHEMA => item
                    .payload
                    .get("data")
                    .and_then(|data| serde_json::to_value(data).ok())
                    .and_then(|value| serde_json::from_value::<SourceCitation>(value).ok()),
                _ => None,
            };
            let Some(citation) = citation else {
                return failed(
                    chunk.id,
                    "citation_id does not resolve to a source citation",
                );
            };
            if citation.source_item_id != chunk.source_item_id
                || citation.extraction_run_id != Some(chunk.extraction_run_id)
                || citation.locator != chunk.locator
            {
                return failed(
                    chunk.id,
                    "chunk citation must identify the same source, extraction, and locator",
                );
            }
        }
        self.put(
            chunk.id,
            CONTENT_CHUNK_SCHEMA,
            &chunk,
            PutOptions {
                source_item_id: chunk.source_item_id,
                extraction_run_id: Some(chunk.extraction_run_id),
                expected_source_hash: None,
                indexed_text: Some(&chunk.text),
                extra_reference: chunk.citation_id.map(|target| TypedReference {
                    target,
                    edge_type: EdgeType::Cites,
                    metadata: None,
                }),
            },
        )
    }

    async fn put_figure_region(&self, input: FigureRegionInput) -> SourceRecordResult {
        let figure = match figure_from_input(input) {
            Ok(figure) => figure,
            Err((id, error)) => return failed_string(id, error),
        };
        if let Err(error) = figure.validate() {
            return failed(figure.id, error.to_string());
        }
        self.put(
            figure.id,
            FIGURE_REGION_SCHEMA,
            &figure,
            PutOptions {
                source_item_id: figure.source_item_id,
                extraction_run_id: figure.extraction_run_id,
                expected_source_hash: Some(&figure.source_content_hash),
                indexed_text: figure.caption_text.as_deref(),
                extra_reference: None,
            },
        )
    }

    async fn get_content_chunk(&self, chunk_id: String) -> SourceRecordResult {
        let id = match Uuid::parse_str(&chunk_id) {
            Ok(id) => id,
            Err(error) => return failed_string(chunk_id, error.to_string()),
        };
        match self.store().get(id) {
            Ok(Some(item)) if item.schema == CONTENT_CHUNK_SCHEMA => match item
                .payload
                .get("data")
                .and_then(|data| serde_json::to_value(data).ok())
            {
                Some(mut record) => {
                    if let Ok(chunk) = serde_json::from_value::<ContentChunk>(record.clone()) {
                        attach_evidence(
                            self,
                            &mut record,
                            chunk.source_item_id,
                            chunk.locator.page_index,
                        );
                    }
                    SourceRecordResult {
                        ok: true,
                        id: id.to_string(),
                        record: Some(record),
                        message: "Resolved content chunk.".into(),
                    }
                }
                None => failed(id, "content chunk has no data payload"),
            },
            Ok(Some(_)) => failed(id, "item is not a content chunk"),
            Ok(None) => failed(id, "content chunk not found"),
            Err(error) => failed(id, error.to_string()),
        }
    }

    async fn search_content_chunks(
        &self,
        query: String,
        source_item_id: Option<String>,
        limit: u32,
    ) -> ContentChunkSearchResult {
        let source_filter = match source_item_id {
            Some(value) => match Uuid::parse_str(&value) {
                Ok(id) => Some(id),
                Err(error) => {
                    return ContentChunkSearchResult {
                        ok: false,
                        hits: vec![],
                        message: format!("invalid source_item_id: {error}"),
                    }
                }
            },
            None => None,
        };
        let requested = if limit == 0 { 10 } else { limit.min(50) } as usize;
        let store = self.store();
        let candidates = match source_search_candidates(&store, &query, requested) {
            Ok(hits) => hits,
            Err(error) => {
                return ContentChunkSearchResult {
                    ok: false,
                    hits: vec![],
                    message: error.to_string(),
                }
            }
        };
        let mut hits = Vec::with_capacity(requested);
        for candidate in candidates
            .into_iter()
            .filter(|candidate| candidate.schema_ref == CONTENT_CHUNK_SCHEMA)
        {
            let id = match Uuid::parse_str(&candidate.id) {
                Ok(id) => id,
                Err(_) => continue,
            };
            let chunk = match store.get(id) {
                Ok(Some(item)) => item
                    .payload
                    .get("data")
                    .and_then(|data| serde_json::to_value(data).ok())
                    .and_then(|value| serde_json::from_value::<ContentChunk>(value).ok()),
                _ => None,
            };
            let Some(chunk) = chunk else { continue };
            if source_filter.is_some_and(|source| source != chunk.source_item_id) {
                continue;
            }
            let source_title = store
                .get(chunk.source_item_id)
                .ok()
                .flatten()
                .and_then(|source| match source.payload.get("title") {
                    Some(Value::String(title)) if !title.trim().is_empty() => Some(title.clone()),
                    _ => None,
                });
            let availability =
                evidence_availability(self, chunk.source_item_id, chunk.locator.page_index);
            hits.push(ContentChunkSearchHit {
                chunk_id: chunk.id.to_string(),
                citation_id: chunk.citation_id.map(|id| id.to_string()),
                source_item_id: chunk.source_item_id.to_string(),
                source_title,
                extraction_run_id: chunk.extraction_run_id.to_string(),
                page_index: chunk.locator.page_index,
                page_label: chunk.locator.page_label,
                section_path: chunk.locator.section_path,
                figure_label: chunk.locator.figure_label,
                table_label: chunk.locator.table_label,
                excerpt: candidate.snippet,
                rank: candidate.rank,
                figures: availability.figures,
                page_image_available: availability.page_image_available,
            });
            if hits.len() == requested {
                break;
            }
        }
        ContentChunkSearchResult {
            ok: true,
            message: format!("Found {} source chunk(s).", hits.len()),
            hits,
        }
    }

    async fn get_page_image(
        &self,
        source_item_id: String,
        page_index: Option<u32>,
        page_label: Option<String>,
        resolution_dpi: Option<u32>,
        format: Option<String>,
    ) -> PageImageResult {
        self.render_page_result(
            &source_item_id,
            page_index,
            page_label.as_deref(),
            resolution_dpi.unwrap_or(DEFAULT_PAGE_DPI),
            format.as_deref().unwrap_or("png"),
        )
    }

    async fn get_figure_image(
        &self,
        citation_id: Option<String>,
        source_item_id: Option<String>,
        figure_label: String,
        padding: Option<u32>,
        resolution_dpi: Option<u32>,
        include_caption: Option<bool>,
        format: Option<String>,
    ) -> FigureImageResult {
        if figure_label.trim().is_empty() {
            return figure_failure("invalid_request", "figure_label must not be blank");
        }
        if citation_id.is_some() == source_item_id.is_some() {
            return figure_failure(
                "invalid_request",
                "provide exactly one of citation_id or source_item_id",
            );
        }
        let store = self.store();
        let (source_id, cited_page) = if let Some(citation_id) = citation_id {
            let citation_uuid = match Uuid::parse_str(&citation_id) {
                Ok(id) => id,
                Err(error) => return figure_failure("invalid_citation", &error.to_string()),
            };
            let citation = match load_record::<SourceCitation>(
                &store,
                citation_uuid,
                SOURCE_CITATION_SCHEMA,
            ) {
                Ok(value) => value,
                Err(error) => return figure_failure("citation_not_found", &error),
            };
            (citation.source_item_id, citation.locator.page_index)
        } else {
            let value = source_item_id.expect("validated exactly one source selector");
            let id = match Uuid::parse_str(&value) {
                Ok(id) => id,
                Err(error) => return figure_failure("invalid_source", &error.to_string()),
            };
            (id, None)
        };
        let mut candidates = match figure_regions(&store, source_id) {
            Ok(values) => values
                .into_iter()
                .filter(|figure| labels_equal(&figure.figure_label, &figure_label))
                .filter(|figure| cited_page.is_none_or(|page| page == figure.page_index))
                .collect::<Vec<_>>(),
            Err(error) => return figure_failure("storage_error", &error),
        };
        candidates.sort_by_key(|figure| match figure.status {
            FigureRegionStatus::Curated => 0,
            FigureRegionStatus::Extracted => 1,
            FigureRegionStatus::Ambiguous => 2,
        });
        let selected = if candidates.first().is_some_and(|first| {
            candidates
                .get(1)
                .is_none_or(|second| second.status != first.status)
        }) {
            candidates.first().cloned()
        } else {
            None
        };
        let fallback_page = selected
            .as_ref()
            .map(|value| value.page_index)
            .or(cited_page);
        let Some(figure) = selected.filter(|value| value.status != FigureRegionStatus::Ambiguous)
        else {
            return self.figure_page_fallback(
                source_id,
                fallback_page,
                &figure_label,
                if candidates.is_empty() {
                    "figure_not_found"
                } else {
                    "ambiguous"
                },
                resolution_dpi.unwrap_or(DEFAULT_FIGURE_DPI),
                format.as_deref().unwrap_or("png"),
            );
        };
        let dpi = resolution_dpi.unwrap_or(DEFAULT_FIGURE_DPI);
        let format = format.as_deref().unwrap_or("png");
        let asset = match source_asset(&store, &self.asset_root(), source_id) {
            Ok(value) => value,
            Err(error) => return figure_failure("source_unavailable", &error),
        };
        if asset.hash != figure.source_content_hash {
            return figure_failure(
                "source_hash_mismatch",
                "figure evidence does not match the immutable source PDF",
            );
        }
        let page = match render_page(
            &self.asset_root(),
            &self.cache_root(),
            &asset.hash,
            figure.page_index,
            dpi,
            format,
        ) {
            Ok(page) => page,
            Err(error) => return figure_failure("render_failed", &error),
        };
        let include_caption = include_caption.unwrap_or(true);
        let normalized = if include_caption {
            union_optional(figure.image_region, figure.caption_region)
        } else {
            figure.image_region
        };
        let Some(normalized) = normalized else {
            return self.figure_page_fallback(
                source_id,
                Some(figure.page_index),
                &figure_label,
                "ambiguous",
                dpi,
                format,
            );
        };
        let pixel = normalized_to_pixel(normalized, page.width, page.height);
        let crop = match crop_page(
            &self.cache_root(),
            &page,
            &FigureCropSpec {
                source_hash: &asset.hash,
                page_index: figure.page_index,
                bounds: (pixel.x, pixel.y, pixel.width, pixel.height),
                padding: padding.unwrap_or(16).min(256),
                dpi,
                include_caption,
            },
        ) {
            Ok(crop) => crop,
            Err(error) => return figure_failure("crop_failed", &error),
        };
        let extraction = extraction_metadata(&store, figure.extraction_run_id);
        FigureImageResult {
            ok: true,
            status: "resolved".into(),
            message: format!(
                "Resolved {} from {}, PDF page {}.",
                figure.figure_label, asset.title, figure.page_label
            ),
            metadata: Some(FigureImageMetadata {
                figure_label: figure.figure_label,
                caption_text: figure.caption_text,
                source_item_id: source_id.to_string(),
                source_title: asset.title,
                page_index: figure.page_index,
                page_label: figure.page_label,
                image_region: figure.image_region.map(rect_input),
                caption_region: figure.caption_region.map(rect_input),
                normalized_crop: Some(rect_input(normalized)),
                pixel_crop: Some(pixel),
                source_content_hash: asset.hash,
                extraction_run_id: figure.extraction_run_id.map(|id| id.to_string()),
                extraction_version: extraction,
                crop_status: match figure.status {
                    FigureRegionStatus::Curated => "curated",
                    _ => "extracted",
                }
                .into(),
                returned_image_kind: "figure_crop".into(),
                mime_type: "image/png".into(),
                pixel_width: crop.width,
                pixel_height: crop.height,
                resolution_dpi: dpi,
                cache_hit: crop.cache_hit,
            }),
            fallback_tool: None,
            fallback_arguments: None,
            mcp_content: vec![image_block(crop.png)],
        }
    }
}

/// Search source pages precisely first, then recover from the verbose natural-
/// language queries models produce by ranking partial term coverage.
///
/// The suite-wide search kernel deliberately ANDs every term because its main
/// caller is a human-driven find box. Source retrieval has a different
/// contract: `1978 California L-Jetronic cold start valve location` must not
/// return nothing merely because the OCR page omits `location`. Exact matches
/// remain first; the fallback counts distinct matching terms, then uses BM25
/// and the item id as deterministic tie-breaks.
fn source_search_candidates(
    store: &SqliteItemStore,
    query: &str,
    requested: usize,
) -> Result<Vec<impress_core::search_ops::SearchHit>, impress_core::store::StoreError> {
    let mut candidates = impress_core::search_ops::search_all(store, query, 200)?
        .into_iter()
        .filter(|candidate| candidate.schema_ref == CONTENT_CHUNK_SCHEMA)
        .collect::<Vec<_>>();
    let mut seen = candidates
        .iter()
        .map(|candidate| candidate.id.clone())
        .collect::<BTreeSet<_>>();
    if candidates.len() >= requested {
        candidates.truncate(requested);
        return Ok(candidates);
    }

    struct PartialMatch {
        matched_terms: usize,
        rank_sum: f64,
        best: impress_core::search_ops::SearchHit,
    }

    let mut partial = BTreeMap::<String, PartialMatch>::new();
    for term in source_query_terms(query) {
        for hit in impress_core::search_ops::search_all(store, &term, 200)?
            .into_iter()
            .filter(|candidate| candidate.schema_ref == CONTENT_CHUNK_SCHEMA)
        {
            if seen.contains(&hit.id) {
                continue;
            }
            partial
                .entry(hit.id.clone())
                .and_modify(|entry| {
                    entry.matched_terms += 1;
                    entry.rank_sum += hit.rank;
                    if hit.rank < entry.best.rank {
                        entry.best = hit.clone();
                    }
                })
                .or_insert(PartialMatch {
                    matched_terms: 1,
                    rank_sum: hit.rank,
                    best: hit,
                });
        }
    }
    let mut partial = partial.into_values().collect::<Vec<_>>();
    partial.sort_by(|left, right| {
        right
            .matched_terms
            .cmp(&left.matched_terms)
            .then_with(|| left.rank_sum.total_cmp(&right.rank_sum))
            .then_with(|| left.best.id.cmp(&right.best.id))
    });
    for entry in partial {
        if candidates.len() == requested {
            break;
        }
        if seen.insert(entry.best.id.clone()) {
            candidates.push(entry.best);
        }
    }
    Ok(candidates)
}

fn source_query_terms(query: &str) -> Vec<String> {
    const INTENT_WORDS: &[&str] = &[
        "about",
        "component",
        "components",
        "find",
        "identification",
        "identify",
        "information",
        "locate",
        "location",
        "manual",
        "system",
        "that",
        "the",
        "this",
        "volkswagen",
        "where",
        "with",
    ];
    let mut terms = query
        .split(|character: char| !character.is_alphanumeric())
        .map(str::to_lowercase)
        .filter(|term| term.len() >= 3 && !INTENT_WORDS.contains(&term.as_str()))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    terms.sort_by_key(|term| std::cmp::Reverse(term.len()));
    terms.truncate(12);
    terms
}

impress_service_impl! {
    service = SourceService,
    impl = DefaultSourceService,
    instance = DefaultSourceService::new,
    methods = [
        put_citation(citation: SourceCitationInput) -> SourceRecordResult,
        get_citation(citation_id: String) -> SourceRecordResult,
        put_extraction_run(run: ExtractionRunInput) -> SourceRecordResult,
        put_content_chunk(chunk: ContentChunkInput) -> SourceRecordResult,
        put_figure_region(figure: FigureRegionInput) -> SourceRecordResult,
        get_content_chunk(chunk_id: String) -> SourceRecordResult,
        search_content_chunks(query: String, source_item_id: Option<String>, limit: u32) -> ContentChunkSearchResult,
        get_page_image(source_item_id: String, page_index: Option<u32>, page_label: Option<String>, resolution_dpi: Option<u32>, format: Option<String>) -> PageImageResult,
        get_figure_image(citation_id: Option<String>, source_item_id: Option<String>, figure_label: String, padding: Option<u32>, resolution_dpi: Option<u32>, include_caption: Option<bool>, format: Option<String>) -> FigureImageResult,
    ],
}

fn locator_from_input(input: SourceLocatorInput) -> Result<SourceLocator, String> {
    let char_range = match (input.char_start, input.char_end) {
        (None, None) => None,
        (Some(start), Some(end)) => Some((start, end)),
        _ => return Err("char_start and char_end must be supplied together".into()),
    };
    let region = input
        .region
        .map(|region| NormalizedRect::new(region.x, region.y, region.width, region.height))
        .transpose()
        .map_err(|error| error.to_string())?;
    Ok(SourceLocator {
        page_index: input.page_index,
        page_label: input.page_label,
        region,
        char_range,
        section_path: input.section_path,
        figure_label: input.figure_label,
        table_label: input.table_label,
    })
}

fn citation_from_input(input: SourceCitationInput) -> Result<SourceCitation, (String, String)> {
    let id = input.id.clone();
    let parse =
        |value: &str| Uuid::parse_str(value).map_err(|error| (id.clone(), error.to_string()));
    Ok(SourceCitation {
        id: parse(&input.id)?,
        source_item_id: parse(&input.source_item_id)?,
        source_content_hash: input.source_content_hash,
        extraction_run_id: input.extraction_run_id.as_deref().map(parse).transpose()?,
        locator: locator_from_input(input.locator).map_err(|error| (id.clone(), error))?,
        quote: input.quote,
        quote_hash: input.quote_hash,
        title: input.title,
    })
}

fn extraction_from_input(input: ExtractionRunInput) -> Result<ExtractionRun, (String, String)> {
    let id = input.id.clone();
    let parse =
        |value: &str| Uuid::parse_str(value).map_err(|error| (id.clone(), error.to_string()));
    Ok(ExtractionRun {
        id: parse(&input.id)?,
        source_item_id: parse(&input.source_item_id)?,
        source_content_hash: input.source_content_hash,
        extractor: input.extractor,
        extractor_version: input.extractor_version,
        profile: input.profile,
        started_at: input.started_at,
        completed_at: input.completed_at,
        output_content_hash: input.output_content_hash,
        warnings: input.warnings,
        produced_item_ids: input
            .produced_item_ids
            .iter()
            .map(|value| parse(value))
            .collect::<Result<Vec<_>, _>>()?,
    })
}

fn chunk_from_input(input: ContentChunkInput) -> Result<ContentChunk, (String, String)> {
    let id = input.id.clone();
    let parse =
        |value: &str| Uuid::parse_str(value).map_err(|error| (id.clone(), error.to_string()));
    Ok(ContentChunk {
        id: parse(&input.id)?,
        source_item_id: parse(&input.source_item_id)?,
        extraction_run_id: parse(&input.extraction_run_id)?,
        citation_id: input.citation_id.as_deref().map(parse).transpose()?,
        ordinal: input.ordinal,
        text: input.text,
        content_hash: input.content_hash,
        locator: locator_from_input(input.locator).map_err(|error| (id.clone(), error))?,
        regions: input
            .regions
            .into_iter()
            .map(|region| {
                Ok(ExtractedTextRegion {
                    text: region.text,
                    confidence: region.confidence,
                    region: NormalizedRect::new(
                        region.region.x,
                        region.region.y,
                        region.region.width,
                        region.region.height,
                    )
                    .map_err(|error| (id.clone(), error.to_string()))?,
                })
            })
            .collect::<Result<Vec<_>, (String, String)>>()?,
    })
}

fn figure_from_input(input: FigureRegionInput) -> Result<FigureRegionEvidence, (String, String)> {
    let id = input.id.clone();
    let parse =
        |value: &str| Uuid::parse_str(value).map_err(|error| (id.clone(), error.to_string()));
    let rect = |value: NormalizedRectInput| {
        NormalizedRect::new(value.x, value.y, value.width, value.height)
            .map_err(|error| (id.clone(), error.to_string()))
    };
    let provenance = match input.provenance {
        FigureRegionProvenanceInput::Automatic {
            extractor,
            extractor_version,
        } => FigureRegionProvenance::Automatic {
            extractor,
            extractor_version,
        },
        FigureRegionProvenanceInput::ManualCorrection {
            curator,
            corrected_at,
            supersedes,
        } => FigureRegionProvenance::ManualCorrection {
            curator,
            corrected_at,
            supersedes: supersedes.as_deref().map(parse).transpose()?,
        },
    };
    Ok(FigureRegionEvidence {
        id: parse(&input.id)?,
        source_item_id: parse(&input.source_item_id)?,
        source_content_hash: input.source_content_hash,
        extraction_run_id: input.extraction_run_id.as_deref().map(parse).transpose()?,
        page_index: input.page_index,
        page_label: input.page_label,
        figure_label: input.figure_label,
        caption_text: input.caption_text,
        image_region: input.image_region.map(rect).transpose()?,
        caption_region: input.caption_region.map(rect).transpose()?,
        status: match input.status {
            FigureRegionStatusInput::Extracted => FigureRegionStatus::Extracted,
            FigureRegionStatusInput::Curated => FigureRegionStatus::Curated,
            FigureRegionStatusInput::Ambiguous => FigureRegionStatus::Ambiguous,
        },
        provenance,
        warnings: input.warnings,
    })
}

fn failed(id: Uuid, message: impl Into<String>) -> SourceRecordResult {
    failed_string(id.to_string(), message)
}

fn failed_string(id: String, message: impl Into<String>) -> SourceRecordResult {
    SourceRecordResult {
        ok: false,
        id,
        record: None,
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{make_item_named, test_store};
    use sha2::{Digest, Sha256};

    const HASH: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const OTHER_HASH: &str = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";

    fn synthetic_pdf() -> Vec<u8> {
        let streams = [
            "0.1 0.3 0.9 rg 20 20 160 160 re f\n",
            "0.9 0.2 0.1 rg 20 20 160 160 re f\n",
        ];
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>".to_string(),
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 5 0 R >>".to_string(),
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 6 0 R >>".to_string(),
            format!("<< /Length {} >>\nstream\n{}endstream", streams[0].len(), streams[0]),
            format!("<< /Length {} >>\nstream\n{}endstream", streams[1].len(), streams[1]),
        ];
        let mut pdf = b"%PDF-1.4\n% synthetic evidence fixture\n".to_vec();
        let mut offsets = vec![0usize];
        for (index, object) in objects.iter().enumerate() {
            offsets.push(pdf.len());
            pdf.extend_from_slice(format!("{} 0 obj\n{}\nendobj\n", index + 1, object).as_bytes());
        }
        let xref = pdf.len();
        pdf.extend_from_slice(
            format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).as_bytes(),
        );
        for offset in offsets.iter().skip(1) {
            pdf.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes());
        }
        pdf.extend_from_slice(
            format!(
                "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
                objects.len() + 1
            )
            .as_bytes(),
        );
        pdf
    }

    fn insert_pdf_source(store: &SqliteItemStore, title: &str, hash: &str) -> Uuid {
        let id = Uuid::new_v4();
        let now = chrono::Utc::now();
        store
            .insert(Item {
                id,
                schema: "impress/artifact/general".into(),
                payload: BTreeMap::from([
                    ("title".into(), Value::String(title.into())),
                    ("file_hash".into(), Value::String(hash.into())),
                    (
                        "file_mime_type".into(),
                        Value::String("application/pdf".into()),
                    ),
                ]),
                created: now,
                modified: now,
                author: "fixture".into(),
                author_kind: ActorKind::System,
                logical_clock: 0,
                origin: None,
                canonical_id: None,
                tags: vec!["vw/knowledge-source".into()],
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
            })
            .unwrap();
        id
    }

    async fn image_fixture() -> (
        tempfile::TempDir,
        DefaultSourceService,
        Uuid,
        String,
        String,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let store = test_store();
        let pdf = synthetic_pdf();
        let hash = format!("{:x}", Sha256::digest(&pdf));
        let source_file = dir.path().join("fixture.pdf");
        std::fs::write(&source_file, pdf).unwrap();
        crate::source_assets::install_source_pdf(&dir.path().join("assets"), &source_file, &hash)
            .unwrap();
        let source = insert_pdf_source(&store, "Synthetic Service Manual", &hash);
        let service = DefaultSourceService::with_store_and_roots(
            store,
            dir.path().join("assets"),
            dir.path().join("cache"),
        );
        let run_id = Uuid::new_v4().to_string();
        assert!(
            service
                .put_extraction_run(ExtractionRunInput {
                    id: run_id.clone(),
                    source_item_id: source.to_string(),
                    source_content_hash: hash.clone(),
                    extractor: "synthetic-layout".into(),
                    extractor_version: "2".into(),
                    profile: "figures".into(),
                    started_at: "2026-08-07T12:00:00Z".into(),
                    completed_at: Some("2026-08-07T12:00:01Z".into()),
                    output_content_hash: None,
                    warnings: vec![],
                    produced_item_ids: vec![],
                })
                .await
                .ok
        );
        for (index, label) in [(0, "i"), (1, "467")] {
            assert!(
                service
                    .put_citation(SourceCitationInput {
                        id: Uuid::new_v4().to_string(),
                        source_item_id: source.to_string(),
                        source_content_hash: hash.clone(),
                        extraction_run_id: Some(run_id.clone()),
                        locator: SourceLocatorInput {
                            page_index: Some(index),
                            page_label: Some(label.into()),
                            region: None,
                            char_start: None,
                            char_end: None,
                            section_path: vec![],
                            figure_label: None,
                            table_label: None
                        },
                        quote: None,
                        quote_hash: None,
                        title: Some("Synthetic Service Manual".into()),
                    })
                    .await
                    .ok
            );
        }
        (dir, service, source, hash, run_id)
    }

    #[tokio::test]
    async fn citation_put_is_idempotent_and_conflicts_are_refused() {
        let store = test_store();
        let source = make_item_named(&store, "impress/artifact/general", "Manual");
        let service = DefaultSourceService::with_store(store);
        let input = SourceCitationInput {
            id: Uuid::new_v4().to_string(),
            source_item_id: source,
            source_content_hash: HASH.into(),
            extraction_run_id: None,
            locator: SourceLocatorInput {
                page_index: Some(0),
                page_label: Some("1".into()),
                region: None,
                char_start: None,
                char_end: None,
                section_path: vec![],
                figure_label: None,
                table_label: None,
            },
            quote: Some("Fixture excerpt".into()),
            quote_hash: Some(impress_core::source::normalized_text_hash(
                "Fixture excerpt",
            )),
            title: Some("Manual".into()),
        };
        assert!(service.put_citation(input.clone()).await.ok);
        assert!(service.put_citation(input.clone()).await.ok);
        let mut changed = input;
        changed.quote = Some("Different".into());
        assert!(!service.put_citation(changed).await.ok);
    }

    #[tokio::test]
    async fn citation_and_extraction_run_must_name_the_same_source_bytes() {
        let store = test_store();
        let source = make_item_named(&store, "impress/artifact/general", "Manual");
        let service = DefaultSourceService::with_store(store);
        let run_id = Uuid::new_v4().to_string();
        assert!(
            service
                .put_extraction_run(ExtractionRunInput {
                    id: run_id.clone(),
                    source_item_id: source.clone(),
                    source_content_hash: HASH.into(),
                    extractor: "fixture-ocr".into(),
                    extractor_version: "1".into(),
                    profile: "layout".into(),
                    started_at: "2026-08-05T12:00:00Z".into(),
                    completed_at: None,
                    output_content_hash: None,
                    warnings: vec![],
                    produced_item_ids: vec![],
                })
                .await
                .ok
        );
        let result = service
            .put_citation(SourceCitationInput {
                id: Uuid::new_v4().to_string(),
                source_item_id: source,
                source_content_hash: OTHER_HASH.into(),
                extraction_run_id: Some(run_id),
                locator: SourceLocatorInput {
                    page_index: Some(0),
                    page_label: None,
                    region: None,
                    char_start: None,
                    char_end: None,
                    section_path: vec![],
                    figure_label: None,
                    table_label: None,
                },
                quote: None,
                quote_hash: None,
                title: None,
            })
            .await;
        assert!(!result.ok);
        assert!(result.message.contains("does not match"));
    }

    #[tokio::test]
    async fn content_chunks_are_full_text_searchable_with_page_provenance() {
        let store = test_store();
        let source = make_item_named(&store, "impress/artifact/general", "Manual");
        let service = DefaultSourceService::with_store(store);
        let run_id = Uuid::new_v4().to_string();
        assert!(
            service
                .put_extraction_run(ExtractionRunInput {
                    id: run_id.clone(),
                    source_item_id: source.clone(),
                    source_content_hash: HASH.into(),
                    extractor: "fixture-ocr".into(),
                    extractor_version: "1".into(),
                    profile: "layout".into(),
                    started_at: "2026-08-05T12:00:00Z".into(),
                    completed_at: None,
                    output_content_hash: None,
                    warnings: vec![],
                    produced_item_ids: vec![],
                })
                .await
                .ok
        );
        let text = "Synthetic airflow meter diagnostic fixture";
        assert!(
            service
                .put_content_chunk(ContentChunkInput {
                    id: Uuid::new_v4().to_string(),
                    source_item_id: source.clone(),
                    extraction_run_id: run_id,
                    citation_id: None,
                    ordinal: 0,
                    text: text.into(),
                    content_hash: impress_core::source::normalized_text_hash(text),
                    locator: SourceLocatorInput {
                        page_index: Some(7),
                        page_label: Some("8".into()),
                        region: None,
                        char_start: None,
                        char_end: None,
                        section_path: vec!["Synthetic test".into()],
                        figure_label: None,
                        table_label: None,
                    },
                    regions: vec![ExtractedTextRegionInput {
                        text: "Synthetic airflow meter diagnostic fixture".into(),
                        confidence: Some(0.95),
                        region: NormalizedRectInput {
                            x: 0.1,
                            y: 0.2,
                            width: 0.6,
                            height: 0.1,
                        },
                    }],
                })
                .await
                .ok
        );
        let result = service
            .search_content_chunks("airflow diagnostic".into(), Some(source), 5)
            .await;
        assert!(result.ok, "{}", result.message);
        assert_eq!(result.hits.len(), 1);
        assert_eq!(result.hits[0].page_index, Some(7));
        assert_eq!(result.hits[0].source_title.as_deref(), Some("Manual"));
        assert!(result.hits[0].excerpt.contains("airflow"));
        let resolved = service
            .get_content_chunk(result.hits[0].chunk_id.clone())
            .await;
        assert!(resolved.ok, "{}", resolved.message);
        let record = resolved.record.unwrap();
        assert_eq!(record["text"], text);
        assert_eq!(record["regions"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn source_search_recovers_from_verbose_intent_terms() {
        let store = test_store();
        let source = make_item_named(&store, "impress/artifact/general", "Manual");
        let service = DefaultSourceService::with_store(store);
        let run_id = Uuid::new_v4().to_string();
        assert!(
            service
                .put_extraction_run(ExtractionRunInput {
                    id: run_id.clone(),
                    source_item_id: source.clone(),
                    source_content_hash: HASH.into(),
                    extractor: "fixture-ocr".into(),
                    extractor_version: "1".into(),
                    profile: "layout".into(),
                    started_at: "2026-08-05T12:00:00Z".into(),
                    completed_at: None,
                    output_content_hash: None,
                    warnings: vec![],
                    produced_item_ids: vec![],
                })
                .await
                .ok
        );
        let text = "The L-Jetronic cold start valve is controlled by the thermo-time switch.";
        assert!(
            service
                .put_content_chunk(ContentChunkInput {
                    id: Uuid::new_v4().to_string(),
                    source_item_id: source,
                    extraction_run_id: run_id,
                    citation_id: None,
                    ordinal: 0,
                    text: text.into(),
                    content_hash: impress_core::source::normalized_text_hash(text),
                    locator: SourceLocatorInput {
                        page_index: Some(10),
                        page_label: Some("11".into()),
                        region: None,
                        char_start: None,
                        char_end: None,
                        section_path: vec![],
                        figure_label: None,
                        table_label: None,
                    },
                    regions: vec![],
                })
                .await
                .ok
        );

        let result = service
            .search_content_chunks(
                "1978 California L-Jetronic cold start valve location identification".into(),
                None,
                5,
            )
            .await;
        assert!(result.ok, "{}", result.message);
        assert_eq!(result.hits.len(), 1);
        assert_eq!(result.hits[0].page_label.as_deref(), Some("11"));
    }

    #[tokio::test]
    async fn renders_exact_pages_by_index_and_nonphysical_label_with_cache() {
        let (dir, service, source, hash, _run_id) = image_fixture().await;
        let first = service
            .get_page_image(
                source.to_string(),
                Some(1),
                None,
                Some(144),
                Some("png".into()),
            )
            .await;
        assert!(first.ok, "{}", first.message);
        let metadata = first.metadata.unwrap();
        assert_eq!(metadata.page_index, 1);
        assert_eq!(metadata.page_label, "467");
        assert_eq!(metadata.source_content_hash, hash);
        assert_eq!(metadata.source_title, "Synthetic Service Manual");
        assert_eq!(
            metadata.extraction_version.as_deref(),
            Some("synthetic-layout:2:figures")
        );
        assert_eq!((metadata.pixel_width, metadata.pixel_height), (400, 400));
        assert!(!metadata.cache_hit);
        assert!(first.mcp_content[0].data.len() > 100);

        let cached = service
            .get_page_image(
                source.to_string(),
                None,
                Some("467".into()),
                Some(144),
                Some("png".into()),
            )
            .await;
        assert!(cached.ok, "{}", cached.message);
        assert!(cached.metadata.unwrap().cache_hit);
        let roman = service
            .get_page_image(source.to_string(), None, Some("i".into()), Some(72), None)
            .await;
        assert_eq!(roman.metadata.unwrap().page_index, 0);
        assert!(
            !service
                .get_page_image(source.to_string(), Some(9), None, None, None)
                .await
                .ok
        );
        assert!(
            !service
                .get_page_image(source.to_string(), Some(0), None, Some(600), None)
                .await
                .ok
        );

        let mut changed = synthetic_pdf();
        changed.extend_from_slice(b"\n% distinct immutable source\n");
        let changed_hash = format!("{:x}", Sha256::digest(&changed));
        let changed_file = dir.path().join("changed.pdf");
        std::fs::write(&changed_file, changed).unwrap();
        crate::source_assets::install_source_pdf(
            &dir.path().join("assets"),
            &changed_file,
            &changed_hash,
        )
        .unwrap();
        let changed_source = insert_pdf_source(&service.store(), "Changed Manual", &changed_hash);
        let invalidated = service
            .get_page_image(
                changed_source.to_string(),
                Some(1),
                None,
                Some(144),
                Some("png".into()),
            )
            .await;
        assert!(invalidated.ok, "{}", invalidated.message);
        assert!(
            !invalidated.metadata.unwrap().cache_hit,
            "a different source hash must not reuse a page cache entry"
        );
    }

    #[tokio::test]
    async fn figure_crop_caption_geometry_and_ambiguous_fallback_are_explicit() {
        let (_dir, service, source, hash, run_id) = image_fixture().await;
        let citation = service
            .store()
            .query(&ItemQuery {
                schema: Some(SOURCE_CITATION_SCHEMA.into()),
                predicates: vec![Predicate::HasParent(source)],
                include_tags: false,
                include_references: false,
                ..Default::default()
            })
            .unwrap()
            .into_iter()
            .find(|item| {
                item.payload
                    .get("data")
                    .and_then(|value| serde_json::to_value(value).ok())
                    .and_then(|value| serde_json::from_value::<SourceCitation>(value).ok())
                    .is_some_and(|value| value.locator.page_index == Some(1))
            })
            .unwrap()
            .id;
        assert!(
            service
                .put_figure_region(FigureRegionInput {
                    id: Uuid::new_v4().to_string(),
                    source_item_id: source.to_string(),
                    source_content_hash: hash.clone(),
                    extraction_run_id: Some(run_id),
                    page_index: 1,
                    page_label: "467".into(),
                    figure_label: "Fig. 4-5".into(),
                    caption_text: Some("Synthetic thermo-time switch caption.".into()),
                    image_region: Some(NormalizedRectInput {
                        x: 0.2,
                        y: 0.35,
                        width: 0.6,
                        height: 0.45
                    }),
                    caption_region: Some(NormalizedRectInput {
                        x: 0.2,
                        y: 0.2,
                        width: 0.6,
                        height: 0.1
                    }),
                    status: FigureRegionStatusInput::Curated,
                    provenance: FigureRegionProvenanceInput::ManualCorrection {
                        curator: "fixture".into(),
                        corrected_at: "2026-08-07T12:00:00Z".into(),
                        supersedes: None
                    },
                    warnings: vec![],
                })
                .await
                .ok
        );
        let without = service
            .get_figure_image(
                Some(citation.to_string()),
                None,
                "Fig. 4-5".into(),
                Some(0),
                Some(144),
                Some(false),
                None,
            )
            .await;
        let with = service
            .get_figure_image(
                Some(citation.to_string()),
                None,
                "Fig. 4-5".into(),
                Some(0),
                Some(144),
                Some(true),
                None,
            )
            .await;
        assert!(without.ok && with.ok);
        let without_meta = without.metadata.unwrap();
        let with_meta = with.metadata.unwrap();
        assert_eq!(without_meta.returned_image_kind, "figure_crop");
        assert_eq!(
            without_meta.pixel_crop,
            Some(PixelRect {
                x: 80,
                y: 80,
                width: 240,
                height: 180
            })
        );
        assert!(with_meta.pixel_height > without_meta.pixel_height);
        assert_eq!(
            with_meta.caption_text.as_deref(),
            Some("Synthetic thermo-time switch caption.")
        );
        assert_eq!(
            with_meta.extraction_version.as_deref(),
            Some("synthetic-layout:2:figures")
        );

        let fallback = service
            .get_figure_image(
                Some(citation.to_string()),
                None,
                "Fig. missing".into(),
                None,
                Some(144),
                None,
                None,
            )
            .await;
        assert!(fallback.ok);
        assert_eq!(fallback.status, "figure_not_found");
        assert_eq!(
            fallback.metadata.unwrap().returned_image_kind,
            "page_fallback"
        );
        assert_eq!(fallback.mcp_content[0].kind, "image");

        assert!(
            service
                .put_figure_region(FigureRegionInput {
                    id: Uuid::new_v4().to_string(),
                    source_item_id: source.to_string(),
                    source_content_hash: hash,
                    extraction_run_id: None,
                    page_index: 1,
                    page_label: "467".into(),
                    figure_label: "Fig. uncertain".into(),
                    caption_text: None,
                    image_region: None,
                    caption_region: None,
                    status: FigureRegionStatusInput::Ambiguous,
                    provenance: FigureRegionProvenanceInput::Automatic {
                        extractor: "fixture".into(),
                        extractor_version: "1".into()
                    },
                    warnings: vec!["multiple candidate regions".into()],
                })
                .await
                .ok
        );
        let ambiguous = service
            .get_figure_image(
                Some(citation.to_string()),
                None,
                "Fig. uncertain".into(),
                None,
                Some(144),
                None,
                None,
            )
            .await;
        assert!(ambiguous.ok);
        assert_eq!(ambiguous.status, "ambiguous");
        assert_eq!(
            ambiguous.metadata.unwrap().returned_image_kind,
            "page_fallback"
        );
    }
}
