//! ADR-0023 W5 — the golden corpus for watched-folder PDF matching.
//!
//! House discipline, the same shape as `golden_parity.rs`: a JSON corpus of
//! whole cases, one accumulating [`Report`] so a single run shows the entire
//! disagreement surface, and a hard pin on the case count so nobody quietly
//! deletes a scenario.
//!
//! What is deliberately different from `golden_parity.rs`: there is no Swift
//! implementation to be parity with, so there is no `KNOWN_DIVERGENCES` list.
//! These are not captured behaviours, they are **specified** ones — every
//! `why` in the corpus is the argument for the number beside it, and changing
//! a number means changing that argument in review.

mod common;

use std::collections::HashMap;

use common::fixtures::load_fixture;
use imbib_core::attachments::{
    match_attachments_internal, AttachmentEntry, AttachmentMatch, AttachmentMatchReport,
    AttachmentSignal, AttachmentVerdict,
};
use imbib_core::bibtex::{bdsk_file_encode, BibTeXField};
use serde_json::Value;

/// Confidences are pinned exactly; this is float-comparison slack, not a
/// tolerance band. A weight change moves a score by far more than this.
const EPSILON: f64 = 1e-6;

/// The corpus size, pinned. `golden_parity.rs` does the same for its 13 dedup
/// scenarios and for the same reason: a corpus that can silently shrink is not
/// a corpus.
const EXPECTED_CASE_COUNT: usize = 23;

// ── The accumulating report ─────────────────────────────────────────────────

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

// ── Corpus loading ──────────────────────────────────────────────────────────

fn corpus() -> Value {
    let raw = load_fixture("golden/pdf_match_golden.json");
    serde_json::from_str(&raw).expect("pdf_match_golden.json is not valid JSON")
}

/// One corpus entry → the matcher's input.
///
/// `bdskFiles` are ENCODED here rather than pasted as base64, so the corpus
/// stays readable AND `bdsk_file_encode`/`bdsk_file_decode` are exercised end
/// to end on every run — the round-trip the W5 gate names.
fn build_entry(spec: &Value) -> AttachmentEntry {
    let mut fields: Vec<BibTeXField> = Vec::new();
    if let Some(map) = spec.get("fields").and_then(Value::as_object) {
        // Sorted, so the corpus's JSON object order cannot leak into results.
        let mut keys: Vec<&String> = map.keys().collect();
        keys.sort();
        for key in keys {
            fields.push(BibTeXField {
                key: key.clone(),
                value: map[key].as_str().unwrap_or_default().to_string(),
            });
        }
    }
    if let Some(files) = spec.get("bdskFiles").and_then(Value::as_array) {
        for (index, path) in files.iter().enumerate() {
            let path = path.as_str().expect("bdskFiles entries are strings");
            let encoded = bdsk_file_encode(path.to_string())
                .unwrap_or_else(|| panic!("bdsk_file_encode refused {path}"));
            fields.push(BibTeXField {
                key: format!("Bdsk-File-{}", index + 1),
                value: encoded,
            });
        }
    }
    AttachmentEntry {
        id: spec["id"].as_str().expect("entry id").to_string(),
        cite_key: spec["citeKey"].as_str().expect("citeKey").to_string(),
        fields,
    }
}

fn signal_name(signal: AttachmentSignal) -> &'static str {
    signal.as_str()
}

fn verdict_name(verdict: AttachmentVerdict) -> &'static str {
    verdict.as_str()
}

fn describe(m: &AttachmentMatch) -> String {
    format!(
        "{} → {} ({}, {}, {:.4})",
        m.pdf_path,
        m.cite_key,
        signal_name(m.signal),
        verdict_name(m.verdict),
        m.confidence
    )
}

// ── The exact form: every match pinned ──────────────────────────────────────

fn check_exact_matches(report: &mut Report, name: &str, got: &AttachmentMatchReport, want: &Value) {
    let want_matches = want["matches"].as_array().expect("matches array");

    if got.matches.len() != want_matches.len() {
        report.push(
            name,
            format!(
                "expected {} match(es), got {}: [{}]",
                want_matches.len(),
                got.matches.len(),
                got.matches
                    .iter()
                    .map(describe)
                    .collect::<Vec<_>>()
                    .join("; ")
            ),
        );
        return;
    }

    for (index, expected) in want_matches.iter().enumerate() {
        let actual = &got.matches[index];
        let want_pdf = expected["pdf"].as_str().unwrap();
        let want_key = expected["citeKey"].as_str().unwrap();
        let want_signal = expected["signal"].as_str().unwrap();
        let want_verdict = expected["verdict"].as_str().unwrap();
        let want_confidence = expected["confidence"].as_f64().unwrap();

        if actual.pdf_path != want_pdf {
            report.push(
                name,
                format!(
                    "match {index}: pdf {:?}, wanted {want_pdf:?}",
                    actual.pdf_path
                ),
            );
        }
        if actual.cite_key != want_key {
            report.push(
                name,
                format!(
                    "match {index}: cite key {:?}, wanted {want_key:?}",
                    actual.cite_key
                ),
            );
        }
        // The entry id is the caller's routing handle. Every corpus entry uses
        // the cite key as its id, so a divergence here means the matcher
        // crossed a wire between the two.
        if actual.entry_id != want_key {
            report.push(
                name,
                format!(
                    "match {index}: entry id {:?}, wanted {want_key:?}",
                    actual.entry_id
                ),
            );
        }
        if signal_name(actual.signal) != want_signal {
            report.push(
                name,
                format!(
                    "match {index}: signal {:?}, wanted {want_signal:?}",
                    signal_name(actual.signal)
                ),
            );
        }
        if verdict_name(actual.verdict) != want_verdict {
            report.push(
                name,
                format!(
                    "match {index}: verdict {:?}, wanted {want_verdict:?} (confidence {:.4})",
                    verdict_name(actual.verdict),
                    actual.confidence
                ),
            );
        }
        if (actual.confidence - want_confidence).abs() > EPSILON {
            report.push(
                name,
                format!(
                    "match {index}: confidence {:.6}, wanted {want_confidence:.6}",
                    actual.confidence
                ),
            );
        }
        if actual.reason.trim().is_empty() {
            report.push(
                name,
                format!("match {index}: empty reason — the offer row would render a blank line"),
            );
        }
    }
}

// ── The shape form: for cases whose exact score is not the point ────────────

fn check_shape(report: &mut Report, name: &str, got: &AttachmentMatchReport, want: &Value) {
    if let Some(count) = want.get("matchCount").and_then(Value::as_u64) {
        if got.matches.len() as u64 != count {
            report.push(
                name,
                format!(
                    "expected {count} match(es), got {}: [{}]",
                    got.matches.len(),
                    got.matches
                        .iter()
                        .map(describe)
                        .collect::<Vec<_>>()
                        .join("; ")
                ),
            );
        }
    }
    if let Some(verdict) = want.get("allVerdicts").and_then(Value::as_str) {
        for m in &got.matches {
            if verdict_name(m.verdict) != verdict {
                report.push(
                    name,
                    format!("expected every verdict {verdict:?}: {}", describe(m)),
                );
            }
        }
    }
    if let Some(signal) = want.get("allSignals").and_then(Value::as_str) {
        for m in &got.matches {
            if signal_name(m.signal) != signal {
                report.push(
                    name,
                    format!("expected every signal {signal:?}: {}", describe(m)),
                );
            }
        }
    }
    if let Some(keys) = want.get("citeKeys").and_then(Value::as_array) {
        let wanted: Vec<&str> = keys.iter().map(|k| k.as_str().unwrap()).collect();
        let actual: Vec<&str> = got.matches.iter().map(|m| m.cite_key.as_str()).collect();
        if actual != wanted {
            report.push(name, format!("cite keys {actual:?}, wanted {wanted:?}"));
        }
    }
}

// ── The test ────────────────────────────────────────────────────────────────

#[test]
fn pdf_matching_reproduces_the_golden_corpus() {
    let corpus = corpus();
    let cases = corpus["cases"].as_array().expect("cases array");
    assert_eq!(
        cases.len(),
        EXPECTED_CASE_COUNT,
        "the golden corpus changed size — add the new case's count here deliberately"
    );

    let mut report = Report::default();
    let mut seen_names: HashMap<&str, usize> = HashMap::new();

    for case in cases {
        let name = case["name"].as_str().expect("case name");
        *seen_names.entry(name).or_default() += 1;

        assert!(
            case.get("why")
                .and_then(Value::as_str)
                .is_some_and(|w| w.len() > 20),
            "case {name} has no `why`: a golden number with no argument for it is a number \
             that will be changed to make a test pass"
        );

        let entries: Vec<AttachmentEntry> = case["entries"]
            .as_array()
            .expect("entries array")
            .iter()
            .map(build_entry)
            .collect();
        let pdfs: Vec<String> = case["pdfs"]
            .as_array()
            .expect("pdfs array")
            .iter()
            .map(|p| p.as_str().expect("pdf path").to_string())
            .collect();

        let got = match_attachments_internal(&entries, &pdfs);
        let want = &case["expected"];

        if want.get("matches").is_some() {
            check_exact_matches(&mut report, name, &got, want);
        } else {
            check_shape(&mut report, name, &got, want);
        }

        let want_unmatched: Vec<&str> = want["unmatched"]
            .as_array()
            .expect("unmatched array")
            .iter()
            .map(|u| u.as_str().unwrap())
            .collect();
        let got_unmatched: Vec<&str> = got.unmatched_pdfs.iter().map(String::as_str).collect();
        if got_unmatched != want_unmatched {
            report.push(
                name,
                format!("unmatched {got_unmatched:?}, wanted {want_unmatched:?}"),
            );
        }

        // Every PDF is accounted for exactly once: it either has at least one
        // candidate or it is unmatched, never both and never neither. This is
        // the invariant the offer surface depends on to render a complete list.
        for path in &pdfs {
            let claimed = got.matches.iter().any(|m| &m.pdf_path == path);
            let unmatched = got.unmatched_pdfs.contains(path);
            if claimed == unmatched {
                report.push(
                    name,
                    format!(
                        "{path} is {} — every PDF must be either matched or unmatched",
                        if claimed {
                            "both matched and unmatched"
                        } else {
                            "neither"
                        }
                    ),
                );
            }
        }

        // An `Automatic` verdict is a write to a user's library, so a PDF may
        // have at most one, and it may not sit beside an offer for the same
        // file.
        for path in &pdfs {
            let for_path: Vec<&AttachmentMatch> =
                got.matches.iter().filter(|m| &m.pdf_path == path).collect();
            let automatic = for_path
                .iter()
                .filter(|m| m.verdict == AttachmentVerdict::Automatic)
                .count();
            if automatic > 1 {
                report.push(name, format!("{path} has {automatic} automatic verdicts"));
            }
            if automatic == 1 && for_path.len() > 1 {
                report.push(
                    name,
                    format!(
                        "{path} has an automatic verdict AND {} offer(s)",
                        for_path.len() - 1
                    ),
                );
            }
        }
    }

    for (name, count) in seen_names {
        if count > 1 {
            report.push(
                "corpus",
                format!("case name {name:?} appears {count} times"),
            );
        }
    }

    report.assert_empty("watched-folder PDF matching");
}

/// The structural rule, asserted against the corpus rather than the constants:
/// **no case in the corpus auto-attaches on a fuzzy signal**, and none ever
/// can, because the ceiling is below the threshold.
#[test]
fn no_fuzzy_match_in_the_corpus_ever_auto_attaches() {
    let corpus = corpus();
    let mut fuzzy_seen = 0;
    for case in corpus["cases"].as_array().unwrap() {
        let entries: Vec<AttachmentEntry> = case["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(build_entry)
            .collect();
        let pdfs: Vec<String> = case["pdfs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| p.as_str().unwrap().to_string())
            .collect();
        for m in match_attachments_internal(&entries, &pdfs).matches {
            if m.signal == AttachmentSignal::Fuzzy {
                fuzzy_seen += 1;
                assert_eq!(
                    m.verdict,
                    AttachmentVerdict::Offer,
                    "a fuzzy match auto-attached in {}: {}",
                    case["name"],
                    describe(&m)
                );
                assert!(
                    m.confidence <= imbib_core::attachments::CONFIDENCE_FUZZY_CEILING + EPSILON,
                    "fuzzy confidence {} exceeds the ceiling in {}",
                    m.confidence,
                    case["name"]
                );
            }
        }
    }
    assert!(
        fuzzy_seen >= 2,
        "the corpus must actually exercise the fuzzy path; it produced {fuzzy_seen} fuzzy match(es)"
    );
}

/// Idempotence at the matcher's own level: the same inputs give the same
/// answer, in the same order. The re-scan idempotence one layer up rests on
/// this — a caller that re-ran the matcher and got a differently ordered
/// report could not tell "nothing changed" from "something did".
#[test]
fn matching_is_deterministic() {
    let corpus = corpus();
    for case in corpus["cases"].as_array().unwrap() {
        let entries: Vec<AttachmentEntry> = case["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(build_entry)
            .collect();
        let pdfs: Vec<String> = case["pdfs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| p.as_str().unwrap().to_string())
            .collect();
        let first = match_attachments_internal(&entries, &pdfs);
        let again = match_attachments_internal(&entries, &pdfs);
        assert_eq!(
            first, again,
            "non-deterministic result for {}",
            case["name"]
        );

        // And independent of the order the entries arrive in, which is the
        // store's business and not a fact about the folder.
        let mut reversed = entries.clone();
        reversed.reverse();
        let flipped = match_attachments_internal(&reversed, &pdfs);
        assert_eq!(
            first, flipped,
            "entry order changed the answer for {} — the tie-break is not total",
            case["name"]
        );
    }
}
