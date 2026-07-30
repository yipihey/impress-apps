//! Extract paper identifiers from a fetched HTML page.
//!
//! Port of the *extraction* half of `URLContentExtractor.swift`. The fetch
//! stays in Swift — see the crate docs. Everything from "here are some bytes"
//! onward is here, which is the half that determines search quality.
//!
//! Most academic pages (publisher landing, ADS, arXiv, ResearchGate,
//! conference proceedings) embed identifiers prominently in the markup, so
//! regex extraction catches the common cases without an LLM.

use lazy_static::lazy_static;
use regex::Regex;
use std::collections::HashSet;

use crate::foundation::trim_ws_nl;
use crate::intent::ARXIV_OLD_ARCHIVES;
use crate::swift_url;
use crate::types::PaperIdentifier;

lazy_static! {
    static ref RE_TITLE: Regex = Regex::new(r"(?is)<title[^>]*>([\s\S]*?)</title>").unwrap();
    /// DOI: stops at HTML/URL boundary characters *and* `&` — real DOIs never
    /// contain `&`, but `&amp;` and `&format=…` trailers are everywhere.
    static ref RE_DOI: Regex = Regex::new(r#"\b10\.\d{4,9}/[^\s"<>()\\{}\[\]&]+"#).unwrap();
    static ref RE_ARXIV_PREFIXED: Regex =
        Regex::new(r"(?i)\barxiv[:\s/]+(\d{4}\.\d{4,5})(?:v\d+)?").unwrap();
    static ref RE_ARXIV_BARE: Regex = Regex::new(r"\b(\d{4}\.\d{4,5})\b").unwrap();
    static ref RE_ARXIV_OLD: Regex =
        Regex::new(r"\b([a-z\-]{2,12}(?:\.[A-Z]{2})?/\d{7})(?:v\d+)?\b").unwrap();
    static ref RE_BIBCODE: Regex =
        Regex::new(r"\b(\d{4}[A-Za-z&.][A-Za-z&.]{1,7}[.\d][.\d]+[A-Z])\b").unwrap();
    static ref RE_PMID_LABEL: Regex = Regex::new(r"(?i)\bpmid[:\s]+(\d{5,9})\b").unwrap();
    static ref RE_PUBMED_URL: Regex =
        Regex::new(r"pubmed\.ncbi\.nlm\.nih\.gov/(\d{5,9})").unwrap();
    static ref RE_NUMERIC_ENTITY: Regex = Regex::new(r"&#(x?[0-9A-Fa-f]+);").unwrap();
    static ref RE_DOUBLE_ENCODED: Regex = Regex::new(r"%25([0-9A-Fa-f]{2})").unwrap();
}

/// Read the `<title>` and decode its entities.
pub fn extract_title(html: &str) -> Option<String> {
    let caps = RE_TITLE.captures(html)?;
    let raw = caps.get(1)?.as_str();
    let decoded = decode_html_entities(raw);
    Some(trim_ws_nl(&decoded).to_string())
}

/// Extract identifiers in priority order — DOI, arXiv (new then old), bibcode,
/// PMID — deduped on `(type, lowercased value)` while preserving first-seen
/// order.
pub fn extract_identifiers(html: &str) -> Vec<PaperIdentifier> {
    let mut found: Vec<PaperIdentifier> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    let mut add = |id: PaperIdentifier, found: &mut Vec<PaperIdentifier>| {
        let key = format!("{}:{}", id.type_name(), id.value().to_lowercase());
        if seen.insert(key) {
            found.push(id);
        }
    };

    for m in RE_DOI.find_iter(html) {
        let cleaned = trim_trailing_punct(m.as_str());
        if cleaned.chars().count() >= 8 {
            add(PaperIdentifier::Doi(cleaned), &mut found);
        }
    }

    // Two passes for the new arXiv format: explicit `arXiv:` prefix first,
    // then bare ids (length-gated, since YYMM.NNNNN is at least 9 chars).
    for caps in RE_ARXIV_PREFIXED.captures_iter(html) {
        add(PaperIdentifier::Arxiv(caps[1].to_string()), &mut found);
    }
    for caps in RE_ARXIV_BARE.captures_iter(html) {
        let cap = &caps[1];
        if cap.chars().count() >= 9 {
            add(PaperIdentifier::Arxiv(cap.to_string()), &mut found);
        }
    }
    // Legacy `archive[.subclass]/YYMMNNN`, whitelisted by archive so unrelated
    // `slug/1234567` patterns (e.g. `gnd/4226307`, a German National Library
    // id) aren't mis-classified as papers.
    for caps in RE_ARXIV_OLD.captures_iter(html) {
        let cap = &caps[1];
        let archive = cap
            .split('/')
            .next()
            .unwrap_or("")
            .split('.')
            .next()
            .unwrap_or("");
        if ARXIV_OLD_ARCHIVES.contains(archive) {
            add(PaperIdentifier::Arxiv(cap.to_string()), &mut found);
        }
    }

    for caps in RE_BIBCODE.captures_iter(html) {
        let cap = &caps[1];
        if cap.chars().count() == 19 {
            add(PaperIdentifier::Bibcode(cap.to_string()), &mut found);
        }
    }

    for caps in RE_PMID_LABEL.captures_iter(html) {
        add(PaperIdentifier::Pmid(caps[1].to_string()), &mut found);
    }
    for caps in RE_PUBMED_URL.captures_iter(html) {
        add(PaperIdentifier::Pmid(caps[1].to_string()), &mut found);
    }

    found
}

/// Trim trailing punctuation that is sentence/markup noise rather than part of
/// the identifier. Note this set does *not* include `/`, unlike
/// [`crate::intent::doi_in_path`] — the Swift original differs the same way.
pub fn trim_trailing_punct(s: &str) -> String {
    let mut t = s.to_string();
    while let Some(last) = t.chars().last() {
        if ".,;:)\"']".contains(last) {
            t.pop();
        } else {
            break;
        }
    }
    t
}

/// The named entities Swift decodes, plus numeric `&#N;` / `&#xHH;`.
///
/// Swift iterates a `[String: String]` dictionary here, so its replacement
/// order is unspecified — which matters for inputs where decoding one entity
/// *creates* another (`&amp;lt;`). We use a fixed order instead, so the Rust
/// behavior is deterministic; the golden corpus contains no nested-entity case,
/// so this is a strict improvement rather than a divergence.
const NAMED_ENTITIES: &[(&str, &str)] = &[
    ("&amp;", "&"),
    ("&lt;", "<"),
    ("&gt;", ">"),
    ("&quot;", "\""),
    ("&apos;", "'"),
    ("&#39;", "'"),
    ("&nbsp;", " "),
    ("&mdash;", "—"),
    ("&ndash;", "–"),
    ("&hellip;", "…"),
    ("&copy;", "©"),
];

pub fn decode_html_entities(s: &str) -> String {
    let mut out = s.to_string();
    for (k, v) in NAMED_ENTITIES {
        out = out.replace(k, v);
    }
    // Numeric entities, applied back-to-front so offsets stay valid.
    let hits: Vec<(std::ops::Range<usize>, String)> = RE_NUMERIC_ENTITY
        .captures_iter(&out)
        .filter_map(|c| {
            let full = c.get(0)?.range();
            let inner = c.get(1)?.as_str();
            let scalar =
                if let Some(hex) = inner.strip_prefix('x').or_else(|| inner.strip_prefix('X')) {
                    u32::from_str_radix(hex, 16).ok()
                } else {
                    inner.parse::<u32>().ok()
                };
            // `Unicode.Scalar(n)` is nil for surrogates and out-of-range
            // values; Swift leaves those entities untouched.
            let ch = scalar.and_then(char::from_u32)?;
            Some((full, ch.to_string()))
        })
        .collect();
    for (range, replacement) in hits.into_iter().rev() {
        out.replace_range(range, &replacement);
    }
    out
}

/// Unwind one round of `%25XX → %XX` in a URL.
///
/// Wikipedia and friends encode an apostrophe as `%27`; doubly encoded it
/// becomes `%2527`, which the server reads as a literal `%27` in the slug and
/// 404s. Returns `None` when there is nothing to unwind or the result doesn't
/// parse.
pub fn unwind_double_encoding(absolute_url: &str) -> Option<String> {
    if !RE_DOUBLE_ENCODED.is_match(absolute_url) {
        return None;
    }
    let unwound = RE_DOUBLE_ENCODED.replace_all(absolute_url, "%$1");
    swift_url::parse(&unwound).map(|u| u.absolute_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_entities_decoded() {
        assert_eq!(
            extract_title("<title>A &amp; B &lt;C&gt;</title>").as_deref(),
            Some("A & B <C>")
        );
        assert_eq!(
            extract_title("<title>&#65;&#66;&#x43;</title>").as_deref(),
            Some("ABC")
        );
        assert_eq!(extract_title("<title>Unclosed"), None);
    }

    #[test]
    fn invalid_numeric_entities_survive() {
        assert_eq!(decode_html_entities("&#999999999;"), "&#999999999;");
        assert_eq!(decode_html_entities("&#xZZ;"), "&#xZZ;");
    }

    #[test]
    fn gnd_ids_are_not_arxiv() {
        assert!(extract_identifiers("gnd/4226307").is_empty());
        assert_eq!(
            extract_identifiers("astro-ph/0112088"),
            vec![PaperIdentifier::Arxiv("astro-ph/0112088".to_string())]
        );
    }

    #[test]
    fn doi_stops_before_ampersand() {
        assert_eq!(
            extract_identifiers(r#"<a href="https://doi.org/10.1126/science.1&amp;format=xml">"#),
            vec![PaperIdentifier::Doi("10.1126/science.1".to_string())]
        );
    }

    #[test]
    fn double_encoding_unwound_once() {
        assert_eq!(
            unwind_double_encoding("https://example.com/a%2527b").as_deref(),
            Some("https://example.com/a%27b")
        );
        assert_eq!(unwind_double_encoding("https://example.com/plain"), None);
    }
}
