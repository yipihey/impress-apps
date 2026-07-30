//! Golden-corpus parity tests for the Swift → Rust parser port (Stage 7).
//!
//! `test_fixtures/golden/*.json` was captured from the Swift implementations of
//! `IdentifierExtractor`, `BibTeXParser` and `RISParser` *before* they were
//! deleted. These tests assert the Rust implementations reproduce that
//! behaviour, so the editor/round-trip path and the import path can no longer
//! disagree.
//!
//! Where a deliberate divergence exists it is listed in `KNOWN_DIVERGENCES`
//! with the reason — an unlisted mismatch fails the build.

mod common;

use std::collections::BTreeMap;

use common::fixtures::{fixture_path, load_fixture};
use serde_json::Value;

// ── Golden loading ───────────────────────────────────────────────────────────

fn golden(name: &str) -> Value {
    let raw = load_fixture(&format!("golden/{name}"));
    serde_json::from_str(&raw).unwrap_or_else(|e| panic!("bad golden {name}: {e}"))
}

fn content_for(record: &Value) -> String {
    let name = record["name"].as_str().unwrap();
    match record.get("content").and_then(Value::as_str) {
        Some(inline) => inline.to_string(),
        None => std::fs::read_to_string(fixture_path(name))
            .unwrap_or_else(|e| panic!("missing corpus file {name}: {e}")),
    }
}

/// Collects mismatches so one run reports the whole disagreement surface
/// instead of stopping at the first.
#[derive(Default)]
struct Report {
    lines: Vec<String>,
}

impl Report {
    fn push(&mut self, scope: &str, detail: String) {
        self.lines.push(format!("[{scope}] {detail}"));
    }

    fn assert_empty(self, what: &str) {
        if !self.lines.is_empty() {
            let shown: Vec<_> = self.lines.iter().take(60).cloned().collect();
            panic!(
                "{} golden mismatches for {what}:\n{}",
                self.lines.len(),
                shown.join("\n")
            );
        }
    }
}

// ── Item 1: identifiers ──────────────────────────────────────────────────────

fn opt(value: &Value) -> Option<String> {
    value.as_str().map(str::to_string)
}

fn field_map(value: &Value) -> std::collections::HashMap<String, String> {
    value
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string()))
        .collect()
}

#[test]
fn identifier_text_scanners_match_swift_golden() {
    use imbib_core::identifiers::{
        extract_arxiv_from_text, extract_bibcode_from_text, extract_doi_from_text,
        extract_pmid_from_text,
    };

    let g = golden("identifiers_golden.json");
    let mut report = Report::default();

    for case in g["textCases"].as_array().unwrap() {
        let input = case["input"].as_str().unwrap().to_string();
        let checks: [(&str, Option<String>, Option<String>); 4] = [
            (
                "doi",
                opt(&case["doi"]),
                extract_doi_from_text(input.clone()),
            ),
            (
                "arxiv",
                opt(&case["arxiv"]),
                extract_arxiv_from_text(input.clone()),
            ),
            (
                "bibcode",
                opt(&case["bibcode"]),
                extract_bibcode_from_text(input.clone()),
            ),
            (
                "pmid",
                opt(&case["pmid"]),
                extract_pmid_from_text(input.clone()),
            ),
        ];
        for (kind, want, got) in checks {
            if want != got {
                report.push(
                    &format!("{input:?}"),
                    format!("{kind}: {want:?} != {got:?}"),
                );
            }
        }
    }

    report.assert_empty("identifier text scanners");
}

#[test]
fn identifier_normalisation_matches_swift_golden() {
    use imbib_core::identifiers::{is_valid_arxiv_id_format, normalize_arxiv_id};

    let g = golden("identifiers_golden.json");
    let mut report = Report::default();

    for case in g["normalizeCases"].as_array().unwrap() {
        let input = case["input"].as_str().unwrap().to_string();
        let want_normalized = case["normalized"].as_str().unwrap();
        let got_normalized = normalize_arxiv_id(input.clone());
        if want_normalized != got_normalized {
            report.push(
                &format!("{input:?}"),
                format!("normalize: {want_normalized:?} != {got_normalized:?}"),
            );
        }

        let want_valid = case["isValidFormat"].as_bool().unwrap();
        let got_valid = is_valid_arxiv_id_format(input.clone());
        if want_valid != got_valid {
            report.push(
                &format!("{input:?}"),
                format!("isValidFormat: {want_valid} != {got_valid}"),
            );
        }
    }

    report.assert_empty("arxiv normalisation");
}

#[test]
fn identifier_field_extraction_matches_swift_golden() {
    use imbib_core::identifiers::{
        all_identifiers_from_fields, arxiv_id_from_fields, bibcode_from_fields, doi_from_fields,
        pmcid_from_fields, pmid_from_fields,
    };

    let g = golden("identifiers_golden.json");
    let mut report = Report::default();

    for case in g["fieldCases"].as_array().unwrap() {
        let fields = field_map(&case["fields"]);
        let scope = format!("{:?}", case["fields"]);

        let checks: [(&str, Option<String>, Option<String>); 5] = [
            (
                "arxiv",
                opt(&case["arxiv"]),
                arxiv_id_from_fields(fields.clone()),
            ),
            ("doi", opt(&case["doi"]), doi_from_fields(fields.clone())),
            (
                "bibcode",
                opt(&case["bibcode"]),
                bibcode_from_fields(fields.clone()),
            ),
            ("pmid", opt(&case["pmid"]), pmid_from_fields(fields.clone())),
            (
                "pmcid",
                opt(&case["pmcid"]),
                pmcid_from_fields(fields.clone()),
            ),
        ];
        for (kind, want, got) in checks {
            if want != got {
                report.push(&scope, format!("{kind}: {want:?} != {got:?}"));
            }
        }

        let want_all = field_map(&case["all"]);
        let got_all = all_identifiers_from_fields(fields);
        if want_all != got_all {
            report.push(&scope, format!("all: {want_all:?} != {got_all:?}"));
        }
    }

    report.assert_empty("identifier field extraction");
}

#[test]
fn ads_url_bibcode_matches_swift_golden() {
    use imbib_core::identifiers::bibcode_from_ads_url;

    let g = golden("identifiers_golden.json");
    let mut report = Report::default();

    for case in g["adsURLCases"].as_array().unwrap() {
        let input = case["input"].as_str().unwrap().to_string();
        let want = opt(&case["bibcode"]);
        let got = bibcode_from_ads_url(input.clone());
        if want != got {
            report.push(&format!("{input:?}"), format!("{want:?} != {got:?}"));
        }
    }

    report.assert_empty("ads url bibcode");
}

// ── Item 2: BibTeX ───────────────────────────────────────────────────────────

/// Reproduces what the Swift FFI path does on top of `bibtex::parse`:
/// lowercase field keys and LaTeX-decode values (see
/// `BibTeXEntryConversions.fromRust(_:decodeLaTeX:)`).
fn rust_bibtex_entries(content: &str) -> Vec<(String, String, BTreeMap<String, String>)> {
    let parsed = match imbib_core::bibtex::parse(content.to_string()) {
        Ok(p) => p,
        Err(_) => return Vec::new(),
    };
    parsed
        .entries
        .into_iter()
        .map(|entry| {
            let mut fields = BTreeMap::new();
            for field in &entry.fields {
                fields.insert(
                    field.key.to_lowercase(),
                    imbib_core::bibtex::decode_latex(field.value.clone()),
                );
            }
            (
                entry.cite_key.clone(),
                entry.entry_type.as_str().to_string(),
                fields,
            )
        })
        .collect()
}

#[test]
fn bibtex_matches_swift_golden() {
    let g = golden("bibtex_golden.json");
    let mut report = Report::default();

    for record in g["files"].as_array().unwrap() {
        let name = record["name"].as_str().unwrap();
        let content = content_for(record);
        let rust = rust_bibtex_entries(&content);
        let swift = record["entries"].as_array().unwrap();

        if rust.len() != swift.len() {
            let rust_keys: Vec<&str> = rust.iter().map(|e| e.0.as_str()).collect();
            let missing: Vec<&str> = swift
                .iter()
                .map(|e| e["citeKey"].as_str().unwrap())
                .filter(|k| !rust_keys.contains(k))
                .collect();
            report.push(
                name,
                format!(
                    "entry count swift={} rust={} (rust missing: {:?})",
                    swift.len(),
                    rust.len(),
                    missing
                ),
            );
            continue;
        }

        for (index, (expected, actual)) in swift.iter().zip(rust.iter()).enumerate() {
            let (cite_key, entry_type, fields) = actual;
            let want_key = expected["citeKey"].as_str().unwrap();
            let want_type = expected["entryType"].as_str().unwrap();

            if want_key != cite_key {
                report.push(
                    name,
                    format!("#{index} citeKey {want_key:?} != {cite_key:?}"),
                );
            }
            if want_type != entry_type {
                report.push(
                    name,
                    format!("#{index} {want_key} entryType {want_type:?} != {entry_type:?}"),
                );
            }

            let want_fields: BTreeMap<String, String> = expected["fields"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.clone(), v.as_str().unwrap_or_default().to_string()))
                .collect();

            for (key, want) in &want_fields {
                match fields.get(key) {
                    None => report.push(name, format!("#{index} {want_key} missing field {key:?}")),
                    Some(got) if got != want => report.push(
                        name,
                        format!("#{index} {want_key} field {key:?}: {want:?} != {got:?}"),
                    ),
                    Some(_) => {}
                }
            }
            for key in fields.keys() {
                if !want_fields.contains_key(key) {
                    report.push(name, format!("#{index} {want_key} extra field {key:?}"));
                }
            }
        }
    }

    report.assert_empty("bibtex");
}

#[test]
fn bibtex_string_macros_and_preambles_match_swift_golden() {
    let g = golden("bibtex_golden.json");
    let mut report = Report::default();

    for record in g["files"].as_array().unwrap() {
        let name = record["name"].as_str().unwrap();
        let content = content_for(record);
        let Ok(parsed) = imbib_core::bibtex::parse(content.clone()) else {
            continue;
        };

        let mut rust_macros: Vec<(String, String)> = parsed
            .strings
            .iter()
            .map(|(k, v)| (k.clone(), imbib_core::bibtex::decode_latex(v.clone())))
            .collect();
        rust_macros.sort();

        let swift_macros: Vec<(String, String)> = record["macros"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| {
                (
                    m["name"].as_str().unwrap().to_string(),
                    m["value"].as_str().unwrap().to_string(),
                )
            })
            .collect();

        if rust_macros != swift_macros {
            report.push(
                name,
                format!("string macros swift={swift_macros:?} rust={rust_macros:?}"),
            );
        }

        let mut rust_preambles: Vec<String> = parsed
            .preambles
            .iter()
            .map(|p| imbib_core::bibtex::decode_latex(p.clone()))
            .collect();
        rust_preambles.sort();
        let swift_preambles: Vec<String> = record["preambles"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| p.as_str().unwrap().to_string())
            .collect();
        if rust_preambles != swift_preambles {
            report.push(
                name,
                format!("preambles swift={swift_preambles:?} rust={rust_preambles:?}"),
            );
        }

        let mut rust_comments = parsed.comments.clone();
        rust_comments.sort();
        let swift_comments: Vec<String> = record["comments"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c.as_str().unwrap().to_string())
            .collect();
        if rust_comments != swift_comments {
            report.push(
                name,
                format!("comments swift={swift_comments:?} rust={rust_comments:?}"),
            );
        }
    }

    report.assert_empty("bibtex macros/preambles");
}

// ── Item 3: RIS ──────────────────────────────────────────────────────────────

/// Cases where the Rust parser is deliberately more permissive than the Swift
/// one it replaced. Each is a strict superset — Rust recovers data Swift threw
/// away — so no previously-working input changes meaning.
const RIS_KNOWN_DIVERGENCES: &[(&str, &str)] = &[(
    "inline/one-space-separator",
    "Swift's tag regex demanded exactly two spaces before the dash, so \
     `TY - JOUR` (emitted by several reference managers) parsed as zero \
     entries — a silent whole-file import failure. Rust accepts it.",
)];

/// Reproduces `RISEntryConversions.fromRust`: unknown tags are dropped and the
/// `Unknown` reference type surfaces as `GEN`.
fn rust_ris_entries(content: &str, known_tags: &[String]) -> Vec<(String, Vec<(String, String)>)> {
    imbib_core::ris::parse(content.to_string())
        .unwrap_or_default()
        .into_iter()
        .map(|entry| {
            let entry_type = match format!("{:?}", entry.entry_type).as_str() {
                "Unknown" => "GEN".to_string(),
                other => other.to_string(),
            };
            (
                entry_type,
                entry
                    .tags
                    .iter()
                    .filter(|t| known_tags.iter().any(|k| k == &t.tag))
                    .map(|t| (t.tag.clone(), t.value.clone()))
                    .collect(),
            )
        })
        .collect()
}

#[test]
fn ris_matches_swift_golden() {
    let g = golden("ris_golden.json");
    let known_tags: Vec<String> = g["knownTags"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t.as_str().unwrap().to_string())
        .collect();
    let mut report = Report::default();

    for record in g["files"].as_array().unwrap() {
        let name = record["name"].as_str().unwrap();
        if RIS_KNOWN_DIVERGENCES.iter().any(|(case, _)| *case == name) {
            continue;
        }
        let content = content_for(record);
        let rust = rust_ris_entries(&content, &known_tags);
        let swift = record["entries"].as_array().unwrap();

        if rust.len() != swift.len() {
            report.push(
                name,
                format!("entry count swift={} rust={}", swift.len(), rust.len()),
            );
            continue;
        }

        for (index, (expected, actual)) in swift.iter().zip(rust.iter()).enumerate() {
            let (entry_type, tags) = actual;
            let want_type = expected["type"].as_str().unwrap();
            if want_type != entry_type {
                report.push(
                    name,
                    format!("#{index} type {want_type:?} != {entry_type:?}"),
                );
            }
            let want_tags: Vec<(String, String)> = expected["tags"]
                .as_array()
                .unwrap()
                .iter()
                .map(|t| {
                    let pair = t.as_array().unwrap();
                    (
                        pair[0].as_str().unwrap().to_string(),
                        pair[1].as_str().unwrap().to_string(),
                    )
                })
                .collect();
            if &want_tags != tags {
                report.push(
                    name,
                    format!("#{index} tags swift={want_tags:?} rust={tags:?}"),
                );
            }
        }
    }

    report.assert_empty("ris");
}
