//! Combined filter parser for reference lists.
//!
//! Parses filter expressions that combine text search, flag queries, tag queries,
//! field-qualified terms, year filters, and read state into a unified filter.
//!
//! # Syntax
//!
//! ```text
//! title:galaxy year:2020-2024 -simulation flag:red tags:methods unread "exact phrase"
//! ```
//!
//! Tokens:
//! - `flag:*`, `flag:red`, `-flag:*` — flag queries (shorthand: `f:`)
//! - `tags:methods`, `tags:a+b`, `-tags:methods` — tag queries (shorthand: `t:`)
//! - `title:word`, `author:name`, `abstract:term`, `venue:name` — field-qualified search
//!   (shorthand: `ti:`, `au:`, `ab:`, `ve:`)
//! - `year:2020`, `year:2020-2024`, `year:>2020`, `year:<2020` — year filter (shorthand: `y:`)
//! - `-word` — negated text term (exclude matches)
//! - `unread`, `read` — read state
//! - Everything else — text search terms

use impress_flags::{parse_flag_query, FlagQuery};
use impress_tags::{parse_tag_query, TagQuery};

/// A field-qualified text search term (e.g., `title:galaxy`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldTerm {
    pub field: SearchField,
    pub term: String,
}

/// Searchable fields for field-qualified terms.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchField {
    Title,
    Author,
    Abstract,
    Venue,
}

/// Year filter (e.g., `year:2020`, `year:2020-2024`, `year:>2020`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum YearFilter {
    Exact(u16),
    Range(u16, u16),
    After(u16),
    Before(u16),
}

/// A combined filter for publications.
#[derive(Debug, Clone, Default)]
pub struct ReferenceFilter {
    /// Text search terms (matched against title, authors, abstract)
    pub text_terms: Vec<String>,
    /// Negated text terms (exclude matches)
    pub negated_text_terms: Vec<String>,
    /// Field-qualified text terms (e.g., title:galaxy)
    pub field_terms: Vec<FieldTerm>,
    /// Year filter
    pub year_filter: Option<YearFilter>,
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

            // Field-qualified text terms
            if let Some(ft) = parse_field_term(&token) {
                filter.field_terms.push(ft);
                continue;
            }

            // Year filter
            if token.starts_with("year:") || token.starts_with("y:") {
                let value = if token.starts_with("year:") {
                    &token[5..]
                } else {
                    &token[2..]
                };
                if let Some(yf) = parse_year_filter(value) {
                    filter.year_filter = Some(yf);
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

            // Negated text term: -word (but not -flag: or -tags:)
            if token.starts_with('-') && token.len() > 1 {
                filter.negated_text_terms.push(token[1..].to_string());
                continue;
            }

            // Everything else is a text search term
            filter.text_terms.push(token);
        }

        filter
    }

    /// Whether this filter is empty (matches everything).
    pub fn is_empty(&self) -> bool {
        self.text_terms.is_empty()
            && self.negated_text_terms.is_empty()
            && self.field_terms.is_empty()
            && self.year_filter.is_none()
            && self.flag_query.is_none()
            && self.tag_queries.is_empty()
            && self.read_state.is_none()
    }
}

/// Parse a field-qualified text term like `title:galaxy` or `author:smith`.
fn parse_field_term(token: &str) -> Option<FieldTerm> {
    let prefixes: &[(&str, SearchField)] = &[
        ("title:", SearchField::Title),
        ("author:", SearchField::Author),
        ("abstract:", SearchField::Abstract),
        ("venue:", SearchField::Venue),
        // Shorthand
        ("ti:", SearchField::Title),
        ("au:", SearchField::Author),
        ("ab:", SearchField::Abstract),
        ("ve:", SearchField::Venue),
    ];

    for (prefix, field) in prefixes {
        if let Some(rest) = token.strip_prefix(prefix) {
            if !rest.is_empty() {
                return Some(FieldTerm {
                    field: *field,
                    term: rest.to_string(),
                });
            }
        }
    }
    None
}

/// Parse a year filter value like `2020`, `2020-2024`, `>2020`, `<2020`.
fn parse_year_filter(value: &str) -> Option<YearFilter> {
    // Range: 2020-2024
    if let Some((start, end)) = value.split_once('-') {
        let s: u16 = start.parse().ok()?;
        let e: u16 = end.parse().ok()?;
        if s <= e {
            return Some(YearFilter::Range(s, e));
        }
        return None;
    }
    // After: >2020 or >=2020
    if let Some(rest) = value.strip_prefix(">=") {
        let y: u16 = rest.parse().ok()?;
        return Some(YearFilter::Range(y, u16::MAX));
    }
    if let Some(rest) = value.strip_prefix('>') {
        let y: u16 = rest.parse().ok()?;
        return Some(YearFilter::After(y));
    }
    // Before: <2020 or <=2020
    if let Some(rest) = value.strip_prefix("<=") {
        let y: u16 = rest.parse().ok()?;
        return Some(YearFilter::Range(0, y));
    }
    if let Some(rest) = value.strip_prefix('<') {
        let y: u16 = rest.parse().ok()?;
        return Some(YearFilter::Before(y));
    }
    // Exact: 2020
    let y: u16 = value.parse().ok()?;
    Some(YearFilter::Exact(y))
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
    /// Negated text terms (exclude matches)
    pub negated_text_terms: Vec<String>,
    /// Field-qualified terms as "field:term" strings (e.g., ["title:galaxy", "author:smith"])
    pub field_term_raws: Vec<String>,
    /// Year filter as string if present (e.g., "2020", "2020-2024", ">2020")
    pub year_filter_raw: Option<String>,
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
            FlagQuery::NotColor(c) => format!("-flag:{}", c.display_name().to_lowercase()),
            FlagQuery::AnyFlag => "flag:*".to_string(),
            FlagQuery::NoFlag => "-flag:*".to_string(),
        }
    });

    let tag_query_raws: Vec<String> = filter.tag_queries.iter().map(format_tag_query).collect();

    let field_term_raws: Vec<String> = filter.field_terms.iter().map(|ft| {
        let field_name = match ft.field {
            SearchField::Title => "title",
            SearchField::Author => "author",
            SearchField::Abstract => "abstract",
            SearchField::Venue => "venue",
        };
        format!("{}:{}", field_name, ft.term)
    }).collect();

    let year_filter_raw = filter.year_filter.as_ref().map(|yf| match yf {
        YearFilter::Exact(y) => format!("{}", y),
        YearFilter::Range(s, e) => format!("{}-{}", s, e),
        YearFilter::After(y) => format!(">{}", y),
        YearFilter::Before(y) => format!("<{}", y),
    });

    let read_state = filter.read_state.map(|rs| match rs {
        ReadState::Read => "read".to_string(),
        ReadState::Unread => "unread".to_string(),
    });

    ParsedFilter {
        text_terms: filter.text_terms.clone(),
        negated_text_terms: filter.negated_text_terms.clone(),
        field_term_raws,
        year_filter_raw,
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
        assert_eq!(
            filter.flag_query,
            Some(FlagQuery::HasColor(FlagColor::Amber))
        );
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

    #[test]
    fn parse_field_terms() {
        let filter = ReferenceFilter::parse("title:galaxy author:smith");
        assert!(filter.text_terms.is_empty());
        assert_eq!(filter.field_terms.len(), 2);
        assert_eq!(filter.field_terms[0].field, SearchField::Title);
        assert_eq!(filter.field_terms[0].term, "galaxy");
        assert_eq!(filter.field_terms[1].field, SearchField::Author);
        assert_eq!(filter.field_terms[1].term, "smith");
    }

    #[test]
    fn parse_field_shorthand() {
        let filter = ReferenceFilter::parse("ti:dark au:einstein");
        assert_eq!(filter.field_terms.len(), 2);
        assert_eq!(filter.field_terms[0].field, SearchField::Title);
        assert_eq!(filter.field_terms[1].field, SearchField::Author);
    }

    #[test]
    fn parse_year_exact() {
        let filter = ReferenceFilter::parse("year:2020");
        assert_eq!(filter.year_filter, Some(YearFilter::Exact(2020)));
    }

    #[test]
    fn parse_year_range() {
        let filter = ReferenceFilter::parse("year:2020-2024");
        assert_eq!(filter.year_filter, Some(YearFilter::Range(2020, 2024)));
    }

    #[test]
    fn parse_year_after() {
        let filter = ReferenceFilter::parse("year:>2020");
        assert_eq!(filter.year_filter, Some(YearFilter::After(2020)));
    }

    #[test]
    fn parse_year_before() {
        let filter = ReferenceFilter::parse("year:<2020");
        assert_eq!(filter.year_filter, Some(YearFilter::Before(2020)));
    }

    #[test]
    fn parse_year_shorthand() {
        let filter = ReferenceFilter::parse("y:2023");
        assert_eq!(filter.year_filter, Some(YearFilter::Exact(2023)));
    }

    #[test]
    fn parse_negated_text() {
        let filter = ReferenceFilter::parse("galaxy -cosmology");
        assert_eq!(filter.text_terms, vec!["galaxy"]);
        assert_eq!(filter.negated_text_terms, vec!["cosmology"]);
    }

    #[test]
    fn parse_combined_new_features() {
        let filter = ReferenceFilter::parse("title:galaxy year:2020-2024 -simulation flag:red");
        assert_eq!(filter.field_terms.len(), 1);
        assert_eq!(filter.field_terms[0].field, SearchField::Title);
        assert_eq!(filter.field_terms[0].term, "galaxy");
        assert_eq!(filter.year_filter, Some(YearFilter::Range(2020, 2024)));
        assert_eq!(filter.negated_text_terms, vec!["simulation"]);
        assert!(filter.flag_query.is_some());
        assert!(filter.text_terms.is_empty());
    }
}
