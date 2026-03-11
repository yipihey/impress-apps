//! BibTeX formatting — delegates to the canonical `impress_bibtex` (→ `im-bibtex`) crate.

use super::entry::BibTeXEntry;

/// Format a single BibTeX entry to string
pub fn format_entry(entry: BibTeXEntry) -> String {
    impress_bibtex::format_entry(entry.into())
}

/// Format multiple entries to a single BibTeX string
pub fn format_entries(entries: Vec<BibTeXEntry>) -> String {
    impress_bibtex::format_entries(entries.into_iter().map(Into::into).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bibtex::entry::BibTeXEntryType;

    #[test]
    fn test_format_simple_entry() {
        let mut entry = BibTeXEntry::new("Smith2024".to_string(), BibTeXEntryType::Article);
        entry.add_field("author", "John Smith");
        entry.add_field("title", "A Great Paper");
        entry.add_field("year", "2024");

        let formatted = format_entry(entry);
        assert!(formatted.contains("@article{Smith2024,"));
        assert!(formatted.contains("author = {John Smith}"));
        assert!(formatted.contains("title = {A Great Paper}"));
        // Year is numeric, so no braces
        assert!(formatted.contains("year = 2024,"));
    }

    #[test]
    fn test_format_numeric_year() {
        let mut entry = BibTeXEntry::new("Test2024".to_string(), BibTeXEntryType::Article);
        entry.add_field("year", "2024");

        let formatted = format_entry(entry);
        // Numeric values should not have braces
        assert!(formatted.contains("year = 2024,"));
    }

    #[test]
    fn test_format_with_latex() {
        let mut entry = BibTeXEntry::new("Test2024".to_string(), BibTeXEntryType::Article);
        entry.add_field("title", "The {LaTeX} Companion");

        let formatted = format_entry(entry);
        assert!(formatted.contains("title = {The {LaTeX} Companion}"));
    }

    #[test]
    fn test_format_multiple_entries() {
        let mut entry1 = BibTeXEntry::new("First2024".to_string(), BibTeXEntryType::Article);
        entry1.add_field("title", "First");

        let mut entry2 = BibTeXEntry::new("Second2024".to_string(), BibTeXEntryType::Book);
        entry2.add_field("title", "Second");

        let formatted = format_entries(vec![entry1, entry2]);
        assert!(formatted.contains("@article{First2024,"));
        assert!(formatted.contains("@book{Second2024,"));
    }
}
