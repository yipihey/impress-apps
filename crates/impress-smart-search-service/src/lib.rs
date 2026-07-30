//! `SmartSearchService` — the agent-facing surface of the smart-search core.
//!
//! Every `#[impress_method]` here becomes three things at once: an MCP tool, a
//! subcommand of the `impress` CLI, and a tool in impel's agent loop. That is
//! the whole reason the logic moved to Rust: in Swift it was reachable only
//! from imbib's Cmd+S overlay, so an agent asking "what would imbib do with
//! this pasted citation?" had no way to find out.
//!
//! The methods are deliberately pure — no store, no network, no app. They are
//! safe to call at any time, which is why this namespace needs no entry in
//! `impress-mcp`'s reachability gate.
//!
//! Note the explicit `this_year` parameters on the year-relative methods.
//! Passing `0` means "use 2026" is *not* the behavior — callers must pass a
//! real year, because guessing one silently changes what `"last 5 years"`
//! means. The CLI/MCP schema marks them required for the same reason.

use serde::{Deserialize, Serialize};

use impress_service_core::async_trait;
// `impress_method` is referenced as a path-only attribute on trait methods;
// `#[impress_service]` strips the attribute, so the symbol is structurally
// "unused" — keep it imported because Rust still requires the path to resolve
// when the macro expands.
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

use impress_smart_search::{
    ads_normalizer, intent, reference, rewriter,
    types::{ParsedReference, QueryParts},
    url_extract, ClassifiedInput,
};

/// Flattened classification result. Mirrors [`ClassifiedInput`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchIntentReport {
    /// `identifier` | `fielded` | `reference` | `freeText` | `url`
    pub kind: String,
    /// Human-readable label the search overlay shows.
    pub label: String,
    /// For `identifier`: `doi` | `arxiv` | `bibcode` | `pmid`.
    pub identifier_kind: Option<String>,
    /// For `identifier`, the id; for `url`, the absolute URL.
    pub value: Option<String>,
    /// For `fielded` / `freeText`, the query to run.
    pub query: Option<String>,
    /// For `reference`, one entry per pasted citation block.
    pub blocks: Vec<String>,
}

impl From<ClassifiedInput> for SearchIntentReport {
    fn from(c: ClassifiedInput) -> Self {
        SearchIntentReport {
            kind: c.kind,
            label: c.label,
            identifier_kind: c.identifier_kind,
            value: c.value,
            query: c.query,
            blocks: c.blocks,
        }
    }
}

/// Result of normalizing an ADS query.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdsNormalizationReport {
    pub corrected_query: String,
    /// One human-readable line per rule that fired.
    pub corrections: Vec<String>,
    pub was_modified: bool,
}

/// Result of rewriting free text into an ADS query.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryRewriteReport {
    pub query: String,
    pub interpretation: String,
    pub confidence: f64,
    /// `appleIntelligence` | `cloud` | `degenerate`.
    pub source: String,
}

/// An identifier scraped from a page or validated from a citation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IdentifierReport {
    /// `doi` | `arxiv` | `bibcode` | `pmid`.
    pub kind: String,
    pub value: String,
}

/// Result of scraping a page's markup.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PageExtractionReport {
    pub page_title: Option<String>,
    pub identifiers: Vec<IdentifierReport>,
}

/// A citation after invented identifiers have been stripped.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CitationReport {
    pub authors: Vec<String>,
    pub title: Option<String>,
    pub year: Option<i64>,
    pub journal: Option<String>,
    pub volume: Option<String>,
    pub pages: Option<String>,
    pub doi: Option<String>,
    pub arxiv: Option<String>,
    pub bibcode: Option<String>,
    /// True when at least one identifier survived validation.
    pub has_identifier: bool,
}

#[impress_service]
pub trait SmartSearchService: Send + Sync + 'static {
    /// Classify a search input the way imbib's Cmd+S overlay does: bare
    /// identifier, ADS fielded query, pasted citation(s), URL, or free text.
    /// Deterministic and cheap — no network, no model.
    #[impress_method]
    async fn classify_search_input(&self, input: String) -> SearchIntentReport;

    /// Repair a hand-written or model-generated ADS query: expand `a:`/`t:`/`b:`
    /// shorthands, quote multi-word field values and comma-bearing author
    /// names, uppercase boolean operators, and reorder `author:"First Last"`
    /// to `author:"Last, F"`. Reports every change it made.
    #[impress_method]
    async fn normalize_ads_query(&self, query: String) -> AdsNormalizationReport;

    /// Rewrite free-text input into an ADS query without a language model,
    /// using the deterministic fallback: year/decade/"last N years"/"since
    /// YYYY" extraction, `refereed` and `by <Author>` recognition, and
    /// `abs:(...)` for the residue. `this_year` anchors every relative range.
    #[impress_method]
    async fn rewrite_free_text_query(&self, input: String, this_year: i64) -> QueryRewriteReport;

    /// Assemble an ADS query from already-extracted structured fields — the
    /// stage that runs on a language model's output. Applies the safety
    /// filters: drops instrument/survey names and hallucinated surnames from
    /// `authors`, demotes them to topics, and strips bare years from
    /// `topic_words`.
    #[impress_method]
    #[allow(clippy::too_many_arguments)]
    async fn build_ads_query(
        &self,
        authors: Vec<String>,
        bibstem: String,
        topic_words: Vec<String>,
        year_from: i64,
        year_to: i64,
        refereed_only: bool,
        original_input: String,
        this_year: i64,
    ) -> String;

    /// Repair a language model's free-form ADS query string: `;`/comma clause
    /// separators, `title:"multi word"` → `title:(multi word)`, collapsed
    /// whitespace, then full normalization.
    #[impress_method]
    async fn clean_ads_query(&self, query: String) -> String;

    /// Split a pasted bibliography into individual reference blocks
    /// (`\bibitem`, numbered markers, or blank-line separated).
    #[impress_method]
    async fn split_reference_blocks(&self, text: String) -> Vec<String>;

    /// Extract paper identifiers and the `<title>` from a page's HTML. This is
    /// the extraction half of the URL path — fetching the page is the caller's
    /// job (imbib does it with `URLSession`).
    #[impress_method]
    async fn extract_page_identifiers(&self, html: String) -> PageExtractionReport;

    /// Validate a model-parsed citation, dropping any DOI / arXiv id / bibcode
    /// that doesn't match its canonical shape. A hallucinated identifier
    /// resolves to the wrong paper silently, so this check is load-bearing.
    #[impress_method]
    #[allow(clippy::too_many_arguments)]
    async fn validate_parsed_reference(
        &self,
        authors: Vec<String>,
        title: String,
        year: i64,
        journal: String,
        volume: String,
        pages: String,
        doi: String,
        arxiv: String,
        bibcode: String,
    ) -> CitationReport;

    /// Build the prompt imbib sends to the on-device model to extract search
    /// fields from free text. Exposed so an agent can see (and A/B) the exact
    /// contract instead of guessing at it.
    #[impress_method]
    async fn free_text_extraction_prompt(
        &self,
        input: String,
        this_year: i64,
        today: String,
    ) -> String;

    /// Build the prompt imbib sends to the on-device model to parse a single
    /// citation reference.
    #[impress_method]
    async fn reference_parse_prompt(&self, block: String) -> String;
}

#[derive(Default, Clone, Copy)]
pub struct DefaultSmartSearchService;

#[async_trait::async_trait]
impl SmartSearchService for DefaultSmartSearchService {
    async fn classify_search_input(&self, input: String) -> SearchIntentReport {
        impress_smart_search::classify_input(&input).into()
    }

    async fn normalize_ads_query(&self, query: String) -> AdsNormalizationReport {
        let r = ads_normalizer::normalize(&query);
        AdsNormalizationReport {
            corrected_query: r.corrected_query,
            was_modified: !r.corrections.is_empty(),
            corrections: r.corrections,
        }
    }

    async fn rewrite_free_text_query(&self, input: String, this_year: i64) -> QueryRewriteReport {
        let r = rewriter::degenerate_rewrite(&input, this_year);
        QueryRewriteReport {
            query: r.query,
            interpretation: r.interpretation,
            confidence: r.confidence,
            source: r.source.raw_value().to_string(),
        }
    }

    async fn build_ads_query(
        &self,
        authors: Vec<String>,
        bibstem: String,
        topic_words: Vec<String>,
        year_from: i64,
        year_to: i64,
        refereed_only: bool,
        original_input: String,
        this_year: i64,
    ) -> String {
        let parts = QueryParts {
            authors,
            bibstem,
            topic_words,
            year_from,
            year_to,
            refereed_only,
            interpretation: String::new(),
            confidence: 0.0,
        };
        rewriter::build_query(&parts, &original_input, this_year)
    }

    async fn clean_ads_query(&self, query: String) -> String {
        rewriter::clean_query(&query)
    }

    async fn split_reference_blocks(&self, text: String) -> Vec<String> {
        intent::split_reference_blocks(&text)
    }

    async fn extract_page_identifiers(&self, html: String) -> PageExtractionReport {
        PageExtractionReport {
            page_title: url_extract::extract_title(&html),
            identifiers: url_extract::extract_identifiers(&html)
                .into_iter()
                .map(|i| IdentifierReport {
                    kind: i.type_name().to_string(),
                    value: i.value().to_string(),
                })
                .collect(),
        }
    }

    async fn validate_parsed_reference(
        &self,
        authors: Vec<String>,
        title: String,
        year: i64,
        journal: String,
        volume: String,
        pages: String,
        doi: String,
        arxiv: String,
        bibcode: String,
    ) -> CitationReport {
        let parsed = ParsedReference {
            authors,
            title,
            year,
            journal,
            volume,
            pages,
            doi,
            arxiv,
            bibcode,
            confidence: 0.0,
        };
        let c = reference::validate(&parsed, "");
        CitationReport {
            has_identifier: c.has_identifier(),
            authors: c.authors,
            title: c.title,
            year: c.year,
            journal: c.journal,
            volume: c.volume,
            pages: c.pages,
            doi: c.doi,
            arxiv: c.arxiv,
            bibcode: c.bibcode,
        }
    }

    async fn free_text_extraction_prompt(
        &self,
        input: String,
        this_year: i64,
        today: String,
    ) -> String {
        rewriter::make_rewrite_prompt(&input, this_year, &today)
    }

    async fn reference_parse_prompt(&self, block: String) -> String {
        reference::make_reference_prompt(&block)
    }
}

fn smart_search_instance() -> DefaultSmartSearchService {
    DefaultSmartSearchService
}

impress_service_impl! {
    service = SmartSearchService,
    impl = DefaultSmartSearchService,
    instance = || smart_search_instance(),
    methods = [
        classify_search_input(input: String) -> SearchIntentReport,
        normalize_ads_query(query: String) -> AdsNormalizationReport,
        rewrite_free_text_query(input: String, this_year: i64) -> QueryRewriteReport,
        build_ads_query(
            authors: Vec<String>,
            bibstem: String,
            topic_words: Vec<String>,
            year_from: i64,
            year_to: i64,
            refereed_only: bool,
            original_input: String,
            this_year: i64
        ) -> String,
        clean_ads_query(query: String) -> String,
        split_reference_blocks(text: String) -> Vec<String>,
        extract_page_identifiers(html: String) -> PageExtractionReport,
        validate_parsed_reference(
            authors: Vec<String>,
            title: String,
            year: i64,
            journal: String,
            volume: String,
            pages: String,
            doi: String,
            arxiv: String,
            bibcode: String
        ) -> CitationReport,
        free_text_extraction_prompt(input: String, this_year: i64, today: String) -> String,
        reference_parse_prompt(block: String) -> String,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_service_core::{CliSubcommand, McpToolDescriptor};

    /// Every method must reach the MCP inventory. A missing entry means the
    /// tool silently doesn't exist for agents.
    #[test]
    fn all_methods_registered_in_mcp_inventory() {
        let names: Vec<&str> = McpToolDescriptor::iter().map(|d| d.name).collect();
        for expected in [
            "smart-search-service_classify-search-input",
            "smart-search-service_normalize-ads-query",
            "smart-search-service_rewrite-free-text-query",
            "smart-search-service_build-ads-query",
            "smart-search-service_clean-ads-query",
            "smart-search-service_split-reference-blocks",
            "smart-search-service_extract-page-identifiers",
            "smart-search-service_validate-parsed-reference",
            "smart-search-service_free-text-extraction-prompt",
            "smart-search-service_reference-parse-prompt",
        ] {
            assert!(
                names.contains(&expected),
                "{expected} missing from MCP inventory; have {names:?}"
            );
        }
    }

    #[test]
    fn all_methods_registered_in_cli_inventory() {
        let names: Vec<&str> = CliSubcommand::iter().map(|d| d.name).collect();
        for expected in [
            "classify-search-input",
            "normalize-ads-query",
            "rewrite-free-text-query",
            "build-ads-query",
            "clean-ads-query",
            "split-reference-blocks",
            "extract-page-identifiers",
            "validate-parsed-reference",
            "free-text-extraction-prompt",
            "reference-parse-prompt",
        ] {
            assert!(
                names.contains(&expected),
                "{expected} missing from CLI inventory; have {names:?}"
            );
        }
    }

    #[test]
    fn descriptions_are_not_the_fallback() {
        // A tool whose description reads "Invoke Service.method" shipped
        // undocumented — 119 tools once did. Guard against regressing.
        for d in McpToolDescriptor::iter() {
            if d.name.starts_with("smart-search-service_") {
                assert!(
                    !d.description.starts_with("Invoke "),
                    "{} has the fallback description",
                    d.name
                );
            }
        }
    }

    #[tokio::test]
    async fn classify_round_trips_through_the_trait() {
        let svc = DefaultSmartSearchService;
        let r = svc
            .classify_search_input("10.1126/science.295.5552.93".to_string())
            .await;
        assert_eq!(r.kind, "identifier");
        assert_eq!(r.identifier_kind.as_deref(), Some("doi"));
        assert_eq!(r.label, "DOI");
    }

    #[tokio::test]
    async fn validate_drops_invented_identifiers() {
        let svc = DefaultSmartSearchService;
        let r = svc
            .validate_parsed_reference(
                vec!["Abel".to_string()],
                "T".to_string(),
                2002,
                "Science".to_string(),
                "295".to_string(),
                "93".to_string(),
                "totally-made-up".to_string(),
                "also-fake".to_string(),
                "nope".to_string(),
            )
            .await;
        assert!(r.doi.is_none() && r.arxiv.is_none() && r.bibcode.is_none());
        assert!(!r.has_identifier);
    }
}
