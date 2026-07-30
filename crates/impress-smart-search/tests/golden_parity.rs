//! Golden parity: every deterministic surface of the Swift
//! `ImpressSmartSearch` package, replayed against the Rust port.
//!
//! The fixtures in `test_fixtures/golden/` were captured from the Swift
//! implementations *before* their bodies were replaced (Stage 7 item 8 of the
//! declarative-chassis campaign), by a temporary harness that has since been
//! deleted — the goldens are the artifact. There is deliberately no
//! regeneration path: a fixture that can be regenerated from the code it
//! checks isn't a golden, it's a snapshot of today's bug.
//!
//! The same files are asserted from Swift by
//! `PublicationManagerCoreTests/Golden/SmartSearchParityTests.swift`, which
//! goes through the real FFI so a bridge-level regression (a lost field, a
//! stale xcframework) fails there rather than here.
//!
//! Style follows `imbib-core/tests/golden_parity.rs`: accumulate every
//! mismatch into a `Report` and panic once, so a single run shows the whole
//! disagreement surface instead of the first case that broke.

use serde_json::Value;
use std::path::PathBuf;

use impress_smart_search::{
    ads_normalizer, intent, reference, rewriter,
    types::{ParsedReference, QueryParts},
    url_extract,
};

// ---------------------------------------------------------------- infrastructure

fn golden(name: &str) -> Vec<Value> {
    let path: PathBuf = [env!("CARGO_MANIFEST_DIR"), "test_fixtures", "golden", name]
        .iter()
        .collect();
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("missing golden {}: {e}", path.display()));
    serde_json::from_str(&raw).unwrap_or_else(|e| panic!("bad golden {name}: {e}"))
}

#[derive(Default)]
struct Report {
    lines: Vec<String>,
}

impl Report {
    fn eq<T: std::fmt::Debug + PartialEq>(&mut self, scope: &str, want: T, got: T) {
        if want != got {
            self.lines
                .push(format!("[{scope}] want {want:?}, got {got:?}"));
        }
    }

    fn assert_empty(self, what: &str) {
        if !self.lines.is_empty() {
            let shown: Vec<_> = self.lines.iter().take(40).cloned().collect();
            panic!(
                "{} golden mismatches for {what}:\n{}",
                self.lines.len(),
                shown.join("\n")
            );
        }
    }
}

fn s(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap_or_default().to_string()
}

fn opt_s(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(String::from)
}

fn strings(v: &Value, key: &str) -> Vec<String> {
    v[key]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|x| x.as_str().unwrap_or_default().to_string())
                .collect()
        })
        .unwrap_or_default()
}

/// Short, stable case label for report lines.
fn tag(input: &str) -> String {
    let flat: String = input
        .chars()
        .map(|c| if c == '\n' { '⏎' } else { c })
        .collect();
    if flat.chars().count() > 48 {
        format!("{}…", flat.chars().take(48).collect::<String>())
    } else {
        flat
    }
}

// ---------------------------------------------------------------- known divergences

/// Cases where the Rust port intentionally differs from Swift. Each entry is a
/// deliberate decision, not a tolerance: an *unlisted* mismatch fails the
/// build. Empty is the goal, and the goal was reached — the only behavioral
/// changes made during the port were on surfaces the Swift original left
/// untestable (year injection) or nondeterministic (HTML-entity ordering,
/// which no corpus case observes). Both are documented in the module docs of
/// `rewriter` and `url_extract` respectively.
const KNOWN_DIVERGENCES: &[(&str, &str)] = &[];

// ---------------------------------------------------------------- intent

#[test]
fn intent_classify_matches_swift() {
    let cases = golden("intent_classify.json");
    assert_eq!(cases.len(), 288, "golden classify corpus size changed");
    let mut r = Report::default();

    for c in &cases {
        let input = s(c, "input");
        let t = tag(&input);
        let got = intent::classify(&input);
        let flat = impress_smart_search::ClassifiedInput::from(got);

        r.eq(&format!("kind/{t}"), s(c, "kind"), flat.kind.clone());
        r.eq(&format!("label/{t}"), s(c, "label"), flat.label.clone());

        match flat.kind.as_str() {
            "identifier" => {
                r.eq(
                    &format!("idKind/{t}"),
                    opt_s(c, "idKind"),
                    flat.identifier_kind,
                );
                r.eq(&format!("idValue/{t}"), opt_s(c, "value"), flat.value);
            }
            "fielded" | "freeText" => {
                r.eq(&format!("query/{t}"), opt_s(c, "query"), flat.query);
            }
            "reference" => {
                r.eq(&format!("blocks/{t}"), strings(c, "blocks"), flat.blocks);
            }
            "url" => {
                r.eq(&format!("url/{t}"), opt_s(c, "url"), flat.value);
            }
            other => panic!("unknown kind {other}"),
        }
    }
    r.assert_empty("intent classification");
}

#[test]
fn intent_predicates_match_swift() {
    let quals = golden("intent_has_field_qualifiers.json");
    let refs = golden("intent_looks_like_reference.json");
    let splits = golden("intent_split_reference_blocks.json");
    let ids = golden("intent_identifier_match.json");
    assert_eq!(quals.len(), 288);
    assert_eq!(refs.len(), 288);
    assert_eq!(splits.len(), 288);
    assert_eq!(ids.len(), 288);
    let mut r = Report::default();

    for c in &quals {
        let input = s(c, "input");
        r.eq(
            &format!("hasFieldQualifiers/{}", tag(&input)),
            c["result"].as_bool().unwrap(),
            intent::has_field_qualifiers(&input),
        );
    }
    for c in &refs {
        let input = s(c, "input");
        r.eq(
            &format!("looksLikeReference/{}", tag(&input)),
            c["result"].as_bool().unwrap(),
            intent::looks_like_reference(&input),
        );
    }
    for c in &splits {
        let input = s(c, "input");
        r.eq(
            &format!("splitBlocks/{}", tag(&input)),
            strings(c, "blocks"),
            intent::split_reference_blocks(&input),
        );
    }
    for c in &ids {
        let input = s(c, "input");
        let t = tag(&input);
        let got = intent::identifier_match(&input);
        r.eq(
            &format!("identifierMatch.kind/{t}"),
            opt_s(c, "idKind"),
            got.as_ref().map(|i| i.type_name().to_string()),
        );
        r.eq(
            &format!("identifierMatch.value/{t}"),
            opt_s(c, "value"),
            got.as_ref().map(|i| i.value().to_string()),
        );
    }
    r.assert_empty("intent predicates");
}

#[test]
fn intent_url_dissection_matches_foundation() {
    let cases = golden("intent_url_dissect.json");
    assert_eq!(cases.len(), 288);
    let mut r = Report::default();

    for c in &cases {
        let input = s(c, "input");
        let t = tag(&input);
        let got = intent::url_match(&input);

        match (opt_s(c, "url"), &got) {
            (None, None) => {}
            (None, Some(u)) => r
                .lines
                .push(format!("[urlMatch/{t}] Swift saw no URL, Rust got {u:?}")),
            (Some(want), None) => r
                .lines
                .push(format!("[urlMatch/{t}] Swift got {want:?}, Rust saw none")),
            (Some(want), Some(u)) => {
                r.eq(
                    &format!("absoluteString/{t}"),
                    want,
                    u.absolute_string.clone(),
                );
                r.eq(&format!("host/{t}"), s(c, "host"), u.host.clone());
                r.eq(&format!("path/{t}"), s(c, "path"), u.path.clone());

                let id = intent::identifier_from_url(u);
                r.eq(
                    &format!("identifierFromURL.kind/{t}"),
                    opt_s(c, "idKind"),
                    id.as_ref().map(|i| i.type_name().to_string()),
                );
                r.eq(
                    &format!("identifierFromURL.value/{t}"),
                    opt_s(c, "idValue"),
                    id.as_ref().map(|i| i.value().to_string()),
                );
                r.eq(
                    &format!("searchQueryFromURL/{t}"),
                    opt_s(c, "searchQuery"),
                    intent::search_query_from_url(u),
                );
                r.eq(
                    &format!("doiInPath/{t}"),
                    opt_s(c, "doiInPath"),
                    intent::doi_in_path(&u.path),
                );
            }
        }
    }
    r.assert_empty("URL dissection");
}

// ---------------------------------------------------------------- ads normalizer

#[test]
fn ads_normalize_matches_swift() {
    let cases = golden("ads_normalize.json");
    assert_eq!(cases.len(), 125, "golden normalizer corpus size changed");
    let mut r = Report::default();

    for c in &cases {
        let input = s(c, "input");
        let t = tag(&input);
        let got = ads_normalizer::normalize(&input);
        r.eq(
            &format!("corrected/{t}"),
            s(c, "corrected"),
            got.corrected_query.clone(),
        );
        r.eq(
            &format!("corrections/{t}"),
            strings(c, "corrections"),
            got.corrections.clone(),
        );
        r.eq(
            &format!("wasModified/{t}"),
            c["wasModified"].as_bool().unwrap(),
            got.was_modified(),
        );
        // Idempotence: normalizing the output must be a fixed point. Swift is
        // a fixed point on all 121 cases; a Rust rule that isn't would silently
        // corrupt a query that round-trips through the UI twice.
        let second = ads_normalizer::normalize(&got.corrected_query);
        r.eq(
            &format!("secondPass/{t}"),
            s(c, "secondPass"),
            second.corrected_query,
        );
    }
    r.assert_empty("ADS normalization");
}

// ---------------------------------------------------------------- rewriter

fn parts_from(v: &Value) -> QueryParts {
    QueryParts {
        authors: strings(v, "authors"),
        bibstem: s(v, "bibstem"),
        topic_words: strings(v, "topicWords"),
        year_from: v["yearFrom"].as_i64().unwrap_or(0),
        year_to: v["yearTo"].as_i64().unwrap_or(0),
        refereed_only: v["refereedOnly"].as_bool().unwrap_or(false),
        interpretation: String::new(),
        confidence: 0.0,
    }
}

#[test]
fn rewriter_build_query_matches_swift() {
    let cases = golden("rewriter_build_query.json");
    assert_eq!(cases.len(), 39, "golden buildQuery corpus size changed");
    let mut r = Report::default();
    for c in &cases {
        let parts = parts_from(&c["parts"]);
        let original = s(c, "originalInput");
        let year = c["thisYear"].as_i64().unwrap();
        r.eq(
            &format!("buildQuery/{}|{:?}", tag(&original), parts.authors),
            s(c, "query"),
            rewriter::build_query(&parts, &original, year),
        );
    }
    r.assert_empty("buildQuery");
}

#[test]
fn rewriter_filter_authors_matches_swift() {
    let cases = golden("rewriter_filter_authors.json");
    assert_eq!(cases.len(), 39);
    let mut r = Report::default();
    for c in &cases {
        let authors = strings(c, "authors");
        let input_lower = s(c, "inputLower");
        let got = rewriter::filter_authors(&authors, &input_lower);
        let t = format!("{:?}|{}", authors, tag(&input_lower));
        r.eq(
            &format!("filtered/{t}"),
            strings(c, "filtered"),
            got.filtered,
        );
        r.eq(
            &format!("rejected/{t}"),
            strings(c, "rejected"),
            got.rejected,
        );
    }
    r.assert_empty("filterAuthors");
}

#[test]
fn rewriter_extract_decade_matches_swift() {
    let cases = golden("rewriter_extract_decade.json");
    assert_eq!(cases.len(), 371);
    let mut r = Report::default();
    for c in &cases {
        let input = s(c, "input");
        let want = match (c["from"].as_i64(), c["to"].as_i64()) {
            (Some(a), Some(b)) => Some((a, b)),
            _ => None,
        };
        r.eq(
            &format!("extractDecade/{}", tag(&input)),
            want,
            rewriter::extract_decade(&input),
        );
    }
    r.assert_empty("extractDecade");
}

#[test]
fn rewriter_degenerate_matches_swift() {
    let cases = golden("rewriter_degenerate.json");
    assert_eq!(cases.len(), 83, "golden degenerate corpus size changed");
    let mut r = Report::default();
    for c in &cases {
        let input = s(c, "input");
        let t = tag(&input);
        let got = rewriter::degenerate_rewrite(&input, c["thisYear"].as_i64().unwrap());
        r.eq(&format!("query/{t}"), s(c, "query"), got.query);
        r.eq(
            &format!("interpretation/{t}"),
            s(c, "interpretation"),
            got.interpretation,
        );
        r.eq(
            &format!("confidence/{t}"),
            c["confidence"].as_f64().unwrap(),
            got.confidence,
        );
        r.eq(
            &format!("source/{t}"),
            s(c, "source"),
            got.source.raw_value().to_string(),
        );
    }
    r.assert_empty("degenerate rewrite");
}

#[test]
fn rewriter_clean_query_matches_swift() {
    let cases = golden("rewriter_clean_query.json");
    assert_eq!(cases.len(), 37);
    let mut r = Report::default();
    for c in &cases {
        let input = s(c, "input");
        let t = tag(&input);
        r.eq(
            &format!("cleaned/{t}"),
            s(c, "cleaned"),
            rewriter::clean_query(&input),
        );
        r.eq(
            &format!("unquoted/{t}"),
            s(c, "unquoted"),
            rewriter::unquote_topic_fields(&input),
        );
        r.eq(
            &format!("commas/{t}"),
            s(c, "commas"),
            rewriter::collapse_commas_outside_quotes(&input),
        );
    }
    r.assert_empty("cleanQuery");
}

#[test]
fn cloud_json_decode_matches_swift() {
    let rw = golden("rewriter_decode_cloud_json.json");
    let rf = golden("reference_decode_cloud_json.json");
    let fences = golden("strip_code_fences.json");
    assert_eq!(rw.len(), 29, "golden cloud-JSON corpus size changed");
    assert_eq!(rf.len(), 29);
    assert_eq!(fences.len(), 29);
    let mut r = Report::default();

    for c in &rw {
        let input = s(c, "input");
        let t = tag(&input);
        let got = rewriter::decode_cloud_json(&input);
        let swift_nil = c.get("result").map(Value::is_null).unwrap_or(false);
        match (swift_nil, &got) {
            (true, None) => {}
            (true, Some(g)) => r.lines.push(format!("[rwCloud/{t}] Swift nil, Rust {g:?}")),
            (false, None) => r
                .lines
                .push(format!("[rwCloud/{t}] Swift decoded, Rust nil")),
            (false, Some(g)) => {
                r.eq(
                    &format!("rwCloud.query/{t}"),
                    s(c, "query"),
                    g.query.clone(),
                );
                r.eq(
                    &format!("rwCloud.interpretation/{t}"),
                    s(c, "interpretation"),
                    g.interpretation.clone(),
                );
                r.eq(
                    &format!("rwCloud.confidence/{t}"),
                    c["confidence"].as_f64().unwrap(),
                    g.confidence,
                );
                r.eq(
                    &format!("rwCloud.source/{t}"),
                    s(c, "source"),
                    g.source.raw_value().to_string(),
                );
            }
        }
    }

    for c in &rf {
        let input = s(c, "input");
        let t = tag(&input);
        let got = reference::decode_cloud_json(&input);
        match (c["parsed"].is_null(), &got) {
            (true, None) => {}
            (true, Some(g)) => r
                .lines
                .push(format!("[refCloud/{t}] Swift nil, Rust {g:?}")),
            (false, None) => r
                .lines
                .push(format!("[refCloud/{t}] Swift decoded, Rust nil")),
            (false, Some(g)) => {
                let want = &c["parsed"];
                r.eq(
                    &format!("refCloud.authors/{t}"),
                    strings(want, "authors"),
                    g.authors.clone(),
                );
                r.eq(
                    &format!("refCloud.title/{t}"),
                    s(want, "title"),
                    g.title.clone(),
                );
                r.eq(
                    &format!("refCloud.year/{t}"),
                    want["year"].as_i64().unwrap(),
                    g.year,
                );
                r.eq(
                    &format!("refCloud.journal/{t}"),
                    s(want, "journal"),
                    g.journal.clone(),
                );
                r.eq(
                    &format!("refCloud.volume/{t}"),
                    s(want, "volume"),
                    g.volume.clone(),
                );
                r.eq(
                    &format!("refCloud.pages/{t}"),
                    s(want, "pages"),
                    g.pages.clone(),
                );
                r.eq(&format!("refCloud.doi/{t}"), s(want, "doi"), g.doi.clone());
                r.eq(
                    &format!("refCloud.arxiv/{t}"),
                    s(want, "arxiv"),
                    g.arxiv.clone(),
                );
                r.eq(
                    &format!("refCloud.bibcode/{t}"),
                    s(want, "bibcode"),
                    g.bibcode.clone(),
                );
                r.eq(
                    &format!("refCloud.confidence/{t}"),
                    want["confidence"].as_f64().unwrap(),
                    g.confidence,
                );
            }
        }
    }

    // Both Swift parsers carried their own private copy of the fence stripper;
    // they were identical, and both are pinned against the one Rust function.
    for c in &fences {
        let input = s(c, "input");
        let t = tag(&input);
        let got = rewriter::strip_code_fences(&input);
        r.eq(
            &format!("fences.rewriter/{t}"),
            s(c, "rewriter"),
            got.clone(),
        );
        r.eq(&format!("fences.reference/{t}"), s(c, "reference"), got);
    }

    r.assert_empty("cloud JSON decoding");
}

// ---------------------------------------------------------------- reference

#[test]
fn reference_validate_matches_swift() {
    let cases = golden("reference_validate.json");
    assert_eq!(cases.len(), 15, "golden validate corpus size changed");
    let mut r = Report::default();

    for c in &cases {
        let p = &c["parsed"];
        let parsed = ParsedReference {
            authors: strings(p, "authors"),
            title: s(p, "title"),
            year: p["year"].as_i64().unwrap(),
            journal: s(p, "journal"),
            volume: s(p, "volume"),
            pages: s(p, "pages"),
            doi: s(p, "doi"),
            arxiv: s(p, "arxiv"),
            bibcode: s(p, "bibcode"),
            confidence: p["confidence"].as_f64().unwrap(),
        };
        let raw = s(c, "raw");
        let got = reference::validate(&parsed, &raw);
        let want = &c["citation"];
        let t = format!("{:?}/{}", parsed.authors, parsed.year);

        r.eq(
            &format!("authors/{t}"),
            strings(want, "authors"),
            got.authors.clone(),
        );
        r.eq(
            &format!("title/{t}"),
            opt_s(want, "title"),
            got.title.clone(),
        );
        r.eq(&format!("year/{t}"), want["year"].as_i64(), got.year);
        r.eq(
            &format!("journal/{t}"),
            opt_s(want, "journal"),
            got.journal.clone(),
        );
        r.eq(
            &format!("volume/{t}"),
            opt_s(want, "volume"),
            got.volume.clone(),
        );
        r.eq(
            &format!("pages/{t}"),
            opt_s(want, "pages"),
            got.pages.clone(),
        );
        r.eq(&format!("doi/{t}"), opt_s(want, "doi"), got.doi.clone());
        r.eq(
            &format!("arxiv/{t}"),
            opt_s(want, "arxiv"),
            got.arxiv.clone(),
        );
        r.eq(
            &format!("bibcode/{t}"),
            opt_s(want, "bibcode"),
            got.bibcode.clone(),
        );
        r.eq(
            &format!("freeText/{t}"),
            opt_s(want, "freeText"),
            got.free_text.clone(),
        );
        r.eq(
            &format!("hasIdentifier/{t}"),
            want["hasIdentifier"].as_bool().unwrap(),
            got.has_identifier(),
        );
    }
    r.assert_empty("reference validation");
}

#[test]
fn prompts_match_swift_byte_for_byte() {
    let cases = golden("prompts.json");
    assert_eq!(cases.len(), 4);
    let mut r = Report::default();
    for c in &cases {
        let input = s(c, "input");
        let t = tag(&input);
        r.eq(
            &format!("rewritePrompt/{t}"),
            s(c, "rewritePrompt"),
            rewriter::make_rewrite_prompt(&input, 2026, "2026-07-30"),
        );
        r.eq(
            &format!("referencePrompt/{t}"),
            s(c, "referencePrompt"),
            reference::make_reference_prompt(&input),
        );
    }
    r.assert_empty("prompts");
}

// ---------------------------------------------------------------- url extraction

#[test]
fn url_extraction_matches_swift() {
    let cases = golden("url_extract.json");
    assert_eq!(cases.len(), 77, "golden HTML corpus size changed");
    let mut r = Report::default();

    for c in &cases {
        let html = s(c, "html");
        let t = tag(&html);
        r.eq(
            &format!("title/{t}"),
            opt_s(c, "title"),
            url_extract::extract_title(&html),
        );

        let want: Vec<(String, String)> = c["identifiers"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| (s(i, "kind"), s(i, "value")))
            .collect();
        let got: Vec<(String, String)> = url_extract::extract_identifiers(&html)
            .into_iter()
            .map(|i| (i.type_name().to_string(), i.value().to_string()))
            .collect();
        r.eq(&format!("identifiers/{t}"), want, got);

        r.eq(
            &format!("entities/{t}"),
            s(c, "entities"),
            url_extract::decode_html_entities(&html),
        );
    }
    r.assert_empty("URL extraction");
}

#[test]
fn url_helpers_match_swift() {
    let punct = golden("url_trim_trailing_punct.json");
    let unwound = golden("url_unwind_double_encoding.json");
    assert_eq!(punct.len(), 13);
    assert_eq!(unwound.len(), 10);
    let mut r = Report::default();

    for c in &punct {
        let input = s(c, "input");
        r.eq(
            &format!("trimTrailingPunct/{}", tag(&input)),
            s(c, "output"),
            url_extract::trim_trailing_punct(&input),
        );
    }
    for c in &unwound {
        let input = s(c, "input");
        r.eq(
            &format!("unwindDoubleEncoding/{}", tag(&input)),
            opt_s(c, "output"),
            url_extract::unwind_double_encoding(&input),
        );
    }
    r.assert_empty("URL helpers");
}

#[test]
fn known_divergences_are_empty() {
    // Kept as an explicit assertion so that adding a tolerance requires
    // editing a test named "known divergences", not quietly widening a match.
    assert!(
        KNOWN_DIVERGENCES.is_empty(),
        "undocumented divergences: {KNOWN_DIVERGENCES:?}"
    );
}
