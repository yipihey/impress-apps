//! Golden-corpus parity for the Swift → Rust `SectionExtractor` port
//! (Stage 7 item 6).
//!
//! `test_fixtures/golden/sections_golden.json` was captured by running the Swift
//! `SectionExtractor` over the documents in `test_fixtures/golden/sections/`
//! before its body was replaced by an FFI call (see
//! `SwiftGoldenCorpusCapture.swift` in git history). These tests assert the Rust
//! implementation reproduces it.
//!
//! The **section ids matter most**: they are persisted as `manuscript-section`
//! row ids, so a derivation change does not error, it silently orphans every
//! existing row. `id_sets_match_swift_exactly` compares the full id set per
//! document; `id_derivation_matches_swift` pins the derivation on its own,
//! independent of the heading scanner.

use std::collections::BTreeMap;
use std::path::PathBuf;

use imprint_core::sections::{extract, section_id, SectionFormat};
use serde_json::Value;
use uuid::Uuid;

fn fixture_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("test_fixtures")
        .join("golden")
}

fn golden() -> Value {
    let path = fixture_root().join("sections_golden.json");
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("missing golden {}: {e}", path.display()));
    serde_json::from_str(&raw).unwrap_or_else(|e| panic!("bad golden JSON: {e}"))
}

/// Collects every mismatch so one run reports the whole disagreement surface
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

fn source_for(name: &str) -> String {
    let path = fixture_root().join(name);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("missing fixture {}: {e}", path.display()))
}

fn format_for(value: &Value) -> Option<SectionFormat> {
    value.as_str().map(SectionFormat::from_str_lenient)
}

#[test]
fn section_extraction_matches_swift_golden() {
    let g = golden();
    let mut report = Report::default();
    let mut documents_seen = 0;
    let mut sections_seen = 0;

    for doc in g["documents"].as_array().unwrap() {
        documents_seen += 1;
        let name = doc["name"].as_str().unwrap();
        let scope = format!("{name} format={}", doc["format"]);
        let source = source_for(name);
        let document_id = Uuid::parse_str(doc["documentID"].as_str().unwrap()).unwrap();

        let got = extract(&source, document_id, format_for(&doc["format"]));
        let want = doc["sections"].as_array().unwrap();

        if got.len() != want.len() {
            report.push(
                &scope,
                format!("section count: want {} got {}", want.len(), got.len()),
            );
            continue;
        }

        for (expected, actual) in want.iter().zip(got.iter()) {
            sections_seen += 1;
            let idx = expected["orderIndex"].as_u64().unwrap();
            let mut check = |field: &str, want: String, have: String| {
                if want != have {
                    report.push(&scope, format!("section {idx} {field}: {want} != {have}"));
                }
            };
            check(
                "id",
                expected["id"].as_str().unwrap().to_string(),
                actual.id.to_string(),
            );
            check(
                "title",
                format!("{:?}", expected["title"].as_str().unwrap()),
                format!("{:?}", actual.title),
            );
            check(
                "level",
                expected["level"].to_string(),
                actual.level.to_string(),
            );
            check(
                "start",
                expected["start"].to_string(),
                actual.start.to_string(),
            );
            check("end", expected["end"].to_string(), actual.end.to_string());
            check(
                "bodyStart",
                expected["bodyStart"].to_string(),
                actual.body_start.to_string(),
            );
            check(
                "orderIndex",
                expected["orderIndex"].to_string(),
                actual.order_index.to_string(),
            );
            check(
                "sectionType",
                format!("{:?}", expected["sectionType"].as_str()),
                format!("{:?}", actual.section_type.as_deref()),
            );
            check(
                "wordCount",
                expected["wordCount"].to_string(),
                actual.word_count.to_string(),
            );
        }
    }

    assert_eq!(documents_seen, 10, "golden document count changed");
    assert_eq!(sections_seen, 36, "golden section count changed");
    report.assert_empty("section extraction");
}

#[test]
fn id_sets_match_swift_exactly() {
    // The narrow question a data migration cares about: for each document, is
    // the SET of section ids identical? Compared separately from the field-level
    // test so a cosmetic field change cannot mask an id change.
    let g = golden();
    let mut report = Report::default();

    for doc in g["documents"].as_array().unwrap() {
        let name = doc["name"].as_str().unwrap();
        let scope = format!("{name} format={}", doc["format"]);
        let source = source_for(name);
        let document_id = Uuid::parse_str(doc["documentID"].as_str().unwrap()).unwrap();

        let want: BTreeMap<u64, String> = doc["sections"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| {
                (
                    s["orderIndex"].as_u64().unwrap(),
                    s["id"].as_str().unwrap().to_string(),
                )
            })
            .collect();
        let got: BTreeMap<u64, String> = extract(&source, document_id, format_for(&doc["format"]))
            .iter()
            .map(|s| (s.order_index as u64, s.id.to_string()))
            .collect();

        if want != got {
            report.push(&scope, format!("id set: want {want:?} got {got:?}"));
        }
    }

    report.assert_empty("section id sets");
}

#[test]
fn id_derivation_matches_swift() {
    let g = golden();
    let mut report = Report::default();
    let cases = g["idCases"].as_array().unwrap();
    assert_eq!(cases.len(), 10);

    for case in cases {
        let doc = Uuid::parse_str(case["documentID"].as_str().unwrap()).unwrap();
        let title = case["title"].as_str().unwrap();
        let index = case["orderIndex"].as_u64().unwrap() as usize;
        let want = case["id"].as_str().unwrap();
        let got = section_id(doc, title, index).to_string();
        if want != got {
            report.push(
                &format!("{title:?}@{index}"),
                format!("id: {want} != {got}"),
            );
        }
    }

    report.assert_empty("section id derivation");
}

#[test]
fn utf16_offsets_agree_with_the_grapheme_offsets_they_shadow() {
    // The `*_utf16` fields are new — Swift had no equivalent, so they cannot be
    // golden-checked. What they must satisfy is that they address the SAME text:
    // slicing the source by UTF-16 units at those offsets must yield the same
    // string as slicing by graphemes.
    for doc in golden()["documents"].as_array().unwrap() {
        let name = doc["name"].as_str().unwrap();
        let source = source_for(name);
        let units: Vec<u16> = source.encode_utf16().collect();
        let graphemes: Vec<&str> =
            unicode_segmentation::UnicodeSegmentation::graphemes(source.as_str(), true).collect();

        for section in extract(&source, Uuid::nil(), format_for(&doc["format"])) {
            let by_grapheme = graphemes[section.start..section.end].concat();
            let by_utf16 =
                String::from_utf16(&units[section.start_utf16..section.end_utf16]).unwrap();
            assert_eq!(
                by_grapheme, by_utf16,
                "{name}: section {}",
                section.order_index
            );
        }
    }
}
