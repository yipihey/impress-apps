//! Per-example fixtures for the G3 store, settings, and source examples.
//!
//! Call `prepare` before opening an effects-spy window. Fixtures use only the
//! caller's scratch store and workspace, and use IDs disjoint from the verb
//! examples so results never depend on inventory traversal order.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;
use std::time::SystemTime;

use impress_core::item::{ActorKind, Item, ItemId, Priority, Value as ItemValue, Visibility};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_store_service::settings_service::settings_instance;
use impress_store_service::source_assets::{install_source_pdf, source_asset_root};
use impress_store_service::source_service::{
    ContentChunkInput, DefaultSourceService, ExtractionRunInput, FigureRegionInput,
    FigureRegionProvenanceInput, FigureRegionStatusInput, NormalizedRectInput, SourceCitationInput,
    SourceLocatorInput, SourceService,
};
use serde_json::Value;

const SOURCE: &str = "57000000-0000-4000-8000-000000000001";
const CITATION: &str = "57000000-0000-4000-8000-000000000002";
const RUN: &str = "57000000-0000-4000-8000-000000000003";
const CHUNK: &str = "57000000-0000-4000-8000-000000000004";
const FIGURE: &str = "57000000-0000-4000-8000-000000000005";
const SOURCE_HASH: &str = "6e6c26340ee8dce53e3eb28fb2e3aad19d15c6573f69efef4bb0804becc9aae5";
const CHUNK_TEXT: &str = "effects source evidence";
const CHUNK_HASH: &str = "9f824f80a33102067b25f064f45525cb2092dc1253975b23f896dafa22ee8fc9";
const INBOX_DAYS: &str = "imbib.retention.inbox_days";
const MANUSCRIPTS: [&str; 4] = [
    "57000000-0000-4000-8000-000000000021",
    "57000000-0000-4000-8000-000000000022",
    "57000000-0000-4000-8000-000000000023",
    "57000000-0000-4000-8000-000000000024",
];

/// Prepare only the family required by this example, before observation.
pub async fn prepare(
    verb: &str,
    _example: &str,
    store: &Arc<SqliteItemStore>,
    root: &Path,
) -> Result<(), String> {
    if verb.starts_with("settings-service_") {
        settings_instance()
            .reset(INBOX_DAYS)
            .map_err(|e| e.to_string())?;
    } else if verb.starts_with("source-service_") {
        prepare_source(store, root).await?;
    } else if verb.starts_with("manuscript-collab-service_") {
        let id = match verb {
            "manuscript-collab-service_manuscript-heads" => MANUSCRIPTS[0],
            "manuscript-collab-service_commit-manuscript-body" => MANUSCRIPTS[1],
            "manuscript-collab-service_manuscript-change-history" => MANUSCRIPTS[2],
            "manuscript-collab-service_manuscript-text-at" => MANUSCRIPTS[3],
            _ => return Ok(()),
        };
        seed_manuscript(store, id)?;
    }
    Ok(())
}

/// Verify a concrete persisted/read-back effect after the example's spy closes.
pub fn verify(
    verb: &str,
    _example: &str,
    store: &Arc<SqliteItemStore>,
    args: &Value,
    result: &Value,
) -> Result<(), String> {
    if result.get("ok") != Some(&Value::Bool(true)) {
        return Err(format!("{verb} did not succeed: {result}"));
    }
    match verb {
        "settings-service_schema" if result["settings"].as_array().is_none_or(Vec::is_empty) => {
            return Err("settings schema did not expose declared keys".into());
        }
        "settings-service_list"
            if !result["settings"].as_array().is_some_and(|rows| {
                rows.iter()
                    .any(|row| row["key"].as_str() == Some(INBOX_DAYS))
            }) =>
        {
            return Err("retention list omitted inbox-days setting".into());
        }
        "settings-service_surface" if !result["spec"].is_object() => {
            return Err("settings surface did not return a spec".into());
        }
        _ => {}
    }
    if verb == "settings-service_set" || verb == "settings-service_reset" {
        let expected = if verb == "settings-service_set" {
            31
        } else {
            30
        };
        let current = settings_instance()
            .get(INBOX_DAYS)
            .map_err(|e| e.to_string())?;
        if current.value != serde_json::json!(expected) {
            return Err(format!(
                "{verb} read-back was {}, expected {expected}",
                current.value
            ));
        }
    }
    if verb.starts_with("source-service_put-") {
        let input_key = match verb {
            "source-service_put-citation" => "citation",
            "source-service_put-extraction-run" => "run",
            "source-service_put-content-chunk" => "chunk",
            "source-service_put-figure-region" => "figure",
            _ => return Ok(()),
        };
        let id = args[input_key]["id"]
            .as_str()
            .ok_or_else(|| format!("{verb} example has no id"))?
            .parse::<ItemId>()
            .map_err(|e| e.to_string())?;
        let row = store.get(id).map_err(|e| e.to_string())?;
        if row.is_none() {
            return Err(format!("{verb} did not persist {id}"));
        }
    }
    if matches!(
        verb,
        "source-service_get-page-image" | "source-service_get-figure-image"
    ) && result["_mcp_content"].as_array().is_none_or(Vec::is_empty)
    {
        return Err(format!("{verb} returned no image content"));
    }
    if verb == "manuscript-collab-service_commit-manuscript-body" {
        let id = MANUSCRIPTS[1]
            .parse::<ItemId>()
            .map_err(|e| e.to_string())?;
        let row = store
            .get(id)
            .map_err(|e| e.to_string())?
            .ok_or("manuscript missing")?;
        if row.payload.get("body_content")
            != Some(&ItemValue::String(
                "A short fixture manuscript, revised.".into(),
            ))
        {
            return Err("collaborative commit did not persist its body".into());
        }
    }
    if verb == "manuscript-collab-service_manuscript-heads"
        && result["heads"].as_array().is_none_or(Vec::is_empty)
    {
        return Err("fixture manuscript returned no heads".into());
    }
    Ok(())
}

fn seed_manuscript(store: &SqliteItemStore, id: &str) -> Result<(), String> {
    let id = id.parse::<ItemId>().map_err(|e| e.to_string())?;
    if store.get(id).map_err(|e| e.to_string())?.is_some() {
        return Ok(());
    }
    let body = "A short fixture manuscript.";
    let mut row = item(id, impress_core::schema::refs::MANUSCRIPT);
    row.payload = BTreeMap::from([
        (
            "title".into(),
            ItemValue::String("G3 fixture manuscript".into()),
        ),
        ("format".into(), ItemValue::String("typst".into())),
        ("body_content".into(), ItemValue::String(body.into())),
        (
            "body_content_hash".into(),
            ItemValue::String(impress_core::manuscript_ops::sha256_hex(body)),
        ),
    ]);
    store.insert(row).map(|_| ()).map_err(|e| e.to_string())
}

async fn prepare_source(store: &Arc<SqliteItemStore>, root: &Path) -> Result<(), String> {
    let id = SOURCE.parse::<ItemId>().map_err(|e| e.to_string())?;
    if store.get(id).map_err(|e| e.to_string())?.is_none() {
        let mut row = item(id, impress_core::schema::refs::IMPRESS_ARTIFACT_GENERAL);
        row.payload = BTreeMap::from([
            (
                "title".into(),
                ItemValue::String("G3 fixture source".into()),
            ),
            ("file_hash".into(), ItemValue::String(SOURCE_HASH.into())),
            (
                "file_mime_type".into(),
                ItemValue::String("application/pdf".into()),
            ),
        ]);
        store.insert(row).map_err(|e| e.to_string())?;
    }
    let source_pdf = root.join("g3-source.pdf");
    if !source_pdf.exists() {
        std::fs::write(&source_pdf, synthetic_pdf()).map_err(|e| e.to_string())?;
    }
    install_source_pdf(&source_asset_root(), &source_pdf, SOURCE_HASH)?;
    let service = DefaultSourceService::with_store(store.clone());
    let locator = SourceLocatorInput {
        page_index: Some(0),
        page_label: Some("1".into()),
        region: None,
        char_start: None,
        char_end: None,
        section_path: vec![],
        figure_label: None,
        table_label: None,
    };
    if !service
        .put_extraction_run(ExtractionRunInput {
            id: RUN.into(),
            source_item_id: SOURCE.into(),
            source_content_hash: SOURCE_HASH.into(),
            extractor: "g3-fixture".into(),
            extractor_version: "1".into(),
            profile: "text".into(),
            started_at: "2026-09-28T00:00:00Z".into(),
            completed_at: None,
            output_content_hash: None,
            warnings: vec![],
            produced_item_ids: vec![],
        })
        .await
        .ok
    {
        return Err("could not seed source extraction run".into());
    }
    if !service
        .put_citation(SourceCitationInput {
            id: CITATION.into(),
            source_item_id: SOURCE.into(),
            source_content_hash: SOURCE_HASH.into(),
            extraction_run_id: Some(RUN.into()),
            locator: locator.clone(),
            quote: None,
            quote_hash: None,
            title: Some("G3 fixture source".into()),
        })
        .await
        .ok
    {
        return Err("could not seed source citation".into());
    }
    if !service
        .put_content_chunk(ContentChunkInput {
            id: CHUNK.into(),
            source_item_id: SOURCE.into(),
            extraction_run_id: RUN.into(),
            citation_id: Some(CITATION.into()),
            ordinal: 0,
            text: CHUNK_TEXT.into(),
            content_hash: CHUNK_HASH.into(),
            locator: locator.clone(),
            regions: vec![],
        })
        .await
        .ok
    {
        return Err("could not seed source chunk".into());
    }
    if !service
        .put_figure_region(FigureRegionInput {
            id: FIGURE.into(),
            source_item_id: SOURCE.into(),
            source_content_hash: SOURCE_HASH.into(),
            extraction_run_id: Some(RUN.into()),
            page_index: 0,
            page_label: "1".into(),
            figure_label: "Fig. 1".into(),
            caption_text: Some("Fixture figure.".into()),
            image_region: Some(NormalizedRectInput {
                x: 0.2,
                y: 0.2,
                width: 0.5,
                height: 0.5,
            }),
            caption_region: None,
            status: FigureRegionStatusInput::Extracted,
            provenance: FigureRegionProvenanceInput::Automatic {
                extractor: "g3-fixture".into(),
                extractor_version: "1".into(),
            },
            warnings: vec![],
        })
        .await
        .ok
    {
        return Err("could not seed source figure".into());
    }
    Ok(())
}

fn item(id: ItemId, schema: impress_core::SchemaRef) -> Item {
    Item {
        id,
        schema,
        payload: BTreeMap::new(),
        created: SystemTime::UNIX_EPOCH.into(),
        modified: SystemTime::UNIX_EPOCH.into(),
        author: "system:g3-fixture".into(),
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
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: None,
    }
}

fn synthetic_pdf() -> Vec<u8> {
    let streams = [
        "0.1 0.3 0.9 rg 20 20 160 160 re f\n",
        "0.9 0.2 0.1 rg 20 20 160 160 re f\n",
    ];
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>".to_string(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 5 0 R >>"
            .to_string(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 6 0 R >>"
            .to_string(),
        format!(
            "<< /Length {} >>\nstream\n{}endstream",
            streams[0].len(),
            streams[0]
        ),
        format!(
            "<< /Length {} >>\nstream\n{}endstream",
            streams[1].len(),
            streams[1]
        ),
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
