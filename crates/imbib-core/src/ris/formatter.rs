//! RIS formatter implementation

use super::entry::RISEntry;

/// Format an RIS entry to string
pub fn format_entry(entry: RISEntry) -> String {
    format_entry_internal(&entry)
}

/// Format multiple entries
#[allow(dead_code)]
pub fn format_entries(entries: &[RISEntry]) -> String {
    entries
        .iter()
        .map(format_entry_internal)
        .collect::<Vec<_>>()
        .join("\n")
}

/// Internal formatting function
fn format_entry_internal(entry: &RISEntry) -> String {
    let mut lines = Vec::new();

    // Type tag first
    lines.push(format!("TY  - {}", entry.entry_type.as_str()));

    // All other tags
    for tag in &entry.tags {
        lines.push(format!("{}  - {}", tag.tag, tag.value));
    }

    // End tag
    lines.push("ER  - ".to_string());

    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ris::RISType;

    #[test]
    fn test_format_simple_entry() {
        let mut entry = RISEntry::new(RISType::JOUR);
        entry.add_tag("TI", "Test Title");
        entry.add_tag("AU", "Smith, John");
        entry.add_tag("PY", "2024");

        let formatted = format_entry(entry);
        assert!(formatted.starts_with("TY  - JOUR"));
        assert!(formatted.contains("TI  - Test Title"));
        assert!(formatted.contains("AU  - Smith, John"));
        assert!(formatted.contains("PY  - 2024"));
        assert!(formatted.ends_with("ER  - "));
    }
}
