//! A compact local-model view of the generated Impress service inventory.
//!
//! Definitions and handlers remain owned by `#[impress_service]`. This crate
//! only groups that inventory into policy buckets and domain/action tools so a
//! local model does not spend its context window on hundreds of flat schemas.

use std::collections::{BTreeMap, BTreeSet};

use async_trait::async_trait;
use impress_ai::{Error, Result, ToolAdapter, ToolDefinition};
use impress_service_core::{call, ProviderStatus, VerbHandle};
use serde_json::{json, Map, Value};

// Keep inventory submissions linked into every consumer of this adapter:
// the one linked inventory (ADR-0033 D4), with the features Cargo.toml
// names, plus the store-generic services — never a second list of service
// crates here (plan-verb-pipeline PL-6).
#[allow(unused_imports)]
use impress_capabilities as _force_link_inventory;
#[allow(unused_imports)]
use impress_store_service as _force_link_store;

const CAPABILITIES_TOOL: &str = "impress_capabilities";
const DOMAINS: &[(&str, &str)] = &[
    (
        "imbib",
        "Bibliography, papers, tags, annotations, and PDFs.",
    ),
    (
        "imprint",
        "Manuscripts, Typst sections, compilation, and structure.",
    ),
    ("implore", "Datasets, plots, and visual selections."),
    ("impart", "Conversations, messages, and communication."),
    ("store", "Cross-kind search, collections, and triage."),
    ("docs", "Filesystem ingest and watched research folders."),
    (
        "impress",
        "Suite bridges, parsers, and shared capabilities.",
    ),
    (
        "vw",
        "Cited VW Type 2 source retrieval and deterministic diagnostic operations.",
    ),
];

const VW_SOURCE_READ_TOOLS: &[&str] = &[
    "source-service_get-citation",
    "source-service_get-content-chunk",
    "source-service_search-content-chunks",
    "source-service_get-page-image",
    "source-service_get-figure-image",
];

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Reachability {
    pub imbib: bool,
    pub imprint: bool,
    pub implore: bool,
    pub impart: bool,
}

#[derive(Clone)]
pub struct ImpressToolAdapter {
    /// LIVE reachability, shared across clones (the daemon's refresh loop
    /// and the executor's catalog reads see one state). The first version
    /// captured a `Reachability` by value at `probe()` — an app closed at
    /// daemon boot had its tools withheld for the daemon's whole life, and
    /// one that launched later was never noticed.
    reachable: std::sync::Arc<std::sync::RwLock<Reachability>>,
}

impl ImpressToolAdapter {
    /// Probe sibling automation services without blocking the async executor.
    /// Store-backed and pure tools remain available when every app is closed.
    pub async fn probe() -> Result<Self> {
        let reachable = Self::probe_reachability().await?;
        let adapter = Self {
            reachable: std::sync::Arc::new(std::sync::RwLock::new(reachable)),
        };
        adapter.install_gate();
        Ok(adapter)
    }

    fn install_gate(&self) {
        impress_app_transport::install(true);
    }

    /// Refresh the catalogue snapshot from the shared transport's probe cache.
    pub async fn refresh(&self) -> Result<Reachability> {
        let fresh = Self::probe_reachability().await?;
        if let Ok(mut guard) = self.reachable.write() {
            *guard = fresh;
        }
        Ok(fresh)
    }

    async fn probe_reachability() -> Result<Reachability> {
        let (imbib, imprint, implore, impart) = tokio::join!(
            impress_app_transport::probe_app("imbib"),
            impress_app_transport::probe_app("imprint"),
            impress_app_transport::probe_app("implore"),
            impress_app_transport::probe_app("impart"),
        );
        Ok(Reachability {
            imbib,
            imprint,
            implore,
            impart,
        })
    }

    pub fn with_reachability(reachable: Reachability) -> Self {
        Self {
            reachable: std::sync::Arc::new(std::sync::RwLock::new(reachable)),
        }
    }

    fn snapshot(&self) -> Reachability {
        self.reachable
            .read()
            .map(|guard| *guard)
            .unwrap_or_default()
    }

    fn available(&self) -> impl Iterator<Item = VerbHandle> + '_ {
        let reachable = self.snapshot();
        call::descriptors()
            .filter(move |descriptor| Self::is_available_handle(reachable, descriptor))
    }

    #[cfg_attr(not(test), allow(dead_code))]
    fn is_available(&self, name: &str) -> bool {
        Self::is_available_with(self.snapshot(), name)
    }

    fn is_available_with(reachable: Reachability, name: &str) -> bool {
        match required_app(name) {
            Some("imbib") => reachable.imbib,
            Some("imprint") => reachable.imprint,
            Some("implore") => reachable.implore,
            Some("impart") => reachable.impart,
            Some(_) => false,
            None => true,
        }
    }

    fn is_available_handle(reachable: Reachability, handle: &VerbHandle) -> bool {
        (matches!(handle, VerbHandle::Provider(_))
            || Self::is_available_with(reachable, handle.name()))
            && handle.provider_status() != Some(ProviderStatus::Unavailable)
            && (!matches!(handle, VerbHandle::Provider(_)) || handle.deprecation_notice().is_none())
    }

    fn definitions(&self) -> BTreeMap<String, Vec<ToolDefinition>> {
        let scix =
            self.group_definition("scix", "NASA ADS/SciX search and library actions.", |h| {
                is_scix(h.name())
            });
        let mut impress = vec![self.capabilities_definition()];
        for (domain, description) in DOMAINS.iter().filter(|(domain, _)| *domain != "vw") {
            if let Some(definition) = self.group_definition(domain, description, |handle| {
                !is_scix(handle.name()) && belongs_to_domain_handle(handle, domain)
            }) {
                impress.push(definition);
            }
        }
        let mut catalog = BTreeMap::new();
        if let Some(scix) = scix {
            catalog.insert("scix".into(), vec![scix]);
        }
        catalog.insert("impress-mcp".into(), impress);
        if let Some(vw) = self.group_definition(
            "vw",
            "Search cited VW source pages and use deterministic VW Type 2 diagnostic services.",
            |handle| is_vw(handle.name()),
        ) {
            catalog.insert("vw".into(), vec![vw]);
        }
        catalog
    }

    fn capabilities_definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: CAPABILITIES_TOOL.into(),
            description:
                "Summarize the currently reachable Impress research-suite domains and actions."
                    .into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "domain": {
                        "type": "string",
                        "enum": DOMAINS.iter().map(|(domain, _)| *domain).collect::<Vec<_>>()
                    }
                }
            }),
        }
    }

    fn group_definition(
        &self,
        name: &str,
        description: &str,
        include: impl Fn(&VerbHandle) -> bool,
    ) -> Option<ToolDefinition> {
        let actions = self.actions(name, include);
        if actions.is_empty() {
            return None;
        }
        Some(ToolDefinition {
            name: name.into(),
            description: format!(
                "{description} Pass `describe: true` with an action to obtain its generated argument schema."
            ),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "action": { "type": "string", "enum": actions },
                    "args": { "type": "object" },
                    "describe": { "type": "boolean" }
                },
                "required": ["action"]
            }),
        })
    }

    fn actions(&self, group: &str, include: impl Fn(&VerbHandle) -> bool) -> Vec<String> {
        self.available()
            .filter(|descriptor| include(descriptor))
            .filter_map(|descriptor| action_of(descriptor.name(), group))
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    fn resolve(&self, group: &str, action: &str) -> Option<VerbHandle> {
        self.available().find(|descriptor| {
            let belongs = if group == "scix" {
                is_scix(descriptor.name())
            } else {
                !is_scix(descriptor.name()) && belongs_to_domain_handle(descriptor, group)
            };
            belongs && action_of(descriptor.name(), group).as_deref() == Some(action)
        })
    }

    fn capabilities(&self, requested_domain: Option<&str>) -> Value {
        if let Some(domain) = requested_domain {
            let actions = self
                .available()
                .filter(|descriptor| belongs_to_domain_handle(descriptor, domain))
                .filter_map(|descriptor| {
                    action_of(descriptor.name(), domain).map(|action| {
                        json!({
                            "action": action,
                            "description": descriptor.description(),
                            "tool": descriptor.name()
                        })
                    })
                })
                .collect::<Vec<_>>();
            return json!({ "domain": domain, "actions": actions });
        }
        let domains = DOMAINS
            .iter()
            .filter_map(|(domain, owns)| {
                let count = self
                    .available()
                    .filter(|descriptor| belongs_to_domain_handle(descriptor, domain))
                    .count();
                (count > 0).then(|| json!({ "domain": domain, "owns": owns, "actions": count }))
            })
            .collect::<Vec<_>>();
        json!({ "suite": "impress", "domains": domains })
    }
}

#[async_trait]
impl ToolAdapter for ImpressToolAdapter {
    fn catalog(&self) -> BTreeMap<String, Vec<ToolDefinition>> {
        self.definitions()
    }

    fn provider_id(&self, _tool_name: &str) -> String {
        "impress-service-inventory".into()
    }

    async fn call(&self, tool_name: &str, arguments: Value) -> Result<Value> {
        if tool_name == CAPABILITIES_TOOL {
            return Ok(self.capabilities(arguments.get("domain").and_then(Value::as_str)));
        }
        let action = arguments
            .get("action")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::Invalid(format!("{tool_name}: missing action")))?;
        let descriptor = self.resolve(tool_name, action).ok_or_else(|| {
            Error::Invalid(format!(
                "{tool_name}: unknown or unavailable action {action}"
            ))
        })?;
        if arguments.get("describe").and_then(Value::as_bool) == Some(true) {
            return Ok(json!({
                "tool": descriptor.name(),
                "action": action,
                "description": descriptor.description(),
                "inputSchema": descriptor.input_schema()
            }));
        }
        let inner = match arguments.get("args") {
            Some(Value::Object(values)) => Value::Object(values.clone()),
            Some(Value::Null) | None => Value::Object(Map::new()),
            Some(_) => {
                return Err(Error::Invalid(format!(
                    "{tool_name}: args must be an object"
                )))
            }
        };
        // The local model is an agent (ADR-0034 D3); the pipeline records
        // it as `impress-ai`, whatever the arguments claim.
        impress_service_core::pipeline::invoke_handle(
            descriptor.clone(),
            impress_service_core::pipeline::Call::agent("impress-ai", inner),
        )
        .await
        .map_err(|error| match error {
            impress_service_core::pipeline::PipelineError::Handler(e) => {
                Error::Invalid(format!("{} failed: {e}", descriptor.name()))
            }
            unavailable => Error::Invalid(unavailable.to_string()),
        })
    }
}

fn required_app(name: &str) -> Option<&'static str> {
    match name.split_once('_')?.0 {
        "imbib-app-service" => Some("imbib"),
        "imprint-app-service" => Some("imprint"),
        "implore-service" => Some("implore"),
        "impart-service" => Some("impart"),
        _ => None,
    }
}

fn is_scix(name: &str) -> bool {
    name.starts_with("imbib-scix-service_")
        || name.starts_with("smart-search-service_")
        || name == "imbib-app-service_search-sources"
}

fn is_vw(name: &str) -> bool {
    name.starts_with("vw-diagnostic-service_") || VW_SOURCE_READ_TOOLS.contains(&name)
}

fn belongs_to_domain(name: &str, domain: &str) -> bool {
    if domain == "vw" {
        is_vw(name)
    } else {
        domain_of(name) == Some(domain)
    }
}

fn belongs_to_domain_handle(handle: &VerbHandle, domain: &str) -> bool {
    if matches!(handle, VerbHandle::Provider(_)) {
        // The compact adapter has no provider namespace in its stable local
        // model contract. Runtime verbs live in the shared Impress group,
        // with their provider service prefix preserved in the action name.
        domain == "impress"
    } else {
        belongs_to_domain(handle.name(), domain)
    }
}

fn domain_of(name: &str) -> Option<&'static str> {
    let namespace = name.split_once('_')?.0;
    if namespace.starts_with("imbib-") {
        Some("imbib")
    } else if namespace.starts_with("imprint-") {
        Some("imprint")
    } else if namespace.starts_with("implore-") {
        Some("implore")
    } else if namespace.starts_with("impart-") {
        Some("impart")
    } else if matches!(
        namespace,
        "collection-service" | "triage-service" | "store-query-service" | "smart-search-service"
    ) {
        Some("store")
    } else if namespace == "docs-import-service" {
        Some("docs")
    } else if namespace.starts_with("impress-") || namespace == "parsers-service" {
        Some("impress")
    } else {
        None
    }
}

fn action_of(name: &str, group: &str) -> Option<String> {
    let (namespace, verb) = name.split_once('_')?;
    if group == "scix" {
        if name == "imbib-app-service_search-sources" {
            return Some("search-sources".into());
        }
        let service = namespace.strip_suffix("-service").unwrap_or(namespace);
        return Some(format!("{}.{}", service, verb));
    }
    let service = namespace.strip_suffix("-service").unwrap_or(namespace);
    let service = service
        .strip_prefix(&format!("{group}-"))
        .unwrap_or(service);
    if service.is_empty() || service == group {
        Some(verb.into())
    } else {
        Some(format!("{service}.{verb}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_service_core::{ProviderVerb, Safety, SafetyClass};
    use std::sync::Arc;

    fn provider(status: ProviderStatus) -> VerbHandle {
        VerbHandle::Provider(Arc::new(ProviderVerb {
            name: "fixture-service_echo".into(),
            service: "fixture-service".into(),
            method: "echo".into(),
            description: "Echo text".into(),
            input_schema: json!({"type":"object"}),
            output_schema: json!({"type":"object"}),
            declared_safety: Safety {
                class: SafetyClass::ReadOnly,
                idempotent: true,
            },
            effective_safety: Safety {
                class: SafetyClass::External,
                idempotent: false,
            },
            since: "0.1.0".into(),
            examples: vec![],
            provider_id: "fixture".into(),
            status,
            deprecated_since: None,
            generation: 1,
        }))
    }

    #[test]
    fn local_projection_is_small_and_generated() {
        let adapter = ImpressToolAdapter::with_reachability(Reachability::default());
        let catalog = adapter.catalog();
        assert!(catalog.contains_key("scix"));
        assert!(catalog.contains_key("impress-mcp"));
        assert!(catalog.contains_key("vw"));
        let count: usize = catalog.values().map(Vec::len).sum();
        assert!(
            count < 16,
            "grouped local surface unexpectedly has {count} tools"
        );
        assert!(call::descriptors().count() > 100);
    }

    #[tokio::test]
    async fn describe_returns_the_generated_schema_without_invoking() {
        let adapter = ImpressToolAdapter::with_reachability(Reachability::default());
        let result = adapter
            .call(
                "imbib",
                json!({ "action": "text.decode-latex", "describe": true }),
            )
            .await
            .unwrap();
        assert_eq!(result["inputSchema"]["type"], "object");
    }

    #[test]
    fn app_gated_tools_are_withheld_but_store_tools_remain() {
        let adapter = ImpressToolAdapter::with_reachability(Reachability::default());
        assert!(!adapter.is_available("imbib-app-service_search-sources"));
        assert!(adapter.is_available("imbib-library-service_list-libraries"));
        assert!(adapter.resolve("impress", "ai.list-models").is_some());
    }

    #[test]
    fn live_provider_projects_to_impress_group_and_unavailable_provider_is_withheld() {
        let live = provider(ProviderStatus::Available);
        assert!(belongs_to_domain_handle(&live, "impress"));
        assert!(!belongs_to_domain_handle(&live, "imbib"));
        assert_eq!(
            action_of(live.name(), "impress").as_deref(),
            Some("fixture.echo")
        );
        assert!(ImpressToolAdapter::is_available_handle(
            Reachability::default(),
            &live
        ));
        let down = provider(ProviderStatus::Unavailable);
        assert!(!ImpressToolAdapter::is_available_handle(
            Reachability::default(),
            &down
        ));
    }

    #[test]
    fn vw_projection_contains_diagnostics_and_read_only_sources() {
        let adapter = ImpressToolAdapter::with_reachability(Reachability::default());
        assert!(adapter
            .resolve("vw", "diagnostic.get-capabilities")
            .is_some());
        assert!(adapter
            .resolve("vw", "source.search-content-chunks")
            .is_some());
        assert!(adapter.resolve("vw", "source.get-content-chunk").is_some());
        assert!(adapter.resolve("vw", "source.get-citation").is_some());
        assert!(adapter.resolve("vw", "source.put-content-chunk").is_none());
    }

    #[tokio::test]
    async fn vw_projection_describes_the_generated_source_search_schema() {
        let adapter = ImpressToolAdapter::with_reachability(Reachability::default());
        let result = adapter
            .call(
                "vw",
                json!({
                    "action": "source.search-content-chunks",
                    "describe": true
                }),
            )
            .await
            .unwrap();
        assert_eq!(result["tool"], "source-service_search-content-chunks");
        assert_eq!(result["inputSchema"]["type"], "object");
        assert!(result["inputSchema"]["properties"]["query"].is_object());
    }
}
