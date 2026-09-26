//! Every declared descriptor field has a check (ADR-0034 D1, plan P1).
//!
//! The descriptor's derived fields (name, group, input and output schema) are
//! true by construction; the declared ones — `safety`, `since` — are only as
//! true as the declaration, so this file walks the linked `full` inventory
//! (`VerbDescriptor::iter()`) and fails naming the verb when:
//!
//! - a verb has no output schema (the macro's `JsonSchema` bound makes this a
//!   compile error; the test pins the schema is an object, not `Null`);
//! - a verb's `since` is empty or not a version;
//! - a verb's safety class disagrees with `docs/verb-safety.md`, or a verb
//!   has no row there, or a row names no linked verb;
//! - a `delete-*` verb is not `destructive` (or `external`, when its default
//!   implementation refuses and the deletion happens in the running app —
//!   the plan's name-convention lint);
//! - the qualified name is not `<service>_<method>`.
//!
//! `cargo test -p impress-capabilities --test descriptor -- --nocapture dump`
//! prints the safety table as the inventory would write it, for pasting.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use impress_service_core::{SafetyClass, VerbDescriptor};
use serde_json::Value;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root")
}

fn safety_doc() -> String {
    let path = repo_root().join("docs/verb-safety.md");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// The `| tool | class | evidence |` rows between the `verb-safety` markers.
fn table() -> BTreeMap<String, (SafetyClass, String)> {
    let doc = safety_doc();
    let mut inside = false;
    let mut rows = BTreeMap::new();
    for line in doc.lines() {
        if line.contains("<!-- verb-safety:begin -->") {
            inside = true;
            continue;
        }
        if line.contains("<!-- verb-safety:end -->") {
            break;
        }
        if !inside || !line.starts_with("| `") {
            continue;
        }
        let cells: Vec<&str> = line.trim().trim_matches('|').split('|').collect();
        assert!(
            cells.len() >= 3,
            "docs/verb-safety.md row has fewer than three cells: {line}"
        );
        let tool = cells[0].trim().trim_matches('`').to_string();
        let class = SafetyClass::parse(cells[1].trim()).unwrap_or_else(|| {
            panic!(
                "docs/verb-safety.md: `{tool}` has class `{}`; one of read_only, mutating, \
                 destructive, external",
                cells[1].trim()
            )
        });
        let evidence = cells[2].trim().to_string();
        assert!(
            rows.insert(tool.clone(), (class, evidence)).is_none(),
            "docs/verb-safety.md lists `{tool}` twice"
        );
    }
    assert!(!rows.is_empty(), "docs/verb-safety.md has no `verb-safety` marker block");
    rows
}

fn verbs() -> Vec<&'static VerbDescriptor> {
    impress_capabilities::force_link();
    let mut out: Vec<_> = VerbDescriptor::iter().collect();
    assert!(!out.is_empty(), "no verb is linked; the `full` feature set is off");
    out.sort_by_key(|v| v.name);
    out
}

fn row(v: &VerbDescriptor, evidence: &str) -> String {
    format!("| `{}` | {} | {} |", v.name, v.safety.class, evidence)
}

#[test]
fn every_verb_declares_the_class_the_table_records() {
    let verbs = verbs();
    let table = table();
    let mut problems = Vec::new();
    let mut seen = BTreeSet::new();
    for v in &verbs {
        seen.insert(v.name.to_string());
        match table.get(v.name) {
            None => problems.push(format!(
                "`{}` is linked but has no row in docs/verb-safety.md; add (with evidence):\n  {}",
                v.name,
                row(v, "name/doc")
            )),
            Some((class, evidence)) if *class != v.safety.class => problems.push(format!(
                "`{}` declares `{}` but docs/verb-safety.md says `{class}` ({evidence}); \
                 fix the declaration (`safety =` on the service, or `#[impress_method(safety = …)]` \
                 on the method), or the table with new evidence",
                v.name, v.safety.class
            )),
            Some(_) => {}
        }
    }
    for tool in table.keys() {
        if !seen.contains(tool) {
            problems.push(format!(
                "docs/verb-safety.md lists `{tool}`, which is not a linked verb; delete the row"
            ));
        }
    }
    assert!(
        problems.is_empty(),
        "docs/verb-safety.md disagrees with the linked inventory:\n- {}",
        problems.join("\n- ")
    );
}

#[test]
fn every_verb_has_a_version_it_appeared_in() {
    let mut problems = Vec::new();
    for v in verbs() {
        let since = v.since.trim();
        let is_version = !since.is_empty()
            && since
                .split('.')
                .all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_digit()));
        if !is_version {
            problems.push(format!(
                "`{}` has since = {:?}; declare `since = \"<major>.<minor>[.<patch>]\"` on the service",
                v.name, v.since
            ));
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn every_verb_has_an_output_schema_and_an_input_schema() {
    let mut problems = Vec::new();
    for v in verbs() {
        let output = (v.output_schema)();
        if !output.is_object() {
            problems.push(format!(
                "`{}` has no output schema (got {output}); its return type must derive `JsonSchema`",
                v.name
            ));
        }
        let input = (v.input_schema)();
        if input.get("type").and_then(Value::as_str) != Some("object") {
            problems.push(format!("`{}` input schema is not an object: {input}", v.name));
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn a_verb_named_delete_is_destructive() {
    let mut problems = Vec::new();
    for v in verbs() {
        let deletes = v.method == "delete"
            || v.method.starts_with("delete-")
            || v.method == "forget"
            || v.method.starts_with("prune-");
        if deletes && !matches!(v.safety.class, SafetyClass::Destructive | SafetyClass::External) {
            problems.push(format!(
                "`{}` is named like a deletion but declares `{}`",
                v.name, v.safety.class
            ));
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn names_and_groups_are_derived_from_the_identifiers() {
    for v in verbs() {
        assert_eq!(
            v.name,
            format!("{}_{}", v.service, v.method),
            "qualified name is `<service>_<method>`"
        );
        assert!(v.service.ends_with("-service"), "{} is a service", v.service);
        assert!(!v.description.is_empty() && !v.description.starts_with("Invoke "));
        // Idempotency defaults from the class unless declared; a read-only
        // verb that says otherwise is a contradiction.
        if v.safety.class == SafetyClass::ReadOnly {
            assert!(v.safety.idempotent, "{} is read-only, so idempotent", v.name);
        }
        // Lifecycle fields are P3's; nothing declares them yet.
        assert!(v.deprecated.is_none() && v.aliases.is_empty(), "{}", v.name);
    }
}

/// The MCP projection reads the annotations off the same descriptor every
/// other interface reads, so a class change reaches `tools/list` without a
/// second table.
#[test]
fn mcp_annotations_follow_the_declared_class() {
    for v in verbs() {
        let a = v.mcp_annotations();
        assert_eq!(
            a["readOnlyHint"],
            v.safety.class == SafetyClass::ReadOnly,
            "{}",
            v.name
        );
        assert_eq!(a["openWorldHint"], v.safety.class == SafetyClass::External, "{}", v.name);
        assert_eq!(
            a["destructiveHint"],
            matches!(
                v.safety.class,
                SafetyClass::Destructive | SafetyClass::External
            ),
            "{}",
            v.name
        );
        assert_eq!(a["idempotentHint"], v.safety.idempotent, "{}", v.name);
    }
}

/// `cargo test -p impress-capabilities --test descriptor -- --nocapture dump`
#[test]
fn dump() {
    let table = table();
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    println!("| Tool | Class | Evidence |");
    println!("|---|---|---|");
    for v in verbs() {
        *counts.entry(v.safety.class.as_str()).or_default() += 1;
        let evidence = table
            .get(v.name)
            .map(|(_, e)| e.as_str())
            .unwrap_or("name/doc");
        println!("{}", row(v, evidence));
    }
    println!();
    for (class, n) in counts {
        println!("{class}: {n}");
    }
}
