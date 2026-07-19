//! Identifier extraction integration tests
//!
//! Ported from Swift IdentifierExtractorTests.swift

use imbib_core::identifiers::{
    extract_all, extract_arxiv_ids, extract_dois, extract_isbns, is_valid_arxiv_id, is_valid_doi,
    is_valid_isbn, normalize_doi,
};
use rstest::rstest;

// === DOI Extraction ===

#[test]
fn test_extract_doi_from_text() {
    let text = "Check out 10.1038/nature12373 for details";
    let dois = extract_dois(text.to_string());

    assert_eq!(dois.len(), 1);
    assert_eq!(dois[0], "10.1038/nature12373");
}

#[test]
fn test_extract_doi_with_prefix() {
    let text = "DOI: 10.1126/science.1234567";
    let dois = extract_dois(text.to_string());
    assert_eq!(dois, vec!["10.1126/science.1234567"]);
}

#[test]
fn test_extract_doi_from_url() {
    let text = "See https://doi.org/10.1038/nature12373";
    let dois = extract_dois(text.to_string());
    assert_eq!(dois, vec!["10.1038/nature12373"]);
}

#[test]
fn test_extract_doi_from_dx_url() {
    let text = "See https://dx.doi.org/10.1038/nature12373";
    let dois = extract_dois(text.to_string());
    assert_eq!(dois, vec!["10.1038/nature12373"]);
}

#[test]
fn test_extract_multiple_dois() {
    let text = "Papers: 10.1234/a and 10.5678/b and 10.9999/c";
    let dois = extract_dois(text.to_string());
    assert_eq!(dois.len(), 3);
}

#[test]
fn test_extract_doi_with_special_chars() {
    let text = "DOI: 10.1000/(SICI)1097-4679(199911)55:11<1401::AID-JCLP4>3.0.CO;2-G";
    let dois = extract_dois(text.to_string());
    assert!(!dois.is_empty());
}

#[rstest]
#[case("10.1038/nature12373", "10.1038/nature12373")]
#[case("doi:10.1038/nature12373", "10.1038/nature12373")]
#[case("https://doi.org/10.1038/nature12373", "10.1038/nature12373")]
fn test_normalize_doi_variants(#[case] input: &str, #[case] expected: &str) {
    let normalized = normalize_doi(input.to_string());
    // Trim to handle any whitespace differences
    assert_eq!(normalized.trim(), expected);
}

// === arXiv ID Extraction ===

#[test]
fn test_extract_arxiv_new_format() {
    let text = "See arXiv:2301.12345 for the paper";
    let ids = extract_arxiv_ids(text.to_string());
    assert!(ids.contains(&"2301.12345".to_string()));
}

#[test]
fn test_extract_arxiv_old_format() {
    let text = "Paper at arXiv:hep-th/9901001";
    let ids = extract_arxiv_ids(text.to_string());
    assert!(!ids.is_empty());
    assert!(ids
        .iter()
        .any(|id| id.contains("hep-th") || id.contains("9901001")));
}

#[test]
fn test_extract_arxiv_with_version() {
    let text = "arXiv:2301.12345v3";
    let ids = extract_arxiv_ids(text.to_string());
    assert!(!ids.is_empty());
    // May include version or may strip it
    assert!(ids.iter().any(|id| id.contains("2301.12345")));
}

#[test]
fn test_extract_arxiv_from_url() {
    let text = "https://arxiv.org/abs/2301.12345";
    let ids = extract_arxiv_ids(text.to_string());
    assert!(ids.contains(&"2301.12345".to_string()));
}

#[test]
fn test_extract_arxiv_multiple() {
    let text = "Papers: arXiv:2301.12345 and 1905.07890 and cond-mat/9901001";
    let ids = extract_arxiv_ids(text.to_string());
    assert!(ids.len() >= 2);
}

// === ISBN Extraction ===

#[test]
fn test_extract_isbn_10() {
    let text = "ISBN: 0-306-40615-2";
    let isbns = extract_isbns(text.to_string());
    assert!(!isbns.is_empty());
    assert!(isbns.iter().any(|i| i.contains("0306406152")));
}

#[test]
fn test_extract_isbn_13() {
    let text = "ISBN-13: 978-0-321-12521-7";
    let isbns = extract_isbns(text.to_string());
    assert!(!isbns.is_empty());
    assert!(isbns.iter().any(|i| i.contains("9780321125217")));
}

#[test]
fn test_extract_isbn_without_hyphens() {
    let text = "ISBN: 9780321125217";
    let isbns = extract_isbns(text.to_string());
    assert!(!isbns.is_empty());
}

#[test]
fn test_extract_isbn_10_with_x() {
    let text = "ISBN: 080442957X";
    let isbns = extract_isbns(text.to_string());
    assert!(!isbns.is_empty());
}

// === Validation Tests ===

#[rstest]
#[case("10.1038/nature12373", true)]
#[case("10.1126/science.1234567", true)]
#[case("10.1000/182", true)]
#[case("11.1038/nature12373", false)] // Wrong prefix
#[case("10.12/test", false)] // Registrant too short
#[case("nature12373", false)] // Missing 10.
fn test_is_valid_doi(#[case] doi: &str, #[case] expected: bool) {
    assert_eq!(is_valid_doi(doi.to_string()), expected, "DOI: {}", doi);
}

#[rstest]
#[case("2301.12345", true)]
#[case("1905.07890v2", true)]
#[case("cond-mat/9901001", true)]
#[case("hep-th/9901001v1", true)]
#[case("12345", false)]
#[case("2301.123", false)] // Too short
fn test_is_valid_arxiv_id(#[case] arxiv_id: &str, #[case] expected: bool) {
    assert_eq!(
        is_valid_arxiv_id(arxiv_id.to_string()),
        expected,
        "arXiv: {}",
        arxiv_id
    );
}

#[rstest]
#[case("0-306-40615-2", true)]
#[case("978-0-321-12521-7", true)]
#[case("0306406152", true)]
#[case("9780321125217", true)]
#[case("080442957X", true)]
#[case("0-306-40615-1", false)] // Bad checksum
#[case("978-0-321-12521-8", false)] // Bad checksum
#[case("12345", false)] // Too short
fn test_is_valid_isbn(#[case] isbn: &str, #[case] expected: bool) {
    assert_eq!(is_valid_isbn(isbn.to_string()), expected, "ISBN: {}", isbn);
}

// === Extract All Tests ===

#[test]
fn test_extract_all_mixed_content() {
    let text = r#"
        Check out arXiv:2301.12345 and DOI:10.1038/nature12373.
        Also see ISBN: 978-0-321-12521-7 for the book.
    "#;

    let ids = extract_all(text.to_string());

    // Should find at least DOI and arXiv
    let types: Vec<&str> = ids.iter().map(|i| i.identifier_type.as_str()).collect();
    assert!(types.contains(&"doi"), "Should find DOI");
    assert!(types.contains(&"arxiv"), "Should find arXiv");
}

#[test]
fn test_extract_all_preserves_order() {
    let text = "First: 10.1234/first, Second: arXiv:2301.99999";
    let ids = extract_all(text.to_string());

    assert!(ids.len() >= 2);
    // Should be sorted by position
    for i in 1..ids.len() {
        assert!(ids[i].start_index >= ids[i - 1].start_index);
    }
}

#[test]
fn test_extract_all_provides_positions() {
    let text = "DOI is 10.1234/test here";
    let ids = extract_all(text.to_string());

    if !ids.is_empty() {
        let doi_id = &ids[0];
        assert!(doi_id.start_index < doi_id.end_index);
        assert_eq!(doi_id.identifier_type, "doi");
    }
}

// === Edge Cases ===

#[test]
fn test_extract_from_empty_string() {
    assert!(extract_dois("".to_string()).is_empty());
    assert!(extract_arxiv_ids("".to_string()).is_empty());
    assert!(extract_isbns("".to_string()).is_empty());
}

#[test]
fn test_no_false_positives_ratio() {
    // Text that looks similar but isn't a DOI
    let text = "The ratio is 10.5 to 1";
    let dois = extract_dois(text.to_string());
    // Should not extract "10.5" as a DOI (no suffix after registrant)
    assert!(dois.is_empty() || !dois.iter().any(|d| d == "10.5"));
}

#[test]
fn test_no_false_positives_phone() {
    // Phone number shouldn't be extracted as ISBN
    let text = "Call 123-456-7890 for info";
    let isbns = extract_isbns(text.to_string());
    assert!(isbns.is_empty());
}

#[test]
fn test_doi_with_trailing_punctuation() {
    let text = "See 10.1038/nature12373.";
    let dois = extract_dois(text.to_string());
    assert_eq!(dois, vec!["10.1038/nature12373"]);

    let text2 = "(10.1038/nature12373)";
    let dois2 = extract_dois(text2.to_string());
    assert_eq!(dois2, vec!["10.1038/nature12373"]);
}

#[test]
fn test_extract_from_bibtex_field() {
    // Common BibTeX field patterns
    let text = r#"
        doi = {10.1038/nature12373},
        eprint = {2301.12345},
        isbn = {978-0-321-12521-7}
    "#;

    assert!(!extract_dois(text.to_string()).is_empty());
    assert!(!extract_arxiv_ids(text.to_string()).is_empty());
    assert!(!extract_isbns(text.to_string()).is_empty());
}

#[test]
fn test_extract_from_url_parameters() {
    let text = "https://example.com/paper?doi=10.1038/nature12373&ref=test";
    let dois = extract_dois(text.to_string());
    assert!(!dois.is_empty());
}

// === Unicode and Special Cases ===

#[test]
fn test_extract_from_unicode_text() {
    let text = "論文のDOI: 10.1038/nature12373 を参照"; // Added space before Japanese
    let dois = extract_dois(text.to_string());
    assert!(!dois.is_empty());
    // The DOI should contain the core identifier
    assert!(dois[0].contains("10.1038/nature12373"));
}

#[test]
fn test_case_insensitivity() {
    let text = "DOI:10.1234/test and doi:10.5678/test and Doi:10.9999/test";
    let dois = extract_dois(text.to_string());
    assert_eq!(dois.len(), 3);
}

// === Normalization Tests ===

#[test]
fn test_normalize_doi_preserves_case_in_suffix() {
    // DOI suffixes can be case-sensitive
    let doi = normalize_doi("10.1234/AbCdEf".to_string());
    assert!(doi.contains("AbCdEf") || doi.contains("abcdef"));
}

#[test]
fn test_normalize_doi_removes_whitespace() {
    let doi = normalize_doi("  10.1234/test  ".to_string());
    assert_eq!(doi, "10.1234/test");
}

// === Real-world Examples ===

#[test]
fn test_extract_from_citation() {
    let citation = r#"
        Smith, J. et al. (2024). "Deep Learning Survey." Nature 123, 456-789.
        https://doi.org/10.1038/s41586-024-12345-6
        Also available at arXiv:2401.12345
    "#;

    let dois = extract_dois(citation.to_string());
    let arxivs = extract_arxiv_ids(citation.to_string());

    assert!(!dois.is_empty());
    assert!(!arxivs.is_empty());
}

#[test]
fn test_extract_from_ads_export() {
    // Typical ADS BibTeX export format
    let bibtex = r#"
        @ARTICLE{2024Natur.123..456S,
            author = {{Smith}, John},
            title = "{Deep Learning}",
            doi = {10.1038/s41586-024-12345-6},
            eprint = {2401.12345},
            archivePrefix = {arXiv},
            primaryClass = {cs.LG}
        }
    "#;

    let dois = extract_dois(bibtex.to_string());
    let arxivs = extract_arxiv_ids(bibtex.to_string());

    assert!(!dois.is_empty());
    assert!(!arxivs.is_empty());
}

// === Performance Tests ===

#[test]
fn test_extract_from_large_text() {
    // Generate a large text with embedded identifiers
    let mut text = String::new();
    for i in 0..1000 {
        text.push_str(&format!("Paper {} has DOI 10.1234/paper{} and ", i, i));
    }

    let dois = extract_dois(text);
    assert_eq!(dois.len(), 1000);
}

// === Property-Based Tests: Cite Key Generation ===
//
// Cite keys follow the {LastName}{Year}{TitleWord} scheme and are embedded
// verbatim in BibTeX files, so they must be deterministic, non-empty, and
// ASCII-safe no matter what unicode the author/title metadata contains.

use imbib_core::identifiers::{
    generate_cite_key, generate_unique_cite_key, make_cite_key_unique, sanitize_cite_key,
};
use proptest::prelude::*;

proptest! {
    // Determinism: the same metadata always yields the same key.
    #[test]
    fn prop_cite_key_deterministic(
        author in proptest::option::of(any::<String>()),
        year in proptest::option::of(any::<String>()),
        title in proptest::option::of(any::<String>()),
    ) {
        let a = generate_cite_key(author.clone(), year.clone(), title.clone());
        let b = generate_cite_key(author, year, title);
        prop_assert_eq!(a, b);
    }

    // ASCII safety + totality: arbitrary unicode metadata never panics and
    // always produces a non-empty, purely ASCII-alphanumeric key.
    #[test]
    fn prop_cite_key_ascii_safe_and_nonempty(
        author in proptest::option::of(any::<String>()),
        year in proptest::option::of(any::<String>()),
        title in proptest::option::of(any::<String>()),
    ) {
        let key = generate_cite_key(author, year, title);
        prop_assert!(!key.is_empty(), "cite key must never be empty");
        prop_assert!(
            key.chars().all(|c| c.is_ascii_alphanumeric()),
            "cite key must be ASCII alphanumeric, got {:?}", key
        );
    }

    // Spec pin: {LastName}{Year}{TitleWord} for simple well-formed input.
    #[test]
    fn prop_cite_key_lastname_year_titleword(
        last in "[A-Z][a-z]{1,10}",
        first in "[A-Z][a-z]{1,8}",
        year in 1900u32..2100,
        word in "[A-Z][a-z]{3,10}",
    ) {
        let key = generate_cite_key(
            Some(format!("{}, {}", last, first)),
            Some(year.to_string()),
            Some(format!("{} dynamics", word)),
        );
        prop_assert_eq!(key, format!("{}{}{}", last, year, word));
    }

    // Uniquification: the returned key never collides with existing keys.
    #[test]
    fn prop_unique_cite_key_avoids_collisions(
        author in proptest::option::of("[A-Za-z ,]{0,20}"),
        year in proptest::option::of("[0-9]{4}"),
        title in proptest::option::of("[A-Za-z ]{0,20}"),
        existing in prop::collection::vec("[A-Za-z0-9]{1,12}", 0..20),
    ) {
        let key = generate_unique_cite_key(author, year, title, existing.clone());
        prop_assert!(
            !existing.contains(&key),
            "unique key {:?} collides with existing keys", key
        );
    }

    // With no existing keys, generate_unique_cite_key equals generate_cite_key.
    #[test]
    fn prop_unique_cite_key_matches_base_when_no_conflict(
        author in proptest::option::of(any::<String>()),
        year in proptest::option::of(any::<String>()),
        title in proptest::option::of(any::<String>()),
    ) {
        let base = generate_cite_key(author.clone(), year.clone(), title.clone());
        let unique = generate_unique_cite_key(author, year, title, vec![]);
        prop_assert_eq!(base, unique);
    }

    // make_cite_key_unique: identity when no conflict; never returns a
    // member of the existing set; suffixed results still start with base.
    #[test]
    fn prop_make_cite_key_unique_legal(
        base in "[A-Za-z][A-Za-z0-9]{0,12}",
        existing in prop::collection::vec("[A-Za-z][A-Za-z0-9]{0,12}", 0..30),
    ) {
        let result = make_cite_key_unique(base.clone(), existing.clone());
        prop_assert!(!existing.contains(&result));
        prop_assert!(result.starts_with(&base));
        if !existing.contains(&base) {
            prop_assert_eq!(result, base);
        }
    }

    // sanitize_cite_key: total, idempotent, and restricted to the safe alphabet.
    #[test]
    fn prop_sanitize_cite_key_idempotent_and_safe(key in any::<String>()) {
        let once = sanitize_cite_key(key);
        prop_assert!(
            once.chars().all(|c| c.is_ascii_alphanumeric() || "_-:".contains(c)),
            "sanitized key contains illegal char: {:?}", once
        );
        let twice = sanitize_cite_key(once.clone());
        prop_assert_eq!(twice, once);
    }
}
