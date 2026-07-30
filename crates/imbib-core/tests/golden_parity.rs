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

// ── Item 4: DocumentFormat grammar ───────────────────────────────────────────

fn affixes(value: &Value) -> Option<(String, String)> {
    value.as_object().map(|o| {
        (
            o["prefix"].as_str().unwrap().to_string(),
            o["suffix"].as_str().unwrap().to_string(),
        )
    })
}

#[test]
fn manuscript_format_grammar_matches_swift_golden() {
    use imbib_core::manuscript_format::manuscript_format_grammar;

    let g = golden("document_format_golden.json");
    let mut report = Report::default();

    let want = g["formats"].as_array().unwrap();
    let got = manuscript_format_grammar();
    assert_eq!(want.len(), 4, "golden format count changed");
    assert_eq!(
        got.len(),
        want.len(),
        "Rust table has {} rows, Swift had {}",
        got.len(),
        want.len()
    );

    for (expected, actual) in want.iter().zip(got.iter()) {
        let scope = expected["id"].as_str().unwrap().to_string();
        let mut check = |field: &str, want: String, have: String| {
            if want != have {
                report.push(&scope, format!("{field}: {want} != {have}"));
            }
        };
        // Order matters too: Swift's `allCases` order is what a picker renders.
        check("id", scope.clone(), actual.id.clone());
        check(
            "displayName",
            expected["displayName"].as_str().unwrap().to_string(),
            actual.display_name.clone(),
        );
        check(
            "previewKind",
            expected["previewKind"].as_str().unwrap().to_string(),
            actual.preview_kind.clone(),
        );
        check(
            "hasPreview",
            expected["hasPreview"].to_string(),
            actual.has_preview.to_string(),
        );
        check(
            "requiresCompile",
            expected["requiresCompile"].to_string(),
            actual.requires_compile.to_string(),
        );
        check(
            "fileExtension",
            expected["fileExtension"].as_str().unwrap().to_string(),
            actual.file_extension.clone(),
        );
        check(
            "mainFileName",
            expected["mainFileName"].as_str().unwrap().to_string(),
            actual.main_file_name.clone(),
        );
        check(
            "commentPrefix",
            format!("{:?}", expected["commentPrefix"].as_str()),
            format!("{:?}", actual.comment_prefix.as_deref()),
        );
        for (field, want_value, have) in [
            (
                "citationInsert",
                affixes(&expected["citationInsert"]),
                actual.citation_insert.clone(),
            ),
            (
                "boldWrap",
                affixes(&expected["boldWrap"]),
                actual.bold_wrap.clone(),
            ),
            (
                "italicWrap",
                affixes(&expected["italicWrap"]),
                actual.italic_wrap.clone(),
            ),
        ] {
            let have_pair = have.map(|a| (a.prefix, a.suffix));
            check(field, format!("{want_value:?}"), format!("{have_pair:?}"));
        }
        check(
            "defaultDebounceMs",
            expected["defaultDebounceMs"].to_string(),
            actual.default_debounce_ms.to_string(),
        );
    }

    report.assert_empty("manuscript format grammar");
}

#[test]
fn manuscript_format_detection_matches_swift_golden() {
    use imbib_core::manuscript_format::{
        detect_manuscript_format, manuscript_format_for_extension,
    };

    let g = golden("document_format_golden.json");
    let mut report = Report::default();

    let detect_cases = g["detectCases"].as_array().unwrap();
    assert_eq!(detect_cases.len(), 30);
    for case in detect_cases {
        let source = case["source"].as_str().unwrap();
        let title = case["title"].as_str();
        let want = case["format"].as_str().unwrap();
        let got = detect_manuscript_format(source.to_string(), title.map(str::to_string));
        if want != got {
            report.push(
                &format!("detect(source={:?}, title={title:?})", truncate(source)),
                format!("{want} != {got}"),
            );
        }
    }

    let extension_cases = g["extensionCases"].as_array().unwrap();
    assert_eq!(extension_cases.len(), 17);
    for case in extension_cases {
        let ext = case["extension"].as_str().unwrap();
        let want = case["format"].as_str();
        let got = manuscript_format_for_extension(ext.to_string());
        if want != got.as_deref() {
            report.push(
                &format!("extension({ext:?})"),
                format!("{want:?} != {:?}", got.as_deref()),
            );
        }
    }

    report.assert_empty("manuscript format detection");
}

fn truncate(text: &str) -> String {
    if text.chars().count() <= 40 {
        text.to_string()
    } else {
        format!("{}…", text.chars().take(40).collect::<String>())
    }
}

// ── Item 5: deduplication ────────────────────────────────────────────────────

/// Scenarios where Rust deliberately disagrees with the captured Swift output.
///
/// `arxiv-prefixed-form`: Swift's `normalizeArXiv` only stripped a trailing
/// `v<n>` (regex `v\d+$`), so `arXiv:2301.99999` and `2301.99999` were treated
/// as different papers and the duplicate reached the results list. Rust also
/// strips the `arxiv:` scheme prefix and lowercases, which merges them. That is
/// the behaviour the surface always wanted, so it is a strict gain rather than a
/// regression — but it *is* a difference, so it is named here instead of being
/// smoothed over.
const DEDUP_KNOWN_DIVERGENCES: [&str; 1] = ["arxiv-prefixed-form"];

fn dedup_input(row: &Value) -> imbib_core::deduplication::DeduplicationInput {
    imbib_core::deduplication::DeduplicationInput {
        id: row["id"].as_str().unwrap().to_string(),
        source_id: row["sourceID"].as_str().unwrap().to_string(),
        title: row["title"].as_str().unwrap().to_string(),
        first_author_last_name: opt(&row["firstAuthorLastName"]),
        year: row["year"].as_i64().map(|y| y as i32),
        doi: opt(&row["doi"]),
        arxiv_id: opt(&row["arxivID"]),
        pmid: opt(&row["pmid"]),
        bibcode: opt(&row["bibcode"]),
        semantic_scholar_id: opt(&row["semanticScholarID"]),
        open_alex_id: opt(&row["openAlexID"]),
    }
}

#[test]
fn deduplication_grouping_matches_swift_golden() {
    use imbib_core::deduplication::{deduplicate_search_results, DeduplicationConfig};

    let g = golden("deduplication_golden.json");
    let mut report = Report::default();
    let scenarios = g["scenarios"].as_array().unwrap();
    assert_eq!(scenarios.len(), 13, "golden scenario count changed");

    for scenario in scenarios {
        let name = scenario["name"].as_str().unwrap();
        if DEDUP_KNOWN_DIVERGENCES.contains(&name) {
            continue;
        }
        let inputs: Vec<_> = scenario["inputs"]
            .as_array()
            .unwrap()
            .iter()
            .map(dedup_input)
            .collect();
        let ids: Vec<String> = inputs.iter().map(|i| i.id.clone()).collect();

        let groups = deduplicate_search_results(inputs, DeduplicationConfig::default());
        let want = scenario["groups"].as_array().unwrap();

        if groups.len() != want.len() {
            report.push(
                name,
                format!("group count: want {} got {}", want.len(), groups.len()),
            );
            continue;
        }

        for (index, (expected, actual)) in want.iter().zip(groups.iter()).enumerate() {
            let want_primary = expected["primary"].as_str().unwrap();
            let got_primary = &ids[actual.primary_index as usize];
            if want_primary != got_primary {
                report.push(
                    name,
                    format!("group {index} primary: {want_primary} != {got_primary}"),
                );
            }

            // Alternate ORDER is asserted, not just the set: Swift sorted the
            // group by source priority, so the order is the source ranking and a
            // UI that shows "also on arXiv, DBLP" depends on it.
            let want_alternates: Vec<&str> = expected["alternates"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap())
                .collect();
            let got_alternates: Vec<&str> = actual
                .alternate_indices
                .iter()
                .map(|&i| ids[i as usize].as_str())
                .collect();
            if want_alternates != got_alternates {
                report.push(
                    name,
                    format!("group {index} alternates: {want_alternates:?} != {got_alternates:?}"),
                );
            }

            let want_identifiers: BTreeMap<String, String> = expected["identifiers"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string()))
                .collect();
            let got_identifiers: BTreeMap<String, String> = actual
                .identifiers
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect();
            if want_identifiers != got_identifiers {
                report.push(
                    name,
                    format!(
                        "group {index} identifiers: {want_identifiers:?} != {got_identifiers:?}"
                    ),
                );
            }
        }
    }

    report.assert_empty("deduplication grouping");
}

#[test]
fn the_known_dedup_divergence_is_the_one_documented() {
    use imbib_core::deduplication::{deduplicate_search_results, DeduplicationConfig};

    // Guard the divergence list itself: if Rust ever stops merging the prefixed
    // arXiv form, the "strict gain" claim above has quietly become false.
    let g = golden("deduplication_golden.json");
    let scenario = g["scenarios"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["name"] == "arxiv-prefixed-form")
        .expect("divergent scenario missing from the golden");

    let inputs: Vec<_> = scenario["inputs"]
        .as_array()
        .unwrap()
        .iter()
        .map(dedup_input)
        .collect();
    let groups = deduplicate_search_results(inputs, DeduplicationConfig::default());

    assert_eq!(
        scenario["groups"].as_array().unwrap().len(),
        2,
        "Swift kept `arXiv:2301.99999` and `2301.99999` apart"
    );
    assert_eq!(groups.len(), 1, "Rust merges them — that is the divergence");
}

#[test]
fn source_priority_table_matches_the_swift_literals() {
    use imbib_core::deduplication::{dedup_source_priorities, dedup_source_priority};

    // The literal table from `DeduplicationService.sourcePriority`.
    let expected: [(&str, u32); 7] = [
        ("crossref", 10),
        ("pubmed", 20),
        ("ads", 30),
        ("semanticscholar", 40),
        ("openalex", 50),
        ("arxiv", 60),
        ("dblp", 70),
    ];
    let table = dedup_source_priorities();
    assert_eq!(table.len(), expected.len());
    for ((name, priority), row) in expected.iter().zip(table.iter()) {
        assert_eq!(*name, row.source_id);
        assert_eq!(*priority, row.priority);
        assert_eq!(dedup_source_priority((*name).to_string()), *priority);
    }
    // Swift's `?? 100` fallback.
    assert_eq!(dedup_source_priority("europepmc".to_string()), 100);
}

// ── Item 7: hybrid search ranking ────────────────────────────────────────────

#[test]
fn hybrid_search_ranking_matches_swift_golden() {
    use impress_core::search_ops::{rank_hybrid_candidates, HybridCandidate};

    let g = golden("search_ranking_golden.json");
    let mut report = Report::default();
    let scenarios = g["scenarios"].as_array().unwrap();
    assert_eq!(scenarios.len(), 10, "golden scenario count changed");

    for scenario in scenarios {
        let name = scenario["name"].as_str().unwrap();
        let query = scenario["query"].as_str().unwrap();
        let candidates: Vec<HybridCandidate> = scenario["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| HybridCandidate {
                id: c["id"].as_str().unwrap().to_string(),
                cite_key: c["citeKey"].as_str().unwrap().to_string(),
                title: c["title"].as_str().unwrap().to_string(),
                authors: c["authors"].as_str().unwrap().to_string(),
                fts_score: c["ftsScore"].as_f64().map(|v| v as f32),
                semantic_similarity: c["semanticSimilarity"].as_f64().map(|v| v as f32),
                chunk_similarity: c["chunkSimilarity"].as_f64().map(|v| v as f32),
            })
            .collect();

        let ranked = rank_hybrid_candidates(query, &candidates);
        let want = scenario["ranked"].as_array().unwrap();

        if ranked.len() != want.len() {
            report.push(
                name,
                format!("row count: want {} got {}", want.len(), ranked.len()),
            );
            continue;
        }

        // Byte-for-byte order, and exact f32 equality on the score: the formula
        // is additions of literals, so "close enough" would hide a reordering.
        for (position, (expected, actual)) in want.iter().zip(ranked.iter()).enumerate() {
            let want_id = expected["id"].as_str().unwrap();
            if want_id != actual.id {
                report.push(name, format!("#{position} id: {want_id} != {}", actual.id));
            }
            let want_score = expected["score"].as_f64().unwrap() as f32;
            if want_score != actual.score {
                report.push(
                    name,
                    format!("#{position} score: {want_score} != {}", actual.score),
                );
            }
            let want_kind = expected["matchType"].as_str().unwrap();
            if want_kind != actual.match_type {
                report.push(
                    name,
                    format!(
                        "#{position} matchType: {want_kind} != {}",
                        actual.match_type
                    ),
                );
            }
        }
    }

    report.assert_empty("hybrid search ranking");
}
