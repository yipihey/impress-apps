//! RIS to BibTeX conversion and vice versa

use crate::bibtex::{BibTeXEntry, BibTeXEntryType};
use crate::identifiers::generate_cite_key;

use super::entry::{RISEntry, RISType};

/// Convert RIS entry to BibTeX entry
pub fn to_bibtex(entry: RISEntry) -> BibTeXEntry {
    let entry_type = ris_to_bibtex_type(&entry.entry_type);

    // Generate cite key from metadata
    let author = entry.authors().first().map(|s| s.to_string());
    let year = entry.year().map(|s| s.to_string());
    let title = entry.title().map(|s| s.to_string());
    let cite_key = generate_cite_key(author, year, title.clone());

    let mut bibtex = BibTeXEntry::new(cite_key, entry_type);

    // Map RIS tags to BibTeX fields
    if let Some(title) = entry.title() {
        bibtex.add_field("title", title);
    }

    // Authors: convert from "Last, First" to "First Last and ..."
    let authors = entry.authors();
    if !authors.is_empty() {
        let bibtex_authors = authors
            .into_iter()
            .map(ris_author_to_bibtex)
            .collect::<Vec<_>>()
            .join(" and ");
        bibtex.add_field("author", bibtex_authors);
    }

    if let Some(year) = entry.year() {
        bibtex.add_field("year", year);
    }

    if let Some(journal) = entry.journal() {
        bibtex.add_field("journal", journal);
    }

    if let Some(doi) = entry.doi() {
        bibtex.add_field("doi", doi);
    }

    if let Some(abstract_text) = entry.abstract_text() {
        bibtex.add_field("abstract", abstract_text);
    }

    // Additional fields
    if let Some(volume) = entry.get_tag("VL") {
        bibtex.add_field("volume", volume);
    }
    if let Some(issue) = entry.get_tag("IS") {
        bibtex.add_field("number", issue);
    }
    if let Some(pages) = entry.get_tag("SP") {
        let end_page = entry.get_tag("EP");
        if let Some(ep) = end_page {
            bibtex.add_field("pages", format!("{}--{}", pages, ep));
        } else {
            bibtex.add_field("pages", pages);
        }
    }
    if let Some(publisher) = entry.get_tag("PB") {
        bibtex.add_field("publisher", publisher);
    }
    if let Some(url) = entry.get_tag("UR") {
        bibtex.add_field("url", url);
    }
    if let Some(isbn) = entry.get_tag("SN") {
        bibtex.add_field("isbn", isbn);
    }

    // Keywords
    let keywords: Vec<&str> = entry.get_all_tags("KW");
    if !keywords.is_empty() {
        bibtex.add_field("keywords", keywords.join(", "));
    }

    bibtex
}

/// Convert BibTeX entry to RIS entry
pub fn from_bibtex(entry: BibTeXEntry) -> RISEntry {
    let ris_type = bibtex_to_ris_type(&entry.entry_type);
    let mut ris = RISEntry::new(ris_type);

    // Title
    if let Some(title) = entry.title() {
        ris.add_tag("TI", title);
    }

    // Authors: convert from "First Last and ..." to separate AU tags
    if let Some(authors) = entry.author() {
        for author in authors.split(" and ") {
            let ris_author = bibtex_author_to_ris(author.trim());
            ris.add_tag("AU", ris_author);
        }
    }

    // Year
    if let Some(year) = entry.year() {
        ris.add_tag("PY", year);
    }

    // Journal
    if let Some(journal) = entry.journal() {
        ris.add_tag("JO", journal);
    }

    // DOI
    if let Some(doi) = entry.doi() {
        ris.add_tag("DO", doi);
    }

    // Abstract
    if let Some(abstract_text) = entry.abstract_text() {
        ris.add_tag("AB", abstract_text);
    }

    // Additional fields
    if let Some(volume) = entry.get_field("volume") {
        ris.add_tag("VL", volume);
    }
    if let Some(number) = entry.get_field("number") {
        ris.add_tag("IS", number);
    }
    if let Some(pages) = entry.get_field("pages") {
        // Split pages on -- or -
        let parts: Vec<&str> = pages.split("--").flat_map(|s| s.split('-')).collect();
        if let Some(sp) = parts.first() {
            ris.add_tag("SP", sp.trim());
        }
        if let Some(ep) = parts.get(1) {
            ris.add_tag("EP", ep.trim());
        }
    }
    if let Some(publisher) = entry.get_field("publisher") {
        ris.add_tag("PB", publisher);
    }
    if let Some(url) = entry.get_field("url") {
        ris.add_tag("UR", url);
    }
    if let Some(isbn) = entry.get_field("isbn") {
        ris.add_tag("SN", isbn);
    }

    // Keywords
    if let Some(keywords) = entry.get_field("keywords") {
        for kw in keywords.split(',') {
            ris.add_tag("KW", kw.trim());
        }
    }

    ris
}

/// Convert RIS type to BibTeX entry type
fn ris_to_bibtex_type(ris_type: &RISType) -> BibTeXEntryType {
    match ris_type {
        RISType::JOUR | RISType::EJOUR | RISType::MGZN => BibTeXEntryType::Article,
        RISType::BOOK | RISType::EBOOK | RISType::EDBOOK => BibTeXEntryType::Book,
        RISType::CHAP | RISType::ECHAP => BibTeXEntryType::InBook,
        RISType::CONF | RISType::CPAPER => BibTeXEntryType::InProceedings,
        RISType::THES => BibTeXEntryType::PhdThesis,
        RISType::RPRT => BibTeXEntryType::TechReport,
        RISType::UNPB => BibTeXEntryType::Unpublished,
        RISType::COMP => BibTeXEntryType::Software,
        RISType::DATA => BibTeXEntryType::Dataset,
        RISType::ELEC | RISType::BLOG => BibTeXEntryType::Online,
        _ => BibTeXEntryType::Misc,
    }
}

/// Convert BibTeX entry type to RIS type
fn bibtex_to_ris_type(bibtex_type: &BibTeXEntryType) -> RISType {
    match bibtex_type {
        BibTeXEntryType::Article => RISType::JOUR,
        BibTeXEntryType::Book => RISType::BOOK,
        BibTeXEntryType::Booklet => RISType::PAMP,
        BibTeXEntryType::InBook | BibTeXEntryType::InCollection => RISType::CHAP,
        BibTeXEntryType::InProceedings => RISType::CPAPER,
        BibTeXEntryType::Manual => RISType::GEN,
        BibTeXEntryType::MastersThesis | BibTeXEntryType::PhdThesis => RISType::THES,
        BibTeXEntryType::Proceedings => RISType::CONF,
        BibTeXEntryType::TechReport => RISType::RPRT,
        BibTeXEntryType::Unpublished => RISType::UNPB,
        BibTeXEntryType::Online => RISType::ELEC,
        BibTeXEntryType::Software => RISType::COMP,
        BibTeXEntryType::Dataset => RISType::DATA,
        _ => RISType::GEN,
    }
}

/// Convert RIS author format "Last, First" to BibTeX format "First Last"
fn ris_author_to_bibtex(author: &str) -> String {
    if let Some(comma_pos) = author.find(',') {
        let last = author[..comma_pos].trim();
        let first = author[comma_pos + 1..].trim();
        format!("{} {}", first, last)
    } else {
        author.to_string()
    }
}

/// Convert BibTeX author format "First Last" to RIS format "Last, First"
fn bibtex_author_to_ris(author: &str) -> String {
    let parts: Vec<&str> = author.split_whitespace().collect();
    if parts.len() >= 2 {
        let last = parts.last().unwrap();
        let first = parts[..parts.len() - 1].join(" ");
        format!("{}, {}", last, first)
    } else {
        author.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ris_to_bibtex() {
        let mut ris = RISEntry::new(RISType::JOUR);
        ris.add_tag("TI", "A Great Paper");
        ris.add_tag("AU", "Smith, John");
        ris.add_tag("AU", "Doe, Jane");
        ris.add_tag("PY", "2024");
        ris.add_tag("JO", "Nature");
        ris.add_tag("DO", "10.1234/test");

        let bibtex = to_bibtex(ris);
        assert_eq!(bibtex.entry_type, BibTeXEntryType::Article);
        assert_eq!(bibtex.title(), Some("A Great Paper"));
        assert_eq!(bibtex.author(), Some("John Smith and Jane Doe"));
        assert_eq!(bibtex.year(), Some("2024"));
        assert_eq!(bibtex.journal(), Some("Nature"));
        assert_eq!(bibtex.doi(), Some("10.1234/test"));
    }

    #[test]
    fn test_bibtex_to_ris() {
        let mut bibtex = BibTeXEntry::new("Smith2024".to_string(), BibTeXEntryType::Article);
        bibtex.add_field("title", "A Great Paper");
        bibtex.add_field("author", "John Smith and Jane Doe");
        bibtex.add_field("year", "2024");
        bibtex.add_field("journal", "Nature");

        let ris = from_bibtex(bibtex);
        assert_eq!(ris.entry_type, RISType::JOUR);
        assert_eq!(ris.title(), Some("A Great Paper"));
        assert_eq!(ris.authors(), vec!["Smith, John", "Doe, Jane"]);
        assert_eq!(ris.year(), Some("2024"));
        assert_eq!(ris.journal(), Some("Nature"));
    }

    #[test]
    fn test_author_conversion() {
        assert_eq!(ris_author_to_bibtex("Smith, John"), "John Smith");
        assert_eq!(
            ris_author_to_bibtex("van der Berg, Jan"),
            "Jan van der Berg"
        );
        assert_eq!(bibtex_author_to_ris("John Smith"), "Smith, John");
    }
}
