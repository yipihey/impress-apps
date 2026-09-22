//! `validate(&SurfaceSpec) -> Vec<Problem>`: every reason a spec is not
//! well-formed, named by path, so an authoring agent (or `surface_validate`, S4)
//! can fix each one without a screenshot. Never panics on a malformed spec — a
//! spec is data, and the whole point of this function is to describe what is
//! wrong with it rather than crash on it.
//!
//! Checks, in the order `docs/plan-agent-surfaces.md` (S1) lists them:
//!
//! 1. `surface` is exactly [`SURFACE_VERSION`].
//! 2. `state` is a JSON object.
//! 3. Every `bind` and `set.path` starts with `state.`.
//! 4. Every template reference's root is one of `state`/`param`/`source`/`event`,
//!    and a `state.…` reference's top-level key exists in `state`.
//! 5. Every `source.<name>` reference names a declared source.
//! 6. Source `args` form no dependency cycle.
//! 7. Node ids (given or auto-derived, [`node_id`]) are unique.
//! 8. A `select` field's `options` are non-empty.
//! 9. `grid.columns >= 1`.
//! 10. Every verb name matches `^[a-z0-9-]+_[a-z0-9-]+$`.
//!
//! What this function does **not** check: whether a verb exists, whether a query
//! compiles, whether a state path a `bind` names actually has a value yet. Those
//! need a store or a live inventory; this module is pure, like the rest of the
//! crate.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use crate::spec::{Action, FieldKind, Node, NodeKind, Source, SurfaceSpec, Table, SURFACE_VERSION};
use crate::template::{source_refs_in, Template};

/// One thing wrong with a spec: `path` is a JSON-pointer-flavoured location
/// (`/sources/hist/args`, `/root/column/1/field/select/options`), not a strict
/// RFC 6901 pointer — good enough to point an agent at the spot, which is the
/// whole job.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Problem {
    pub path: String,
    pub message: String,
}

impl Problem {
    fn new(path: impl Into<String>, message: impl Into<String>) -> Self {
        Problem {
            path: path.into(),
            message: message.into(),
        }
    }
}

/// See the module docs for the full list of checks.
pub fn validate(spec: &SurfaceSpec) -> Vec<Problem> {
    let mut problems = Vec::new();

    if spec.surface != SURFACE_VERSION {
        problems.push(Problem::new(
            "/surface",
            format!(
                "unsupported surface version '{}', this build understands '{SURFACE_VERSION}'",
                spec.surface
            ),
        ));
    }

    if !spec.state.is_object() {
        problems.push(Problem::new("/state", "`state` must be a JSON object"));
    }

    let state_keys: BTreeSet<&str> = spec
        .state
        .as_object()
        .map(|m| m.keys().map(String::as_str).collect())
        .unwrap_or_default();

    // ── sources: declared names, verb-name shape, dependency cycles ────────
    let declared_sources: BTreeSet<&str> = spec.sources.keys().map(String::as_str).collect();
    let mut deps: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    for (name, source) in &spec.sources {
        match source {
            Source::Verb { verb, args } => {
                let path = format!("/sources/{name}/verb");
                check_verb_name(verb, &path, &mut problems);
                deps.insert(name.as_str(), source_refs_in(args));
                check_template_refs(
                    args,
                    &format!("/sources/{name}/args"),
                    &state_keys,
                    &declared_sources,
                    &mut problems,
                );
            }
            Source::Value { .. } => {
                deps.insert(name.as_str(), Vec::new());
            }
            Source::Query { .. } => {
                // `PaneQuery` params are filled from pane channel bindings, not
                // from this crate's template roots, so there is nothing here to
                // scan for `source.…`/`state.…` references.
                deps.insert(name.as_str(), Vec::new());
            }
        }
    }
    for (name, refs) in &deps {
        for r in refs {
            if !declared_sources.contains(r.as_str()) {
                problems.push(Problem::new(
                    format!("/sources/{name}/args"),
                    format!("references undeclared source '{r}'"),
                ));
            }
        }
    }
    for name in find_cycle(&deps) {
        problems.push(Problem::new(
            format!("/sources/{name}"),
            "participates in a source dependency cycle",
        ));
    }

    // ── the tree: ids, binds, template refs, per-kind invariants ───────────
    let mut ids: BTreeMap<String, usize> = BTreeMap::new();
    for (id, _) in crate::spec::walk_with_ids(&spec.root) {
        *ids.entry(id).or_insert(0) += 1;
    }
    for (id, count) in &ids {
        if *count > 1 {
            problems.push(Problem::new(
                "/root",
                format!("node id '{id}' is used by {count} nodes"),
            ));
        }
    }

    walk_node(
        &spec.root,
        "/root".to_string(),
        &state_keys,
        &declared_sources,
        &mut problems,
    );

    problems
}

fn check_verb_name(verb: &str, path: &str, problems: &mut Vec<Problem>) {
    let parts: Vec<&str> = verb.split('_').collect();
    let ok = parts.len() == 2
        && parts.iter().all(|p| {
            !p.is_empty()
                && p.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        });
    if !ok {
        problems.push(Problem::new(
            path,
            format!("verb name '{verb}' does not match ^[a-z0-9-]+_[a-z0-9-]+$"),
        ));
    }
}

fn check_bind_or_set_path(path_value: &str, at: &str, problems: &mut Vec<Problem>) {
    if !path_value.starts_with("state.") {
        problems.push(Problem::new(
            at,
            format!("path '{path_value}' must start with 'state.'"),
        ));
    }
}

/// Scan every string inside `value` for template references and check their
/// roots (and, for `state`, the top-level key).
fn check_template_refs(
    value: &Value,
    at: &str,
    state_keys: &BTreeSet<&str>,
    declared_sources: &BTreeSet<&str>,
    problems: &mut Vec<Problem>,
) {
    match value {
        Value::String(s) => {
            for path in reference_paths(s) {
                check_reference_path(&path, at, state_keys, declared_sources, problems);
            }
        }
        Value::Array(items) => {
            for item in items {
                check_template_refs(item, at, state_keys, declared_sources, problems);
            }
        }
        Value::Object(map) => {
            for v in map.values() {
                check_template_refs(v, at, state_keys, declared_sources, problems);
            }
        }
        _ => {}
    }
}

fn reference_paths(s: &str) -> Vec<Vec<String>> {
    match Template::parse(s) {
        crate::template::Template::Literal(_) => Vec::new(),
        crate::template::Template::Single(p) => vec![p],
        crate::template::Template::Mixed(segments) => segments
            .into_iter()
            .filter_map(|seg| match seg {
                crate::template::Segment::Ref(p) => Some(p),
                crate::template::Segment::Literal(_) => None,
            })
            .collect(),
    }
}

fn check_reference_path(
    path: &[String],
    at: &str,
    state_keys: &BTreeSet<&str>,
    declared_sources: &BTreeSet<&str>,
    problems: &mut Vec<Problem>,
) {
    let Some(root) = path.first() else {
        return;
    };
    match root.as_str() {
        "state" => {
            if let Some(key) = path.get(1) {
                if !state_keys.contains(key.as_str()) {
                    problems.push(Problem::new(
                        at,
                        format!(
                            "'{}' references state key '{key}', which `state` does not declare",
                            path.join(".")
                        ),
                    ));
                }
            }
        }
        "source" => {
            if let Some(name) = path.get(1) {
                if !declared_sources.contains(name.as_str()) {
                    problems.push(Problem::new(
                        at,
                        format!("'{}' references undeclared source '{name}'", path.join(".")),
                    ));
                }
            }
        }
        "param" | "event" => {}
        other => problems.push(Problem::new(
            at,
            format!("'{}' has unknown root '{other}'", path.join(".")),
        )),
    }
}

fn walk_node(
    node: &Node,
    at: String,
    state_keys: &BTreeSet<&str>,
    declared_sources: &BTreeSet<&str>,
    problems: &mut Vec<Problem>,
) {
    if let Some(bind) = &node.bind {
        check_bind_or_set_path(bind, &format!("{at}/bind"), problems);
    }
    for (label, actions) in [
        ("on_change", &node.on_change),
        ("on_submit", &node.on_submit),
    ] {
        check_actions(
            actions,
            &format!("{at}/{label}"),
            state_keys,
            declared_sources,
            problems,
        );
    }
    if let Some(when) = &node.when {
        // `when.path` is a literal dotted path (`state.x`), not a `{{…}}`
        // template — `resolve.rs`'s `when_is_true` reads it the same way, by
        // wrapping it before handing it to `Template::parse`. Checked directly
        // against the same root/state-key rules a template reference gets
        // (`check_reference_path`), rather than through `check_template_refs`
        // (which only finds `{{…}}` occurrences and would silently skip a bare
        // path with none).
        let segments: Vec<String> = when.path.split('.').map(str::to_string).collect();
        check_reference_path(
            &segments,
            &format!("{at}/when/path"),
            state_keys,
            declared_sources,
            problems,
        );
    }
    if let Some(label) = &node.label {
        check_template_refs(
            &Value::String(label.clone()),
            &format!("{at}/label"),
            state_keys,
            declared_sources,
            problems,
        );
    }

    match &node.kind {
        NodeKind::Column(items) => {
            for (i, child) in items.iter().enumerate() {
                walk_node(
                    child,
                    format!("{at}/column/{i}"),
                    state_keys,
                    declared_sources,
                    problems,
                );
            }
        }
        NodeKind::Row(items) => {
            for (i, child) in items.iter().enumerate() {
                walk_node(
                    child,
                    format!("{at}/row/{i}"),
                    state_keys,
                    declared_sources,
                    problems,
                );
            }
        }
        NodeKind::Grid(g) => {
            if g.columns < 1 {
                problems.push(Problem::new(
                    format!("{at}/grid/columns"),
                    "grid.columns must be >= 1",
                ));
            }
            for (i, child) in g.items.iter().enumerate() {
                walk_node(
                    child,
                    format!("{at}/grid/items/{i}"),
                    state_keys,
                    declared_sources,
                    problems,
                );
            }
        }
        NodeKind::Section(s) => {
            walk_node(
                &s.body,
                format!("{at}/section/body"),
                state_keys,
                declared_sources,
                problems,
            );
        }
        NodeKind::Tabs(tabs) => {
            for (i, tab) in tabs.iter().enumerate() {
                walk_node(
                    &tab.body,
                    format!("{at}/tabs/{i}/body"),
                    state_keys,
                    declared_sources,
                    problems,
                );
            }
        }
        NodeKind::Text(s) => {
            check_template_refs(
                &Value::String(s.clone()),
                &format!("{at}/text"),
                state_keys,
                declared_sources,
                problems,
            );
        }
        NodeKind::Table(Table {
            rows, on_select, ..
        }) => {
            check_template_refs(
                rows,
                &format!("{at}/table/rows"),
                state_keys,
                declared_sources,
                problems,
            );
            check_actions(
                on_select,
                &format!("{at}/table/on_select"),
                state_keys,
                declared_sources,
                problems,
            );
        }
        NodeKind::List(l) => {
            check_template_refs(
                &l.rows,
                &format!("{at}/list/rows"),
                state_keys,
                declared_sources,
                problems,
            );
            check_actions(
                &l.on_select,
                &format!("{at}/list/on_select"),
                state_keys,
                declared_sources,
                problems,
            );
        }
        NodeKind::Plot(p) => {
            check_template_refs(
                &p.spec,
                &format!("{at}/plot/spec"),
                state_keys,
                declared_sources,
                problems,
            );
        }
        NodeKind::Image(img) => {
            if let Some(v) = &img.blob {
                check_template_refs(
                    v,
                    &format!("{at}/image/blob"),
                    state_keys,
                    declared_sources,
                    problems,
                );
            }
            if let Some(v) = &img.url {
                check_template_refs(
                    v,
                    &format!("{at}/image/url"),
                    state_keys,
                    declared_sources,
                    problems,
                );
            }
        }
        NodeKind::Field(f) => {
            if let FieldKind::Select(v) = f {
                let non_empty = v
                    .get("options")
                    .and_then(Value::as_array)
                    .map(|a| !a.is_empty())
                    .unwrap_or(false);
                if !non_empty {
                    problems.push(Problem::new(
                        format!("{at}/field/select/options"),
                        "a select field's options must be a non-empty array",
                    ));
                }
            }
        }
        NodeKind::Button(b) => {
            check_actions(
                &b.on_click,
                &format!("{at}/button/on_click"),
                state_keys,
                declared_sources,
                problems,
            );
        }
        NodeKind::Status(s) => {
            check_template_refs(
                &s.message,
                &format!("{at}/status/message"),
                state_keys,
                declared_sources,
                problems,
            );
        }
        NodeKind::Log(v) | NodeKind::Kv(v) => {
            check_template_refs(
                v,
                &format!("{at}/{}", node.kind_name()),
                state_keys,
                declared_sources,
                problems,
            );
        }
        NodeKind::Divider | NodeKind::Spacer => {}
        NodeKind::Unknown { kind, .. } => {
            problems.push(Problem::new(
                at.clone(),
                format!("unrecognized node kind '{kind}' (kept as a placeholder at render time)"),
            ));
        }
    }
}

fn check_actions(
    actions: &[Action],
    at: &str,
    state_keys: &BTreeSet<&str>,
    declared_sources: &BTreeSet<&str>,
    problems: &mut Vec<Problem>,
) {
    for (i, action) in actions.iter().enumerate() {
        let at = format!("{at}/{i}");
        match action {
            Action::Set { path, value } => {
                check_bind_or_set_path(path, &format!("{at}/set/path"), problems);
                check_template_refs(
                    value,
                    &format!("{at}/set/value"),
                    state_keys,
                    declared_sources,
                    problems,
                );
            }
            Action::Call { verb, args, .. } => {
                check_verb_name(verb, &format!("{at}/call/verb"), problems);
                check_template_refs(
                    args,
                    &format!("{at}/call/args"),
                    state_keys,
                    declared_sources,
                    problems,
                );
            }
            Action::Publish { ids } => {
                if let Some(ids) = ids {
                    check_bind_or_set_path(ids, &format!("{at}/publish/ids"), problems);
                }
            }
            Action::Emit { payload, .. } => {
                check_template_refs(
                    payload,
                    &format!("{at}/emit/payload"),
                    state_keys,
                    declared_sources,
                    problems,
                );
            }
            Action::Open { query, .. } => {
                check_template_refs(
                    query,
                    &format!("{at}/open/query"),
                    state_keys,
                    declared_sources,
                    problems,
                );
            }
            Action::Refresh { source } => {
                if !declared_sources.contains(source.as_str()) {
                    problems.push(Problem::new(
                        format!("{at}/refresh/source"),
                        format!("refreshes undeclared source '{source}'"),
                    ));
                }
            }
        }
    }
}

/// Every source name that participates in a dependency cycle (empty if the
/// graph is a DAG). A three-colour DFS: white (unvisited), grey (on the
/// current path), black (finished) — a grey node reached again is the
/// back-edge that proves a cycle, and everything from it to the top of the
/// stack is a member.
fn find_cycle(deps: &BTreeMap<&str, Vec<String>>) -> Vec<String> {
    #[derive(Clone, Copy, PartialEq)]
    enum Mark {
        White,
        Grey,
        Black,
    }
    let mut mark: BTreeMap<&str, Mark> = deps.keys().map(|k| (*k, Mark::White)).collect();
    let mut cycle_members = BTreeSet::new();

    fn visit<'a>(
        node: &'a str,
        deps: &'a BTreeMap<&'a str, Vec<String>>,
        mark: &mut BTreeMap<&'a str, Mark>,
        stack: &mut Vec<&'a str>,
        cycle_members: &mut BTreeSet<String>,
    ) {
        match mark.get(node).copied().unwrap_or(Mark::Black) {
            Mark::Black => return,
            Mark::Grey => {
                // Back-edge: everything on the stack from `node` onward is in
                // the cycle.
                if let Some(pos) = stack.iter().position(|n| *n == node) {
                    for n in &stack[pos..] {
                        cycle_members.insert((*n).to_string());
                    }
                }
                return;
            }
            Mark::White => {}
        }
        mark.insert(node, Mark::Grey);
        stack.push(node);
        if let Some(refs) = deps.get(node) {
            for r in refs {
                if deps.contains_key(r.as_str()) {
                    visit(r.as_str(), deps, mark, stack, cycle_members);
                }
            }
        }
        stack.pop();
        mark.insert(node, Mark::Black);
    }

    for name in deps.keys() {
        if mark.get(name).copied() == Some(Mark::White) {
            let mut stack = Vec::new();
            visit(name, deps, &mut mark, &mut stack, &mut cycle_members);
        }
    }
    cycle_members.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{Button, FieldKind, Grid, Node, NodeKind, Source, When};
    use std::collections::BTreeMap;

    fn minimal(root: Node) -> SurfaceSpec {
        SurfaceSpec {
            surface: SURFACE_VERSION.to_string(),
            name: "t".to_string(),
            params: Vec::new(),
            state: serde_json::json!({ "x": 1 }),
            sources: BTreeMap::new(),
            root,
        }
    }

    #[test]
    fn an_empty_spec_has_no_problems() {
        let spec = minimal(Node::leaf(NodeKind::Spacer));
        assert_eq!(validate(&spec), Vec::new());
    }

    #[test]
    fn a_wrong_surface_version_is_a_problem() {
        let mut spec = minimal(Node::leaf(NodeKind::Spacer));
        spec.surface = "0.9".to_string();
        let problems = validate(&spec);
        assert_eq!(problems.len(), 1);
        assert_eq!(problems[0].path, "/surface");
    }

    #[test]
    fn non_object_state_is_a_problem() {
        let mut spec = minimal(Node::leaf(NodeKind::Spacer));
        spec.state = serde_json::json!([1, 2, 3]);
        let problems = validate(&spec);
        assert!(problems.iter().any(|p| p.path == "/state"));
    }

    #[test]
    fn a_bind_not_starting_with_state_is_a_problem() {
        let node = Node::leaf(NodeKind::Field(FieldKind::Text(serde_json::json!({}))))
            .with_bind("param.oops");
        let problems = validate(&minimal(node));
        assert!(problems.iter().any(|p| p.path == "/root/bind"));
    }

    #[test]
    fn a_set_path_not_starting_with_state_is_a_problem() {
        let node = Node::leaf(NodeKind::Button(Button {
            label: "go".to_string(),
            on_click: vec![Action::Set {
                path: "oops.x".to_string(),
                value: serde_json::json!(1),
            }],
        }));
        let problems = validate(&minimal(node));
        assert!(
            problems
                .iter()
                .any(|p| p.path == "/root/button/on_click/0/set/path"),
            "{problems:?}"
        );
    }

    #[test]
    fn a_reference_to_an_undeclared_state_key_is_a_problem() {
        let node = Node::leaf(NodeKind::Text("{{state.missing}}".to_string()));
        let problems = validate(&minimal(node));
        assert!(problems.iter().any(|p| p.message.contains("missing")));
    }

    #[test]
    fn a_when_path_with_an_undeclared_state_key_is_a_problem() {
        let node = Node::leaf(NodeKind::Text("hi".to_string())).with_when(When {
            path: "state.missing".to_string(),
            equals: None,
        });
        let problems = validate(&minimal(node));
        assert!(
            problems.iter().any(|p| p.path == "/root/when/path"),
            "{problems:?}"
        );
    }

    #[test]
    fn a_reference_to_an_undeclared_source_is_a_problem() {
        let node = Node::leaf(NodeKind::Text("{{source.nope}}".to_string()));
        let problems = validate(&minimal(node));
        assert!(problems.iter().any(|p| p.message.contains("nope")));
    }

    #[test]
    fn a_source_dependency_cycle_is_a_problem() {
        let mut spec = minimal(Node::leaf(NodeKind::Spacer));
        spec.sources.insert(
            "a".to_string(),
            Source::Verb {
                verb: "x-service_a".to_string(),
                args: serde_json::json!({ "v": "{{source.b}}" }),
            },
        );
        spec.sources.insert(
            "b".to_string(),
            Source::Verb {
                verb: "x-service_b".to_string(),
                args: serde_json::json!({ "v": "{{source.a}}" }),
            },
        );
        let problems = validate(&spec);
        assert!(
            problems.iter().any(|p| p.message.contains("cycle")),
            "{problems:?}"
        );
    }

    #[test]
    fn duplicate_node_ids_are_a_problem() {
        let root = Node::leaf(NodeKind::Column(vec![
            Node::leaf(NodeKind::Spacer).with_id("dup"),
            Node::leaf(NodeKind::Divider).with_id("dup"),
        ]));
        let problems = validate(&minimal(root));
        assert!(problems.iter().any(|p| p.message.contains("dup")));
    }

    #[test]
    fn empty_select_options_are_a_problem() {
        let node = Node::leaf(NodeKind::Field(FieldKind::Select(serde_json::json!({
            "options": []
        }))));
        let problems = validate(&minimal(node));
        assert!(problems
            .iter()
            .any(|p| p.path.ends_with("/field/select/options")));
    }

    #[test]
    fn non_empty_select_options_are_fine() {
        let node = Node::leaf(NodeKind::Field(FieldKind::Select(serde_json::json!({
            "options": ["a"]
        }))));
        let problems = validate(&minimal(node));
        assert!(problems.is_empty());
    }

    #[test]
    fn a_grid_with_zero_columns_is_a_problem() {
        let node = Node::leaf(NodeKind::Grid(Grid {
            columns: 0,
            items: Vec::new(),
        }));
        let problems = validate(&minimal(node));
        assert!(problems.iter().any(|p| p.path.ends_with("/grid/columns")));
    }

    #[test]
    fn a_malformed_verb_name_is_a_problem() {
        let mut spec = minimal(Node::leaf(NodeKind::Spacer));
        spec.sources.insert(
            "s".to_string(),
            Source::Verb {
                verb: "not_a_valid_verb_name".to_string(),
                args: serde_json::json!({}),
            },
        );
        let problems = validate(&spec);
        assert!(problems.iter().any(|p| p.path == "/sources/s/verb"));
    }

    #[test]
    fn a_well_formed_verb_name_is_fine() {
        let mut spec = minimal(Node::leaf(NodeKind::Spacer));
        spec.sources.insert(
            "s".to_string(),
            Source::Verb {
                verb: "surface-demo-service_series".to_string(),
                args: serde_json::json!({}),
            },
        );
        assert_eq!(validate(&spec), Vec::new());
    }

    #[test]
    fn an_unrecognized_node_kind_is_reported_but_does_not_panic() {
        let node = Node::leaf(NodeKind::Unknown {
            kind: "sparkline".to_string(),
            node: serde_json::json!({"values": [1, 2, 3]}),
        });
        let problems = validate(&minimal(node));
        assert!(problems.iter().any(|p| p.message.contains("sparkline")));
    }
}
