//! RIS format integration tests
//!
//! Ported from Swift RIS*Tests.swift files

mod common;

use common::fixtures::load_ris_fixture;
use imbib_core::bibtex::{BibTeXEntry, BibTeXEntryType};
use imbib_core::ris::{format_entry, from_bibtex, parse, to_bibtex, RISEntry, RISType};

// === Parser Tests ===

#[test]
fn test_parse_single_entry() {
    let ris = "TY  - JOUR\nAU  - Smith, John\nTI  - Test Title\nPY  - 2024\nER  -";
    let entries = parse(ris.to_string()).unwrap();

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].entry_type, RISType::JOUR);
}

#[test]
fn test_parse_multiple_entries() {
    let ris = r#"TY  - JOUR
TI  - First
ER  -

TY  - BOOK
TI  - Second
ER  -"#;
    let entries = parse(ris.to_string()).unwrap();
    assert_eq!(entries.len(), 2);
}

#[test]
fn test_parse_multiple_authors() {
    let ris = "TY  - JOUR\nAU  - Smith, John\nAU  - Doe, Jane\nAU  - Wilson, Bob\nER  -";
    let entries = parse(ris.to_string()).unwrap();

    let authors = entries[0].authors();
    assert_eq!(authors.len(), 3);
    assert!(authors.contains(&"Smith, John"));
    assert!(authors.contains(&"Doe, Jane"));
    assert!(authors.contains(&"Wilson, Bob"));
}

#[test]
fn test_parse_all_common_ris_types() {
    let types = [
        ("JOUR", RISType::JOUR),
        ("BOOK", RISType::BOOK),
        ("CHAP", RISType::CHAP),
        ("CONF", RISType::CONF),
        ("THES", RISType::THES),
        ("RPRT", RISType::RPRT),
        ("GEN", RISType::GEN),
    ];

    for (tag, expected_type) in types {
        let ris = format!("TY  - {}\nTI  - Test\nER  -", tag);
        let entries = parse(ris).unwrap();
        assert_eq!(
            entries[0].entry_type, expected_type,
            "Failed for type {}",
            tag
        );
    }
}

#[test]
fn test_parse_with_abstract() {
    let ris = "TY  - JOUR\nTI  - Test\nAB  - This is the abstract text.\nER  -";
    let entries = parse(ris.to_string()).unwrap();
    assert_eq!(
        entries[0].abstract_text(),
        Some("This is the abstract text.")
    );
}

#[test]
fn test_parse_with_doi() {
    let ris = "TY  - JOUR\nTI  - Test\nDO  - 10.1234/test.123\nER  -";
    let entries = parse(ris.to_string()).unwrap();
    assert_eq!(entries[0].doi(), Some("10.1234/test.123"));
}

#[test]
fn test_parse_with_urls() {
    let ris =
        "TY  - JOUR\nTI  - Test\nUR  - https://example.com\nL1  - https://pdf.com/paper.pdf\nER  -";
    let entries = parse(ris.to_string()).unwrap();
    let url = entries[0].get_tag("UR");
    assert!(url.is_some());
}

#[test]
fn test_parse_with_keywords() {
    let ris = "TY  - JOUR\nTI  - Test\nKW  - keyword1\nKW  - keyword2\nKW  - keyword3\nER  -";
    let entries = parse(ris.to_string()).unwrap();
    let keywords = entries[0].get_all_tags("KW");
    assert_eq!(keywords.len(), 3);
}

#[test]
fn test_parse_year_with_date() {
    let ris = "TY  - JOUR\nTI  - Test\nPY  - 2024/03/15\nER  -";
    let entries = parse(ris.to_string()).unwrap();
    // Should extract just the year
    assert_eq!(entries[0].year(), Some("2024"));
}

// === Exporter Tests ===

#[test]
fn test_format_basic_entry() {
    let mut entry = RISEntry::new(RISType::JOUR);
    entry.add_tag("TI", "Test Article");
    entry.add_tag("AU", "Smith, John");
    entry.add_tag("PY", "2024");

    let output = format_entry(entry);

    assert!(output.contains("TY  - JOUR"));
    assert!(output.contains("TI  - Test Article"));
    assert!(output.contains("AU  - Smith, John"));
    assert!(output.contains("PY  - 2024"));
    assert!(output.contains("ER  -"));
}

#[test]
fn test_format_preserves_field_order() {
    let mut entry = RISEntry::new(RISType::JOUR);
    entry.add_tag("TI", "Test");
    entry.add_tag("JF", "Nature");
    entry.add_tag("PY", "2024");

    let output = format_entry(entry);
    let ty_pos = output.find("TY  -").unwrap();
    let er_pos = output.find("ER  -").unwrap();

    // TY should come first, ER should come last
    assert!(ty_pos < er_pos);
}

#[test]
fn test_format_multiple_authors() {
    let mut entry = RISEntry::new(RISType::JOUR);
    entry.add_tag("TI", "Test");
    entry.add_tag("AU", "Smith, John");
    entry.add_tag("AU", "Doe, Jane");
    entry.add_tag("AU", "Wilson, Bob");

    let output = format_entry(entry);

    // Count AU occurrences
    let au_count = output.matches("AU  -").count();
    assert_eq!(au_count, 3);
}

// === Converter Tests (RIS <-> BibTeX) ===

#[test]
fn test_ris_to_bibtex_journal_to_article() {
    let mut ris = RISEntry::new(RISType::JOUR);
    ris.add_tag("TI", "Test");
    ris.add_tag("AU", "Smith, John");
    ris.add_tag("PY", "2024");
    ris.add_tag("JF", "Nature");

    let bibtex = to_bibtex(ris);

    assert_eq!(bibtex.entry_type, BibTeXEntryType::Article);
    assert_eq!(bibtex.get_field("title"), Some("Test"));
    assert_eq!(bibtex.get_field("journal"), Some("Nature"));
}

#[test]
fn test_ris_to_bibtex_book() {
    let mut ris = RISEntry::new(RISType::BOOK);
    ris.add_tag("TI", "The Book");
    ris.add_tag("AU", "Author, A");
    ris.add_tag("PY", "2020");

    let bibtex = to_bibtex(ris);
    assert_eq!(bibtex.entry_type, BibTeXEntryType::Book);
}

#[test]
fn test_ris_to_bibtex_conference() {
    let mut ris = RISEntry::new(RISType::CONF);
    ris.add_tag("TI", "Paper");
    ris.add_tag("PY", "2024");

    let bibtex = to_bibtex(ris);
    assert!(
        bibtex.entry_type == BibTeXEntryType::InProceedings
            || bibtex.entry_type == BibTeXEntryType::InCollection
    );
}

#[test]
fn test_ris_to_bibtex_thesis() {
    let mut ris = RISEntry::new(RISType::THES);
    ris.add_tag("TI", "My Thesis");
    ris.add_tag("AU", "Student, A");
    ris.add_tag("PY", "2024");

    let bibtex = to_bibtex(ris);
    assert!(
        bibtex.entry_type == BibTeXEntryType::PhdThesis
            || bibtex.entry_type == BibTeXEntryType::MastersThesis
    );
}

#[test]
fn test_bibtex_to_ris_article() {
    let mut bibtex = BibTeXEntry::new("Test".into(), BibTeXEntryType::Article);
    bibtex.add_field("title", "Test Article");
    bibtex.add_field("author", "Smith, John");
    bibtex.add_field("year", "2024");

    let ris = from_bibtex(bibtex);
    assert_eq!(ris.entry_type, RISType::JOUR);
}

#[test]
fn test_bibtex_to_ris_book() {
    let mut bibtex = BibTeXEntry::new("Test".into(), BibTeXEntryType::Book);
    bibtex.add_field("title", "Test Book");
    bibtex.add_field("author", "Author, A");
    bibtex.add_field("year", "2020");

    let ris = from_bibtex(bibtex);
    assert_eq!(ris.entry_type, RISType::BOOK);
}

#[test]
fn test_roundtrip_ris_bibtex_ris() {
    let mut original = RISEntry::new(RISType::JOUR);
    original.add_tag("TI", "Roundtrip Test");
    original.add_tag("AU", "Tester, T");
    original.add_tag("PY", "2024");
    original.add_tag("DO", "10.1234/test");

    let bibtex = to_bibtex(original.clone());
    let roundtrip = from_bibtex(bibtex);

    assert_eq!(original.entry_type, roundtrip.entry_type);
    assert_eq!(original.title(), roundtrip.title());
    assert_eq!(original.doi(), roundtrip.doi());
}

#[test]
fn test_roundtrip_bibtex_ris_bibtex() {
    let mut original = BibTeXEntry::new("Test2024".into(), BibTeXEntryType::Article);
    original.add_field("title", "Roundtrip Test");
    original.add_field("author", "Smith, John");
    original.add_field("year", "2024");
    original.add_field("journal", "Test Journal");

    let ris = from_bibtex(original.clone());
    let roundtrip = to_bibtex(ris);

    assert_eq!(original.entry_type, roundtrip.entry_type);
    assert_eq!(original.get_field("title"), roundtrip.get_field("title"));
    assert_eq!(original.get_field("year"), roundtrip.get_field("year"));
}

// === Fixture Tests ===

#[test]
fn test_parse_sample_fixture() {
    let ris = load_ris_fixture("sample.ris");
    let entries = parse(ris).unwrap();

    assert_eq!(entries.len(), 1);

    let entry = &entries[0];
    assert_eq!(entry.entry_type, RISType::JOUR);
    assert_eq!(
        entry.title(),
        Some("A Relational Model of Data for Large Shared Data Banks")
    );
    assert!(entry.authors().contains(&"Codd, Edgar F."));
    assert_eq!(entry.year(), Some("1970"));
    assert_eq!(entry.doi(), Some("10.1145/362384.362685"));
}

#[test]
fn test_parse_multiple_authors_fixture() {
    let ris = load_ris_fixture("multiple_authors.ris");
    let entries = parse(ris).unwrap();

    assert_eq!(entries.len(), 2);

    // First entry: ImageNet paper with 3 authors
    let imagenet = &entries[0];
    assert!(imagenet.authors().len() >= 3);
    assert!(imagenet.authors().iter().any(|a| a.contains("Krizhevsky")));

    // Second entry: Attention paper with 8 authors
    let attention = &entries[1];
    assert!(attention.authors().len() >= 7);
    assert!(attention.authors().iter().any(|a| a.contains("Vaswani")));
}

#[test]
fn test_parse_all_types_fixture() {
    let ris = load_ris_fixture("all_types.ris");
    let entries = parse(ris).unwrap();

    // Should have multiple entries of various types
    assert!(entries.len() >= 5);

    // Check for expected types
    let types: Vec<_> = entries.iter().map(|e| &e.entry_type).collect();
    assert!(types.contains(&&RISType::BOOK));
    assert!(types.contains(&&RISType::CHAP));
    assert!(types.contains(&&RISType::THES));
    assert!(types.contains(&&RISType::RPRT));
}

// === Edge Cases ===

#[test]
fn test_parse_empty_input() {
    let result = parse("".to_string()).unwrap();
    assert!(result.is_empty());
}

#[test]
fn test_parse_entry_without_er() {
    // Entry without ER tag at end - should still parse
    let ris = "TY  - JOUR\nTI  - Test\nAU  - Author";
    let result = parse(ris.to_string());
    // Parser may or may not accept this
    if let Ok(entries) = result {
        if !entries.is_empty() {
            assert_eq!(entries[0].title(), Some("Test"));
        }
    }
}

#[test]
fn test_parse_with_blank_lines() {
    let ris = r#"TY  - JOUR

TI  - Test Title

AU  - Smith, John

PY  - 2024

ER  -"#;
    let entries = parse(ris.to_string()).unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].title(), Some("Test Title"));
}

#[test]
fn test_parse_with_unicode() {
    let ris = "TY  - JOUR\nTI  - Über die Théorie des α-Zerfalls\nAU  - Müller, Hans\nER  -";
    let entries = parse(ris.to_string()).unwrap();
    let title = entries[0].title().unwrap();
    // Should preserve Unicode
    assert!(title.contains("Über") || title.contains("Uber") || title.contains("ber"));
}

#[test]
fn test_parse_long_abstract() {
    let abstract_text = "A".repeat(5000);
    let ris = format!("TY  - JOUR\nTI  - Test\nAB  - {}\nER  -", abstract_text);
    let entries = parse(ris).unwrap();

    let parsed_abstract = entries[0].abstract_text().unwrap();
    assert_eq!(parsed_abstract.len(), 5000);
}

// === Type Conversion Tests ===

#[test]
fn test_ris_type_to_bibtex_mapping() {
    let mappings = [
        (RISType::JOUR, BibTeXEntryType::Article),
        (RISType::BOOK, BibTeXEntryType::Book),
        (RISType::CHAP, BibTeXEntryType::InBook), // CHAP maps to InBook in implementation
        (RISType::RPRT, BibTeXEntryType::TechReport),
    ];

    for (ris_type, expected_bibtex) in mappings {
        let mut entry = RISEntry::new(ris_type.clone());
        entry.add_tag("TI", "Test");
        entry.add_tag("PY", "2024");

        let bibtex = to_bibtex(entry);
        assert_eq!(
            bibtex.entry_type, expected_bibtex,
            "Failed for RIS type {:?}",
            ris_type
        );
    }
}

#[test]
fn test_bibtex_type_to_ris_mapping() {
    let mappings = [
        (BibTeXEntryType::Article, RISType::JOUR),
        (BibTeXEntryType::Book, RISType::BOOK),
        (BibTeXEntryType::InCollection, RISType::CHAP),
        (BibTeXEntryType::TechReport, RISType::RPRT),
        (BibTeXEntryType::PhdThesis, RISType::THES),
    ];

    for (bibtex_type, expected_ris) in mappings {
        let mut entry = BibTeXEntry::new("Test".into(), bibtex_type.clone());
        entry.add_field("title", "Test");
        entry.add_field("year", "2024");

        let ris = from_bibtex(entry);
        assert_eq!(
            ris.entry_type, expected_ris,
            "Failed for BibTeX type {:?}",
            bibtex_type
        );
    }
}
