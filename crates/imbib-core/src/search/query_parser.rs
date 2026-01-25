//! Parse ADS/arXiv query strings back to form fields

use super::query_builder::{ADSDatabase, QueryLogic};
use lazy_static::lazy_static;
use regex::Regex;

lazy_static! {
    static ref AUTHOR_PATTERN: Regex = Regex::new(r#"author:"([^"]+)""#).unwrap();
    static ref OBJECT_PATTERN: Regex = Regex::new(r#"object:"([^"]+)""#).unwrap();
    static ref TITLE_PATTERN: Regex = Regex::new(r#"title:(\([^)]+\)|[^\s]+)"#).unwrap();
    static ref ABS_PATTERN: Regex = Regex::new(r#"abs:(\([^)]+\)|[^\s]+)"#).unwrap();
    static ref YEAR_PATTERN: Regex = Regex::new(r#"year:(\d{4})?-?(\d{4})?"#).unwrap();
    static ref COLLECTION_PATTERN: Regex = Regex::new(r#"collection:(astronomy|physics)"#).unwrap();
    static ref BIBCODE_PATTERN: Regex = Regex::new(r#"bibcode:([^\s]+)"#).unwrap();
    static ref DOI_PATTERN: Regex = Regex::new(r#"doi:([^\s]+)"#).unwrap();
    static ref ARXIV_PATTERN: Regex = Regex::new(r#"arXiv:([^\s]+)"#).unwrap();
    static ref CAT_PATTERN: Regex = Regex::new(r#"cat:([^\s()]+)"#).unwrap();
    static ref DATE_RANGE_PATTERN: Regex =
        Regex::new(r#"submittedDate:\[(\d+|\*) TO (\d+|\*)\]"#).unwrap();
}

/// Parsed ADS Classic form state
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct ParsedClassicForm {
    pub authors: String,
    pub objects: String,
    pub title_words: String,
    pub title_logic: QueryLogic,
    pub abstract_words: String,
    pub abstract_logic: QueryLogic,
    pub year_from: Option<i32>,
    pub year_to: Option<i32>,
    pub database: ADSDatabase,
    pub refereed_only: bool,
    pub articles_only: bool,
}

/// Parsed ADS Paper form state
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct ParsedPaperForm {
    pub bibcode: String,
    pub doi: String,
    pub arxiv_id: String,
}

/// Parsed arXiv form state
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct ParsedArXivForm {
    pub search_terms: Vec<ParsedArXivTerm>,
    pub categories: Vec<String>,
    pub date_from: Option<String>,
    pub date_to: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ParsedArXivTerm {
    pub term: String,
    pub field: String,
    pub logic: String,
}

/// Try to parse an ADS query back to classic form fields
#[cfg(feature = "native")]
#[uniffi::export]
pub fn parse_classic_query(query: String) -> Option<ParsedClassicForm> {
    let mut state = ParsedClassicForm::default();
    let mut has_content = false;

    // Extract authors
    for cap in AUTHOR_PATTERN.captures_iter(&query) {
        if let Some(m) = cap.get(1) {
            if !state.authors.is_empty() {
                state.authors.push('\n');
            }
            state.authors.push_str(m.as_str());
            has_content = true;
        }
    }

    // Extract objects
    if let Some(cap) = OBJECT_PATTERN.captures(&query) {
        if let Some(m) = cap.get(1) {
            state.objects = m.as_str().to_string();
            has_content = true;
        }
    }

    // Extract title
    if let Some(cap) = TITLE_PATTERN.captures(&query) {
        if let Some(m) = cap.get(1) {
            let title_part = m.as_str();
            state.title_words = clean_query_part(title_part);
            if title_part.contains(" OR ") {
                state.title_logic = QueryLogic::Or;
            }
            has_content = true;
        }
    }

    // Extract abstract
    if let Some(cap) = ABS_PATTERN.captures(&query) {
        if let Some(m) = cap.get(1) {
            let abs_part = m.as_str();
            state.abstract_words = clean_query_part(abs_part);
            if abs_part.contains(" OR ") {
                state.abstract_logic = QueryLogic::Or;
            }
            has_content = true;
        }
    }

    // Extract year range
    if let Some(cap) = YEAR_PATTERN.captures(&query) {
        if let Some(m) = cap.get(1) {
            state.year_from = m.as_str().parse().ok();
            has_content = true;
        }
        if let Some(m) = cap.get(2) {
            state.year_to = m.as_str().parse().ok();
            has_content = true;
        }
    }

    // Extract collection/database
    if let Some(cap) = COLLECTION_PATTERN.captures(&query) {
        if let Some(m) = cap.get(1) {
            state.database = match m.as_str() {
                "astronomy" => ADSDatabase::Astronomy,
                "physics" => ADSDatabase::Physics,
                _ => ADSDatabase::All,
            };
            has_content = true;
        }
    }

    // Check for property flags
    if query.contains("property:eprint") {
        state.database = ADSDatabase::Arxiv;
        has_content = true;
    }
    if query.contains("property:refereed") {
        state.refereed_only = true;
    }
    if query.contains("doctype:article") {
        state.articles_only = true;
    }

    if has_content {
        Some(state)
    } else {
        None
    }
}

/// Try to parse an ADS query to paper form fields
#[cfg(feature = "native")]
#[uniffi::export]
pub fn parse_paper_query(query: String) -> Option<ParsedPaperForm> {
    let mut state = ParsedPaperForm::default();
    let mut has_match = false;

    if let Some(cap) = BIBCODE_PATTERN.captures(&query) {
        if let Some(m) = cap.get(1) {
            state.bibcode = m.as_str().to_string();
            has_match = true;
        }
    }

    if let Some(cap) = DOI_PATTERN.captures(&query) {
        if let Some(m) = cap.get(1) {
            state.doi = m.as_str().to_string();
            has_match = true;
        }
    }

    if let Some(cap) = ARXIV_PATTERN.captures(&query) {
        if let Some(m) = cap.get(1) {
            state.arxiv_id = m.as_str().to_string();
            has_match = true;
        }
    }

    // Paper form queries should only contain identifiers
    let mut cleaned = query.clone();
    cleaned = BIBCODE_PATTERN.replace_all(&cleaned, "").to_string();
    cleaned = DOI_PATTERN.replace_all(&cleaned, "").to_string();
    cleaned = ARXIV_PATTERN.replace_all(&cleaned, "").to_string();
    cleaned = cleaned.replace(" OR ", "").trim().to_string();

    if !cleaned.is_empty() {
        return None; // Has non-identifier content
    }

    if has_match {
        Some(state)
    } else {
        None
    }
}

/// Try to parse an arXiv query back to form fields
#[cfg(feature = "native")]
#[uniffi::export]
pub fn parse_arxiv_query(query: String) -> Option<ParsedArXivForm> {
    let mut state = ParsedArXivForm::default();

    // Check if this looks like an arXiv query
    let has_category = query.contains("cat:");
    let has_arxiv_fields = [
        "ti:",
        "au:",
        "abs:",
        "co:",
        "jr:",
        "rn:",
        "id:",
        "submittedDate:",
    ]
    .iter()
    .any(|f| query.contains(f));

    if !has_category && !has_arxiv_fields {
        return None;
    }

    // Parse categories
    for cap in CAT_PATTERN.captures_iter(&query) {
        if let Some(m) = cap.get(1) {
            state.categories.push(m.as_str().to_string());
        }
    }

    // Parse date range
    if let Some(cap) = DATE_RANGE_PATTERN.captures(&query) {
        if let Some(m) = cap.get(1) {
            let from = m.as_str();
            if from != "*" {
                state.date_from = Some(from.to_string());
            }
        }
        if let Some(m) = cap.get(2) {
            let to = m.as_str();
            if to != "*" {
                state.date_to = Some(to.to_string());
            }
        }
    }

    // Parse search terms (simplified)
    let field_prefixes = [
        ("ti:", "title"),
        ("au:", "author"),
        ("abs:", "abstract"),
        ("co:", "comments"),
        ("jr:", "journal"),
        ("rn:", "report"),
        ("id:", "arxiv_id"),
        ("doi:", "doi"),
        ("all:", "all"),
    ];

    for part in query.split_whitespace() {
        if part == "AND" || part == "OR" || part == "ANDNOT" {
            continue;
        }

        // Skip category and date patterns
        if part.starts_with("cat:") || part.starts_with("submittedDate:") {
            continue;
        }

        let mut field = "all".to_string();
        let mut value = part.to_string();

        for (prefix, field_name) in &field_prefixes {
            if part.to_lowercase().starts_with(prefix) {
                field = field_name.to_string();
                value = part[prefix.len()..].trim_matches('"').to_string();
                break;
            }
        }

        if !value.is_empty() && !value.starts_with('[') {
            state.search_terms.push(ParsedArXivTerm {
                term: value,
                field,
                logic: "AND".to_string(),
            });
        }
    }

    Some(state)
}

fn clean_query_part(part: &str) -> String {
    part.replace(['(', ')'], "")
        .replace(" AND ", " ")
        .replace(" OR ", " ")
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_classic_query() {
        let query = r#"author:"Einstein, A." title:(relativity theory) year:1905-1920"#;
        let parsed = parse_classic_query(query.to_string()).unwrap();
        assert_eq!(parsed.authors, "Einstein, A.");
        assert!(parsed.title_words.contains("relativity"));
        assert_eq!(parsed.year_from, Some(1905));
        assert_eq!(parsed.year_to, Some(1920));
    }

    #[test]
    fn test_parse_paper_query() {
        let query = "bibcode:2023ApJ...123..456A doi:10.1234/test";
        let parsed = parse_paper_query(query.to_string()).unwrap();
        assert_eq!(parsed.bibcode, "2023ApJ...123..456A");
        assert_eq!(parsed.doi, "10.1234/test");
    }

    #[test]
    fn test_parse_arxiv_query() {
        let query = "cat:cs.LG au:Smith ti:machine learning";
        let parsed = parse_arxiv_query(query.to_string()).unwrap();
        assert!(parsed.categories.contains(&"cs.LG".to_string()));
        assert_eq!(parsed.search_terms.len(), 3);
    }

    #[test]
    fn test_parse_classic_query_with_filters() {
        let query = "author:\"Smith, J.\" collection:astronomy property:refereed doctype:article";
        let parsed = parse_classic_query(query.to_string()).unwrap();
        assert_eq!(parsed.authors, "Smith, J.");
        assert_eq!(parsed.database, ADSDatabase::Astronomy);
        assert!(parsed.refereed_only);
        assert!(parsed.articles_only);
    }
}
