//! UniFFI surface for the deterministic smart-search core.
//!
//! `imbib-core` hosts these bindings rather than a dedicated framework: PMC
//! already links `ImbibCore.xcframework`, so the smart-search surface reaches
//! every app that embeds PMC (imbib, imprint, implore, impel, impart) with no
//! new xcframework, no new checksum to keep in step, and no change to any
//! app's build settings. The logic itself lives in the standalone, UI-free
//! [`impress_smart_search`] crate, which knows nothing about UniFFI — this
//! module is only the record-shuffling boundary.
//!
//! The Swift side (`packages/ImpressSmartSearch`) keeps its public API and
//! delegates its bodies here; see that package for the Swift/Rust split.

use impress_smart_search::{
    ads_normalizer, intent, reference, rewriter,
    types::{ParsedReference, QueryParts},
    url_extract,
};

// ---------------------------------------------------------------- records

/// Flattened `SearchIntent`. `kind` is one of `identifier`, `fielded`,
/// `reference`, `freeText`, `url`.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SmartSearchIntent {
    pub kind: String,
    /// UI label, e.g. `"DOI"`, `"References (3)"`, `"URL · arxiv.org"`.
    pub label: String,
    /// For `identifier`: `doi` | `arxiv` | `bibcode` | `pmid`.
    pub identifier_kind: Option<String>,
    /// For `identifier`, the id; for `url`, the absolute URL string.
    pub value: Option<String>,
    /// For `fielded` / `freeText`.
    pub query: Option<String>,
    /// For `reference`, one entry per citation block.
    pub blocks: Vec<String>,
}

/// Result of ADS query normalization.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SmartSearchNormalization {
    pub corrected_query: String,
    pub corrections: Vec<String>,
    pub was_modified: bool,
}

/// Result of a free-text → ADS query rewrite.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SmartSearchRewrite {
    pub query: String,
    pub interpretation: String,
    pub confidence: f64,
    /// `appleIntelligence` | `cloud` | `degenerate`.
    pub source: String,
}

/// Structured fields a language model extracted from free text.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SmartSearchQueryParts {
    pub authors: Vec<String>,
    pub bibstem: String,
    pub topic_words: Vec<String>,
    pub year_from: i32,
    pub year_to: i32,
    pub refereed_only: bool,
}

/// An identifier, as `(kind, value)`.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SmartSearchIdentifier {
    /// `doi` | `arxiv` | `bibcode` | `pmid`.
    pub kind: String,
    pub value: String,
}

/// What a page's markup yielded.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SmartSearchPageExtraction {
    pub page_title: Option<String>,
    pub identifiers: Vec<SmartSearchIdentifier>,
}

/// A model's raw citation parse, before validation.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SmartSearchParsedReference {
    pub authors: Vec<String>,
    pub title: String,
    pub year: i32,
    pub journal: String,
    pub volume: String,
    pub pages: String,
    pub doi: String,
    pub arxiv: String,
    pub bibcode: String,
    pub confidence: f64,
}

/// A citation after invented identifiers have been dropped.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SmartSearchCitation {
    pub authors: Vec<String>,
    pub title: Option<String>,
    pub year: Option<i32>,
    pub journal: Option<String>,
    pub volume: Option<String>,
    pub pages: Option<String>,
    pub doi: Option<String>,
    pub arxiv: Option<String>,
    pub bibcode: Option<String>,
    pub free_text: Option<String>,
    pub has_identifier: bool,
}

// ---------------------------------------------------------------- conversions

impl From<impress_smart_search::ClassifiedInput> for SmartSearchIntent {
    fn from(c: impress_smart_search::ClassifiedInput) -> Self {
        SmartSearchIntent {
            kind: c.kind,
            label: c.label,
            identifier_kind: c.identifier_kind,
            value: c.value,
            query: c.query,
            blocks: c.blocks,
        }
    }
}

impl From<SmartSearchQueryParts> for QueryParts {
    fn from(p: SmartSearchQueryParts) -> Self {
        QueryParts {
            authors: p.authors,
            bibstem: p.bibstem,
            topic_words: p.topic_words,
            year_from: p.year_from as i64,
            year_to: p.year_to as i64,
            refereed_only: p.refereed_only,
            interpretation: String::new(),
            confidence: 0.0,
        }
    }
}

impl From<SmartSearchParsedReference> for ParsedReference {
    fn from(p: SmartSearchParsedReference) -> Self {
        ParsedReference {
            authors: p.authors,
            title: p.title,
            year: p.year as i64,
            journal: p.journal,
            volume: p.volume,
            pages: p.pages,
            doi: p.doi,
            arxiv: p.arxiv,
            bibcode: p.bibcode,
            confidence: p.confidence,
        }
    }
}

impl From<ParsedReference> for SmartSearchParsedReference {
    fn from(p: ParsedReference) -> Self {
        SmartSearchParsedReference {
            authors: p.authors,
            title: p.title,
            year: p.year as i32,
            journal: p.journal,
            volume: p.volume,
            pages: p.pages,
            doi: p.doi,
            arxiv: p.arxiv,
            bibcode: p.bibcode,
            confidence: p.confidence,
        }
    }
}

fn rewrite_to_ffi(r: impress_smart_search::QueryRewriteResult) -> SmartSearchRewrite {
    SmartSearchRewrite {
        query: r.query,
        interpretation: r.interpretation,
        confidence: r.confidence,
        source: r.source.raw_value().to_string(),
    }
}

// ---------------------------------------------------------------- exports

/// Classify search input. Deterministic and cheap — safe on every keystroke.
#[uniffi::export]
pub fn smart_search_classify(input: String) -> SmartSearchIntent {
    impress_smart_search::classify_input(&input).into()
}

/// Repair an ADS query (shorthands, quoting, boolean case, author order).
#[uniffi::export]
pub fn smart_search_normalize_ads_query(query: String) -> SmartSearchNormalization {
    let r = ads_normalizer::normalize(&query);
    SmartSearchNormalization {
        corrected_query: r.corrected_query,
        was_modified: !r.corrections.is_empty(),
        corrections: r.corrections,
    }
}

/// The no-model fallback rewrite. `this_year` anchors relative ranges.
#[uniffi::export]
pub fn smart_search_degenerate_rewrite(input: String, this_year: i32) -> SmartSearchRewrite {
    rewrite_to_ffi(rewriter::degenerate_rewrite(&input, this_year as i64))
}

/// Assemble an ADS query from model-extracted structured fields, applying the
/// hallucinated-author and bare-year filters.
#[uniffi::export]
pub fn smart_search_build_ads_query(
    parts: SmartSearchQueryParts,
    original_input: String,
    this_year: i32,
) -> String {
    let parts: QueryParts = parts.into();
    rewriter::build_query(&parts, &original_input, this_year as i64)
}

/// Repair a model-emitted ADS query string, then normalize it.
#[uniffi::export]
pub fn smart_search_clean_ads_query(query: String) -> String {
    rewriter::clean_query(&query)
}

/// Split a pasted bibliography into reference blocks.
#[uniffi::export]
pub fn smart_search_split_reference_blocks(text: String) -> Vec<String> {
    intent::split_reference_blocks(&text)
}

/// Scrape identifiers and the `<title>` out of a page's HTML. The fetch itself
/// stays in Swift (`URLSession`); this is everything after the bytes arrive.
#[uniffi::export]
pub fn smart_search_extract_page_identifiers(html: String) -> SmartSearchPageExtraction {
    SmartSearchPageExtraction {
        page_title: url_extract::extract_title(&html),
        identifiers: url_extract::extract_identifiers(&html)
            .into_iter()
            .map(|i| SmartSearchIdentifier {
                kind: i.type_name().to_string(),
                value: i.value().to_string(),
            })
            .collect(),
    }
}

/// Drop any identifier the model invented. `raw` is kept as the citation's
/// free-text fallback.
#[uniffi::export]
pub fn smart_search_validate_reference(
    parsed: SmartSearchParsedReference,
    raw: String,
) -> SmartSearchCitation {
    let p: ParsedReference = parsed.into();
    let c = reference::validate(&p, &raw);
    SmartSearchCitation {
        has_identifier: c.has_identifier(),
        authors: c.authors,
        title: c.title,
        year: c.year.map(|y| y as i32),
        journal: c.journal,
        volume: c.volume,
        pages: c.pages,
        doi: c.doi,
        arxiv: c.arxiv,
        bibcode: c.bibcode,
        free_text: c.free_text,
    }
}

/// Decode a cloud model's JSON citation response. `None` on malformed input.
#[uniffi::export]
pub fn smart_search_decode_reference_json(text: String) -> Option<SmartSearchParsedReference> {
    reference::decode_cloud_json(&text).map(Into::into)
}

/// Decode a cloud model's JSON query-rewrite response. `None` on malformed input.
#[uniffi::export]
pub fn smart_search_decode_rewrite_json(text: String) -> Option<SmartSearchRewrite> {
    rewriter::decode_cloud_json(&text).map(rewrite_to_ffi)
}

/// The on-device prompt for extracting search fields from free text.
#[uniffi::export]
pub fn smart_search_rewrite_prompt(input: String, this_year: i32, today: String) -> String {
    rewriter::make_rewrite_prompt(&input, this_year as i64, &today)
}

/// The on-device prompt for parsing one citation reference.
#[uniffi::export]
pub fn smart_search_reference_prompt(block: String) -> String {
    reference::make_reference_prompt(&block)
}

/// Unwind one round of `%25XX → %XX` in a URL, for the 404-retry path.
/// `None` when there is nothing to unwind.
#[uniffi::export]
pub fn smart_search_unwind_double_encoding(url: String) -> Option<String> {
    url_extract::unwind_double_encoding(&url)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_crosses_the_boundary_intact() {
        let r = smart_search_classify("10.1126/science.295.5552.93".to_string());
        assert_eq!(r.kind, "identifier");
        assert_eq!(r.identifier_kind.as_deref(), Some("doi"));
        assert_eq!(r.label, "DOI");
    }

    #[test]
    fn page_extraction_crosses_the_boundary_intact() {
        let r = smart_search_extract_page_identifiers(
            "<title>T</title><p>doi:10.1086/164143</p>".to_string(),
        );
        assert_eq!(r.page_title.as_deref(), Some("T"));
        assert_eq!(r.identifiers.len(), 1);
        assert_eq!(r.identifiers[0].kind, "doi");
        assert_eq!(r.identifiers[0].value, "10.1086/164143");
    }

    #[test]
    fn year_narrowing_round_trips() {
        let parsed = SmartSearchParsedReference {
            authors: vec!["Abel".to_string()],
            title: "T".to_string(),
            year: 2002,
            journal: "Science".to_string(),
            volume: "295".to_string(),
            pages: "93".to_string(),
            doi: "10.1126/science.295.5552.93".to_string(),
            arxiv: String::new(),
            bibcode: "2002Sci...295...93A".to_string(),
            confidence: 0.9,
        };
        let c = smart_search_validate_reference(parsed, "RAW".to_string());
        assert_eq!(c.year, Some(2002));
        assert!(c.has_identifier);
        assert_eq!(c.free_text.as_deref(), Some("RAW"));
    }
}
