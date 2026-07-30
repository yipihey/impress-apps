//! Free-text → ADS query rewriting.
//!
//! Port of the deterministic half of `FreeTextQueryRewriter.swift`. The LLM
//! call itself (Apple Intelligence `@Generable`, or a cloud runner) stays in
//! Swift — see the crate docs for the split. Everything the model's output
//! passes *through* lives here:
//!
//! * [`build_query`] — assemble ADS syntax from structured [`QueryParts`],
//!   including the hallucination filters. This is the on-device path's whole
//!   output stage.
//! * [`degenerate_rewrite`] — the no-LLM fallback.
//! * [`clean_query`] — repair a cloud model's free-form query string.
//! * [`decode_cloud_json`] / [`strip_code_fences`] — parse the cloud response.
//! * [`make_rewrite_prompt`] — the prompt is part of the contract with the
//!   model, so it is pinned by the golden corpus too.
//!
//! `this_year` is threaded explicitly rather than read from the clock: the
//! Swift original called `Calendar.current.component(.year, from: Date())`
//! inline, which made every year-relative branch untestable.

use lazy_static::lazy_static;
use regex::Regex;
use serde::Deserialize;
use std::collections::HashSet;

use crate::ads_normalizer;
use crate::foundation::{split_ws_nl, trim_ws, trim_ws_nl};
use crate::types::{QueryParts, QueryRewriteResult, RewriteSource};

lazy_static! {
    static ref RE_DECADE: Regex = Regex::new(r"\b(19|20)(\d)0s\b").unwrap();
    static ref RE_DECADE_WORD: Regex = Regex::new(r"\A(\d{4})s\z").unwrap();
    /// `\bfield:"value"` per topic field, case-insensitive.
    static ref RE_TOPIC_FIELDS: Vec<(&'static str, Regex)> = TOPIC_FIELDS
        .iter()
        .map(|f| (*f, Regex::new(&format!(r#"(?i)\b{f}:"([^"]+)""#)).unwrap()))
        .collect();
}

/// Fields where ADS expects a word list in `(...)`, not a quoted exact phrase.
const TOPIC_FIELDS: &[&str] = &[
    "title", "abs", "abstract", "body", "full", "object", "keyword",
];

/// Names that are never human authors — instruments, telescopes, satellites,
/// surveys, common nouns. The model mis-classifies these as authors often
/// enough that the blacklist earns its keep.
const NON_AUTHOR_NAMES: &[&str] = &[
    // Telescopes / observatories
    "JWST",
    "HST",
    "Hubble",
    "Webb",
    "Chandra",
    "Fermi",
    "Spitzer",
    "Herschel",
    "Kepler",
    "TESS",
    "ALMA",
    "VLA",
    "VLBA",
    "LIGO",
    "Virgo",
    "KAGRA",
    "Planck",
    "WMAP",
    "COBE",
    "GAIA",
    "Gaia",
    "ROSAT",
    "XMM",
    "INTEGRAL",
    "Swift",
    "NICER",
    "Euclid",
    "Roman",
    "PLATO",
    "ARIEL",
    "WFIRST",
    // Surveys / datasets
    "SDSS",
    "DESI",
    "DES",
    "LSST",
    "Pan-STARRS",
    "PanSTARRS",
    "ZTF",
    "ATLAS",
    "BOSS",
    "eBOSS",
    "MaNGA",
    "APOGEE",
    "GALAH",
    "RAVE",
    "2MASS",
    "WISE",
    "GALEX",
    "Vera",
    "Rubin",
    "DR16",
    "DR17",
    "DR18",
    "DR19",
    "DR20",
    // Generic words sometimes mis-flagged
    "Galaxy",
    "Galaxies",
    "Star",
    "Stars",
    "Curves",
    "Curve",
    "Rotation",
    "Energy",
    "Matter",
    "Radiation",
    "Waves",
    "Wave",
    "Field",
    "Fields",
    "Cosmology",
    "Inflation",
    "Universe",
    "Cosmic",
    "Astronomy",
];

lazy_static! {
    static ref NON_AUTHOR_LOWER: HashSet<String> =
        NON_AUTHOR_NAMES.iter().map(|n| n.to_lowercase()).collect();
}

/// Outcome of author filtering: accepted names, plus names rejected as
/// non-authors (which get re-injected as topic words rather than dropped).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthorFilterResult {
    pub filtered: Vec<String>,
    pub rejected: Vec<String>,
}

/// Three rules, in order: blacklist, capitalization, and presence in the
/// original input (which catches hallucinations like
/// `"SDSS DR17 spectroscopy"` → `author:"Smith"`).
///
/// Names shorter than 2 characters, or with no letters at all, are dropped
/// entirely — they appear in neither list.
pub fn filter_authors(raw: &[String], input_lower: &str) -> AuthorFilterResult {
    let mut ok: Vec<String> = Vec::new();
    let mut bad: Vec<String> = Vec::new();

    for r in raw {
        let trimmed = trim_ws_nl(r);
        if trimmed.chars().count() < 2 {
            continue;
        }
        if !trimmed.chars().any(|c| c.is_alphabetic()) {
            continue;
        }
        let lower = trimmed.to_lowercase();
        if NON_AUTHOR_LOWER.contains(&lower) {
            bad.push(trimmed.to_string());
            continue;
        }
        // Swift: `trimmed.first?.isUppercase == false` — a leading digit or an
        // uncased script (e.g. CJK) counts as "not uppercase" and is rejected.
        if !trimmed
            .chars()
            .next()
            .map(char::is_uppercase)
            .unwrap_or(false)
        {
            bad.push(trimmed.to_string());
            continue;
        }
        if !input_lower.is_empty() && !input_lower.contains(&lower) {
            bad.push(trimmed.to_string());
            continue;
        }
        ok.push(trimmed.to_string());
    }

    AuthorFilterResult {
        filtered: ok,
        rejected: bad,
    }
}

/// Detect a decade ("1970s") in the input. Returns the inclusive range.
pub fn extract_decade(input: &str) -> Option<(i64, i64)> {
    let caps = RE_DECADE.captures(input)?;
    let cent: i64 = caps.get(1)?.as_str().parse().ok()?;
    let dec: i64 = caps.get(2)?.as_str().parse().ok()?;
    let from = cent * 100 + dec * 10;
    Some((from, from + 9))
}

/// Build a deterministic ADS Lucene query from extracted structured parts.
/// Always produces well-formed syntax; applies the post-processing safety
/// filters that catch common model mistakes.
pub fn build_query(parts: &QueryParts, original_input: &str, this_year: i64) -> String {
    let mut clauses: Vec<String> = Vec::new();
    let input_lower = original_input.to_lowercase();

    let non_authors = filter_authors(&parts.authors, &input_lower);

    // If we have ≥4 "authors" and zero topicWords, the model probably
    // mis-classified topic words as authors. Demote them all.
    let demoted = non_authors.filtered.len() >= 4 && parts.topic_words.is_empty();
    let authors: Vec<String> = if demoted {
        Vec::new()
    } else {
        non_authors.filtered.clone()
    };
    let mut extra_topics: Vec<String> = if demoted {
        non_authors.filtered.clone()
    } else {
        Vec::new()
    };
    extra_topics.extend(non_authors.rejected.iter().cloned());

    for surname in &authors {
        clauses.push(format!("author:\"{surname}\""));
    }

    // Bibstem — only if it looks like a real abbreviation.
    let bibstem = trim_ws_nl(&parts.bibstem);
    if !bibstem.is_empty()
        && bibstem.chars().count() <= 12
        && bibstem
            .chars()
            .all(|c| c.is_alphabetic() || c == '&' || c == '.')
    {
        clauses.push(format!("bibstem:{bibstem}"));
    }

    // Topic words — model topicWords plus demoted/rejected authors, minus
    // anything already used as an author, deduped per word, minus bare years
    // (Apple Intelligence leaks the search year into topicWords, and
    // `abs:(1970)` over-constrains to zero hits).
    let author_set: HashSet<String> = authors.iter().map(|a| a.to_lowercase()).collect();
    let mut year_tokens: HashSet<String> = HashSet::new();
    if parts.year_from > 0 {
        year_tokens.insert(parts.year_from.to_string());
    }
    if parts.year_to > 0 {
        year_tokens.insert(parts.year_to.to_string());
    }

    let mut raw_topics: Vec<String> = parts
        .topic_words
        .iter()
        .map(|t| trim_ws_nl(t).to_string())
        .filter(|t| !t.is_empty())
        .collect();
    raw_topics.extend(extra_topics);

    let mut seen_words: HashSet<String> = HashSet::new();
    let mut topic_tokens: Vec<String> = Vec::new();
    for phrase in &raw_topics {
        for word in phrase.split_whitespace() {
            let key = word.to_lowercase();
            if author_set.contains(&key) {
                continue;
            }
            if year_tokens.contains(&key) {
                continue;
            }
            if word.chars().count() == 4 {
                if let Ok(n) = word.parse::<i64>() {
                    if (1900..=2100).contains(&n) {
                        continue;
                    }
                }
            }
            if !seen_words.insert(key) {
                continue;
            }
            topic_tokens.push(word.to_string());
        }
    }
    if !topic_tokens.is_empty() {
        clauses.push(format!("abs:({})", topic_tokens.join(" ")));
    }

    // Year range. A decade in the raw input wins over the model's bounds.
    if let Some((decade_from, decade_to)) = extract_decade(original_input) {
        clauses.push(format!("year:{decade_from}-{decade_to}"));
    } else if parts.year_from > 0 {
        let from = parts.year_from;
        let to = if parts.year_to >= from {
            parts.year_to
        } else {
            this_year
        };
        if from == to {
            clauses.push(format!("year:{from}"));
        } else {
            clauses.push(format!("year:{from}-{to}"));
        }
    }

    if parts.refereed_only {
        clauses.push("property:refereed".to_string());
    }

    clauses.join(" ")
}

/// Last-resort rewrite when no model is available: pull year/decade tokens out
/// with pattern matching and wrap the residue in `abs:(...)`.
pub fn degenerate_rewrite(input: &str, this_year: i64) -> QueryRewriteResult {
    let words: Vec<&str> = split_ws_nl(input);
    let mut query_parts: Vec<String> = Vec::new();
    let mut topic_words: Vec<&str> = Vec::new();
    let mut refereed = false;
    let mut i = 0;

    while i < words.len() {
        let word = words[i];
        let lower = word.to_lowercase();

        // Decade: "1970s"
        if let Some(caps) = RE_DECADE_WORD.captures(word) {
            if let Ok(start) = caps[1].parse::<i64>() {
                if (1900..=2090).contains(&start) {
                    query_parts.push(format!("year:{}-{}", start - 2, start + 12));
                    i += 1;
                    continue;
                }
            }
        }
        // Hyphenated year range: "2020-2024"
        let hyphen_parts: Vec<&str> = word.split('-').collect();
        if hyphen_parts.len() == 2 {
            if let (Ok(from), Ok(to)) = (
                hyphen_parts[0].parse::<i64>(),
                hyphen_parts[1].parse::<i64>(),
            ) {
                if (1900..=2100).contains(&from) && (1900..=2100).contains(&to) {
                    query_parts.push(format!("year:{from}-{to}"));
                    i += 1;
                    continue;
                }
            }
        }
        // Standalone year
        if let Ok(year) = word.parse::<i64>() {
            if (1900..=2100).contains(&year) {
                query_parts.push(format!("year:{year}"));
                i += 1;
                continue;
            }
        }
        // "since YYYY" / "after YYYY"
        if (lower == "since" || lower == "after") && i + 1 < words.len() {
            if let Ok(y) = words[i + 1].parse::<i64>() {
                if (1900..=2100).contains(&y) {
                    query_parts.push(format!("year:{y}-{this_year}"));
                    i += 2;
                    continue;
                }
            }
        }
        // "recent" / "latest"
        if lower == "recent" || lower == "latest" {
            query_parts.push(format!("year:{}-{}", this_year - 4, this_year));
            i += 1;
            continue;
        }
        // "last N years"
        if lower == "last" && i + 2 < words.len() && words[i + 2].to_lowercase() == "years" {
            if let Ok(n) = words[i + 1].parse::<i64>() {
                if n > 0 && n < 100 {
                    query_parts.push(format!("year:{}-{}", this_year - n, this_year));
                    i += 3;
                    continue;
                }
            }
        }
        // Refereed flag
        if lower == "refereed" || lower == "peer-reviewed" {
            refereed = true;
            i += 1;
            continue;
        }
        // "by Author"
        if lower == "by" && i + 1 < words.len() {
            query_parts.push(format!("author:\"{}\"", capitalized(words[i + 1])));
            i += 2;
            continue;
        }
        topic_words.push(word);
        i += 1;
    }

    if !topic_words.is_empty() {
        query_parts.push(format!("abs:({})", topic_words.join(" ")));
    }
    if refereed {
        query_parts.push("property:refereed".to_string());
    }

    let joined = query_parts.join(" ");
    let query = trim_ws(&joined).to_string();
    let interpretation = if query_parts.is_empty() {
        "Free-text search (no parser available)"
    } else {
        "Local pattern match (no AI available)"
    };
    QueryRewriteResult {
        query: if query.is_empty() {
            input.to_string()
        } else {
            query
        },
        interpretation: interpretation.to_string(),
        confidence: 0.4,
        source: RewriteSource::Degenerate,
    }
}

/// Swift `String.capitalized`: title-case each word, lowercase the remainder.
///
/// Word boundaries are non-alphanumeric characters **except** apostrophes,
/// which Foundation treats as intra-word. Verified against the corpus:
/// `"van-der-waals"` → `"Van-Der-Waals"` (hyphen splits) but `"o'brien"` →
/// `"O'brien"` (apostrophe does not).
fn capitalized(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut at_word_start = true;
    for c in s.chars() {
        if at_word_start {
            out.extend(c.to_uppercase());
        } else {
            out.extend(c.to_lowercase());
        }
        at_word_start = !(c.is_alphanumeric() || c == '\'' || c == '\u{2019}');
    }
    out
}

// ------------------------------------------------------ cloud-response repair

/// Post-process a model-emitted query to fix the mistakes they reliably make:
/// `;`/stray-comma clause separators, `title:"X Y"` where ADS wants
/// `title:(X Y)`, and doubled whitespace. Finishes by handing off to
/// [`ads_normalizer::normalize`] for unquoted authors and lowercase booleans.
pub fn clean_query(raw: &str) -> String {
    let mut s = trim_ws_nl(raw).to_string();
    s = s.replace(';', " ");
    s = collapse_commas_outside_quotes(&s);
    s = unquote_topic_fields(&s);
    while s.contains("  ") {
        s = s.replace("  ", " ");
    }
    s = trim_ws(&s).to_string();
    ads_normalizer::normalize(&s).corrected_query
}

/// `title:"X Y"` → `title:(X Y)`. Single-word values stay quoted (harmless
/// either way) and `author:"Last, F"` is untouched because `author` is not a
/// topic field.
///
/// Preserved quirk: the replacement writes the *lowercase* field name from the
/// table, not the matched spelling, so `TITLE:"dark matter"` becomes
/// `title:(dark matter)`.
pub fn unquote_topic_fields(input: &str) -> String {
    let mut output = input.to_string();
    for (field, re) in RE_TOPIC_FIELDS.iter() {
        // Collect first, then rewrite back-to-front so earlier offsets stay valid.
        let hits: Vec<(std::ops::Range<usize>, String)> = re
            .captures_iter(&output)
            .filter_map(|c| {
                let full = c.get(0)?;
                let value = c.get(1)?.as_str().to_string();
                Some((full.range(), value))
            })
            .collect();
        for (range, value) in hits.into_iter().rev() {
            if value.split_whitespace().count() >= 2 {
                output.replace_range(range, &format!("{field}:({value})"));
            }
        }
    }
    output
}

/// Replace commas outside double-quoted strings with spaces, so
/// `author:"Last, F"` survives while `title:foo, abs:bar` is repaired.
pub fn collapse_commas_outside_quotes(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_quote = false;
    for ch in s.chars() {
        match ch {
            '"' => {
                in_quote = !in_quote;
                out.push(ch);
            }
            ',' if !in_quote => out.push(' '),
            _ => out.push(ch),
        }
    }
    out
}

/// Strip a leading ```` ```lang ```` fence line and a trailing ```` ``` ````.
pub fn strip_code_fences(s: &str) -> String {
    let mut t = trim_ws_nl(s).to_string();
    if t.starts_with("```") {
        if let Some(idx) = t.find('\n') {
            t = t[idx + 1..].to_string();
        }
    }
    if t.ends_with("```") {
        t.truncate(t.len() - 3);
    }
    trim_ws_nl(&t).to_string()
}

#[derive(Deserialize)]
struct CloudQueryPlan {
    query: Option<String>,
    interpretation: Option<String>,
    confidence: Option<f64>,
}

/// Decode a cloud model's JSON response into a rewrite result.
///
/// Matches `JSONDecoder`'s behavior: unknown keys are ignored, but a
/// *type* mismatch on a known key fails the whole decode (returns `None`).
pub fn decode_cloud_json(text: &str) -> Option<QueryRewriteResult> {
    let cleaned = strip_code_fences(text);
    let raw: CloudQueryPlan = serde_json::from_str(&cleaned).ok()?;
    Some(QueryRewriteResult {
        query: clean_query(raw.query.as_deref().unwrap_or("")),
        interpretation: raw
            .interpretation
            .unwrap_or_else(|| "ADS query".to_string()),
        confidence: raw.confidence.unwrap_or(0.5),
        source: RewriteSource::Cloud,
    })
}

// ------------------------------------------------------------------- prompting

/// The on-device extraction prompt. Byte-pinned by the golden corpus because a
/// silent change here changes what the model returns.
pub fn make_rewrite_prompt(input: &str, this_year: i64, today: &str) -> String {
    let yr = this_year;
    let yr4 = this_year - 4;
    format!(
        r#"Today is {today}.
Extract structured search fields from this scientific publication search request.

Identify each piece separately:
  - authors: surnames of HUMAN researchers (last names, capitalized). Most requests have 0–3 authors. NEVER include: instruments (JWST, ALMA, LIGO, Hubble, Webb, Chandra, Fermi), satellites, surveys (SDSS, DESI, BOSS), telescopes, programs, common nouns, topic words.
  - bibstem: ADS journal abbreviation if a journal is named (Sci=Science, Nat=Nature, ApJ, ApJL, ApJS, MNRAS, A&A, PRL, PRD, PNAS, JCAP, JHEP) — empty otherwise.
  - topicWords: subject keywords. Instruments, surveys, methods, and physics terms ALL go here. Drop generic words ('paper', 'about', 'on', 'recent').
  - yearFrom / yearTo: year bounds if mentioned. "since 2020" → from=2020, to=0. "2018-2024" → from=2018, to=2024. "1970s" → from=1970, to=1979. "recent" → from={yr4}, to={yr}. "this year" → from={yr}, to={yr}. No year mentioned → both 0.
  - refereedOnly: true ONLY if the user EXPLICITLY requested refereed / peer-reviewed papers.

CRITICAL: when in doubt about authors vs. topics, prefer topics. A query with 4+ "authors" is almost certainly wrong.

Examples:
  Input: "abel norman first stars science"
  → authors=["Abel", "Norman"]  bibstem="Sci"  topicWords=["first stars"]
    yearFrom=0  yearTo=0  refereedOnly=false

  Input: "Riess dark energy since 2020 refereed"
  → authors=["Riess"]  bibstem=""  topicWords=["dark energy"]
    yearFrom=2020  yearTo=0  refereedOnly=true

  Input: "BBKS power spectrum"
  → authors=[]  bibstem=""  topicWords=["BBKS", "power spectrum"]
    yearFrom=0  yearTo=0  refereedOnly=false

  Input: "recent JWST galaxy formation"
  → authors=[]  bibstem=""  topicWords=["JWST", "galaxy formation"]
    yearFrom={yr4}  yearTo={yr}  refereedOnly=false
    (JWST is a telescope, NOT an author!)

  Input: "JWST galaxy formation high redshift"
  → authors=[]  bibstem=""  topicWords=["JWST", "galaxy formation", "high redshift"]
    yearFrom=0  yearTo=0  refereedOnly=false

  Input: "Bardeen ApJ 1986"
  → authors=["Bardeen"]  bibstem="ApJ"  topicWords=[]
    yearFrom=1986  yearTo=1986  refereedOnly=false

  Input: "galaxy rotation curves 1970s"
  → authors=[]  bibstem=""  topicWords=["galaxy rotation curves"]
    yearFrom=1970  yearTo=1979  refereedOnly=false
    (ALL of "galaxy", "rotation", "curves" are topic words, NOT authors!)

  Input: "SDSS DR17 spectroscopy"
  → authors=[]  bibstem=""  topicWords=["SDSS", "DR17", "spectroscopy"]
    yearFrom=0  yearTo=0  refereedOnly=false

  Input: "Smith and Jones 2020"
  → authors=["Smith", "Jones"]  bibstem=""  topicWords=[]
    yearFrom=2020  yearTo=2020  refereedOnly=false

Request: {input}"#
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn degenerate_extracts_years() {
        assert_eq!(
            degenerate_rewrite("last 5 years", 2026).query,
            "year:2021-2026"
        );
        assert_eq!(
            degenerate_rewrite("last 100 years", 2026).query,
            "abs:(last 100 years)"
        );
        assert_eq!(
            degenerate_rewrite("by van der waals", 2026).query,
            "author:\"Van\" abs:(der waals)"
        );
    }

    #[test]
    fn empty_input_falls_back_to_input() {
        let r = degenerate_rewrite("", 2026);
        assert_eq!(r.query, "");
        assert_eq!(r.interpretation, "Free-text search (no parser available)");
    }

    #[test]
    fn build_query_demotes_four_authors_with_no_topics() {
        let parts = QueryParts {
            authors: ["Abel", "Bryan", "Norman", "Klessen"]
                .iter()
                .map(|s| s.to_string())
                .collect(),
            ..Default::default()
        };
        assert_eq!(
            build_query(&parts, "abel bryan norman klessen", 2026),
            "abs:(Abel Bryan Norman Klessen)"
        );
    }

    #[test]
    fn build_query_drops_bare_year_topics() {
        let parts = QueryParts {
            topic_words: vec!["2020".to_string()],
            ..Default::default()
        };
        assert_eq!(build_query(&parts, "2020 dark energy", 2026), "");
    }

    #[test]
    fn clean_query_unquotes_topic_fields_lowercasing_the_name() {
        assert_eq!(clean_query(r#"TITLE:"dark matter""#), "title:(dark matter)");
        assert_eq!(
            clean_query(r#"title:"a" abs:"b c""#),
            r#"title:"a" abs:(b c)"#
        );
    }

    #[test]
    fn cloud_decode_ignores_unknown_keys_but_not_type_errors() {
        assert!(decode_cloud_json(r#"{"authors":"Abel"}"#).is_some());
        assert!(decode_cloud_json("not json").is_none());
        assert!(decode_cloud_json("[]").is_none());
    }
}
