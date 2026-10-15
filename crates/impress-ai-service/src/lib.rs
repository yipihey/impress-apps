//! Generated management surface for the provenance-first Impress AI core.
//!
//! The verbs are koine's (`koine_ai::service`, koine
//! docs/plan-koine-ai-tasks.md AI-D1), with their names. This crate is what
//! makes them impress's: it re-exports them (so `impress_capabilities` and
//! every `impress_ai_service::` path keep linking the same descriptors) and
//! submits the suite's [`Deployment`](koine_ai::service::Deployment) — the
//! shared SQLite store every Impress app uses, and the registry over
//! `<workspace>/ai/preferences.json` beside it, exactly what this crate's
//! verbs used before they moved.

use std::sync::{Arc, OnceLock};

pub use koine_ai::service::*;

use impress_ai::{AiRegistry, AiStore};

/// The suite's store and registry, opened once per process.
fn impress_deployment() -> DefaultImpressAiService {
    static SERVICE: OnceLock<DefaultImpressAiService> = OnceLock::new();
    SERVICE
        .get_or_init(|| {
            let ai = Arc::new(AiStore::from_store(
                impress_store_service::store_instance(),
                "agent:impress-ai-service",
            ));
            // The registry lives beside the store: `<workspace>/ai/preferences.json`
            // is the same file every app and daemon on this device reads.
            let store_path = impress_store_service::store_path();
            let workspace = store_path
                .parent()
                .map(std::path::Path::to_path_buf)
                .unwrap_or_else(|| std::path::PathBuf::from("."));
            DefaultImpressAiService::with_components(ai, AiRegistry::for_daemon(workspace))
        })
        .clone()
}

impress_service_core::inventory::submit! {
    Deployment { name: "impress", deploy: impress_deployment }
}

/// Keep this crate's deployment and the verbs it deploys in the final
/// binary: real references, so neither registration's object file is
/// dropped (`impress_capabilities::force_link` calls this).
pub fn ensure_linked() {
    std::hint::black_box(impress_deployment as fn() -> DefaultImpressAiService);
    std::hint::black_box(std::ptr::addr_of!(
        koine_ai::service::__IMPRESS_VERB_ImpressAiService_list_models
    ));
}

#[cfg(test)]
mod tests {
    use impress_service_core::{CliSubcommand, McpToolDescriptor};

    #[test]
    fn the_verbs_keep_their_names_in_both_generated_inventories() {
        let mcp: Vec<&str> = McpToolDescriptor::iter().map(|item| item.name).collect();
        let cli: Vec<&str> = CliSubcommand::iter().map(|item| item.name).collect();
        for (mcp_name, cli_name) in [
            ("impress-ai-service_list-models", "list-models"),
            ("impress-ai-service_select-model", "select-model"),
            ("impress-ai-service_queue-message", "queue-message"),
            ("impress-ai-service_ai-health", "ai-health"),
            ("impress-ai-service_mint-pairing-link", "mint-pairing-link"),
        ] {
            assert!(mcp.contains(&mcp_name), "missing {mcp_name}");
            assert!(cli.contains(&cli_name), "missing {cli_name}");
        }
    }

    #[test]
    fn the_impress_deployment_is_the_one_linked() {
        let deployments: Vec<&str> = impress_service_core::inventory::iter::<super::Deployment>
            .into_iter()
            .map(|d| d.name)
            .collect();
        assert_eq!(deployments, ["impress"]);
    }
}
