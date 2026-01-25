//! Search query building utilities
//!
//! Builds ADS and arXiv API query strings from form inputs.
//!
//! Note: Date-based filtering (e.g., ArXivDateFilter) stays in Swift
//! since it requires Calendar/DateFormatter (Apple-specific).

/// Boolean logic for combining search terms
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Enum)]
pub enum QueryLogic {
    #[default]
    And,
    Or,
}

impl QueryLogic {
    pub fn as_str(&self) -> &'static str {
        match self {
            QueryLogic::And => "AND",
            QueryLogic::Or => "OR",
        }
    }
}

/// ADS database/collection selector
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Enum)]
pub enum ADSDatabase {
    Astronomy,
    Physics,
    Arxiv,
    #[default]
    All,
}

impl ADSDatabase {
    pub fn display_name(&self) -> &'static str {
        match self {
            ADSDatabase::Astronomy => "Astronomy",
            ADSDatabase::Physics => "Physics",
            ADSDatabase::Arxiv => "arXiv Preprints",
            ADSDatabase::All => "All Databases",
        }
    }
}

/// Build an ADS query from classic form fields.
///
/// # Arguments
/// * `authors` - Newline-separated author names
/// * `objects` - SIMBAD/NED object names
/// * `title_words` - Space-separated title words
/// * `title_logic` - AND/OR logic for title words
/// * `abstract_words` - Space-separated abstract/keyword words
/// * `abstract_logic` - AND/OR logic for abstract words
/// * `year_from` - Start year (optional)
/// * `year_to` - End year (optional)
/// * `database` - ADS database selection
/// * `refereed_only` - Only peer-reviewed papers
/// * `articles_only` - Only journal articles
///
/// # Returns
/// ADS query string
#[cfg(feature = "native")]
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn build_classic_query(
    authors: String,
    objects: String,
    title_words: String,
    title_logic: QueryLogic,
    abstract_words: String,
    abstract_logic: QueryLogic,
    year_from: Option<i32>,
    year_to: Option<i32>,
    database: ADSDatabase,
    refereed_only: bool,
    articles_only: bool,
) -> String {
    let mut parts: Vec<String> = Vec::new();

    // Authors: each line becomes author:"..."
    let author_lines: Vec<&str> = authors
        .lines()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();

    if !author_lines.is_empty() {
        let author_queries: Vec<String> = author_lines
            .iter()
            .map(|a| format!("author:\"{}\"", a))
            .collect();
        parts.push(author_queries.join(" AND "));
    }

    // Objects (SIMBAD/NED object names)
    let trimmed_objects = objects.trim();
    if !trimmed_objects.is_empty() {
        parts.push(format!("object:\"{}\"", trimmed_objects));
    }

    // Title words
    let trimmed_title = title_words.trim();
    if !trimmed_title.is_empty() {
        let words: Vec<&str> = trimmed_title
            .split_whitespace()
            .filter(|s| !s.is_empty())
            .collect();

        if words.len() == 1 {
            parts.push(format!("title:{}", words[0]));
        } else if !words.is_empty() {
            let joined = words.join(&format!(" {} ", title_logic.as_str()));
            parts.push(format!("title:({})", joined));
        }
    }

    // Abstract/Keywords words
    let trimmed_abstract = abstract_words.trim();
    if !trimmed_abstract.is_empty() {
        let words: Vec<&str> = trimmed_abstract
            .split_whitespace()
            .filter(|s| !s.is_empty())
            .collect();

        if words.len() == 1 {
            parts.push(format!("abs:{}", words[0]));
        } else if !words.is_empty() {
            let joined = words.join(&format!(" {} ", abstract_logic.as_str()));
            parts.push(format!("abs:({})", joined));
        }
    }

    // Year range
    match (year_from, year_to) {
        (Some(from), Some(to)) if from == to => {
            parts.push(format!("year:{}", from));
        }
        (Some(from), Some(to)) => {
            parts.push(format!("year:{}-{}", from, to));
        }
        (Some(from), None) => {
            parts.push(format!("year:{}-", from));
        }
        (None, Some(to)) => {
            parts.push(format!("year:-{}", to));
        }
        (None, None) => {}
    }

    // Database filter
    match database {
        ADSDatabase::Astronomy => parts.push("collection:astronomy".to_string()),
        ADSDatabase::Physics => parts.push("collection:physics".to_string()),
        ADSDatabase::Arxiv => parts.push("property:eprint".to_string()),
        ADSDatabase::All => {} // No filter
    }

    // Refereed filter
    if refereed_only {
        parts.push("property:refereed".to_string());
    }

    // Articles filter
    if articles_only {
        parts.push("doctype:article".to_string());
    }

    parts.join(" ")
}

/// Build an ADS query from paper identifier fields.
///
/// # Arguments
/// * `bibcode` - ADS bibcode
/// * `doi` - Digital Object Identifier
/// * `arxiv_id` - arXiv identifier (old or new format)
///
/// # Returns
/// ADS query string (identifiers joined with OR)
#[cfg(feature = "native")]
#[uniffi::export]
pub fn build_paper_query(bibcode: String, doi: String, arxiv_id: String) -> String {
    let mut parts: Vec<String> = Vec::new();

    let trimmed_bibcode = bibcode.trim();
    if !trimmed_bibcode.is_empty() {
        parts.push(format!("bibcode:{}", trimmed_bibcode));
    }

    let trimmed_doi = doi.trim();
    if !trimmed_doi.is_empty() {
        parts.push(format!("doi:{}", trimmed_doi));
    }

    let trimmed_arxiv = arxiv_id.trim();
    if !trimmed_arxiv.is_empty() {
        parts.push(format!("arXiv:{}", trimmed_arxiv));
    }

    parts.join(" OR ")
}

/// Check if classic form has any search criteria.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_classic_form_empty(
    authors: String,
    objects: String,
    title_words: String,
    abstract_words: String,
    year_from: Option<i32>,
    year_to: Option<i32>,
) -> bool {
    let has_authors = !authors.trim().is_empty();
    let has_objects = !objects.trim().is_empty();
    let has_title = !title_words.trim().is_empty();
    let has_abstract = !abstract_words.trim().is_empty();
    let has_year = year_from.is_some() || year_to.is_some();

    !has_authors && !has_objects && !has_title && !has_abstract && !has_year
}

/// Check if paper form has any identifier.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_paper_form_empty(bibcode: String, doi: String, arxiv_id: String) -> bool {
    let has_bibcode = !bibcode.trim().is_empty();
    let has_doi = !doi.trim().is_empty();
    let has_arxiv = !arxiv_id.trim().is_empty();

    !has_bibcode && !has_doi && !has_arxiv
}

/// Build an arXiv API query for author + categories.
///
/// # Arguments
/// * `author` - Author name to search for
/// * `categories` - List of arXiv category IDs (e.g., "astro-ph.GA", "hep-th")
/// * `include_cross_listed` - Whether to include cross-listed papers (currently unused)
///
/// # Returns
/// arXiv API query string
#[cfg(feature = "native")]
#[uniffi::export]
pub fn build_arxiv_author_category_query(
    author: String,
    categories: Vec<String>,
    _include_cross_listed: bool,
) -> String {
    let mut parts: Vec<String> = Vec::new();

    // Author query
    let trimmed_author = author.trim();
    if !trimmed_author.is_empty() {
        // Wrap multi-word names in quotes
        let formatted = if trimmed_author.contains(' ') {
            format!("\"{}\"", trimmed_author)
        } else {
            trimmed_author.to_string()
        };
        parts.push(format!("au:{}", formatted));
    }

    // Category filter
    if !categories.is_empty() {
        let mut sorted_cats = categories.clone();
        sorted_cats.sort();
        let cat_query: Vec<String> = sorted_cats.iter().map(|c| format!("cat:{}", c)).collect();
        let cat_str = cat_query.join(" OR ");
        if categories.len() > 1 {
            parts.push(format!("({})", cat_str));
        } else {
            parts.push(cat_str);
        }
    }

    // Combine with AND
    if parts.len() > 1 {
        parts.join(" AND ")
    } else {
        parts.join(" ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_classic_query_authors() {
        let query = build_classic_query(
            "Smith, John\nDoe, Jane".to_string(),
            "".to_string(),
            "".to_string(),
            QueryLogic::And,
            "".to_string(),
            QueryLogic::And,
            None,
            None,
            ADSDatabase::All,
            false,
            false,
        );
        assert!(query.contains("author:\"Smith, John\""));
        assert!(query.contains("author:\"Doe, Jane\""));
        assert!(query.contains(" AND "));
    }

    #[test]
    fn test_build_classic_query_title() {
        let query = build_classic_query(
            "".to_string(),
            "".to_string(),
            "machine learning".to_string(),
            QueryLogic::And,
            "".to_string(),
            QueryLogic::And,
            None,
            None,
            ADSDatabase::All,
            false,
            false,
        );
        assert!(query.contains("title:(machine AND learning)"));
    }

    #[test]
    fn test_build_classic_query_title_or() {
        let query = build_classic_query(
            "".to_string(),
            "".to_string(),
            "machine learning".to_string(),
            QueryLogic::Or,
            "".to_string(),
            QueryLogic::And,
            None,
            None,
            ADSDatabase::All,
            false,
            false,
        );
        assert!(query.contains("title:(machine OR learning)"));
    }

    #[test]
    fn test_build_classic_query_year_range() {
        let query = build_classic_query(
            "".to_string(),
            "".to_string(),
            "test".to_string(),
            QueryLogic::And,
            "".to_string(),
            QueryLogic::And,
            Some(2020),
            Some(2024),
            ADSDatabase::All,
            false,
            false,
        );
        assert!(query.contains("year:2020-2024"));
    }

    #[test]
    fn test_build_classic_query_same_year() {
        let query = build_classic_query(
            "".to_string(),
            "".to_string(),
            "test".to_string(),
            QueryLogic::And,
            "".to_string(),
            QueryLogic::And,
            Some(2024),
            Some(2024),
            ADSDatabase::All,
            false,
            false,
        );
        assert!(query.contains("year:2024"));
        assert!(!query.contains("-"));
    }

    #[test]
    fn test_build_classic_query_filters() {
        let query = build_classic_query(
            "".to_string(),
            "".to_string(),
            "test".to_string(),
            QueryLogic::And,
            "".to_string(),
            QueryLogic::And,
            None,
            None,
            ADSDatabase::Astronomy,
            true,
            true,
        );
        assert!(query.contains("collection:astronomy"));
        assert!(query.contains("property:refereed"));
        assert!(query.contains("doctype:article"));
    }

    #[test]
    fn test_build_paper_query() {
        let query = build_paper_query(
            "2024ApJ...123..456S".to_string(),
            "10.1234/example".to_string(),
            "2401.12345".to_string(),
        );
        assert!(query.contains("bibcode:2024ApJ...123..456S"));
        assert!(query.contains("doi:10.1234/example"));
        assert!(query.contains("arXiv:2401.12345"));
        assert!(query.contains(" OR "));
    }

    #[test]
    fn test_is_classic_form_empty() {
        assert!(is_classic_form_empty(
            "".to_string(),
            "".to_string(),
            "".to_string(),
            "".to_string(),
            None,
            None
        ));
        assert!(!is_classic_form_empty(
            "Smith".to_string(),
            "".to_string(),
            "".to_string(),
            "".to_string(),
            None,
            None
        ));
    }

    #[test]
    fn test_is_paper_form_empty() {
        assert!(is_paper_form_empty(
            "".to_string(),
            "".to_string(),
            "".to_string()
        ));
        assert!(!is_paper_form_empty(
            "2024ApJ...".to_string(),
            "".to_string(),
            "".to_string()
        ));
    }

    #[test]
    fn test_build_arxiv_author_category_query() {
        let query = build_arxiv_author_category_query(
            "John Smith".to_string(),
            vec!["astro-ph.GA".to_string(), "hep-th".to_string()],
            false,
        );
        assert!(query.contains("au:\"John Smith\""));
        assert!(query.contains("(cat:astro-ph.GA OR cat:hep-th)"));
        assert!(query.contains(" AND "));
    }

    #[test]
    fn test_build_arxiv_single_category() {
        let query = build_arxiv_author_category_query(
            "Smith".to_string(),
            vec!["astro-ph".to_string()],
            false,
        );
        assert!(query.contains("au:Smith"));
        assert!(query.contains("cat:astro-ph"));
        assert!(!query.contains("(cat:")); // No parens for single category
    }
}
