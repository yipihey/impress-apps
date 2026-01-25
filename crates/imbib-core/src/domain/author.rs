//! Author representation

use serde::{Deserialize, Serialize};

/// Represents an author of a publication
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Author {
    pub id: String,
    pub given_name: Option<String>,
    pub family_name: String,
    pub suffix: Option<String>,
    pub orcid: Option<String>,
    pub affiliation: Option<String>,
}

impl Author {
    /// Create a new author with just a family name
    pub fn new(family_name: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            given_name: None,
            family_name,
            suffix: None,
            orcid: None,
            affiliation: None,
        }
    }

    /// Builder method to add given name
    pub fn with_given_name(mut self, given: impl Into<String>) -> Self {
        self.given_name = Some(given.into());
        self
    }

    /// Builder method to add suffix
    pub fn with_suffix(mut self, suffix: impl Into<String>) -> Self {
        self.suffix = Some(suffix.into());
        self
    }

    /// Builder method to add ORCID
    pub fn with_orcid(mut self, orcid: impl Into<String>) -> Self {
        self.orcid = Some(orcid.into());
        self
    }

    /// Format as "Family, Given" for BibTeX
    pub fn to_bibtex_format(&self) -> String {
        match &self.given_name {
            Some(given) => format!("{}, {}", self.family_name, given),
            None => self.family_name.clone(),
        }
    }

    /// Format as "Given Family" for display
    pub fn display_name(&self) -> String {
        let mut name = match &self.given_name {
            Some(given) => format!("{} {}", given, self.family_name),
            None => self.family_name.clone(),
        };
        if let Some(suffix) = &self.suffix {
            name.push_str(", ");
            name.push_str(suffix);
        }
        name
    }
}

pub(crate) fn parse_author_string_internal(input: String) -> Vec<Author> {
    crate::text::split_authors(input)
        .into_iter()
        .map(|author_str| parse_single_author(&author_str))
        .collect()
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn parse_author_string(input: String) -> Vec<Author> {
    parse_author_string_internal(input)
}

/// Parse a single author string into an Author struct
fn parse_single_author(input: &str) -> Author {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Author::new("Unknown".to_string());
    }

    // Check for "Last, First" format
    if let Some(comma_pos) = trimmed.find(',') {
        let family = trimmed[..comma_pos].trim();
        let given = trimmed[comma_pos + 1..].trim();
        let mut author = Author::new(family.to_string());
        if !given.is_empty() {
            author.given_name = Some(given.to_string());
        }
        return author;
    }

    // "First Last" format - take last word as family name
    let parts: Vec<&str> = trimmed.split_whitespace().collect();
    if parts.len() == 1 {
        return Author::new(parts[0].to_string());
    }

    let family = parts.last().unwrap_or(&"Unknown").to_string();
    let given = parts[..parts.len() - 1].join(" ");
    let mut author = Author::new(family);
    if !given.is_empty() {
        author.given_name = Some(given);
    }
    author
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_author_new() {
        let author = Author::new("Einstein".to_string());
        assert_eq!(author.family_name, "Einstein");
        assert!(author.given_name.is_none());
    }

    #[test]
    fn test_author_with_given_name() {
        let author = Author::new("Einstein".to_string()).with_given_name("Albert");
        assert_eq!(author.family_name, "Einstein");
        assert_eq!(author.given_name, Some("Albert".to_string()));
    }

    #[test]
    fn test_to_bibtex_format() {
        let author = Author::new("Einstein".to_string()).with_given_name("Albert");
        assert_eq!(author.to_bibtex_format(), "Einstein, Albert");

        let no_given = Author::new("Einstein".to_string());
        assert_eq!(no_given.to_bibtex_format(), "Einstein");
    }

    #[test]
    fn test_display_name() {
        let author = Author::new("Einstein".to_string()).with_given_name("Albert");
        assert_eq!(author.display_name(), "Albert Einstein");

        let with_suffix = Author::new("King".to_string())
            .with_given_name("Martin Luther")
            .with_suffix("Jr.");
        assert_eq!(with_suffix.display_name(), "Martin Luther King, Jr.");
    }
}
