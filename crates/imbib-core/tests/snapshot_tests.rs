//! Snapshot tests for format output
//!
//! Uses insta crate to detect unexpected output changes

use imbib_core::bibtex::{format_entry, BibTeXEntry, BibTeXEntryType};
use imbib_core::ris::{format_entry as format_ris, RISEntry, RISType};
use insta::assert_snapshot;

// === BibTeX Formatting ===

#[test]
fn test_bibtex_article_format() {
    let mut entry = BibTeXEntry::new("Einstein1905".into(), BibTeXEntryType::Article);
    entry.add_field("author", "Albert Einstein");
    entry.add_field("title", "On the Electrodynamics of Moving Bodies");
    entry.add_field("journal", "Annalen der Physik");
    entry.add_field("year", "1905");
    entry.add_field("volume", "17");
    entry.add_field("pages", "891--921");

    assert_snapshot!(format_entry(entry));
}

#[test]
fn test_bibtex_book_format() {
    let mut entry = BibTeXEntry::new("Knuth1997".into(), BibTeXEntryType::Book);
    entry.add_field("author", "Donald E. Knuth");
    entry.add_field("title", "The Art of Computer Programming");
    entry.add_field("publisher", "Addison-Wesley");
    entry.add_field("year", "1997");
    entry.add_field("edition", "3rd");

    assert_snapshot!(format_entry(entry));
}

#[test]
fn test_bibtex_inproceedings_format() {
    let mut entry = BibTeXEntry::new("Turing1950".into(), BibTeXEntryType::InProceedings);
    entry.add_field("author", "Alan M. Turing");
    entry.add_field("title", "Computing Machinery and Intelligence");
    entry.add_field("booktitle", "Mind");
    entry.add_field("year", "1950");
    entry.add_field("pages", "433--460");

    assert_snapshot!(format_entry(entry));
}

#[test]
fn test_bibtex_phdthesis_format() {
    let mut entry = BibTeXEntry::new("Student2024".into(), BibTeXEntryType::PhdThesis);
    entry.add_field("author", "Jane Doe");
    entry.add_field("title", "Novel Approaches to Machine Learning");
    entry.add_field("school", "Stanford University");
    entry.add_field("year", "2024");

    assert_snapshot!(format_entry(entry));
}

#[test]
fn test_bibtex_misc_format() {
    let mut entry = BibTeXEntry::new("Website2024".into(), BibTeXEntryType::Misc);
    entry.add_field("author", "Open Source Project");
    entry.add_field("title", "Project Documentation");
    entry.add_field("url", "https://example.com/docs");
    entry.add_field("year", "2024");
    entry.add_field("note", "Accessed: 2024-01-15");

    assert_snapshot!(format_entry(entry));
}

#[test]
fn test_bibtex_with_multiple_authors() {
    let mut entry = BibTeXEntry::new("Team2024".into(), BibTeXEntryType::Article);
    entry.add_field(
        "author",
        "Smith, John and Doe, Jane and Wilson, Bob and Brown, Alice",
    );
    entry.add_field("title", "Collaborative Research Paper");
    entry.add_field("journal", "Science");
    entry.add_field("year", "2024");

    assert_snapshot!(format_entry(entry));
}

#[test]
fn test_bibtex_with_abstract() {
    let mut entry = BibTeXEntry::new("Paper2024".into(), BibTeXEntryType::Article);
    entry.add_field("author", "Author, A");
    entry.add_field("title", "Paper with Abstract");
    entry.add_field("journal", "Journal");
    entry.add_field("year", "2024");
    entry.add_field("abstract", "This is a detailed abstract that describes the paper content, methodology, and key findings. It spans multiple sentences to test formatting.");

    assert_snapshot!(format_entry(entry));
}

#[test]
fn test_bibtex_with_doi_and_url() {
    let mut entry = BibTeXEntry::new("Online2024".into(), BibTeXEntryType::Article);
    entry.add_field("author", "Digital, D");
    entry.add_field("title", "Online Paper");
    entry.add_field("journal", "Digital Journal");
    entry.add_field("year", "2024");
    entry.add_field("doi", "10.1234/test.2024.001");
    entry.add_field("url", "https://example.com/paper");

    assert_snapshot!(format_entry(entry));
}

// === RIS Formatting ===

#[test]
fn test_ris_journal_format() {
    let mut entry = RISEntry::new(RISType::JOUR);
    entry.add_tag("TI", "Test Article");
    entry.add_tag("AU", "Smith, John");
    entry.add_tag("AU", "Doe, Jane");
    entry.add_tag("PY", "2024");
    entry.add_tag("JF", "Nature");
    entry.add_tag("VL", "123");
    entry.add_tag("SP", "456");
    entry.add_tag("EP", "789");
    entry.add_tag("DO", "10.1038/test");

    assert_snapshot!(format_ris(entry));
}

#[test]
fn test_ris_book_format() {
    let mut entry = RISEntry::new(RISType::BOOK);
    entry.add_tag("TI", "Important Book");
    entry.add_tag("AU", "Author, A");
    entry.add_tag("PY", "2020");
    entry.add_tag("PB", "Publisher Inc");
    entry.add_tag("CY", "New York");
    entry.add_tag("SN", "978-0-123-45678-9");

    assert_snapshot!(format_ris(entry));
}

#[test]
fn test_ris_conference_format() {
    let mut entry = RISEntry::new(RISType::CONF);
    entry.add_tag("TI", "Conference Paper");
    entry.add_tag("AU", "Presenter, P");
    entry.add_tag("PY", "2024");
    entry.add_tag("T2", "International Conference on Testing");
    entry.add_tag("CY", "San Francisco, CA");
    entry.add_tag("SP", "1");
    entry.add_tag("EP", "10");

    assert_snapshot!(format_ris(entry));
}

#[test]
fn test_ris_thesis_format() {
    let mut entry = RISEntry::new(RISType::THES);
    entry.add_tag("TI", "Doctoral Dissertation");
    entry.add_tag("AU", "Graduate, G");
    entry.add_tag("PY", "2024");
    entry.add_tag("PB", "University of Testing");
    entry.add_tag("M3", "Ph.D. thesis");

    assert_snapshot!(format_ris(entry));
}

#[test]
fn test_ris_with_abstract() {
    let mut entry = RISEntry::new(RISType::JOUR);
    entry.add_tag("TI", "Paper with Abstract");
    entry.add_tag("AU", "Researcher, R");
    entry.add_tag("PY", "2024");
    entry.add_tag("AB", "This is a long abstract that describes the paper in detail. It includes the motivation, methodology, results, and conclusions of the research work.");

    assert_snapshot!(format_ris(entry));
}

#[test]
fn test_ris_with_keywords() {
    let mut entry = RISEntry::new(RISType::JOUR);
    entry.add_tag("TI", "Tagged Paper");
    entry.add_tag("AU", "Tagger, T");
    entry.add_tag("PY", "2024");
    entry.add_tag("KW", "machine learning");
    entry.add_tag("KW", "deep learning");
    entry.add_tag("KW", "neural networks");
    entry.add_tag("KW", "artificial intelligence");

    assert_snapshot!(format_ris(entry));
}

#[test]
fn test_ris_with_urls() {
    let mut entry = RISEntry::new(RISType::JOUR);
    entry.add_tag("TI", "Online Paper");
    entry.add_tag("AU", "Web, W");
    entry.add_tag("PY", "2024");
    entry.add_tag("UR", "https://example.com/paper");
    entry.add_tag("L1", "https://example.com/paper.pdf");

    assert_snapshot!(format_ris(entry));
}

// === Edge Cases ===

#[test]
fn test_bibtex_minimal_entry() {
    let mut entry = BibTeXEntry::new("Minimal".into(), BibTeXEntryType::Misc);
    entry.add_field("title", "Minimal Entry");

    assert_snapshot!(format_entry(entry));
}

#[test]
fn test_ris_minimal_entry() {
    let mut entry = RISEntry::new(RISType::GEN);
    entry.add_tag("TI", "Minimal Entry");

    assert_snapshot!(format_ris(entry));
}

#[test]
fn test_bibtex_with_special_characters() {
    let mut entry = BibTeXEntry::new("Special".into(), BibTeXEntryType::Article);
    entry.add_field("author", "O'Brien, John & Smith, Jane");
    entry.add_field("title", "Cost: $100 & Benefits > Costs");
    entry.add_field("journal", "Journal of Testing & Validation");
    entry.add_field("year", "2024");

    assert_snapshot!(format_entry(entry));
}

#[test]
fn test_bibtex_with_latex() {
    let mut entry = BibTeXEntry::new("Latex".into(), BibTeXEntryType::Article);
    entry.add_field("author", "M{\\\"u}ller, Hans");
    entry.add_field("title", "The {LaTeX} Guide: From $\\alpha$ to $\\omega$");
    entry.add_field("journal", "Journal of {TeX}nology");
    entry.add_field("year", "2024");

    assert_snapshot!(format_entry(entry));
}

#[test]
fn test_bibtex_with_unicode() {
    let mut entry = BibTeXEntry::new("Unicode".into(), BibTeXEntryType::Article);
    entry.add_field("author", "François Müller and José García");
    entry.add_field("title", "Über die Théorie des α-Zerfalls");
    entry.add_field("journal", "日本語ジャーナル");
    entry.add_field("year", "2024");

    assert_snapshot!(format_entry(entry));
}

// === Consistency Tests ===

#[test]
fn test_bibtex_field_order_consistency() {
    // Same entry created twice should produce identical output
    let create_entry = || {
        let mut entry = BibTeXEntry::new("Test".into(), BibTeXEntryType::Article);
        entry.add_field("title", "Test");
        entry.add_field("author", "Author");
        entry.add_field("year", "2024");
        entry.add_field("journal", "Journal");
        format_entry(entry)
    };

    let output1 = create_entry();
    let output2 = create_entry();
    assert_eq!(output1, output2);
}

#[test]
fn test_ris_field_order_consistency() {
    let create_entry = || {
        let mut entry = RISEntry::new(RISType::JOUR);
        entry.add_tag("TI", "Test");
        entry.add_tag("AU", "Author");
        entry.add_tag("PY", "2024");
        format_ris(entry)
    };

    let output1 = create_entry();
    let output2 = create_entry();
    assert_eq!(output1, output2);
}
