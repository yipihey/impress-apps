//! BibTeX formatting module
//!
//! Converts BibTeXEntry structures back to BibTeX string format.

use super::entry::BibTeXEntry;

/// Format a single BibTeX entry to string
pub fn format_entry(entry: BibTeXEntry) -> String {
    format_entry_internal(&entry)
}

/// Format multiple entries to a single BibTeX string
pub fn format_entries(entries: Vec<BibTeXEntry>) -> String {
    entries
        .iter()
        .map(format_entry_internal)
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// Internal formatting function
fn format_entry_internal(entry: &BibTeXEntry) -> String {
    let mut result = String::new();

    // Entry type and cite key
    result.push('@');
    result.push_str(entry.entry_type.as_str());
    result.push('{');
    result.push_str(&entry.cite_key);
    result.push(',');
    result.push('\n');

    // Fields
    for field in &entry.fields {
        result.push_str("    ");
        result.push_str(&field.key);
        result.push_str(" = ");

        // Format the value
        let formatted_value = format_field_value(&field.value);
        result.push_str(&formatted_value);
        result.push(',');
        result.push('\n');
    }

    result.push('}');
    result
}

/// Format a field value, choosing appropriate delimiters
fn format_field_value(value: &str) -> String {
    // Check if the value is purely numeric
    if value.chars().all(|c| c.is_ascii_digit()) {
        return value.to_string();
    }

    // Use braces for values containing special characters or nested braces
    // This preserves LaTeX commands and formatting
    let mut result = String::with_capacity(value.len() + 2);
    result.push('{');
    result.push_str(value);
    result.push('}');
    result
}

/// Escape special BibTeX characters in a value
#[allow(dead_code)]
pub fn escape_value(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            // These characters need escaping in BibTeX
            '#' | '$' | '%' | '&' | '_' => {
                result.push('\\');
                result.push(c);
            }
            // Preserve other characters as-is
            _ => result.push(c),
        }
    }
    result
}

/// Format a @string definition
#[allow(dead_code)]
pub fn format_string_definition(key: &str, value: &str) -> String {
    format!("@string{{{} = {{{}}}}}", key, value)
}

/// Format a @preamble
#[allow(dead_code)]
pub fn format_preamble(text: &str) -> String {
    format!("@preamble{{{{{}}}}}", text)
}

/// Format a complete BibTeX file with strings, preambles, and entries
#[allow(dead_code)]
pub fn format_complete(
    strings: &[(String, String)],
    preambles: &[String],
    entries: &[BibTeXEntry],
) -> String {
    let mut result = String::new();

    // Preambles first
    for preamble in preambles {
        result.push_str(&format_preamble(preamble));
        result.push_str("\n\n");
    }

    // String definitions
    for (key, value) in strings {
        result.push_str(&format_string_definition(key, value));
        result.push_str("\n\n");
    }

    // Entries
    for entry in entries {
        result.push_str(&format_entry_internal(entry));
        result.push_str("\n\n");
    }

    // Remove trailing newlines
    result.trim_end().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::entry::BibTeXEntryType;

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
    fn test_escape_special_chars() {
        assert_eq!(escape_value("10%"), "10\\%");
        assert_eq!(escape_value("$100"), "\\$100");
        assert_eq!(escape_value("A & B"), "A \\& B");
    }
}
