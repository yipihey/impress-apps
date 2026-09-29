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
    if let Some(sn) = entry.get_tag("SN") {
        // SN is ISBN for books, ISSN for journals/serials
        match entry.entry_type {
            RISType::BOOK | RISType::CHAP | RISType::EBOOK | RISType::ECHAP | RISType::EDBOOK => {
                bibtex.add_field("isbn", sn);
            }
            _ => {
                bibtex.add_field("issn", sn);
            }
        }
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
        // Try splitting on -- first (standard BibTeX); fall back to single -
        let parts: Vec<&str> = if pages.contains("--") {
            pages.split("--").collect()
        } else {
            pages.split('-').collect()
        };
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

/// Convert a BibTeX entry using imbib's legacy automation export mapping.
///
/// This deliberately preserves the tag names, tag order, and author strings
/// emitted by `RISBibTeXConverter.toRIS` in PublicationManagerCore. The
/// general-purpose `from_bibtex` converter remains unchanged for existing
/// Rust/UniFFI callers; the generated `export-ris` service uses this adapter
/// so `/api/export?format=ris` and the generated verb return the same bytes.
pub fn from_bibtex_legacy_export(entry: BibTeXEntry) -> RISEntry {
    let mut ris = RISEntry::new(legacy_ris_type(&entry.entry_type));

    if let Some(authors) = entry.author() {
        for author in authors.split(" and ") {
            let author = author.trim();
            if !author.is_empty() {
                ris.add_tag("AU", author);
            }
        }
    }
    if let Some(editors) = entry.get_field("editor") {
        for editor in editors.split(" and ") {
            let editor = editor.trim();
            if !editor.is_empty() {
                ris.add_tag("A2", editor);
            }
        }
    }
    if let Some(title) = entry.title() {
        ris.add_tag("TI", title);
    }
    if let Some(year) = entry.year() {
        ris.add_tag("PY", year);
    }
    if let Some(journal) = entry.journal() {
        ris.add_tag("JF", journal);
        ris.add_tag("T2", journal);
    } else if let Some(booktitle) = entry.get_field("booktitle") {
        ris.add_tag("T2", booktitle);
    }
    if let Some(volume) = entry.get_field("volume") {
        ris.add_tag("VL", volume);
    }
    if let Some(number) = entry.get_field("number") {
        ris.add_tag("IS", number);
    }
    if let Some(pages) = entry.get_field("pages") {
        let parts: Vec<&str> = pages.split(['-', '–', '—']).collect();
        if parts.len() >= 2 {
            ris.add_tag("SP", parts[0].trim());
            ris.add_tag("EP", parts[1].trim());
        } else if let Some(page) = parts.first() {
            ris.add_tag("SP", page.trim());
        }
    }
    if let Some(doi) = entry.doi() {
        ris.add_tag("DO", doi);
    }
    if let Some(abstract_text) = entry.abstract_text() {
        ris.add_tag("AB", abstract_text);
    }
    if let Some(keywords) = entry.get_field("keywords") {
        for keyword in keywords
            .split([',', ';'])
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            ris.add_tag("KW", keyword);
        }
    }
    if let Some(url) = entry.get_field("url") {
        ris.add_tag("UR", url);
    }
    if let Some(publisher) = entry.get_field("publisher") {
        ris.add_tag("PB", publisher);
    }
    if let Some(address) = entry.get_field("address") {
        ris.add_tag("CY", address);
    }
    if let Some(serial) = entry.get_field("issn").or_else(|| entry.get_field("isbn")) {
        ris.add_tag("SN", serial);
    }
    if let Some(note) = entry.get_field("note") {
        ris.add_tag("N1", note);
    }
    if let Some(series) = entry.get_field("series") {
        ris.add_tag("T3", series);
    }
    if let Some(edition) = entry.get_field("edition") {
        ris.add_tag("ET", edition);
    }
    if let Some(language) = entry.get_field("language") {
        ris.add_tag("LA", language);
    }
    ris.add_tag("ID", entry.cite_key);
    ris
}

fn legacy_ris_type(entry_type: &BibTeXEntryType) -> RISType {
    match entry_type {
        BibTeXEntryType::Article => RISType::JOUR,
        BibTeXEntryType::Book => RISType::BOOK,
        BibTeXEntryType::InBook | BibTeXEntryType::InCollection => RISType::CHAP,
        BibTeXEntryType::InProceedings | BibTeXEntryType::Proceedings => RISType::CONF,
        BibTeXEntryType::PhdThesis | BibTeXEntryType::MastersThesis => RISType::THES,
        BibTeXEntryType::TechReport => RISType::RPRT,
        BibTeXEntryType::Unpublished => RISType::UNPB,
        BibTeXEntryType::Software => RISType::COMP,
        BibTeXEntryType::Online => RISType::ELEC,
        _ => RISType::GEN,
    }
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
    fn legacy_export_mapping_matches_publication_manager_core_tag_order() {
        let mut bibtex = BibTeXEntry::new("G3RIS2026".to_string(), BibTeXEntryType::Article);
        for (key, value) in [
            ("author", "Doe, Jane"),
            ("editor", "Roe, John"),
            ("title", "RIS parity paper"),
            ("year", "2026"),
            ("journal", "Research Journal"),
            ("volume", "12"),
            ("number", "3"),
            ("pages", "100--110"),
            ("doi", "10.5555/g3-ris"),
            ("abstract", "Representative abstract"),
            ("keywords", "alpha, beta"),
            ("url", "https://example.org/g3-ris"),
            ("publisher", "Example Press"),
            ("address", "Boston"),
            ("issn", "1234-5678"),
            ("note", "G3 export note"),
            ("series", "Research Series"),
            ("edition", "2"),
            ("language", "en"),
        ] {
            bibtex.add_field(key, value);
        }

        let ris = from_bibtex_legacy_export(bibtex);
        assert_eq!(
            crate::ris::format_entry(ris),
            concat!(
                "TY  - JOUR\nAU  - Doe, Jane\nA2  - Roe, John\nTI  - RIS parity paper\n",
                "PY  - 2026\nJF  - Research Journal\nT2  - Research Journal\n",
                "VL  - 12\nIS  - 3\nSP  - 100\nEP  - \nDO  - 10.5555/g3-ris\n",
                "AB  - Representative abstract\nKW  - alpha\nKW  - beta\n",
                "UR  - https://example.org/g3-ris\nPB  - Example Press\nCY  - Boston\n",
                "SN  - 1234-5678\nN1  - G3 export note\nT3  - Research Series\n",
                "ET  - 2\nLA  - en\nID  - G3RIS2026\nER  - "
            )
        );
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
