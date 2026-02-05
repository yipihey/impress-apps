//! Combined filter parser for reference lists.
//!
//! Parses filter expressions that combine text search, flag queries, tag queries,
//! and read state into a unified filter.
//!
//! # Syntax
//!
//! ```text
//! flag:red tags:methods/hydro unread "exact phrase"
//! ```
//!
//! Tokens:
//! - `flag:*`, `flag:red`, `-flag:*` — flag queries
//! - `tags:methods`, `tags:a+b`, `-tags:methods` — tag queries
//! - `unread`, `read` — read state
//! - Everything else — text search terms

use impress_flags::{FlagQuery, parse_flag_query};
use impress_tags::{TagQuery, parse_tag_query};

/// A combined filter for publications.
#[derive(Debug, Clone, Default)]
pub struct ReferenceFilter {
    /// Text search terms (matched against title, authors, abstract)
    pub text_terms: Vec<String>,
    /// Flag filter
    pub flag_query: Option<FlagQuery>,
    /// Tag filters (all must match — implicit AND)
    pub tag_queries: Vec<TagQuery>,
    /// Read state filter
    pub read_state: Option<ReadState>,
}

/// Read state filter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadState {
    Read,
    Unread,
}

impl ReferenceFilter {
    /// Parse a filter expression string.
    pub fn parse(input: &str) -> Self {
        let mut filter = Self::default();

        // Tokenize: respect quoted strings
        let tokens = tokenize(input);

        for token in tokens {
            // Try flag query
            if token.starts_with("flag:") || token.starts_with("-flag:") {
                if let Some(fq) = parse_flag_query(&token) {
                    filter.flag_query = Some(fq);
                    continue;
                }
            }

            // Try tag query
            if token.starts_with("tags:") || token.starts_with("-tags:") {
                if let Some(tq) = parse_tag_query(&token) {
                    filter.tag_queries.push(tq);
                    continue;
                }
            }

            // Read state
            match token.to_lowercase().as_str() {
                "unread" => {
                    filter.read_state = Some(ReadState::Unread);
                    continue;
                }
                "read" => {
                    filter.read_state = Some(ReadState::Read);
                    continue;
                }
                _ => {}
            }

            // Everything else is a text search term
            filter.text_terms.push(token);
        }

        filter
    }

    /// Whether this filter is empty (matches everything).
    pub fn is_empty(&self) -> bool {
        self.text_terms.is_empty()
            && self.flag_query.is_none()
            && self.tag_queries.is_empty()
            && self.read_state.is_none()
    }
}

/// Tokenize a filter string, respecting quoted strings.
fn tokenize(input: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;

    for c in input.chars() {
        match c {
            '"' => {
                in_quotes = !in_quotes;
                if !in_quotes && !current.is_empty() {
                    tokens.push(current.clone());
                    current.clear();
                }
            }
            ' ' if !in_quotes => {
                if !current.is_empty() {
                    tokens.push(current.clone());
                    current.clear();
                }
            }
            _ => {
                current.push(c);
            }
        }
    }

    if !current.is_empty() {
        tokens.push(current);
    }

    tokens
}

// ===== FFI-friendly filter representation =====
// ReferenceFilter can't be directly exported via UniFFI because TagQuery uses Box<T>.
// This flat struct provides the same data in a form UniFFI can serialize.

/// FFI-friendly parsed filter result.
#[cfg(feature = "native")]
#[derive(uniffi::Record, Clone, Debug)]
pub struct ParsedFilter {
    /// Text search terms (matched against title, authors, abstract)
    pub text_terms: Vec<String>,
    /// Flag query string if present (e.g., "flag:red", "flag:*", "-flag:*")
    pub flag_query_raw: Option<String>,
    /// Tag query strings if present (e.g., ["tags:methods/hydro", "-tags:obs"])
    pub tag_query_raws: Vec<String>,
    /// Read state: "read", "unread", or None
    pub read_state: Option<String>,
    /// Whether this filter is empty (matches everything)
    pub is_empty: bool,
}

/// Parse a filter expression and return an FFI-friendly result.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn parse_reference_filter(input: String) -> ParsedFilter {
    let filter = ReferenceFilter::parse(&input);

    // Reconstruct raw strings for flag/tag queries
    let flag_query_raw = filter.flag_query.as_ref().map(|fq| {
        use impress_flags::FlagQuery;
        match fq {
            FlagQuery::HasColor(c) => format!("flag:{}", c.display_name().to_lowercase()),
            FlagQuery::HasAny => "flag:*".to_string(),
            FlagQuery::HasNone => "-flag:*".to_string(),
        }
    });

    let tag_query_raws: Vec<String> = filter.tag_queries.iter().map(|tq| {
        format_tag_query(tq)
    }).collect();

    let read_state = filter.read_state.map(|rs| match rs {
        ReadState::Read => "read".to_string(),
        ReadState::Unread => "unread".to_string(),
    });

    ParsedFilter {
        text_terms: filter.text_terms.clone(),
        flag_query_raw,
        tag_query_raws,
        read_state,
        is_empty: filter.is_empty(),
    }
}

/// Format a TagQuery back to its string representation.
fn format_tag_query(tq: &TagQuery) -> String {
    match tq {
        TagQuery::Has(path) => format!("tags:{}", path),
        TagQuery::Not(path) => format!("-tags:{}", path),
        TagQuery::And(a, b) => {
            let a_str = format_tag_query_path(a);
            let b_str = format_tag_query_path(b);
            format!("tags:{}+{}", a_str, b_str)
        }
        TagQuery::Or(a, b) => {
            let a_str = format_tag_query_path(a);
            let b_str = format_tag_query_path(b);
            format!("tags:{}|{}", a_str, b_str)
        }
    }
}

/// Extract just the path portion from a TagQuery.
fn format_tag_query_path(tq: &TagQuery) -> String {
    match tq {
        TagQuery::Has(path) | TagQuery::Not(path) => path.clone(),
        TagQuery::And(a, b) => format!("{}+{}", format_tag_query_path(a), format_tag_query_path(b)),
        TagQuery::Or(a, b) => format!("{}|{}", format_tag_query_path(a), format_tag_query_path(b)),
    }
}

/// Tokenize a filter string (exposed for FFI).
#[cfg(feature = "native")]
#[uniffi::export]
pub fn tokenize_filter(input: String) -> Vec<String> {
    tokenize(&input)
}

/// Check if a filter expression string is empty (matches everything).
#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_filter_empty(input: String) -> bool {
    ReferenceFilter::parse(&input).is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_flags::FlagColor;

    #[test]
    fn parse_empty() {
        let filter = ReferenceFilter::parse("");
        assert!(filter.is_empty());
    }

    #[test]
    fn parse_text_only() {
        let filter = ReferenceFilter::parse("dark matter halos");
        assert_eq!(filter.text_terms, vec!["dark", "matter", "halos"]);
        assert!(filter.flag_query.is_none());
        assert!(filter.tag_queries.is_empty());
    }

    #[test]
    fn parse_flag_query() {
        let filter = ReferenceFilter::parse("flag:red");
        assert_eq!(filter.flag_query, Some(FlagQuery::HasColor(FlagColor::Red)));
        assert!(filter.text_terms.is_empty());
    }

    #[test]
    fn parse_tag_query() {
        let filter = ReferenceFilter::parse("tags:methods/hydro");
        assert_eq!(filter.tag_queries.len(), 1);
    }

    #[test]
    fn parse_combined() {
        let filter = ReferenceFilter::parse("hydro flag:amber unread tags:methods");
        assert_eq!(filter.text_terms, vec!["hydro"]);
        assert_eq!(filter.flag_query, Some(FlagQuery::HasColor(FlagColor::Amber)));
        assert_eq!(filter.read_state, Some(ReadState::Unread));
        assert_eq!(filter.tag_queries.len(), 1);
    }

    #[test]
    fn parse_quoted_phrase() {
        let filter = ReferenceFilter::parse("\"dark matter\" flag:red");
        assert_eq!(filter.text_terms, vec!["dark matter"]);
        assert!(filter.flag_query.is_some());
    }

    #[test]
    fn tokenize_mixed() {
        let tokens = tokenize("hello \"world foo\" bar");
        assert_eq!(tokens, vec!["hello", "world foo", "bar"]);
    }
}
