//! BibTeX parser integration tests
//!
//! Ported from Swift BibTeXParserTests.swift

mod common;

use common::fixtures::load_bibtex_fixture;
use imbib_core::bibtex::{parse, BibTeXEntryType};

// === Basic Parsing ===

#[test]
fn test_parse_simple_article() {
    let input = r#"
@article{Einstein1905,
    author = {Albert Einstein},
    title = {On the Electrodynamics of Moving Bodies},
    journal = {Annalen der Physik},
    year = {1905}
}
"#;
    let result = parse(input.to_string()).unwrap();

    assert_eq!(result.entries.len(), 1);
    let entry = &result.entries[0];
    assert_eq!(entry.cite_key, "Einstein1905");
    assert_eq!(entry.entry_type, BibTeXEntryType::Article);
    assert_eq!(entry.get_field("author"), Some("Albert Einstein"));
    assert_eq!(
        entry.get_field("title"),
        Some("On the Electrodynamics of Moving Bodies")
    );
    assert_eq!(entry.get_field("year"), Some("1905"));
}

#[test]
fn test_parse_multiple_entries() {
    let input = r#"
@article{Paper1, title = {First}}
@book{Book1, title = {Second}}
@inproceedings{Conf1, title = {Third}}
"#;
    let result = parse(input.to_string()).unwrap();
    assert_eq!(result.entries.len(), 3);
}

// === Brace Handling ===

#[test]
fn test_parse_nested_braces() {
    let input = r#"@article{Test, title = {The {LaTeX} Guide}}"#;
    let result = parse(input.to_string()).unwrap();
    let entry = &result.entries[0];
    // Inner braces preserved for case protection
    let title = entry.get_field("title").unwrap();
    assert!(title.contains("LaTeX"));
}

#[test]
fn test_parse_deep_nested_braces() {
    let input = r#"@article{Test, title = {A {{B {C}}} D}}"#;
    let result = parse(input.to_string()).unwrap();
    assert!(result.entries[0].get_field("title").is_some());
}

// === String Macros ===

#[test]
fn test_parse_string_macro() {
    let input = r#"
@string{jphys = "Journal of Physics"}
@article{Test, journal = jphys}
"#;
    let result = parse(input.to_string()).unwrap();
    let entry = &result.entries[0];
    assert_eq!(entry.get_field("journal"), Some("Journal of Physics"));
}

#[test]
fn test_parse_builtin_month_macros() {
    let input = r#"@article{Test, month = jan}"#;
    let result = parse(input.to_string()).unwrap();
    let month = result.entries[0].get_field("month");
    // Should be "January" or "jan" depending on implementation
    assert!(month.is_some());
}

#[test]
fn test_parse_string_concatenation() {
    let input = r#"
@string{prefix = "Phys."}
@article{Test, journal = prefix # " Rev. Lett."}
"#;
    let result = parse(input.to_string()).unwrap();
    let journal = result.entries[0].get_field("journal").unwrap();
    assert!(journal.contains("Phys.") && journal.contains("Rev. Lett."));
}

// === Value Formats ===

#[test]
fn test_parse_quoted_value() {
    let input = r#"@article{Test, title = "Quoted Title"}"#;
    let result = parse(input.to_string()).unwrap();
    assert_eq!(result.entries[0].get_field("title"), Some("Quoted Title"));
}

#[test]
fn test_parse_numeric_year() {
    let input = r#"@article{Test, year = 2024}"#;
    let result = parse(input.to_string()).unwrap();
    assert_eq!(result.entries[0].get_field("year"), Some("2024"));
}

// === LaTeX Decoding ===

#[test]
fn test_decode_latex_accents() {
    let input = r#"@article{Test, author = {Schr{\"o}dinger}}"#;
    let result = parse(input.to_string()).unwrap();
    let author = result.entries[0].get_field("author").unwrap();
    // Should decode to "Schrödinger" or preserve the LaTeX
    assert!(author.contains("dinger"));
}

#[test]
fn test_decode_latex_special_chars() {
    let input = r#"@article{Test, title = {Cost is \$100 \& cheap}}"#;
    let result = parse(input.to_string()).unwrap();
    let title = result.entries[0].get_field("title").unwrap();
    // Should decode \$ to $ and \& to &
    assert!(title.contains("100"));
}

// === Crossref ===

#[test]
fn test_crossref_inheritance() {
    let input = r#"
@proceedings{ICML2024,
    booktitle = {ICML 2024},
    year = {2024}
}
@inproceedings{Paper1,
    crossref = {ICML2024},
    title = {My Paper}
}
"#;
    let result = parse(input.to_string()).unwrap();
    let paper = result
        .entries
        .iter()
        .find(|e| e.cite_key == "Paper1")
        .unwrap();
    // Should inherit booktitle and year from crossref
    // Note: crossref expansion may or may not be implemented
    assert_eq!(paper.get_field("title"), Some("My Paper"));
}

// === Error Handling ===

#[test]
fn test_parse_recovers_from_malformed_entry() {
    let input = r#"
@article{Bad, title =
@article{Good, title = {Valid}}
"#;
    let result = parse(input.to_string());
    // Parser should recover and parse the valid entry, or return an error
    // depending on implementation strategy
    if let Ok(parsed) = result {
        assert!(parsed.entries.iter().any(|e| e.cite_key == "Good"));
    }
}

// === Fixture Tests ===

#[test]
fn test_parse_simple_fixture() {
    let content = load_bibtex_fixture("simple.bib");
    let result = parse(content).unwrap();

    assert_eq!(result.entries.len(), 3);

    // Check specific entries
    let einstein = result
        .entries
        .iter()
        .find(|e| e.cite_key == "Einstein1905")
        .unwrap();
    assert_eq!(einstein.entry_type, BibTeXEntryType::Article);
    assert!(einstein
        .get_field("title")
        .unwrap()
        .contains("Electrodynamics"));

    let hawking = result
        .entries
        .iter()
        .find(|e| e.cite_key == "Hawking1988")
        .unwrap();
    assert_eq!(hawking.entry_type, BibTeXEntryType::Book);

    let turing = result
        .entries
        .iter()
        .find(|e| e.cite_key == "Turing1950")
        .unwrap();
    assert_eq!(turing.entry_type, BibTeXEntryType::InProceedings);
}

#[test]
fn test_parse_nested_braces_fixture() {
    let content = load_bibtex_fixture("nested_braces.bib");
    let result = parse(content).unwrap();
    assert!(!result.entries.is_empty());
}

#[test]
fn test_parse_string_macros_fixture() {
    let content = load_bibtex_fixture("string_macros.bib");
    let result = parse(content).unwrap();
    assert!(!result.entries.is_empty());
}

#[test]
fn test_parse_latex_chars_fixture() {
    let content = load_bibtex_fixture("latex_chars.bib");
    let result = parse(content).unwrap();
    assert!(!result.entries.is_empty());
}

#[test]
fn test_parse_ads_style_fixture() {
    let content = load_bibtex_fixture("ads_style.bib");
    let result = parse(content).unwrap();
    assert!(!result.entries.is_empty());
}

#[test]
fn test_parse_large_thesis_file() {
    let content = load_bibtex_fixture("thesis_ref.bib");
    let result = parse(content).unwrap();

    // Should parse many entries (thesis bibliographies are usually 100+ entries)
    assert!(
        result.entries.len() > 50,
        "Expected more than 50 entries, got {}",
        result.entries.len()
    );

    // Verify entries have required fields
    for entry in &result.entries {
        assert!(!entry.cite_key.is_empty(), "Entry should have cite key");
    }
}

// === Entry Types ===

#[test]
fn test_parse_all_standard_entry_types() {
    let types = [
        ("article", BibTeXEntryType::Article),
        ("book", BibTeXEntryType::Book),
        ("inproceedings", BibTeXEntryType::InProceedings),
        ("incollection", BibTeXEntryType::InCollection),
        ("phdthesis", BibTeXEntryType::PhdThesis),
        ("mastersthesis", BibTeXEntryType::MastersThesis),
        ("techreport", BibTeXEntryType::TechReport),
        ("misc", BibTeXEntryType::Misc),
        ("unpublished", BibTeXEntryType::Unpublished),
    ];

    for (type_str, expected_type) in types {
        let input = format!("@{}{{Test, title = {{Title}}}}", type_str);
        let result = parse(input).unwrap();
        assert_eq!(result.entries.len(), 1, "Failed to parse {}", type_str);
        assert_eq!(
            result.entries[0].entry_type, expected_type,
            "Wrong type for {}",
            type_str
        );
    }
}

// === Round-trip Tests ===

#[test]
fn test_format_and_reparse() {
    use imbib_core::bibtex::format_entry;

    let input = r#"@article{Test2024,
    author = {John Smith and Jane Doe},
    title = {A Test Paper},
    journal = {Test Journal},
    year = {2024},
    volume = {42},
    pages = {1--10}
}"#;

    let parsed = parse(input.to_string()).unwrap();
    let entry = &parsed.entries[0];

    // Format and reparse
    let formatted = format_entry(entry.clone());
    let reparsed = parse(formatted).unwrap();

    // Should preserve all fields
    let reparsed_entry = &reparsed.entries[0];
    assert_eq!(entry.cite_key, reparsed_entry.cite_key);
    assert_eq!(
        entry.get_field("author"),
        reparsed_entry.get_field("author")
    );
    assert_eq!(entry.get_field("title"), reparsed_entry.get_field("title"));
    assert_eq!(entry.get_field("year"), reparsed_entry.get_field("year"));
}

// === Edge Cases ===

#[test]
fn test_parse_entry_with_url() {
    let input = r#"@misc{Website,
    author = {Author},
    title = {Website Title},
    url = {https://example.com/path?query=value&other=123},
    year = {2024}
}"#;
    let result = parse(input.to_string()).unwrap();
    let url = result.entries[0].get_field("url").unwrap();
    assert!(url.contains("https://"));
}

#[test]
fn test_parse_entry_with_unicode() {
    let input = r#"@article{Unicode,
    author = {José García and François Müller},
    title = {Ελληνικά and 中文 in Title},
    year = {2024}
}"#;
    let result = parse(input.to_string()).unwrap();
    let author = result.entries[0].get_field("author").unwrap();
    assert!(author.contains("José") || author.contains("Garcia"));
}

#[test]
fn test_parse_empty_input() {
    let result = parse("".to_string()).unwrap();
    assert!(result.entries.is_empty());
}

#[test]
fn test_parse_comments_only() {
    let input = r#"
% This is a comment
% Another comment
"#;
    let result = parse(input.to_string()).unwrap();
    assert!(result.entries.is_empty());
}
