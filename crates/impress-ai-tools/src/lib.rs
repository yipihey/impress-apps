//! A compact local-model view of the generated Impress service inventory.
//!
//! Definitions and handlers remain owned by `#[impress_service]`. This crate
//! only groups that inventory into policy buckets and domain/action tools so a
//! local model does not spend its context window on hundreds of flat schemas.

use std::collections::{BTreeMap, BTreeSet};

use async_trait::async_trait;
use impress_ai::{Error, Result, ToolAdapter, ToolDefinition};
use impress_service_core::McpToolDescriptor;
use serde_json::{json, Map, Value};

// Keep inventory submissions linked into every consumer of this adapter.
#[allow(unused_imports)]
use imbib_service as _force_link_imbib;
#[allow(unused_imports)]
use impart_service as _force_link_impart;
#[allow(unused_imports)]
use implore_service as _force_link_implore;
#[allow(unused_imports)]
use impress_ai_service as _force_link_ai;
#[allow(unused_imports)]
use impress_bridges_service as _force_link_bridges;
#[allow(unused_imports)]
use impress_parsers_service as _force_link_parsers;
#[allow(unused_imports)]
use impress_smart_search_service as _force_link_smart_search;
#[allow(unused_imports)]
use impress_store_service as _force_link_store;
#[allow(unused_imports)]
use imprint_service as _force_link_imprint;
#[allow(unused_imports)]
use vw_impress_adapter as _force_link_vw;

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
    reachable: Reachability,
}

impl ImpressToolAdapter {
    /// Probe sibling automation services without blocking the async executor.
    /// Store-backed and pure tools remain available when every app is closed.
    pub async fn probe() -> Result<Self> {
        let reachable = tokio::task::spawn_blocking(|| Reachability {
            imbib: imbib_service_http::maybe_install_http_backend(),
            imprint: imprint_service_http::maybe_install_http_backend(),
            implore: implore_service_http::maybe_install_http_backend(),
            impart: impart_service_http::maybe_install_http_backend(),
        })
        .await
        .map_err(|error| Error::Invalid(format!("tool backend probe failed: {error}")))?;
        Ok(Self { reachable })
    }

    pub fn with_reachability(reachable: Reachability) -> Self {
        Self { reachable }
    }

    fn available(&self) -> impl Iterator<Item = &'static McpToolDescriptor> + '_ {
        McpToolDescriptor::iter().filter(|descriptor| self.is_available(descriptor.name))
    }

    fn is_available(&self, name: &str) -> bool {
        match required_app(name) {
            Some("imbib") => self.reachable.imbib,
            Some("imprint") => self.reachable.imprint,
            Some("implore") => self.reachable.implore,
            Some("impart") => self.reachable.impart,
            Some(_) => false,
            None => true,
        }
    }

    fn definitions(&self) -> BTreeMap<String, Vec<ToolDefinition>> {
        let scix =
            self.group_definition("scix", "NASA ADS/SciX search and library actions.", is_scix);
        let mut impress = vec![self.capabilities_definition()];
        for (domain, description) in DOMAINS.iter().filter(|(domain, _)| *domain != "vw") {
            if let Some(definition) = self.group_definition(domain, description, |name| {
                !is_scix(name) && belongs_to_domain(name, domain)
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
            is_vw,
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
        include: impl Fn(&str) -> bool,
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

    fn actions(&self, group: &str, include: impl Fn(&str) -> bool) -> Vec<String> {
        self.available()
            .filter(|descriptor| include(descriptor.name))
            .filter_map(|descriptor| action_of(descriptor.name, group))
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    fn resolve(&self, group: &str, action: &str) -> Option<&'static McpToolDescriptor> {
        self.available().find(|descriptor| {
            let belongs = if group == "scix" {
                is_scix(descriptor.name)
            } else {
                !is_scix(descriptor.name) && belongs_to_domain(descriptor.name, group)
            };
            belongs && action_of(descriptor.name, group).as_deref() == Some(action)
        })
    }

    fn capabilities(&self, requested_domain: Option<&str>) -> Value {
        if let Some(domain) = requested_domain {
            let actions = self
                .available()
                .filter(|descriptor| belongs_to_domain(descriptor.name, domain))
                .filter_map(|descriptor| {
                    action_of(descriptor.name, domain).map(|action| {
                        json!({
                            "action": action,
                            "description": descriptor.description,
                            "tool": descriptor.name
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
                    .filter(|descriptor| belongs_to_domain(descriptor.name, domain))
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
                "tool": descriptor.name,
                "action": action,
                "description": descriptor.description,
                "inputSchema": (descriptor.input_schema)()
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
        (descriptor.handler)(inner)
            .await
            .map_err(|error| Error::Invalid(format!("{} failed: {error}", descriptor.name)))
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
        assert!(McpToolDescriptor::iter().count() > 100);
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
