//! Deterministic smart-search core.
//!
//! Rust port of the `ImpressSmartSearch` Swift package: the logic behind
//! imbib's Cmd+S overlay, which turns whatever a researcher pastes into a
//! search plan. It classifies input (DOI? ADS query? pasted bibliography? a
//! URL?), repairs and assembles ADS Lucene queries, validates model-parsed
//! citations, and scrapes identifiers out of fetched pages.
//!
//! # The Swift/Rust split
//!
//! Three of the five original components ride on Apple platform frameworks,
//! and forcing those into Rust would have meant reimplementing an on-device
//! LLM and an HTTP stack. They are split instead, and the split is drawn at
//! the boundary where behavior stops being platform-dependent:
//!
//! | Component | Rust | Stays Swift |
//! |---|---|---|
//! | `IntentClassifier` | **all of it** | — |
//! | `ADSQueryNormalizer` | **all of it** | — |
//! | `FreeTextQueryRewriter` | prompt, [`rewriter::build_query`], author/hallucination filters, [`rewriter::clean_query`], cloud-JSON decode, [`rewriter::degenerate_rewrite`] | the `FoundationModels` session + cloud runner call |
//! | `ReferenceParser` | prompt, cloud-JSON decode, [`reference::validate`] | the `FoundationModels` session + cloud runner call |
//! | `URLContentExtractor` | [`url_extract`] — title, identifiers, entities, double-encoding unwind | the `URLSession` fetch, redirect/status/encoding handling |
//!
//! What that buys: the search-quality-determining code — every regex, every
//! filter, every "is this DOI real" check — is now testable by `cargo test`,
//! reachable from the MCP tool and the CLI, and has exactly one definition.
//! What stays Swift is I/O and model invocation, which is thin, and which the
//! platform already does better than we would.
//!
//! # Determinism
//!
//! Anything year-relative takes `this_year` (and `today`) as a parameter. The
//! Swift original read `Date()` inline, so `"last 5 years"` could not be
//! tested at all. The golden corpus pins those branches at 2026.

pub mod ads_normalizer;
pub mod foundation;
pub mod intent;
pub mod reference;
pub mod rewriter;
pub mod swift_url;
pub mod types;
pub mod url_extract;

pub use ads_normalizer::normalize as normalize_ads_query;
pub use intent::classify;
pub use types::{
    CitationInput, NormalizationResult, PaperIdentifier, ParsedReference, QueryParts,
    QueryRewriteResult, RewriteSource, SearchIntent, UrlExtractionResult,
};

/// A classification plus the derived payloads a caller needs, in one struct —
/// the shape the FFI and the service trait hand across a boundary.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ClassifiedInput {
    /// `identifier` | `fielded` | `reference` | `freeText` | `url`
    pub kind: String,
    /// UI label, e.g. `"DOI"`, `"References (3)"`, `"URL · arxiv.org"`.
    pub label: String,
    /// Set for `identifier`: `doi` | `arxiv` | `bibcode` | `pmid`.
    pub identifier_kind: Option<String>,
    /// Set for `identifier` (the id) and `url` (the absolute URL).
    pub value: Option<String>,
    /// Set for `fielded` and `freeText`.
    pub query: Option<String>,
    /// Set for `reference`.
    pub blocks: Vec<String>,
}

impl From<SearchIntent> for ClassifiedInput {
    fn from(intent: SearchIntent) -> Self {
        let kind = intent.kind_raw_value().to_string();
        let label = intent.label();
        let mut out = ClassifiedInput {
            kind,
            label,
            identifier_kind: None,
            value: None,
            query: None,
            blocks: Vec::new(),
        };
        match intent {
            SearchIntent::Identifier(id) => {
                out.identifier_kind = Some(id.type_name().to_string());
                out.value = Some(id.value().to_string());
            }
            SearchIntent::Fielded { query } | SearchIntent::FreeText { query } => {
                out.query = Some(query)
            }
            SearchIntent::Reference { blocks } => out.blocks = blocks,
            SearchIntent::Url { url, .. } => out.value = Some(url),
        }
        out
    }
}

/// Classify input and flatten the result. The hot path for the search overlay.
pub fn classify_input(input: &str) -> ClassifiedInput {
    classify(input).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classified_input_flattens_every_case() {
        assert_eq!(
            classify_input("10.1086/164143").identifier_kind.as_deref(),
            Some("doi")
        );
        assert_eq!(classify_input("au:Abel").kind, "fielded");
        assert_eq!(
            classify_input("dark matter").query.as_deref(),
            Some("dark matter")
        );
        let u = classify_input("https://en.wikipedia.org/wiki/Quicksort");
        assert_eq!(u.kind, "url");
        assert_eq!(u.label, "URL · en.wikipedia.org");
    }
}
