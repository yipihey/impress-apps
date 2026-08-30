//! BibTeX formatting module
//!
//! Converts BibTeXEntry structures back to BibTeX string format.
//
// TODO(phase-1d): byte-equivalent parity with Swift `BibTeXExporter`.
//
// `BibTeXEntry.fields` is a `Vec<BibTeXField>`, but every Swift caller stores
// fields in a `[String: String]` whose iteration order is undefined. When such
// a dict is converted to `Vec<BibTeXField>` and handed to `format_entry`, the
// resulting BibTeX has non-deterministic field order. The Swift exporter
// instead (1) sorts fields by `BibTeXFieldNames.defaultFieldOrder` then
// alphabetical, (2) omits the trailing comma on the last field, and (3)
// treats only a small allow-list as numeric (year/volume/number/pages) — all
// other digit-only values get braces. Direct byte equivalence therefore fails;
// see `BibTeXExporterByteEquivalenceTests` in PublicationManagerCore for the
// empirical evidence.
//
// To consolidate onto Rust we need a `format_entry_with_options(entry, opts)`
// API that accepts a field-order vector, a numeric-field set, and a
// trailing-comma toggle — plus a UniFFI export + xcframework rebuild so Swift
// can call it. Tracked in Phase 1D of we-are-planning-to-frolicking-boot.md.

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
    // Empty values need braces, not bare output
    if value.is_empty() {
        return "{}".to_string();
    }

    // Check if the value is purely numeric
    if value.chars().all(|c| c.is_ascii_digit()) {
        return value.to_string();
    }

    // Use braces for values containing special characters or nested braces
    // This preserves LaTeX commands and formatting
    let value = sanitize_field_value(value);
    let mut result = String::with_capacity(value.len() + 2);
    result.push('{');
    result.push_str(&value);
    result.push('}');
    result
}

/// Make a field value safe to re-parse, so one damaged field (a truncated
/// enrichment abstract, say) cannot render a whole exported bibliography
/// unreadable. Hayagriva in particular treats an unclosed `$` as verbatim
/// math and consumes the rest of the FILE, and an unbalanced brace ends the
/// entry early — either way every entry after the bad one is lost, which is
/// exactly what broke the imbib→imprint citation seam on the ULDM manuscript.
///
/// Well-formed values pass through byte-identical. A value with unbalanced
/// braces loses its brace characters (the grouping was already meaningless);
/// a value with an odd count of unescaped `$` gets one closing `$` appended.
fn sanitize_field_value(value: &str) -> String {
    let mut depth: i64 = 0;
    let mut balanced = true;
    let mut dollars = 0usize;
    let mut prev_backslash = false;
    for c in value.chars() {
        match c {
            '{' if !prev_backslash => depth += 1,
            '}' if !prev_backslash => {
                depth -= 1;
                if depth < 0 {
                    balanced = false;
                }
            }
            '$' if !prev_backslash => dollars += 1,
            _ => {}
        }
        prev_backslash = c == '\\' && !prev_backslash;
    }
    if depth != 0 {
        balanced = false;
    }

    if balanced && dollars.is_multiple_of(2) {
        return value.to_string();
    }

    let mut out: String = if balanced {
        value.to_string()
    } else {
        let mut prev = false;
        let filtered: String = value
            .chars()
            .filter(|&c| {
                let keep = !matches!(c, '{' | '}') || prev;
                prev = c == '\\' && !prev;
                keep
            })
            .collect();
        filtered
    };
    if !dollars.is_multiple_of(2) {
        out.push('$');
    }
    out
}

/// Escape special BibTeX characters in a value
pub fn escape_value(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            // These characters need escaping in BibTeX
            '#' | '$' | '%' | '&' | '_' | '{' | '}' | '\\' => {
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
pub fn format_string_definition(key: &str, value: &str) -> String {
    format!("@string{{{} = {{{}}}}}", key, value)
}

/// Format a @preamble
pub fn format_preamble(text: &str) -> String {
    format!("@preamble{{{{{}}}}}", text)
}

/// Format a complete BibTeX file with strings, preambles, and entries
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

#[cfg(test)]
mod sanitize_tests {
    use super::*;

    #[test]
    fn well_formed_values_pass_through() {
        assert_eq!(
            sanitize_field_value("The {LaTeX} Companion"),
            "The {LaTeX} Companion"
        );
        assert_eq!(
            sanitize_field_value("energy $E = mc^2$ here"),
            "energy $E = mc^2$ here"
        );
        assert_eq!(
            sanitize_field_value(r"escaped \{ brace \}"),
            r"escaped \{ brace \}"
        );
    }

    #[test]
    fn unclosed_math_gets_closed() {
        // The truncated-abstract case that broke the ULDM bibliography.
        assert_eq!(
            sanitize_field_value("mixes with the environment when $H"),
            "mixes with the environment when $H$"
        );
    }

    #[test]
    fn unbalanced_braces_are_stripped() {
        assert_eq!(sanitize_field_value("dangling {group"), "dangling group");
        assert_eq!(sanitize_field_value("closes} early"), "closes early");
    }

    #[test]
    fn formatted_entry_with_broken_field_stays_parseable() {
        use crate::entry::{BibTeXEntry, BibTeXEntryType};
        let mut entry = BibTeXEntry::new("Broken2021".to_string(), BibTeXEntryType::Article);
        entry.add_field("title", "Fine Title");
        entry.add_field("abstract", "truncated at math $H");
        let formatted = format_entry(entry);
        assert!(formatted.contains("abstract = {truncated at math $H$},"));
    }
}
