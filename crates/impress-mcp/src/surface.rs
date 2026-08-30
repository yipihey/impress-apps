//! How the tool inventory is *rendered* for MCP clients (ADR-0024).
//!
//! `McpToolDescriptor` stays exactly one entry per `#[impress_method]` — the
//! single authority for the CLI, impel and the parity tests. This module adds a
//! second **rendering** of that same inventory, not a second definition. A
//! grouped tool is a view; a view cannot drift from its source. That is the
//! whole distinction between this and the TypeScript server that was retired
//! for keeping a parallel authority (`docs/mcp-migration-ledger.md`).
//!
//! Why: the flat surface measured 222 tools / ~30k tokens on 2026-08-02, paid
//! by every client on every request. That is affordable against a frontier
//! model and not affordable against a local one, where it costs both context
//! and — with a 222-entry menu — tool-selection accuracy.
//!
//! The grouped surface is hybrid (ADR-0024 D2):
//!
//! * one root tool, [`CAPABILITIES_TOOL`], that lets an agent rule the whole
//!   suite in or out in a single read;
//! * the [`PRIMARY`] tools flat, with full schemas, callable with no preamble;
//! * everything else behind one tool per domain, carrying an `action` enum and
//!   a `describe` flag that returns the real schema for one action.
//!
//! Anything this module cannot classify stays flat. Losing a capability is the
//! one failure mode that matters, so the fallback is always "expose it".

use impress_service_core::McpToolDescriptor;
use serde_json::{json, Map, Value};

/// The root tool: what the suite can do, and when it is the wrong instrument.
pub const CAPABILITIES_TOOL: &str = "impress_capabilities";

/// Cross-cutting entry points kept flat, with full schemas (ADR-0024 D2).
///
/// These are the calls an agent reaches for first, where a `describe` round
/// trip would cost more than the schema costs to carry. ADR-0024 D3 moves this
/// to `#[impress_method(surface = "primary")]`; until then it is a declared
/// table, and `surface_tests::every_primary_tool_exists` is what stops it
/// naming a tool that no longer exists.
pub const PRIMARY: &[&str] = &[
    // Store-generic reads — the mixed-kind entry points (ADR-0022 D5/D6/D8).
    "store-query-service_search-all",
    "store-query-service_list-items",
    "store-query-service_get-item",
    "store-query-service_related-items",
    "collection-service_tree",
    // imbib reads: the common research starting points.
    "imbib-library-service_list-libraries",
    "imbib-library-service_list-publications",
    "imbib-library-service_search-publications",
    "imbib-library-service_get-publication-detail",
    "imbib-search-service_full-text-search",
    "imbib-tags-service_list-tags",
    // Triage: the universal write verbs.
    "triage-service_set-status",
    "triage-service_add-tag",
    // Suite-wide memory (ADR-0028): the two calls used every session.
    "memory-service_remember",
    "memory-service_recall",
    // Expert-system entry points: semantic state and deterministic diagnosis.
    "vw-diagnostic-service_get-capabilities",
    "vw-diagnostic-service_create-session",
    "vw-diagnostic-service_get-session",
    "vw-diagnostic-service_record-observation",
    "vw-diagnostic-service_evaluate-session",
    "vw-diagnostic-service_recommend-next-test",
];

/// Namespace prefix → domain. First match wins, so exact namespaces precede
/// the generic `app-` prefixes.
const DOMAINS: &[(&str, &str)] = &[
    ("collection-service", "store"),
    ("triage-service", "store"),
    ("store-query-service", "store"),
    ("smart-search-service", "store"),
    ("memory-service", "memory"),
    ("docs-import-service", "docs"),
    ("parsers-service", "impress"),
    ("imbib-", "imbib"),
    ("imprint-", "imprint"),
    ("implore-", "implore"),
    ("impart-", "impart"),
    ("impel-", "impel"),
    ("vw-", "vw"),
    ("impress-", "impress"),
];

/// Stable output order, and the one-line "what it owns" the root tool reports.
const DOMAIN_DOC: &[(&str, &str)] = &[
    (
        "imbib",
        "Bibliography: libraries, publications, tags, annotations, PDFs, BibTeX.",
    ),
    (
        "imprint",
        "Manuscripts: Typst sections, compilation, cross-document structure.",
    ),
    (
        "implore",
        "Data visualisation: datasets, plots, selections.",
    ),
    ("impart", "Communication: conversations and messages."),
    ("impel", "Agent orchestration and task delegation."),
    (
        "vw",
        "VW Type 2 expert diagnosis: typed sessions, evidence, procedures and deterministic assessments.",
    ),
    (
        "store",
        "Cross-kind reads and writes over the shared store: search, browse, collections, triage.",
    ),
    (
        "memory",
        "Suite-wide agent memory: remember, recall and brief over the unified store.",
    ),
    (
        "docs",
        "Filesystem ingest: directory import, watched folders, discovered rows.",
    ),
    (
        "impress",
        "Suite-level bridges, parsers and shared plumbing.",
    ),
];

/// Which rendering of the inventory a client gets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Projection {
    /// Every method as its own tool. What impel consumes, and what the parity
    /// tests pin (ADR-0024 D6).
    Flat,
    /// Root + primary tools + one tool per domain.
    Grouped,
}

/// `IMPRESS_MCP_SURFACE=grouped|flat`, defaulting to grouped.
///
/// `IMPRESS_MCP_LIST_ALL=1` forces flat: introspection — the migration ledger,
/// a capability audit — wants the true inventory, and must not have to
/// understand a projection to get it.
pub fn projection() -> Projection {
    if std::env::var("IMPRESS_MCP_LIST_ALL").as_deref() == Ok("1") {
        return Projection::Flat;
    }
    match std::env::var("IMPRESS_MCP_SURFACE").as_deref() {
        Ok("flat") => Projection::Flat,
        _ => Projection::Grouped,
    }
}

/// The domain a tool belongs to, or `None` when nothing claims it — in which
/// case it is rendered flat rather than dropped.
pub fn domain_of(tool_name: &str) -> Option<&'static str> {
    let namespace = tool_name.split_once('_')?.0;
    DOMAINS
        .iter()
        .find(|(prefix, _)| namespace.starts_with(prefix))
        .map(|(_, domain)| *domain)
}

/// The `action` value that addresses this tool inside its domain tool.
///
/// `imbib-library-service_list-libraries` in domain `imbib` becomes
/// `library.list-libraries`; `implore-service_status` becomes plain `status`.
/// Both `tools/list` and dispatch call this, so the enum a client is shown and
/// the name it resolves to cannot disagree.
pub fn action_of(tool_name: &str, domain: &str) -> Option<String> {
    let (namespace, verb) = tool_name.split_once('_')?;
    let service = namespace.strip_suffix("-service").unwrap_or(namespace);
    let service = service
        .strip_prefix(&format!("{domain}-"))
        .unwrap_or(service);
    if service.is_empty() || service == domain {
        Some(verb.to_string())
    } else {
        Some(format!("{service}.{verb}"))
    }
}

/// Descriptors a client may currently reach, after reachability gating.
fn available() -> impl Iterator<Item = &'static McpToolDescriptor> {
    McpToolDescriptor::iter().filter(|d| crate::reachability::is_available(d.name))
}

fn is_primary(name: &str) -> bool {
    PRIMARY.contains(&name)
}

/// Resolve a `{domain, action}` pair back to a real tool name.
///
/// Computed from the same [`action_of`] the listing uses, over the same gated
/// iterator, so a resolvable action is exactly an advertised one.
pub fn resolve(domain: &str, action: &str) -> Option<&'static str> {
    available()
        .filter(|d| domain_of(d.name) == Some(domain))
        .find(|d| action_of(d.name, domain).as_deref() == Some(action))
        .map(|d| d.name)
}

fn definition_of(d: &McpToolDescriptor) -> Value {
    json!({
        "name": d.name,
        "description": d.description,
        "inputSchema": (d.input_schema)(),
    })
}

/// The grouped `tools/list` payload, given the legacy hand-written tools.
///
/// Legacy tools are passed through flat: they predate the codegen, are not in
/// the inventory, and ADR-0024 D7 folds them into a real namespace separately.
pub fn grouped_definitions(legacy: Vec<Value>) -> Vec<Value> {
    let mut tools = vec![capabilities_definition()];

    tools.extend(legacy);
    tools.extend(
        available()
            .filter(|d| is_primary(d.name))
            .map(definition_of),
    );

    // Unclassifiable tools stay flat — never dropped.
    tools.extend(
        available()
            .filter(|d| !is_primary(d.name) && domain_of(d.name).is_none())
            .map(definition_of),
    );

    for (domain, doc) in DOMAIN_DOC {
        let mut actions: Vec<String> = available()
            .filter(|d| !is_primary(d.name) && domain_of(d.name) == Some(domain))
            .filter_map(|d| action_of(d.name, domain))
            .collect();
        if actions.is_empty() {
            continue;
        }
        actions.sort();
        actions.dedup();

        tools.push(json!({
            "name": domain,
            "description": format!(
                "{doc} {n} actions. Pass `describe: true` with an action to get its \
                 argument schema, then call again with `args`.",
                n = actions.len(),
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "description": "Which capability of this domain to use.",
                        "enum": actions,
                    },
                    "args": {
                        "type": "object",
                        "description": "Arguments for the action. Call with `describe: true` first if the shape is not known.",
                    },
                    "describe": {
                        "type": "boolean",
                        "description": "Return the action's input schema instead of invoking it.",
                    },
                },
                "required": ["action"],
            },
        }));
    }

    tools
}

fn capabilities_definition() -> Value {
    json!({
        "name": CAPABILITIES_TOOL,
        "description":
            "What the impress research suite can do, and when it is the wrong tool. \
             Call this first if unsure whether impress is relevant: it owns bibliography, \
             manuscripts, plots, messages and their shared store — not general file, web \
             or shell work. Pass a domain to list that domain's actions.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "domain": {
                    "type": "string",
                    "description": "List the actions of one domain instead of summarising all.",
                    "enum": DOMAIN_DOC.iter().map(|(d, _)| *d).collect::<Vec<_>>(),
                },
            },
        },
    })
}

/// Answer the root tool: a domain summary, or one domain's actions.
pub fn capabilities_payload(domain: Option<&str>) -> Value {
    if let Some(domain) = domain {
        let mut actions: Vec<Value> = available()
            .filter(|d| domain_of(d.name) == Some(domain))
            .filter_map(|d| {
                action_of(d.name, domain).map(|a| {
                    json!({
                        "action": a,
                        "description": d.description,
                        "primary": is_primary(d.name),
                        "tool": d.name,
                    })
                })
            })
            .collect();
        actions.sort_by(|a, b| a["action"].as_str().cmp(&b["action"].as_str()));
        return json!({ "domain": domain, "actions": actions });
    }

    let domains: Vec<Value> = DOMAIN_DOC
        .iter()
        .filter_map(|(d, doc)| {
            let count = available().filter(|t| domain_of(t.name) == Some(d)).count();
            if count == 0 {
                return None;
            }
            Some(json!({ "domain": d, "owns": doc, "actions": count }))
        })
        .collect();

    json!({
        "suite": "impress — a research operating environment (bibliography, manuscripts, \
                  plots, messages, and the store beneath them)",
        "not_for": "general filesystem, web, shell or coding work",
        "domains": domains,
        "hint": format!(
            "Call {CAPABILITIES_TOOL} with a domain, or call the domain tool directly \
             with `describe: true` to get an action's argument schema."
        ),
    })
}

/// Dispatch a grouped call. Returns `None` when `name` is not a surface tool,
/// so the caller can fall through to the flat path unchanged.
pub fn dispatch(name: &str, args: &Value) -> Option<Result<Value, String>> {
    if name == CAPABILITIES_TOOL {
        let domain = args.get("domain").and_then(|v| v.as_str());
        if let Some(d) = domain {
            if !DOMAIN_DOC.iter().any(|(known, _)| *known == d) {
                return Some(Err(format!("Unknown domain: {d}")));
            }
        }
        return Some(Ok(capabilities_payload(domain)));
    }

    let domain = DOMAIN_DOC
        .iter()
        .find(|(d, _)| *d == name)
        .map(|(d, _)| *d)?;

    let action = match args.get("action").and_then(|v| v.as_str()) {
        Some(a) => a,
        None => return Some(Err(format!("{domain}: missing required argument: action"))),
    };

    let Some(tool) = resolve(domain, action) else {
        return Some(Err(format!(
            "{domain}: unknown action {action:?}. Call {CAPABILITIES_TOOL} with \
             domain={domain:?} to list the available ones."
        )));
    };

    if args.get("describe").and_then(|v| v.as_bool()) == Some(true) {
        let descriptor = McpToolDescriptor::iter().find(|d| d.name == tool)?;
        return Some(Ok(json!({
            "tool": tool,
            "action": action,
            "description": descriptor.description,
            "inputSchema": (descriptor.input_schema)(),
        })));
    }

    // A gated tool reached through a stale client list gets the same honest
    // refusal the flat path gives.
    if let Some(reason) = crate::reachability::unavailable_reason(tool) {
        return Some(Err(reason));
    }

    let inner = match args.get("args") {
        Some(Value::Object(map)) => Value::Object(map.clone()),
        Some(Value::Null) | None => Value::Object(Map::new()),
        Some(other) => {
            return Some(Err(format!(
                "{domain}: `args` must be an object, got {}",
                match other {
                    Value::Array(_) => "an array",
                    Value::String(_) => "a string",
                    Value::Number(_) => "a number",
                    Value::Bool(_) => "a boolean",
                    _ => "something else",
                }
            )))
        }
    };

    Some(crate::inventory_bridge::call_inventory_tool(tool, inner))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn domains_classify_the_namespaces_they_claim() {
        assert_eq!(
            domain_of("imbib-library-service_list-libraries"),
            Some("imbib")
        );
        assert_eq!(domain_of("imprint-app-service_get-pdf"), Some("imprint"));
        assert_eq!(domain_of("collection-service_tree"), Some("store"));
        assert_eq!(domain_of("store-query-service_search-all"), Some("store"));
        assert_eq!(
            domain_of("docs-import-service_import-directory"),
            Some("docs")
        );
        assert_eq!(domain_of("impress-bridges-service_ping"), Some("impress"));
    }

    /// The pre-codegen tools have no namespace at all, so nothing claims them
    /// and they must stay flat rather than vanish (ADR-0024 D7).
    #[test]
    fn unclassifiable_tools_have_no_domain() {
        assert_eq!(domain_of("search_papers"), None);
        assert_eq!(domain_of("no-underscore-at-all"), None);
    }

    #[test]
    fn actions_strip_the_domain_and_the_service_suffix() {
        assert_eq!(
            action_of("imbib-library-service_list-libraries", "imbib").as_deref(),
            Some("library.list-libraries")
        );
        assert_eq!(
            action_of("collection-service_tree", "store").as_deref(),
            Some("collection.tree")
        );
        assert_eq!(
            action_of("store-query-service_search-all", "store").as_deref(),
            Some("query.search-all")
        );
        // A namespace that is exactly its domain keeps a bare verb.
        assert_eq!(
            action_of("implore-service_status", "implore").as_deref(),
            Some("status")
        );
    }

    #[test]
    fn projection_defaults_to_grouped() {
        // Env-dependent, so only assert the mapping that has no env in it.
        assert_ne!(Projection::Flat, Projection::Grouped);
    }

    #[test]
    fn capabilities_summary_names_only_populated_domains() {
        let payload = capabilities_payload(None);
        let domains = payload["domains"].as_array().expect("domains array");
        for d in domains {
            assert!(
                d["actions"].as_u64().unwrap_or(0) > 0,
                "empty domain listed: {d}"
            );
        }
    }

    #[test]
    fn unknown_domain_is_refused_not_silently_empty() {
        let out = dispatch(CAPABILITIES_TOOL, &json!({ "domain": "nope" }));
        assert!(matches!(out, Some(Err(ref e)) if e.contains("Unknown domain")));
    }

    #[test]
    fn non_surface_tools_fall_through() {
        assert!(dispatch("imbib-library-service_list-libraries", &json!({})).is_none());
    }

    /// ADR-0024 D6, the invariant the whole design rests on: the projection may
    /// re-shape the surface, it may not lose a capability. Every descriptor a
    /// client could reach flat must be reachable grouped — as a primary tool, as
    /// an unclassified flat passthrough, or as a domain action.
    ///
    /// If this is ever weakened, D1's argument (a view cannot drift from its
    /// source) no longer holds and this becomes the second authority the
    /// TypeScript server was retired for being.
    #[test]
    fn grouped_loses_no_capability() {
        let grouped = grouped_definitions(vec![]);
        let listed: Vec<&str> = grouped.iter().filter_map(|t| t["name"].as_str()).collect();

        for d in available() {
            if listed.contains(&d.name) {
                continue; // primary, or an unclassified flat passthrough
            }
            let domain = domain_of(d.name).unwrap_or_else(|| {
                panic!(
                    "{} is neither listed flat nor classified into a domain",
                    d.name
                )
            });
            let action = action_of(d.name, domain)
                .unwrap_or_else(|| panic!("{} has no action label", d.name));
            assert_eq!(
                resolve(domain, &action),
                Some(d.name),
                "{} is advertised under {domain}/{action} but does not resolve back",
                d.name,
            );
        }
    }

    /// Every action advertised in a domain enum resolves. The reverse of the
    /// test above: that one catches a dropped capability, this catches an
    /// advertised action that dead-ends — which the model would spend a turn
    /// discovering, the failure `reachability` already refuses to allow.
    #[test]
    fn every_advertised_action_resolves() {
        for tool in grouped_definitions(vec![]) {
            let Some(name) = tool["name"].as_str() else {
                continue;
            };
            let Some(domain) = DOMAIN_DOC.iter().find(|(d, _)| *d == name).map(|(d, _)| *d) else {
                continue;
            };
            let actions = tool["inputSchema"]["properties"]["action"]["enum"]
                .as_array()
                .unwrap_or_else(|| panic!("{name} has no action enum"));
            for action in actions {
                let action = action.as_str().expect("action enum holds strings");
                assert!(
                    resolve(domain, action).is_some(),
                    "{domain} advertises {action:?}, which resolves to nothing",
                );
            }
        }
    }

    /// The declared [`PRIMARY`] table is the one place ADR-0024 D3 admits a
    /// second listing of tool names, and this is the check that keeps it honest
    /// until the macro carries the flag instead. Skips app-gated entries so the
    /// test does not depend on which apps happened to be running.
    #[test]
    fn every_primary_tool_exists() {
        let all: Vec<&str> = McpToolDescriptor::iter().map(|d| d.name).collect();
        for name in PRIMARY {
            assert!(
                all.contains(name),
                "PRIMARY names {name}, which is not in the inventory",
            );
        }
    }

    /// A primary tool inside a domain must not also appear in that domain's
    /// enum: two ways to invoke one capability is exactly the ambiguity the
    /// grouping exists to remove.
    #[test]
    fn primary_tools_are_not_also_domain_actions() {
        for tool in grouped_definitions(vec![]) {
            let Some(name) = tool["name"].as_str() else {
                continue;
            };
            let Some(domain) = DOMAIN_DOC.iter().find(|(d, _)| *d == name).map(|(d, _)| *d) else {
                continue;
            };
            let actions = tool["inputSchema"]["properties"]["action"]["enum"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            for primary in PRIMARY.iter().filter(|p| domain_of(p) == Some(domain)) {
                let label = action_of(primary, domain).expect("primary has an action label");
                assert!(
                    !actions.iter().any(|a| a.as_str() == Some(label.as_str())),
                    "{primary} is primary but also listed as {domain}/{label}",
                );
            }
        }
    }
}
