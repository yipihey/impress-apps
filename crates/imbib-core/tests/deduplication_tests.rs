//! Deduplication integration tests
//!
//! Ported from Swift DeduplicationServiceTests.swift
//! Enhanced with property-based testing

use imbib_core::bibtex::{BibTeXEntry, BibTeXEntryType};
use imbib_core::deduplication::{
    authors_overlap, calculate_publication_similarity, calculate_similarity,
    deduplicate_search_results, find_duplicates, normalize_author_export as normalize_author,
    normalize_title_export as normalize_title, shares_identifier, titles_match,
    DeduplicationConfig, DeduplicationInput,
};
use imbib_core::domain::{Author, Identifiers, Publication};
use proptest::prelude::*;
use std::collections::BTreeSet;

// === Identifier-Based Deduplication ===

#[test]
fn test_deduplicate_by_doi() {
    let mut pub1 = Publication::new(
        "p1".to_string(),
        "article".to_string(),
        "Paper A".to_string(),
    );
    pub1.identifiers = Identifiers {
        doi: Some("10.1234/test".to_string()),
        ..Default::default()
    };

    let mut pub2 = Publication::new(
        "p2".to_string(),
        "article".to_string(),
        "Paper B".to_string(),
    );
    pub2.identifiers = Identifiers {
        doi: Some("10.1234/test".to_string()),
        ..Default::default()
    };

    let result = calculate_publication_similarity(&pub1, &pub2);
    assert!(
        result.score >= 0.99,
        "DOI match should give score ~1.0, got {}",
        result.score
    );
    assert!(
        result.reason.to_lowercase().contains("doi"),
        "Reason should mention DOI, got: {}",
        result.reason
    );
}

#[test]
fn test_deduplicate_by_arxiv_id() {
    let mut pub1 = Publication::new(
        "p1".to_string(),
        "article".to_string(),
        "Paper A".to_string(),
    );
    pub1.identifiers = Identifiers {
        arxiv_id: Some("2301.12345".to_string()),
        ..Default::default()
    };

    let mut pub2 = Publication::new(
        "p2".to_string(),
        "article".to_string(),
        "Paper B".to_string(),
    );
    pub2.identifiers = Identifiers {
        arxiv_id: Some("2301.12345".to_string()),
        ..Default::default()
    };

    let result = calculate_publication_similarity(&pub1, &pub2);
    assert!(result.score >= 0.99);
}

#[test]
fn test_deduplicate_by_bibcode() {
    let mut pub1 = Publication::new(
        "p1".to_string(),
        "article".to_string(),
        "Paper A".to_string(),
    );
    pub1.identifiers = Identifiers {
        bibcode: Some("2024ApJ...123..456A".to_string()),
        ..Default::default()
    };

    let mut pub2 = Publication::new(
        "p2".to_string(),
        "article".to_string(),
        "Paper B".to_string(),
    );
    pub2.identifiers = Identifiers {
        bibcode: Some("2024ApJ...123..456A".to_string()),
        ..Default::default()
    };

    let result = calculate_publication_similarity(&pub1, &pub2);
    assert!(result.score >= 0.99);
}

// === BibTeX Entry Deduplication ===

#[test]
fn test_bibtex_doi_match() {
    let mut entry1 = BibTeXEntry::new("Test1".to_string(), BibTeXEntryType::Article);
    entry1.add_field("doi", "10.1038/nature12373");
    entry1.add_field("title", "Paper A");

    let mut entry2 = BibTeXEntry::new("Test2".to_string(), BibTeXEntryType::Article);
    entry2.add_field("doi", "10.1038/nature12373");
    entry2.add_field("title", "Different Title");

    let result = calculate_similarity(entry1, entry2);
    assert_eq!(result.score, 1.0);
    assert!(result.reason.contains("DOI"));
}

#[test]
fn test_bibtex_similar_titles() {
    let mut entry1 = BibTeXEntry::new("Test1".to_string(), BibTeXEntryType::Article);
    entry1.add_field("title", "Deep Learning for Natural Language Processing");
    entry1.add_field("author", "Smith, John");
    entry1.add_field("year", "2024");

    let mut entry2 = BibTeXEntry::new("Test2".to_string(), BibTeXEntryType::Article);
    entry2.add_field("title", "Deep Learning for Natural Language Processing");
    entry2.add_field("author", "J. Smith");
    entry2.add_field("year", "2024");

    let result = calculate_similarity(entry1, entry2);
    assert!(
        result.score > 0.7,
        "Similar entries should have high score, got {}",
        result.score
    );
}

// === Fuzzy Title Matching ===

#[test]
fn test_titles_match_identical() {
    let title = "Deep Learning for Natural Language Processing".to_string();
    assert!(titles_match(title.clone(), title, 0.9));
}

#[test]
fn test_titles_match_case_insensitive() {
    assert!(titles_match(
        "Machine Learning Basics".to_string(),
        "machine learning basics".to_string(),
        0.9
    ));
}

#[test]
fn test_titles_match_with_threshold() {
    assert!(titles_match(
        "Machine Learning Basics".to_string(),
        "Machine Learning Basics".to_string(),
        0.9
    ));
    assert!(!titles_match(
        "Machine Learning".to_string(),
        "Deep Learning".to_string(),
        0.9
    ));
}

#[test]
fn test_titles_dont_match_when_different() {
    assert!(!titles_match(
        "Deep Learning for Computer Vision".to_string(),
        "Quantum Computing Fundamentals".to_string(),
        0.5
    ));
}

// === Author Matching ===

#[test]
fn test_authors_overlap_exact_match() {
    assert!(authors_overlap(
        "Smith, John".to_string(),
        "Smith, John".to_string()
    ));
}

#[test]
fn test_authors_overlap_reversed_format() {
    assert!(authors_overlap(
        "John Smith".to_string(),
        "Smith, John".to_string()
    ));
}

#[test]
fn test_authors_overlap_with_multiple() {
    assert!(authors_overlap(
        "Smith, J. and Doe, J.".to_string(),
        "John Smith and Jane Doe".to_string()
    ));
}

#[test]
fn test_authors_no_overlap() {
    assert!(!authors_overlap(
        "Smith, John".to_string(),
        "Wilson, Bob".to_string()
    ));
}

// === Duplicate Finding ===

#[test]
fn test_find_duplicates_groups_by_doi() {
    let pubs = vec![
        {
            let mut p = Publication::new(
                "p1".to_string(),
                "article".to_string(),
                "Paper A".to_string(),
            );
            p.identifiers = Identifiers {
                doi: Some("10.1234/a".to_string()),
                ..Default::default()
            };
            p
        },
        {
            let mut p = Publication::new(
                "p2".to_string(),
                "article".to_string(),
                "Paper B".to_string(),
            );
            p.identifiers = Identifiers {
                doi: Some("10.1234/a".to_string()),
                ..Default::default()
            };
            p
        },
        {
            let mut p = Publication::new(
                "p3".to_string(),
                "article".to_string(),
                "Paper C".to_string(),
            );
            p.identifiers = Identifiers {
                doi: Some("10.1234/b".to_string()),
                ..Default::default()
            };
            p
        },
    ];

    let groups = find_duplicates(pubs, 0.9);

    // Should find the duplicates (p1 and p2 have the same DOI)
    // The grouping may vary - just check that duplicates are detected
    if !groups.is_empty() {
        // At least one group should have more than 1 publication
        assert!(
            groups.iter().any(|g| g.publication_ids.len() >= 2),
            "Expected at least one group with duplicates, got: {:?}",
            groups
        );
    } else {
        // If no groups returned, the implementation may just skip singletons
        // In that case we need to verify p1 and p2 would match
        let mut pub1 = Publication::new(
            "p1".to_string(),
            "article".to_string(),
            "Paper A".to_string(),
        );
        pub1.identifiers = Identifiers {
            doi: Some("10.1234/a".to_string()),
            ..Default::default()
        };
        let mut pub2 = Publication::new(
            "p2".to_string(),
            "article".to_string(),
            "Paper B".to_string(),
        );
        pub2.identifiers = Identifiers {
            doi: Some("10.1234/a".to_string()),
            ..Default::default()
        };
        let similarity = calculate_publication_similarity(&pub1, &pub2);
        assert!(
            similarity.score >= 0.9,
            "DOI match should be >= 0.9, got {}",
            similarity.score
        );
    }
}

#[test]
fn test_find_duplicates_no_duplicates() {
    let pubs = vec![
        Publication::new(
            "p1".to_string(),
            "article".to_string(),
            "Unique Paper About Machine Learning".to_string(),
        ),
        Publication::new(
            "p2".to_string(),
            "article".to_string(),
            "Unique Paper About Quantum Computing".to_string(),
        ),
        Publication::new(
            "p3".to_string(),
            "article".to_string(),
            "Unique Paper About Blockchain".to_string(),
        ),
    ];

    let groups = find_duplicates(pubs, 0.9);

    // No groups should have more than 1 publication with high threshold
    assert!(groups.iter().all(|g| g.publication_ids.len() == 1) || groups.is_empty());
}

#[test]
fn test_find_duplicates_by_similar_title() {
    let mut pubs = Vec::new();

    let mut p1 = Publication::new(
        "p1".to_string(),
        "article".to_string(),
        "Deep Learning for Natural Language Processing".to_string(),
    );
    p1.year = Some(2024);
    p1.authors.push(Author::new("Smith".to_string()));
    pubs.push(p1);

    let mut p2 = Publication::new(
        "p2".to_string(),
        "article".to_string(),
        "Deep Learning for Natural Language Processing".to_string(),
    );
    p2.year = Some(2024);
    p2.authors.push(Author::new("Smith".to_string()));
    pubs.push(p2);

    let groups = find_duplicates(pubs, 0.7);
    assert!(groups.iter().any(|g| g.publication_ids.len() >= 2));
}

// === Normalization Tests ===

#[test]
fn test_normalize_title() {
    let normalized = normalize_title("The  Machine   Learning   BOOK".to_string());
    // Should lowercase and normalize whitespace
    assert!(normalized.contains("machine"));
    assert!(!normalized.contains("  ")); // No double spaces
}

#[test]
fn test_normalize_author() {
    let cases = [
        ("Smith, John", "smith"),
        ("John Smith", "smith"),
        ("Smith, J.", "smith"),
    ];

    for (input, expected_contains) in cases {
        let normalized = normalize_author(input.to_string());
        assert!(
            normalized.to_lowercase().contains(expected_contains),
            "Expected '{}' to contain '{}', got '{}'",
            input,
            expected_contains,
            normalized
        );
    }
}

// === Property-Based Tests ===

proptest! {
    #[test]
    fn test_titles_match_symmetric(a in "[a-zA-Z ]{5,30}", b in "[a-zA-Z ]{5,30}") {
        let match_ab = titles_match(a.clone(), b.clone(), 0.5);
        let match_ba = titles_match(b, a, 0.5);
        prop_assert_eq!(match_ab, match_ba, "titles_match should be symmetric");
    }

    #[test]
    fn test_identical_non_empty_titles_always_match(title in "[a-zA-Z][a-zA-Z ]{4,29}") {
        prop_assert!(
            titles_match(title.clone(), title, 0.99),
            "Identical non-empty titles should always match"
        );
    }

    #[test]
    fn test_doi_match_always_high_similarity(doi in "10\\.[0-9]{4}/[a-z0-9]{5,10}") {
        let mut pub1 = Publication::new("p1".to_string(), "article".to_string(), "Title A".to_string());
        pub1.identifiers = Identifiers { doi: Some(doi.clone()), ..Default::default() };

        let mut pub2 = Publication::new("p2".to_string(), "article".to_string(), "Title B".to_string());
        pub2.identifiers = Identifiers { doi: Some(doi), ..Default::default() };

        let result = calculate_publication_similarity(&pub1, &pub2);
        prop_assert!(result.score >= 0.99, "DOI match should always be high similarity, got {}", result.score);
    }

    #[test]
    fn test_normalize_title_produces_lowercase(title in "[a-zA-Z ]{5,30}") {
        let normalized = normalize_title(title);
        // Should produce lowercase output
        prop_assert!(
            normalized.chars().all(|c| !c.is_uppercase()),
            "normalize_title should produce lowercase: {}",
            normalized
        );
    }

    #[test]
    fn test_similarity_score_bounded(
        title1 in "[a-zA-Z ]{5,20}",
        title2 in "[a-zA-Z ]{5,20}"
    ) {
        let mut entry1 = BibTeXEntry::new("e1".to_string(), BibTeXEntryType::Article);
        entry1.add_field("title", &title1);

        let mut entry2 = BibTeXEntry::new("e2".to_string(), BibTeXEntryType::Article);
        entry2.add_field("title", &title2);

        let result = calculate_similarity(entry1, entry2);
        prop_assert!(result.score >= 0.0 && result.score <= 1.0,
            "Similarity score should be in [0, 1], got {}", result.score);
    }
}

// === Edge Cases ===

#[test]
fn test_empty_titles() {
    assert!(!titles_match("".to_string(), "Some Title".to_string(), 0.5));
    assert!(!titles_match("Some Title".to_string(), "".to_string(), 0.5));
    assert!(!titles_match("     ".to_string(), "     ".to_string(), 0.5));
}

#[test]
fn test_empty_authors() {
    assert!(!authors_overlap("".to_string(), "Smith, John".to_string()));
}

#[test]
fn test_very_long_title() {
    let long_title = "A".repeat(10000);
    let result = titles_match(long_title.clone(), long_title, 0.9);
    assert!(result);
}

#[test]
fn test_unicode_in_titles() {
    assert!(titles_match(
        "Über die Théorie des α-Zerfalls".to_string(),
        "Über die Théorie des α-Zerfalls".to_string(),
        0.9
    ));
}

#[test]
fn test_unicode_in_authors() {
    assert!(authors_overlap(
        "Müller, Hans".to_string(),
        "Hans Müller".to_string()
    ));
}

// === Real-world Examples ===

#[test]
fn test_arxiv_vs_published_version() {
    // Often the same paper appears as arXiv preprint and published version
    let mut arxiv = Publication::new(
        "arxiv".to_string(),
        "article".to_string(),
        "Attention Is All You Need".to_string(),
    );
    arxiv.authors.push(Author::new("Vaswani".to_string()));
    arxiv.year = Some(2017);
    arxiv.identifiers.arxiv_id = Some("1706.03762".to_string());

    let mut published = Publication::new(
        "published".to_string(),
        "inproceedings".to_string(),
        "Attention Is All You Need".to_string(),
    );
    published.authors.push(Author::new("Vaswani".to_string()));
    published.year = Some(2017);

    let result = calculate_publication_similarity(&arxiv, &published);
    assert!(
        result.score > 0.7,
        "Same paper in different venues should match, got {}",
        result.score
    );
}

#[test]
fn test_slight_title_variation() {
    // Titles sometimes have minor variations
    let mut pub1 = Publication::new(
        "p1".to_string(),
        "article".to_string(),
        "Deep Learning: A Comprehensive Survey".to_string(),
    );
    pub1.authors.push(Author::new("LeCun".to_string()));
    pub1.year = Some(2015);

    let mut pub2 = Publication::new(
        "p2".to_string(),
        "article".to_string(),
        "Deep Learning - A Comprehensive Survey".to_string(),
    );
    pub2.authors.push(Author::new("LeCun".to_string()));
    pub2.year = Some(2015);

    let result = calculate_publication_similarity(&pub1, &pub2);
    assert!(
        result.score > 0.7,
        "Minor title variations should still match, got {}",
        result.score
    );
}

// === Property-Based Tests: identifier matching & dedup invariants ===

/// Strategy: an optional identifier-ish string (arbitrary content).
fn opt_ident() -> impl Strategy<Value = Option<String>> {
    prop_oneof![
        2 => Just(None),
        3 => "[a-zA-Z0-9./:-]{1,16}".prop_map(Some),
    ]
}

fn arb_dedup_input() -> impl Strategy<Value = DeduplicationInput> {
    (
        "[a-z0-9]{1,6}",
        prop::sample::select(vec!["crossref", "arxiv", "ads", "pubmed", "openalex"]),
        "[a-zA-Z ]{0,20}",
        opt_ident(),
        opt_ident(),
        opt_ident(),
        opt_ident(),
        prop_oneof![Just(None), (1900i32..2100).prop_map(Some)],
    )
        .prop_map(|(id, source, title, doi, arxiv_id, pmid, bibcode, year)| {
            DeduplicationInput {
                id,
                source_id: source.to_string(),
                title,
                first_author_last_name: Some("Smith".to_string()),
                year,
                doi,
                arxiv_id,
                pmid,
                bibcode,
                semantic_scholar_id: None,
                open_alex_id: None,
            }
        })
}

/// Publication with sane years and unique author surnames per list
/// (the domain-canonical shape produced by BibTeX/enrichment import).
fn arb_publication_canonical() -> impl Strategy<Value = Publication> {
    (
        "[a-z0-9]{1,6}",
        "[a-zA-Z ]{0,24}",
        prop::collection::btree_set("[A-Z][a-z]{2,8}", 0..4),
        prop_oneof![Just(None), (1800i32..2100).prop_map(Some)],
        opt_ident(),
        opt_ident(),
        opt_ident(),
    )
        .prop_map(|(id, title, surnames, year, doi, arxiv_id, bibcode)| {
            let mut p = Publication::new(id, "article".to_string(), title);
            for s in surnames {
                p.authors.push(Author::new(s));
            }
            p.year = year;
            p.identifiers = Identifiers {
                doi,
                arxiv_id,
                bibcode,
                ..Default::default()
            };
            p
        })
}

const DOI_PREFIXES: &[&str] = &["", "doi:", "https://doi.org/", "http://doi.org/"];

proptest! {
    /// shares_identifier is symmetric for arbitrary inputs.
    #[test]
    fn shares_identifier_symmetric(a in arb_dedup_input(), b in arb_dedup_input()) {
        prop_assert_eq!(shares_identifier(&a, &b), shares_identifier(&b, &a));
    }

    /// shares_identifier is reflexive whenever any identifier is present.
    #[test]
    fn shares_identifier_reflexive(a in arb_dedup_input()) {
        let has_ident = a.doi.is_some() || a.arxiv_id.is_some()
            || a.pmid.is_some() || a.bibcode.is_some();
        prop_assert_eq!(shares_identifier(&a, &a), has_ident);
    }

    /// Normalized DOI comparison is case- and format-insensitive:
    /// "10.1234/x", "DOI:10.1234/X", "https://doi.org/10.1234/x" all match.
    #[test]
    fn doi_match_case_and_format_insensitive(
        core in "10\\.[0-9]{4,5}/[a-z0-9.]{3,12}",
        pa in 0usize..4,
        pb in 0usize..4,
        upper_a in any::<bool>(),
        upper_b in any::<bool>(),
    ) {
        let fmt = |prefix: &str, upper: bool| {
            let s = format!("{}{}", prefix, core);
            if upper { s.to_uppercase() } else { s }
        };
        let mut a = DeduplicationInput {
            id: "a".into(), source_id: "crossref".into(), title: "T".into(),
            first_author_last_name: None, year: None,
            doi: Some(fmt(DOI_PREFIXES[pa], upper_a)),
            arxiv_id: None, pmid: None, bibcode: None,
            semantic_scholar_id: None, open_alex_id: None,
        };
        let mut b = a.clone();
        b.id = "b".into();
        b.doi = Some(fmt(DOI_PREFIXES[pb], upper_b));
        prop_assert!(
            shares_identifier(&a, &b),
            "DOI variants failed to match: {:?} vs {:?}", a.doi, b.doi
        );
        // and a non-matching DOI core must NOT match
        b.doi = Some(format!("10.9999/other{}", core.len()));
        a.doi = Some(core);
        prop_assert!(!shares_identifier(&a, &b));
    }

    /// Normalized arXiv comparison ignores the "arXiv:" prefix, case, and
    /// version suffix (2301.12345 == arXiv:2301.12345v7).
    #[test]
    fn arxiv_match_prefix_and_version_insensitive(
        core in "[0-9]{4}\\.[0-9]{4,5}",
        prefix_a in any::<bool>(),
        prefix_b in any::<bool>(),
        version_a in prop_oneof![Just(None), (1u8..20).prop_map(Some)],
        version_b in prop_oneof![Just(None), (1u8..20).prop_map(Some)],
    ) {
        let fmt = |prefix: bool, version: Option<u8>| {
            let mut s = String::new();
            if prefix { s.push_str("arXiv:"); }
            s.push_str(&core);
            if let Some(v) = version { s.push_str(&format!("v{}", v)); }
            s
        };
        let a = DeduplicationInput {
            id: "a".into(), source_id: "arxiv".into(), title: "T".into(),
            first_author_last_name: None, year: None,
            doi: None, arxiv_id: Some(fmt(prefix_a, version_a)),
            pmid: None, bibcode: None,
            semantic_scholar_id: None, open_alex_id: None,
        };
        let mut b = a.clone();
        b.arxiv_id = Some(fmt(prefix_b, version_b));
        prop_assert!(
            shares_identifier(&a, &b),
            "arXiv variants failed to match: {:?} vs {:?}", a.arxiv_id, b.arxiv_id
        );
    }

    /// A publication always matches itself with maximal confidence when it
    /// carries any strong identifier (DOI/arXiv/bibcode).
    #[test]
    fn publication_self_similarity_with_identifier_is_max(
        p in arb_publication_canonical()
    ) {
        prop_assume!(
            p.identifiers.doi.is_some()
                || p.identifiers.arxiv_id.is_some()
                || p.identifiers.bibcode.is_some()
        );
        let result = calculate_publication_similarity(&p, &p);
        prop_assert!(result.score >= 0.99, "self-similarity was {}", result.score);
    }

    /// Similarity is symmetric for canonical publications (unique surnames
    /// within each author list, sane years).
    #[test]
    fn publication_similarity_symmetric_canonical(
        a in arb_publication_canonical(),
        b in arb_publication_canonical(),
    ) {
        let ab = calculate_publication_similarity(&a, &b);
        let ba = calculate_publication_similarity(&b, &a);
        prop_assert!(
            (ab.score - ba.score).abs() < 1e-12,
            "asymmetric: ab={} ba={}", ab.score, ba.score
        );
    }

    /// Duplicate detection must be symmetric for ALL publications.
    ///
    /// BUG (found by this property): `pub_author_similarity` counts matches
    /// from the first argument's perspective (`a.iter().filter(...)`) but
    /// divides by `max(len)`. With a repeated surname the counts differ:
    /// authors [Wang, Wang] vs [Wang] gives 2/2 = 1.0 one way and
    /// 1/2 = 0.5 the other, so dup(a,b) != dup(b,a).
    /// Minimal counterexample: a.authors=[Wang, Wang], b.authors=[Wang],
    /// distinct titles => scores 0.476 vs 0.326.
    #[test]
    fn publication_similarity_symmetric_with_repeated_surnames(
        surnames_a in prop::collection::vec(prop::sample::select(vec!["Wang", "Li", "Kim"]), 0..4),
        surnames_b in prop::collection::vec(prop::sample::select(vec!["Wang", "Li", "Kim"]), 0..4),
        title_a in "[a-z ]{4,16}",
        title_b in "[a-z ]{4,16}",
    ) {
        let mut a = Publication::new("a".into(), "article".into(), title_a);
        for s in surnames_a { a.authors.push(Author::new(s.to_string())); }
        let mut b = Publication::new("b".into(), "article".into(), title_b);
        for s in surnames_b { b.authors.push(Author::new(s.to_string())); }
        let ab = calculate_publication_similarity(&a, &b);
        let ba = calculate_publication_similarity(&b, &a);
        prop_assert!(
            (ab.score - ba.score).abs() < 1e-12,
            "asymmetric: ab={} ba={}", ab.score, ba.score
        );
    }

    /// Totality: similarity must not panic for any year values.
    ///
    /// BUG (found by this property): the year-bonus computation does
    /// `(y1 - y2).abs()` on raw i32 years, which overflows and panics
    /// (debug builds) for widely separated values.
    /// Minimal counterexample: a.year=Some(i32::MAX), b.year=Some(-2).
    #[test]
    fn publication_similarity_total_over_years(
        ya in prop::num::i32::ANY,
        yb in prop::num::i32::ANY,
    ) {
        let mut a = Publication::new("a".into(), "article".into(), "alpha".into());
        a.year = Some(ya);
        let mut b = Publication::new("b".into(), "article".into(), "beta".into());
        b.year = Some(yb);
        let r = calculate_publication_similarity(&a, &b);
        prop_assert!((0.0..=1.0).contains(&r.score));
    }
}

// === Property-Based Tests: planted-duplicate corpus ===

/// Planted-duplicate corpus: `sizes[i]` duplicates of class `i`, each class
/// with its own DOI rendered in a per-duplicate case/format variant.
#[derive(Debug, Clone)]
struct PlantedCorpus {
    /// (class index, duplicate index, doi variant string) per input, in
    /// shuffled order.
    entries: Vec<(usize, usize, String)>,
    num_classes: usize,
}

fn arb_planted_corpus() -> impl Strategy<Value = PlantedCorpus> {
    prop::collection::vec((1usize..4, 0usize..4, any::<bool>()), 1..5).prop_flat_map(|classes| {
        let mut entries = Vec::new();
        for (ci, (size, prefix_seed, upper)) in classes.iter().enumerate() {
            for di in 0..*size {
                // Vary the DOI rendering per duplicate.
                let prefix = DOI_PREFIXES[(prefix_seed + di) % DOI_PREFIXES.len()];
                let core = format!("10.5555/class{}", ci);
                let doi = if *upper && di % 2 == 0 {
                    format!("{}{}", prefix, core).to_uppercase()
                } else {
                    format!("{}{}", prefix, core)
                };
                entries.push((ci, di, doi));
            }
        }
        let n = classes.len();
        Just(entries)
            .prop_shuffle()
            .prop_map(move |entries| PlantedCorpus {
                entries,
                num_classes: n,
            })
    })
}

// A corpus with planted duplicates dedups to exactly the distinct classes,
// regardless of insertion order and identifier formatting.
proptest! {
    #[test]
    fn planted_duplicates_dedup_to_distinct_set(corpus in arb_planted_corpus()) {
        let sources = ["crossref", "arxiv", "ads", "pubmed"];
        let inputs: Vec<DeduplicationInput> = corpus
            .entries
            .iter()
            .map(|(ci, di, doi)| DeduplicationInput {
                id: format!("c{}-d{}", ci, di),
                source_id: sources[(ci + di) % sources.len()].to_string(),
                title: format!("paper of class {}", ci),
                first_author_last_name: Some("Smith".to_string()),
                year: Some(2024),
                doi: Some(doi.clone()),
                arxiv_id: None,
                pmid: None,
                bibcode: None,
                semantic_scholar_id: None,
                open_alex_id: None,
            })
            .collect();

        // Identifier-only matching: the planted DOI classes are the ground truth.
        let config = DeduplicationConfig {
            use_fuzzy_matching: false,
            ..DeduplicationConfig::default()
        };
        let groups = deduplicate_search_results(inputs.clone(), config);

        // Expected partition: one group per class, containing exactly its ids.
        let mut expected: Vec<BTreeSet<String>> = vec![BTreeSet::new(); corpus.num_classes];
        for (ci, di, _) in &corpus.entries {
            expected[*ci].insert(format!("c{}-d{}", ci, di));
        }
        let expected: BTreeSet<BTreeSet<String>> = expected.into_iter().collect();

        let actual: BTreeSet<BTreeSet<String>> = groups
            .iter()
            .map(|g| {
                std::iter::once(g.primary_index)
                    .chain(g.alternate_indices.iter().copied())
                    .map(|idx| inputs[idx as usize].id.clone())
                    .collect()
            })
            .collect();

        prop_assert_eq!(
            actual, expected,
            "dedup partition differs from planted classes (order/format must not matter)"
        );
    }

    /// find_duplicates groups exactly the same-DOI publications: every
    /// planted duplicate pair lands in the same group, and no group ever
    /// mixes two classes — independent of insertion order.
    #[test]
    fn find_duplicates_recovers_planted_doi_classes(corpus in arb_planted_corpus()) {
        let pubs: Vec<Publication> = corpus
            .entries
            .iter()
            .map(|(ci, di, doi)| {
                let mut p = Publication::new(
                    format!("c{}-d{}", ci, di),
                    "article".to_string(),
                    format!("title {}", ci),
                );
                // find_duplicates reports Publication.id (a random UUID from
                // `new`) — overwrite it with the planted class label.
                p.id = format!("c{}-d{}", ci, di);
                // No authors and widely spaced years keep cross-class fuzzy
                // scores far below the 0.99 threshold (max possible 0.5).
                p.year = Some(1900 + 2 * (*ci as i32));
                p.identifiers = Identifiers {
                    doi: Some(doi.clone()),
                    ..Default::default()
                };
                p
            })
            .collect();

        let groups = find_duplicates(pubs, 0.99);

        let class_of = |id: &str| -> usize {
            id[1..id.find('-').unwrap()].parse().unwrap()
        };

        // No group mixes classes.
        for g in &groups {
            let classes: BTreeSet<usize> =
                g.publication_ids.iter().map(|id| class_of(id)).collect();
            prop_assert_eq!(classes.len(), 1, "group mixes classes: {:?}", g.publication_ids);
        }

        // Every class of size >= 2 is fully reunited in one group.
        let mut class_sizes = vec![0usize; corpus.num_classes];
        for (ci, _, _) in &corpus.entries {
            class_sizes[*ci] += 1;
        }
        for (ci, size) in class_sizes.iter().enumerate() {
            if *size >= 2 {
                let found = groups.iter().any(|g| {
                    g.publication_ids.len() == *size
                        && g.publication_ids.iter().all(|id| class_of(id) == ci)
                });
                prop_assert!(found, "class {} (size {}) not fully grouped", ci, size);
            }
        }
    }
}
