//! The verb census (plan-auto-gui-and-self-docs.md, G0).
//!
//! The plan's tables 1 and 5 were measured once, by throwaway tests, on
//! 2026-09-26. This file makes them a permanent check: it walks the linked
//! `full` inventory (`McpToolDescriptor::iter()`), classifies every verb and
//! every workspace crate, and compares what it finds with the marker tables in
//! `docs/verb-coverage.md`. The numbers come from the inventory; the table
//! records the verdicts and the counts a human last accepted. When they
//! disagree the test prints the row as it should now read, so keeping the
//! document true is a paste, not a recount.
//!
//! What fails:
//! - a service in the inventory with no row, or a row for a service that is
//!   no longer linked;
//! - a service row whose counts (verbs, real descriptions, arguments, described
//!   arguments, strict verbs) differ from the inventory;
//! - a workspace crate with no verdict, a verdict for a crate that is gone, or
//!   a crate holding an `impress_service_impl!` block without the `verb-crate` verdict (and
//!   the reverse);
//! - more `should-be-verb` crates than the plan counted (C-1: the gap is held,
//!   not allowed to grow — a new crate that should expose verbs writes them,
//!   or is listed `internal` with a reason);
//! - the argument-shape histogram moving.
//!
//! Two facts a descriptor does not carry — which crate defines a service, and
//! whether a service is `strict_args` — are read from the service crates'
//! sources, the way the plan measured them. `scripts/check-verb-coverage.sh`
//! runs the source-only half of this without a build.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use impress_service_core::McpToolDescriptor;
use serde_json::Value;

/// The plan's count of `should-be-verb` crates (table 5, appendix A5). Lower
/// it when a crate gains its verbs or is reclassified with a reason; raising
/// it is a plan decision, not a test edit.
const SHOULD_BE_VERB_CEILING: usize = 20;

const VERDICTS: &[&str] = &[
    "verb-crate",
    "covered-through",
    "internal",
    "should-be-verb",
];

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root")
}

fn coverage_doc() -> String {
    let path = repo_root().join("docs/verb-coverage.md");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// The lines between `<!-- <name>:begin -->` and `<!-- <name>:end -->`.
fn marker_block<'a>(doc: &'a str, name: &str) -> Vec<&'a str> {
    let begin = format!("<!-- {name}:begin -->");
    let end = format!("<!-- {name}:end -->");
    let mut out = Vec::new();
    let mut inside = false;
    for line in doc.lines() {
        if line.contains(&begin) {
            inside = true;
            continue;
        }
        if line.contains(&end) {
            break;
        }
        if inside {
            out.push(line);
        }
    }
    assert!(
        !out.is_empty(),
        "docs/verb-coverage.md has no `{name}` marker block"
    );
    out
}

/// Table rows (lines starting with `| \``) as their trimmed cells, backticks
/// stripped from the first cell.
fn table_rows(block: &[&str]) -> Vec<Vec<String>> {
    block
        .iter()
        .filter(|l| l.starts_with("| `") || l.starts_with("| **"))
        .map(|l| {
            l.trim()
                .trim_matches('|')
                .split('|')
                .map(|c| c.trim().trim_matches('`').trim_matches('*').to_string())
                .collect()
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Verb classification
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Shape {
    Scalar,
    ArrayOfScalars,
    ArrayOfObjects,
    RefObject,
    InlineObject,
    Map,
    TaggedUnion,
    Other,
}

impl Shape {
    fn label(self) -> &'static str {
        match self {
            Shape::Scalar => "scalar",
            Shape::ArrayOfScalars => "array-of-scalars",
            Shape::ArrayOfObjects => "array-of-objects",
            Shape::RefObject => "ref-object",
            Shape::InlineObject => "inline-object",
            Shape::Map => "map",
            Shape::TaggedUnion => "tagged-union",
            Shape::Other => "other",
        }
    }
}

/// The JSON-schema `type` of a property, ignoring a `null` alternative
/// (schemars spells `Option<T>` as `"type": ["T", "null"]`).
fn schema_type(prop: &Value) -> Option<String> {
    match prop.get("type") {
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(Value::as_str)
            .find(|s| *s != "null")
            .map(str::to_string),
        _ => None,
    }
}

fn is_scalar_type(t: &str) -> bool {
    matches!(t, "string" | "integer" | "number" | "boolean")
}

fn classify(prop: &Value) -> Shape {
    if prop.get("$ref").is_some() {
        return Shape::RefObject;
    }
    if let Some(alts) = prop
        .get("oneOf")
        .or_else(|| prop.get("anyOf"))
        .and_then(Value::as_array)
    {
        // schemars spells `Option<Dto>` as `anyOf: [{$ref}, {type: null}]`;
        // that is the DTO, not a union. Anything with two real alternatives is.
        let real: Vec<&Value> = alts
            .iter()
            .filter(|a| schema_type(a).as_deref() != Some("null") || a.get("$ref").is_some())
            .collect();
        return match real.as_slice() {
            [one] => classify(one),
            _ => Shape::TaggedUnion,
        };
    }
    match schema_type(prop).as_deref() {
        Some(t) if is_scalar_type(t) => Shape::Scalar,
        Some("array") => match prop.get("items") {
            Some(items) if items.get("$ref").is_some() => Shape::ArrayOfObjects,
            Some(items) => match schema_type(items).as_deref() {
                Some(t) if is_scalar_type(t) => Shape::ArrayOfScalars,
                Some("object") => Shape::ArrayOfObjects,
                _ => Shape::Other,
            },
            None => Shape::Other,
        },
        Some("object") => {
            if prop.get("additionalProperties").is_some() && prop.get("properties").is_none() {
                Shape::Map
            } else {
                Shape::InlineObject
            }
        }
        _ => Shape::Other,
    }
}

struct Verb {
    service: String,
    real_description: bool,
    args: Vec<(String, Shape, bool)>, // (name, shape, described)
    required: usize,
}

fn verbs() -> Vec<Verb> {
    // The reference the linker needs to keep every service crate's
    // `inventory::submit!` statics (see the crate's module docs).
    impress_capabilities::force_link();
    let mut out = Vec::new();
    for d in McpToolDescriptor::iter() {
        let (service, method) = d
            .name
            .split_once('_')
            .unwrap_or_else(|| panic!("tool name `{}` has no service prefix", d.name));
        let _ = method;
        let schema = (d.input_schema)();
        let props = schema
            .get("properties")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        let required = schema
            .get("required")
            .and_then(Value::as_array)
            .map(|a| a.len())
            .unwrap_or(0);
        let args = props
            .iter()
            .map(|(name, prop)| {
                (
                    name.clone(),
                    classify(prop),
                    prop.get("description").is_some(),
                )
            })
            .collect();
        out.push(Verb {
            service: service.to_string(),
            real_description: !d.description.starts_with("Invoke "),
            args,
            required,
        });
    }
    out
}

// ---------------------------------------------------------------------------
// Source facts: which crate defines which service, and which are strict
// ---------------------------------------------------------------------------

fn rust_sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            rust_sources(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

fn kebab(s: &str) -> String {
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if c == '_' {
            out.push('-');
        } else if c.is_ascii_uppercase() {
            if i != 0 {
                out.push('-');
            }
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

struct SourceFacts {
    /// kebab service name -> crate directory name
    service_crate: BTreeMap<String, String>,
    strict_services: BTreeSet<String>,
}

fn source_facts() -> SourceFacts {
    let mut facts = SourceFacts {
        service_crate: BTreeMap::new(),
        strict_services: BTreeSet::new(),
    };
    let crates = repo_root().join("crates");
    for entry in fs::read_dir(&crates).expect("crates/").flatten() {
        let crate_dir = entry.path();
        let crate_name = crate_dir.file_name().unwrap().to_string_lossy().to_string();
        let mut files = Vec::new();
        rust_sources(&crate_dir.join("src"), &mut files);
        for file in files {
            let text = fs::read_to_string(&file).unwrap_or_default();
            // `impress_service_impl! { service = X, ..., strict_args = true, ... }`
            // is what emits the inventory entries, so the crate holding it is
            // the verb crate (vw-service holds only the trait; the verbs are
            // vw-impress-adapter's).
            for block in text.split("impress_service_impl!").skip(1) {
                let end = block.find("methods").unwrap_or(block.len());
                let head = &block[..end];
                let service = head.split("service =").nth(1).and_then(|s| {
                    let s = s.trim_start();
                    let name: String = s
                        .chars()
                        .take_while(|c| c.is_alphanumeric() || *c == '_')
                        .collect();
                    (!name.is_empty()).then_some(name)
                });
                let strict = head
                    .split("strict_args =")
                    .nth(1)
                    .is_some_and(|s| s.trim_start().starts_with("true"));
                let Some(service) = service else { continue };
                let service = kebab(&service);
                if strict {
                    facts.strict_services.insert(service.clone());
                }
                facts.service_crate.insert(service, crate_name.clone());
            }
        }
    }
    facts
}

fn workspace_members() -> BTreeSet<String> {
    let toml = fs::read_to_string(repo_root().join("Cargo.toml")).expect("root Cargo.toml");
    let members = toml.split("members = [").nth(1).expect("workspace members");
    // The list ends at the line that is `]`, not at the first `]`: the
    // comments between members mention `#[impress_service]`.
    members
        .lines()
        .take_while(|l| !l.trim().starts_with(']'))
        .filter_map(|l| {
            let l = l.trim();
            let l = l.strip_prefix('"')?;
            let path = l.split('"').next()?;
            Some(path.rsplit('/').next()?.to_string())
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Per-service census rows
// ---------------------------------------------------------------------------

#[derive(Default, Debug, PartialEq, Eq)]
struct ServiceCount {
    verbs: usize,
    real: usize,
    args: usize,
    required: usize,
    described: usize,
    strict: usize,
}

impl ServiceCount {
    fn cells(&self) -> [String; 5] {
        [
            self.verbs.to_string(),
            self.real.to_string(),
            format!("{} ({})", self.args, self.required),
            self.described.to_string(),
            self.strict.to_string(),
        ]
    }
}

fn census(verbs: &[Verb], facts: &SourceFacts) -> BTreeMap<String, ServiceCount> {
    let mut by_service: BTreeMap<String, ServiceCount> = BTreeMap::new();
    for v in verbs {
        let c = by_service.entry(v.service.clone()).or_default();
        c.verbs += 1;
        c.real += usize::from(v.real_description);
        c.args += v.args.len();
        c.required += v.required;
        c.described += v.args.iter().filter(|(_, _, d)| *d).count();
        c.strict += usize::from(facts.strict_services.contains(&v.service));
    }
    by_service
}

fn service_row(service: &str, crate_name: &str, c: &ServiceCount) -> String {
    let [verbs, real, args, described, strict] = c.cells();
    format!("| `{service}` | {crate_name} | {verbs} | {real} | {args} | {described} | {strict} |")
}

fn total_row(rows: &BTreeMap<String, ServiceCount>, crates: usize) -> String {
    let mut t = ServiceCount::default();
    for c in rows.values() {
        t.verbs += c.verbs;
        t.real += c.real;
        t.args += c.args;
        t.required += c.required;
        t.described += c.described;
        t.strict += c.strict;
    }
    let [verbs, real, args, described, strict] = t.cells();
    format!(
        "| **Total** | {crates} crates, {} services | **{verbs}** | **{real}** | **{args}** | **{described}** | **{strict}** |",
        rows.len()
    )
}

/// The crates whose `impress_service_impl!` blocks are linked. Not every block
/// in the sources is: the macro crate's own module doc spells one for an
/// `EchoService` that exists nowhere.
fn verb_crates(counts: &BTreeMap<String, ServiceCount>, facts: &SourceFacts) -> BTreeSet<String> {
    counts
        .keys()
        .filter_map(|s| facts.service_crate.get(s).cloned())
        .collect()
}

#[test]
fn every_linked_service_has_a_true_row() {
    let verbs = verbs();
    assert!(
        !verbs.is_empty(),
        "no verb is linked; the `full` feature set is off"
    );
    let facts = source_facts();
    let counts = census(&verbs, &facts);
    let doc = coverage_doc();
    let rows = table_rows(&marker_block(&doc, "verb-coverage-services"));

    let mut problems = Vec::new();
    let mut seen = BTreeSet::new();
    for row in &rows {
        if row[0] == "Total" {
            let expected = total_row(&counts, verb_crates(&counts, &facts).len());
            let got = format!(
                "| **Total** | {} | **{}** | **{}** | **{}** | **{}** | **{}** |",
                row[1], row[2], row[3], row[4], row[5], row[6]
            );
            if got != expected {
                problems.push(format!("total row is stale; it should read:\n  {expected}"));
            }
            continue;
        }
        let service = &row[0];
        seen.insert(service.clone());
        let Some(c) = counts.get(service) else {
            problems.push(format!(
                "`{service}` has a row but is not linked in `full`; delete the row"
            ));
            continue;
        };
        let crate_name = facts
            .service_crate
            .get(service)
            .cloned()
            .unwrap_or_else(|| "?".into());
        let expected = service_row(service, &crate_name, c);
        let got = format!(
            "| `{service}` | {} | {} | {} | {} | {} | {} |",
            row[1], row[2], row[3], row[4], row[5], row[6]
        );
        if got != expected {
            problems.push(format!(
                "`{service}` row is stale; it should read:\n  {expected}"
            ));
        }
    }
    for (service, c) in &counts {
        if !seen.contains(service) {
            let crate_name = facts
                .service_crate
                .get(service)
                .cloned()
                .unwrap_or_else(|| "?".into());
            problems.push(format!(
                "`{service}` is linked but has no row in docs/verb-coverage.md; add:\n  {}",
                service_row(service, &crate_name, c)
            ));
        }
    }
    for service in counts.keys() {
        if !facts.service_crate.contains_key(service) {
            problems.push(format!(
                "`{service}` is linked but no `impress_service_impl!` block under crates/*/src names it"
            ));
        }
    }
    assert!(
        problems.is_empty(),
        "docs/verb-coverage.md disagrees with the linked inventory:\n- {}",
        problems.join("\n- ")
    );
}

#[test]
fn argument_shapes_are_pinned() {
    let verbs = verbs();
    let mut hist: BTreeMap<&str, usize> = BTreeMap::new();
    for v in &verbs {
        for (_, shape, _) in &v.args {
            *hist.entry(shape.label()).or_default() += 1;
        }
    }
    let doc = coverage_doc();
    let rows = table_rows(&marker_block(&doc, "verb-coverage-shapes"));
    let recorded: BTreeMap<&str, usize> = rows
        .iter()
        .map(|r| (r[0].as_str(), r[1].parse::<usize>().unwrap_or(usize::MAX)))
        .collect();
    let mut expected = String::new();
    for (shape, n) in &hist {
        expected.push_str(&format!("| `{shape}` | {n} |\n"));
    }
    assert_eq!(
        recorded, hist,
        "the argument-shape table in docs/verb-coverage.md is stale; it should read:\n{expected}"
    );
}

#[test]
fn every_workspace_crate_has_a_verdict() {
    let members = workspace_members();
    let facts = source_facts();
    let verb_crates = verb_crates(&census(&verbs(), &facts), &facts);
    let doc = coverage_doc();
    let rows = table_rows(&marker_block(&doc, "verb-coverage-crates"));

    let mut problems = Vec::new();
    let mut seen = BTreeMap::new();
    for row in &rows {
        let (crate_name, verdict) = (&row[0], &row[2]);
        if !VERDICTS.contains(&verdict.as_str()) {
            problems.push(format!(
                "`{crate_name}` has verdict `{verdict}`; one of {VERDICTS:?}"
            ));
        }
        if !members.contains(crate_name) {
            problems.push(format!(
                "`{crate_name}` has a row but is not a workspace member; delete the row"
            ));
        }
        let is_verb_crate = verb_crates.contains(crate_name);
        if is_verb_crate && verdict != "verb-crate" {
            problems.push(format!("`{crate_name}` holds an `impress_service_impl!` block but is `{verdict}`, not `verb-crate`"));
        }
        if !is_verb_crate && verdict == "verb-crate" {
            problems.push(format!(
                "`{crate_name}` is `verb-crate` but holds no `impress_service_impl!` block"
            ));
        }
        if row[3].trim().is_empty() && verdict != "verb-crate" {
            problems.push(format!("`{crate_name}` is `{verdict}` with no reason"));
        }
        seen.insert(crate_name.clone(), verdict.clone());
    }
    for m in &members {
        if !seen.contains_key(m) {
            let hint = if verb_crates.contains(m) {
                "verb-crate"
            } else {
                "internal / covered-through / should-be-verb"
            };
            problems.push(format!(
                "`{m}` has no verdict in docs/verb-coverage.md (expected `{hint}`)"
            ));
        }
    }
    let should_be_verb = seen.values().filter(|v| *v == "should-be-verb").count();
    if should_be_verb > SHOULD_BE_VERB_CEILING {
        problems.push(format!(
            "{should_be_verb} crates are `should-be-verb`, more than the plan's {SHOULD_BE_VERB_CEILING} (C-1): \
             write the verbs or list the crate `internal` with a reason"
        ));
    }
    assert!(
        problems.is_empty(),
        "docs/verb-coverage.md disagrees with the workspace:\n- {}",
        problems.join("\n- ")
    );
}

/// `cargo test -p impress-capabilities --test census -- --nocapture dump`
/// prints the tables as they should read now, for pasting.
#[test]
fn dump() {
    let verbs = verbs();
    let facts = source_facts();
    let counts = census(&verbs, &facts);
    let crates = verb_crates(&counts, &facts);
    println!("| Service | Crate | Verbs | Real description | Args (required) | Args described | Strict |");
    println!("|---|---|---:|---:|---:|---:|---:|");
    for (service, c) in &counts {
        let crate_name = facts
            .service_crate
            .get(service)
            .cloned()
            .unwrap_or_else(|| "?".into());
        println!("{}", service_row(service, &crate_name, c));
    }
    println!("{}", total_row(&counts, crates.len()));
    let mut hist: BTreeMap<&str, usize> = BTreeMap::new();
    for v in &verbs {
        for (_, shape, _) in &v.args {
            *hist.entry(shape.label()).or_default() += 1;
        }
    }
    println!();
    for (shape, n) in &hist {
        println!("| `{shape}` | {n} |");
    }
    println!();
    for v in &verbs {
        if !v.real_description {
            println!("fallback description: {}", v.service);
        }
    }
}
