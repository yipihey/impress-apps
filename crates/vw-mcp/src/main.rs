use std::path::PathBuf;

use impress_mcp_host::{HostConfig, Resource, ToolFileParams, ToolUi};

#[allow(unused_imports)]
use vw_impress_adapter as _force_link_vw_diagnostic_service;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut store_path: Option<PathBuf> = None;
    let mut knowledge_pack_path: Option<PathBuf> = None;
    let mut http_bind: Option<String> = None;
    let mut asset_root: Option<PathBuf> = None;
    let mut cache_root: Option<PathBuf> = None;
    let mut curation = false;
    let mut args = std::env::args().skip(1);
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "--store-path" => {
                store_path = Some(PathBuf::from(
                    args.next().ok_or("--store-path requires a value")?,
                ));
            }
            "--knowledge-pack" => {
                knowledge_pack_path = Some(PathBuf::from(
                    args.next().ok_or("--knowledge-pack requires a value")?,
                ));
            }
            "--http-bind" => {
                http_bind = Some(args.next().ok_or("--http-bind requires a value")?);
            }
            "--asset-root" => {
                asset_root = Some(PathBuf::from(
                    args.next().ok_or("--asset-root requires a value")?,
                ))
            }
            "--cache-root" => {
                cache_root = Some(PathBuf::from(
                    args.next().ok_or("--cache-root requires a value")?,
                ))
            }
            "--curation" => curation = true,
            "--help" | "-h" => {
                println!(
                    "vw-mcp [--store-path PATH] [--knowledge-pack PACK.json] [--curation] \
                     [--http-bind ADDRESS] [--asset-root DIR] [--cache-root DIR]"
                );
                println!("Focused VW diagnostic MCP server over stdio by default.");
                println!(
                    "HTTP mode requires IMPRESS_MCP_ACCESS_TOKEN and serves /mcp and /healthz."
                );
                return Ok(());
            }
            "--version" | "-V" => {
                println!("vw-mcp {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            unknown => return Err(format!("unknown argument: {unknown}").into()),
        }
    }
    if let Some(path) = store_path {
        impress_store_service::set_store_path(path)?;
    }
    if let Some(path) = asset_root {
        impress_store_service::set_source_asset_root(path)?;
    }
    if let Some(path) = cache_root {
        impress_store_service::set_source_cache_root(path)?;
    }
    if let Some(path) = knowledge_pack_path {
        let bytes = std::fs::read(&path)?;
        let pack: vw_domain::KnowledgePack = serde_json::from_slice(&bytes)?;
        vw_impress_adapter::activate_default_pack(pack)
            .map_err(|error| format!("activate {}: {error}", path.display()))?;
    }

    let mut allowed_tool_prefixes = vec!["vw-diagnostic-service_".into()];
    if curation {
        allowed_tool_prefixes.push("source-service_".into());
    } else {
        // Diagnosis may retrieve source text and resolve citations but cannot
        // author provenance records.
        allowed_tool_prefixes.push("source-service_get-citation".into());
        allowed_tool_prefixes.push("source-service_get-content-chunk".into());
        allowed_tool_prefixes.push("source-service_search-content-chunks".into());
        allowed_tool_prefixes.push("source-service_get-page-image".into());
        allowed_tool_prefixes.push("source-service_get-figure-image".into());
    }

    const EVIDENCE_IMAGE_UI: &str = "ui://vw/evidence-image-v1.html";
    let config = HostConfig {
        server_name: "vw-diagnostic".into(),
        server_version: env!("CARGO_PKG_VERSION").into(),
        instructions:
            "Use only semantic VW tools. Search source chunks and resolve citations before presenting evidence. When a cited procedure has a useful figure, call source-service_get-figure-image and display it; call source-service_get-page-image when the complete page or surrounding context matters. When the user shares a photo of their bus, engine, or a related part as diagnostic evidence, inspect it visually and call vw-diagnostic-service_ingest-photo with a grounded description; do not ingest unrelated images. Search stored user photos with vw-diagnostic-service_search-photos and display one with vw-diagnostic-service_get-photo. User photos are private evidence and never become published diagnostic rules automatically. An ambiguous figure result is a full-page fallback, never a verified crop. Never invent measurements, citations, applicability, figures, photo details, or probabilities."
                .into(),
        allowed_tool_prefixes,
        resources: vec![
            Resource {
                uri: "impress://expert/vw/guide".into(),
                name: "VW diagnostic guide".into(),
                description: "Workflow, evidence and safety contract for the VW expert system."
                    .into(),
                mime_type: "text/markdown".into(),
                text: include_str!("../../../docs/vw-mcp-guide.md").into(),
                meta: None,
            },
            Resource {
                uri: "impress://expert/vw/schema".into(),
                name: "VW public vocabulary".into(),
                description: "Public domain concepts and command rules.".into(),
                mime_type: "application/json".into(),
                text: serde_json::json!({
                    "domain": "vw-type2-diagnostics",
                    "session_revision": "Every mutation requires expected_revision.",
                    "command_id": "Every mutation requires a caller-generated UUID and is idempotent.",
                    "inference": "Ordinal deterministic rule priority, never probability.",
                    "knowledge": "Only published, cited pack content executes."
                })
                .to_string(),
                meta: None,
            },
            Resource {
                uri: EVIDENCE_IMAGE_UI.into(),
                name: "VW evidence image viewer".into(),
                description:
                    "Displays a resolved PDF page, figure, or private user photo with provenance."
                        .into(),
                mime_type: "text/html;profile=mcp-app".into(),
                text: include_str!("evidence-image.html").into(),
                meta: Some(serde_json::json!({
                    "ui": { "prefersBorder": true }
                })),
            },
        ],
        tool_ui: vec![
            ToolUi {
                tool_name: "source-service_get-figure-image".into(),
                resource_uri: EVIDENCE_IMAGE_UI.into(),
                invoking: "Retrieving cited figure…".into(),
                invoked: "Figure ready.".into(),
            },
            ToolUi {
                tool_name: "source-service_get-page-image".into(),
                resource_uri: EVIDENCE_IMAGE_UI.into(),
                invoking: "Rendering cited page…".into(),
                invoked: "Page ready.".into(),
            },
            ToolUi {
                tool_name: "vw-diagnostic-service_ingest-photo".into(),
                resource_uri: EVIDENCE_IMAGE_UI.into(),
                invoking: "Saving bus photo evidence…".into(),
                invoked: "Photo stored privately.".into(),
            },
            ToolUi {
                tool_name: "vw-diagnostic-service_get-photo".into(),
                resource_uri: EVIDENCE_IMAGE_UI.into(),
                invoking: "Retrieving stored bus photo…".into(),
                invoked: "Photo ready.".into(),
            },
        ],
        tool_file_params: vec![ToolFileParams {
            tool_name: "vw-diagnostic-service_ingest-photo".into(),
            params: vec!["photo".into()],
        }],
    };
    if let Some(bind) = http_bind {
        let token = std::env::var("IMPRESS_MCP_ACCESS_TOKEN")
            .map_err(|_| "HTTP mode requires IMPRESS_MCP_ACCESS_TOKEN")?;
        impress_mcp_host::run_http(config, &bind, token)
    } else {
        impress_mcp_host::run_stdio(config)
    }
}
