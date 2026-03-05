//! RIS parser implementation
//!
//! Parses RIS (Research Information Systems) format files.
//! RIS format uses tagged lines with format: XX  - value

use super::entry::{RISEntry, RISType};
use crate::bibtex::parser::ParseError;

/// Parse a RIS string into entries
pub fn parse(input: String) -> Result<Vec<RISEntry>, ParseError> {
    parse_ris(&input)
}

/// Internal parsing function
fn parse_ris(input: &str) -> Result<Vec<RISEntry>, ParseError> {
    let mut entries = Vec::new();
    let mut current_entry: Option<RISEntry> = None;
    let mut raw_lines = Vec::new();
    let mut last_tag: Option<String> = None;

    for line in input.lines() {
        // Skip empty lines
        if line.trim().is_empty() {
            if current_entry.is_some() {
                raw_lines.push(line.to_string());
            }
            continue;
        }

        // Parse tag-value pair
        if let Some((tag, value)) = parse_ris_line(line) {
            match tag.as_str() {
                "TY" => {
                    // Start of new entry
                    if let Some(mut entry) = current_entry.take() {
                        entry.raw_ris = Some(raw_lines.join("\n"));
                        entries.push(entry);
                    }
                    raw_lines.clear();
                    raw_lines.push(line.to_string());
                    last_tag = None;

                    let entry_type = RISType::from_str(&value);
                    current_entry = Some(RISEntry::new(entry_type));
                }
                "ER" => {
                    // End of entry
                    raw_lines.push(line.to_string());
                    if let Some(mut entry) = current_entry.take() {
                        entry.raw_ris = Some(raw_lines.join("\n"));
                        entries.push(entry);
                    }
                    raw_lines.clear();
                    last_tag = None;
                }
                _ => {
                    // Regular tag
                    raw_lines.push(line.to_string());
                    if let Some(ref mut entry) = current_entry {
                        entry.add_tag(tag.clone(), value);
                        last_tag = Some(tag);
                    }
                }
            }
        } else if let Some(ref mut entry) = current_entry {
            // Continuation line (doesn't start with tag) — append to last tag's value
            raw_lines.push(line.to_string());
            if let Some(ref tag) = last_tag {
                let trimmed = line.trim();
                if !trimmed.is_empty() {
                    if let Some(last) = entry.tags.iter_mut().rev().find(|t| t.tag == *tag) {
                        last.value.push(' ');
                        last.value.push_str(trimmed);
                    }
                }
            }
        }
    }

    // Handle entry without ER tag
    if let Some(mut entry) = current_entry.take() {
        entry.raw_ris = Some(raw_lines.join("\n"));
        entries.push(entry);
    }

    Ok(entries)
}

/// Parse a single RIS line into tag and value
fn parse_ris_line(line: &str) -> Option<(String, String)> {
    // RIS format: XX  - value (two chars, two spaces, dash, space, value)
    // Some variants: XX - value (two chars, space, dash, space, value)
    // ER tags may appear as "ER  -" with no value

    if line.len() < 2 {
        return None;
    }

    // Check for valid tag prefix (two uppercase/digit characters)
    let tag = &line[0..2];
    if !tag
        .chars()
        .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
    {
        return None;
    }

    let rest = &line[2..];

    // Find the separator "  - " or " - " or "- " (with value after)
    // Also handle "  -" or " -" at end of line (no value, e.g. "ER  -")
    let value_start = if rest.starts_with("  - ") {
        4
    } else if rest.starts_with(" - ") {
        3
    } else if rest.starts_with("- ") {
        2
    } else if rest.trim() == "-" || rest.trim().is_empty() {
        // Tag with no value (e.g., "ER  -" or "ER")
        return Some((tag.to_string(), String::new()));
    } else {
        return None;
    };

    let value = rest[value_start..].to_string();
    Some((tag.to_string(), value))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_entry() {
        let input = r#"TY  - JOUR
TI  - A Great Paper
AU  - Smith, John
AU  - Doe, Jane
PY  - 2024
ER  -
"#;
        let entries = parse(input.to_string()).unwrap();
        assert_eq!(entries.len(), 1);

        let entry = &entries[0];
        assert_eq!(entry.entry_type, RISType::JOUR);
        assert_eq!(entry.title(), Some("A Great Paper"));
        assert_eq!(entry.authors(), vec!["Smith, John", "Doe, Jane"]);
        assert_eq!(entry.year(), Some("2024"));
    }

    #[test]
    fn test_parse_multiple_entries() {
        let input = r#"TY  - JOUR
TI  - First Paper
ER  -

TY  - BOOK
TI  - Second Book
ER  -
"#;
        let entries = parse(input.to_string()).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].entry_type, RISType::JOUR);
        assert_eq!(entries[1].entry_type, RISType::BOOK);
    }

    #[test]
    fn test_parse_with_doi() {
        let input = r#"TY  - JOUR
TI  - Test
DO  - 10.1234/test.2024
ER  -
"#;
        let entries = parse(input.to_string()).unwrap();
        assert_eq!(entries[0].doi(), Some("10.1234/test.2024"));
    }

    #[test]
    fn test_parse_multiline_continuation() {
        let input = "TY  - JOUR\n\
                      TI  - A Very Long Title That\n\
                      Continues on the Next Line\n\
                      AU  - Smith, John\n\
                      AB  - This abstract spans\n\
                      multiple lines and should\n\
                      be concatenated together.\n\
                      ER  -\n";
        let entries = parse(input.to_string()).unwrap();
        assert_eq!(entries.len(), 1);

        let entry = &entries[0];
        assert_eq!(
            entry.title(),
            Some("A Very Long Title That Continues on the Next Line")
        );
        assert_eq!(
            entry.abstract_text(),
            Some("This abstract spans multiple lines and should be concatenated together.")
        );
        assert_eq!(entry.authors(), vec!["Smith, John"]);
    }

    #[test]
    fn test_parse_ris_line() {
        assert_eq!(
            parse_ris_line("TY  - JOUR"),
            Some(("TY".to_string(), "JOUR".to_string()))
        );
        assert_eq!(
            parse_ris_line("TI  - A Title"),
            Some(("TI".to_string(), "A Title".to_string()))
        );
        assert_eq!(parse_ris_line("invalid"), None);
    }
}
