# Rust Migration Phase 4: Test Migration Strategy

You are implementing Phase 4 of the Rust core expansion for imbib. Phases 1-3 (domain models, source plugins, search/PDF) should already be complete. This phase focuses on migrating platform-agnostic tests to Rust for cross-platform verification.

## Project Context

**imbib** is a cross-platform (macOS/iOS) scientific publication manager. The goal is to maximize code sharing for a future web app by moving all platform-agnostic logic to Rust.

**Current Test State:**
- Swift tests: ~24,000 LOC, 72 files, ~1,351 test methods
- Rust tests: ~150 unit tests embedded in source files, no integration tests

**Target State (Post Phase 4):**
- Rust has comprehensive integration tests for all core logic
- Swift retains only platform-specific tests (ViewModels, Core Data, UITests)
- Property-based tests for edge case coverage
- Snapshot tests for format output stability
- Benchmarks for performance regression detection

---

## Phase 4 Implementation

Execute these phases in order. After each phase, run `cargo build && cargo test`.

---

### Phase 4.1: Test Infrastructure Setup

**Goal**: Create proper test organization with fixtures, mocks, and utilities.

**Create directory structure:**
```
imbib-core/
├── tests/                      # Integration tests
│   ├── common/
│   │   ├── mod.rs
│   │   └── fixtures.rs
│   ├── bibtex_tests.rs
│   ├── ris_tests.rs
│   ├── deduplication_tests.rs
│   ├── identifier_tests.rs
│   ├── source_plugin_tests.rs
│   ├── merge_tests.rs
│   └── snapshot_tests.rs
├── test_fixtures/              # Test data files
│   ├── bibtex/
│   │   ├── simple.bib
│   │   ├── nested_braces.bib
│   │   ├── string_macros.bib
│   │   ├── latex_chars.bib
│   │   ├── ads_style.bib
│   │   └── thesis_ref.bib
│   ├── ris/
│   │   ├── sample.ris
│   │   ├── multiple_authors.ris
│   │   └── all_types.ris
│   └── responses/
│       ├── ads_search.json
│       ├── crossref_work.json
│       ├── arxiv_search.xml
│       └── pubmed_efetch.xml
└── benches/
    └── parsing_bench.rs
```

**Update `Cargo.toml` dev-dependencies:**
```toml
[dev-dependencies]
proptest = "1.4"               # Property-based testing
rstest = "0.18"                # Parameterized tests
test-case = "3.3"              # Simple test cases
wiremock = "0.6"               # HTTP mocking
tokio-test = "0.4"             # Async test utilities
criterion = "0.5"              # Benchmarking
insta = "1.34"                 # Snapshot testing
tempfile = "3.10"              # Temporary files

[[bench]]
name = "parsing"
harness = false
```

**Create `tests/common/mod.rs`:**
```rust
pub mod fixtures;
```

**Create `tests/common/fixtures.rs`:**
```rust
//! Test fixture loading utilities

use std::path::PathBuf;

/// Get the path to a fixture file
pub fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("test_fixtures")
        .join(name)
}

/// Load a fixture file as a string
pub fn load_fixture(name: &str) -> String {
    std::fs::read_to_string(fixture_path(name))
        .unwrap_or_else(|_| panic!("Failed to load fixture: {}", name))
}

/// Load a BibTeX fixture
pub fn load_bibtex_fixture(name: &str) -> String {
    load_fixture(&format!("bibtex/{}", name))
}

/// Load a RIS fixture
pub fn load_ris_fixture(name: &str) -> String {
    load_fixture(&format!("ris/{}", name))
}

/// Load a mock API response fixture
pub fn load_response_fixture(name: &str) -> String {
    load_fixture(&format!("responses/{}", name))
}
```

**Copy fixtures from Swift test directory:**
```bash
# BibTeX fixtures
cp PublicationManagerCore/Tests/PublicationManagerCoreTests/Fixtures/*.bib \
   imbib-core/test_fixtures/bibtex/

# RIS fixtures
cp PublicationManagerCore/Tests/PublicationManagerCoreTests/Fixtures/*.ris \
   imbib-core/test_fixtures/ris/

# API response fixtures (if they exist)
cp PublicationManagerCore/Tests/PublicationManagerCoreTests/Fixtures/Responses/* \
   imbib-core/test_fixtures/responses/
```

**Checkpoint:** `cargo build && cargo test`

---

### Phase 4.2: BibTeX Parser Tests Migration

**Goal**: Port all BibTeX parser tests from `BibTeXParserTests.swift` (~35 tests).

**Source:** `PublicationManagerCore/Tests/PublicationManagerCoreTests/BibTeXParserTests.swift`

**Create `tests/bibtex_tests.rs`:**
```rust
//! BibTeX parser integration tests
//!
//! Ported from Swift BibTeXParserTests.swift

mod common;

use common::fixtures::load_bibtex_fixture;
use imbib_core::bibtex::{parse, BibTeXEntry, BibTeXEntryType};

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
    assert_eq!(entry.get_field("title"), Some("The {LaTeX} Guide"));
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
    assert_eq!(result.entries[0].get_field("month"), Some("January"));
}

#[test]
fn test_parse_string_concatenation() {
    let input = r#"
@string{prefix = "Phys."}
@article{Test, journal = prefix # " Rev. Lett."}
"#;
    let result = parse(input.to_string()).unwrap();
    assert_eq!(
        result.entries[0].get_field("journal"),
        Some("Phys. Rev. Lett.")
    );
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
    assert!(author.contains("ö") || author.contains("Schrodinger"));
}

#[test]
fn test_decode_latex_special_chars() {
    let input = r#"@article{Test, title = {Cost is \$100 \& cheap}}"#;
    let result = parse(input.to_string()).unwrap();
    let title = result.entries[0].get_field("title").unwrap();
    assert!(title.contains("$") || title.contains("&"));
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
    assert_eq!(paper.get_field("booktitle"), Some("ICML 2024"));
}

// === Error Handling ===

#[test]
fn test_parse_error_on_unclosed_brace() {
    let input = r#"@article{Test, title = {Unclosed"#;
    let result = parse(input.to_string());
    assert!(result.is_err() || result.unwrap().entries.is_empty());
}

#[test]
fn test_parse_recovers_from_malformed_entry() {
    let input = r#"
@article{Bad, title =
@article{Good, title = {Valid}}
"#;
    let result = parse(input.to_string()).unwrap();
    // Should recover and parse the valid entry
    assert!(result.entries.iter().any(|e| e.cite_key == "Good"));
}

// === Fixture Tests ===

#[test]
fn test_parse_simple_fixture() {
    let content = load_bibtex_fixture("simple.bib");
    let result = parse(content).unwrap();

    assert!(!result.entries.is_empty());
    // Verify expected entries exist
    for entry in &result.entries {
        assert!(!entry.cite_key.is_empty());
        assert!(entry.get_field("title").is_some());
    }
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
fn test_parse_large_thesis_file() {
    let content = load_bibtex_fixture("thesis_ref.bib");
    let result = parse(content).unwrap();

    // Should parse hundreds of entries
    assert!(result.entries.len() > 100);

    // Verify no outer braces on titles
    for entry in &result.entries {
        if let Some(title) = entry.get_field("title") {
            assert!(
                !title.starts_with('{') || !title.ends_with('}'),
                "Title should not have outer braces: {}",
                title
            );
        }
    }
}

// === Entry Types ===

#[test]
fn test_parse_all_standard_entry_types() {
    let types = [
        "article",
        "book",
        "inproceedings",
        "incollection",
        "phdthesis",
        "mastersthesis",
        "techreport",
        "misc",
        "unpublished",
    ];

    for entry_type in types {
        let input = format!("@{entry_type}{{Test, title = {{Title}}}}");
        let result = parse(input).unwrap();
        assert_eq!(result.entries.len(), 1, "Failed to parse {}", entry_type);
    }
}
```

**Checkpoint:** `cargo test bibtex`

---

### Phase 4.3: RIS Format Tests Migration

**Goal**: Port RIS parser, exporter, and converter tests (~125 tests total).

**Sources:**
- `PublicationManagerCore/Tests/PublicationManagerCoreTests/RISParserTests.swift`
- `PublicationManagerCore/Tests/PublicationManagerCoreTests/RISExporterTests.swift`
- `PublicationManagerCore/Tests/PublicationManagerCoreTests/RISBibTeXConverterTests.swift`

**Create `tests/ris_tests.rs`:**
```rust
//! RIS format integration tests
//!
//! Ported from Swift RIS*Tests.swift files

mod common;

use common::fixtures::load_ris_fixture;
use imbib_core::ris::{format_entry, parse, RISEntry, RISType};

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
    assert!(authors.contains(&"Smith, John".to_string()));
    assert!(authors.contains(&"Doe, Jane".to_string()));
}

#[test]
fn test_parse_all_ris_types() {
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
        Some("This is the abstract text.".to_string())
    );
}

#[test]
fn test_parse_with_doi() {
    let ris = "TY  - JOUR\nTI  - Test\nDO  - 10.1234/test.123\nER  -";
    let entries = parse(ris.to_string()).unwrap();
    assert_eq!(entries[0].doi(), Some("10.1234/test.123".to_string()));
}

#[test]
fn test_parse_with_urls() {
    let ris = "TY  - JOUR\nTI  - Test\nUR  - https://example.com\nL1  - https://pdf.com/paper.pdf\nER  -";
    let entries = parse(ris.to_string()).unwrap();
    assert!(entries[0].url().is_some());
}

// === Exporter Tests ===

#[test]
fn test_format_basic_entry() {
    let entry = RISEntry::new(RISType::JOUR)
        .with_title("Test Article")
        .with_author("Smith, John")
        .with_year(2024);

    let output = format_entry(&entry);

    assert!(output.contains("TY  - JOUR"));
    assert!(output.contains("TI  - Test Article"));
    assert!(output.contains("AU  - Smith, John"));
    assert!(output.contains("PY  - 2024"));
    assert!(output.ends_with("ER  -\n") || output.ends_with("ER  -"));
}

#[test]
fn test_format_preserves_field_order() {
    let entry = RISEntry::new(RISType::JOUR)
        .with_title("Test")
        .with_journal("Nature")
        .with_year(2024);

    let output = format_entry(&entry);
    let ty_pos = output.find("TY  -").unwrap();
    let er_pos = output.find("ER  -").unwrap();

    // TY should come first, ER should come last
    assert!(ty_pos < er_pos);
}

// === Converter Tests (RIS <-> BibTeX) ===

#[test]
fn test_ris_to_bibtex_journal_to_article() {
    use imbib_core::ris::converter::ris_to_bibtex;

    let ris = RISEntry::new(RISType::JOUR)
        .with_title("Test")
        .with_author("Smith, John")
        .with_year(2024)
        .with_journal("Nature");

    let bibtex = ris_to_bibtex(&ris);

    assert_eq!(bibtex.entry_type.to_string().to_lowercase(), "article");
    assert_eq!(bibtex.get_field("title"), Some("Test"));
    assert_eq!(bibtex.get_field("journal"), Some("Nature"));
}

#[test]
fn test_ris_to_bibtex_book() {
    use imbib_core::ris::converter::ris_to_bibtex;

    let ris = RISEntry::new(RISType::BOOK)
        .with_title("The Book")
        .with_author("Author, A")
        .with_year(2020);

    let bibtex = ris_to_bibtex(&ris);
    assert_eq!(bibtex.entry_type.to_string().to_lowercase(), "book");
}

#[test]
fn test_ris_to_bibtex_conference() {
    use imbib_core::ris::converter::ris_to_bibtex;

    let ris = RISEntry::new(RISType::CONF).with_title("Paper").with_year(2024);

    let bibtex = ris_to_bibtex(&ris);
    assert!(
        bibtex.entry_type.to_string().to_lowercase() == "inproceedings"
            || bibtex.entry_type.to_string().to_lowercase() == "conference"
    );
}

#[test]
fn test_bibtex_to_ris_article() {
    use imbib_core::bibtex::{BibTeXEntry, BibTeXEntryType};
    use imbib_core::ris::converter::bibtex_to_ris;

    let mut bibtex = BibTeXEntry::new("Test".into(), BibTeXEntryType::Article);
    bibtex.add_field("title", "Test Article");
    bibtex.add_field("author", "Smith, John");
    bibtex.add_field("year", "2024");

    let ris = bibtex_to_ris(&bibtex);
    assert_eq!(ris.entry_type, RISType::JOUR);
}

#[test]
fn test_roundtrip_ris_bibtex_ris() {
    use imbib_core::ris::converter::{bibtex_to_ris, ris_to_bibtex};

    let original = RISEntry::new(RISType::JOUR)
        .with_title("Roundtrip Test")
        .with_author("Tester, T")
        .with_year(2024)
        .with_doi("10.1234/test");

    let bibtex = ris_to_bibtex(&original);
    let roundtrip = bibtex_to_ris(&bibtex);

    assert_eq!(original.entry_type, roundtrip.entry_type);
    assert_eq!(original.title(), roundtrip.title());
    assert_eq!(original.doi(), roundtrip.doi());
}

// === Fixture Tests ===

#[test]
fn test_parse_sample_fixture() {
    let ris = load_ris_fixture("sample.ris");
    let entries = parse(ris).unwrap();

    assert!(!entries.is_empty());
    assert!(entries[0].title().is_some());
}

#[test]
fn test_parse_multiple_authors_fixture() {
    let ris = load_ris_fixture("multiple_authors.ris");
    let entries = parse(ris).unwrap();

    assert!(!entries.is_empty());
    let authors = entries[0].authors();
    assert!(authors.len() > 1);
}

#[test]
fn test_parse_all_types_fixture() {
    let ris = load_ris_fixture("all_types.ris");
    let entries = parse(ris).unwrap();

    // Should have entries of various types
    let types: Vec<_> = entries.iter().map(|e| &e.entry_type).collect();
    assert!(types.len() > 1);
}
```

**Checkpoint:** `cargo test ris`

---

### Phase 4.4: Deduplication Tests Migration

**Goal**: Port deduplication tests with property-based testing enhancements.

**Source:** `PublicationManagerCore/Tests/PublicationManagerCoreTests/DeduplicationServiceTests.swift`

**Create `tests/deduplication_tests.rs`:**
```rust
//! Deduplication integration tests
//!
//! Ported from Swift DeduplicationServiceTests.swift
//! Enhanced with property-based testing

mod common;

use imbib_core::deduplication::{
    authors_overlap, calculate_publication_similarity, find_duplicates, title_similarity,
    titles_match,
};
use imbib_core::domain::{Author, Identifiers, Publication};
use proptest::prelude::*;

// === Identifier-Based Deduplication ===

#[test]
fn test_deduplicate_by_doi() {
    let pub1 = Publication::new("p1", "article", "Paper A").with_identifiers(Identifiers {
        doi: Some("10.1234/test".into()),
        ..Default::default()
    });
    let pub2 = Publication::new("p2", "article", "Paper B").with_identifiers(Identifiers {
        doi: Some("10.1234/test".into()),
        ..Default::default()
    });

    let result = calculate_publication_similarity(&pub1, &pub2);
    assert!(result.score >= 0.99, "DOI match should give score ~1.0");
    assert!(
        result.reason.to_lowercase().contains("doi"),
        "Reason should mention DOI"
    );
}

#[test]
fn test_deduplicate_by_arxiv_id() {
    let pub1 = Publication::new("p1", "article", "Paper A").with_identifiers(Identifiers {
        arxiv_id: Some("2301.12345".into()),
        ..Default::default()
    });
    let pub2 = Publication::new("p2", "article", "Paper B").with_identifiers(Identifiers {
        arxiv_id: Some("2301.12345".into()),
        ..Default::default()
    });

    let result = calculate_publication_similarity(&pub1, &pub2);
    assert!(result.score >= 0.99);
}

#[test]
fn test_deduplicate_by_bibcode() {
    let pub1 = Publication::new("p1", "article", "Paper A").with_identifiers(Identifiers {
        bibcode: Some("2024ApJ...123..456A".into()),
        ..Default::default()
    });
    let pub2 = Publication::new("p2", "article", "Paper B").with_identifiers(Identifiers {
        bibcode: Some("2024ApJ...123..456A".into()),
        ..Default::default()
    });

    let result = calculate_publication_similarity(&pub1, &pub2);
    assert!(result.score >= 0.99);
}

// === Fuzzy Title Matching ===

#[test]
fn test_fuzzy_match_identical_titles() {
    let title = "Deep Learning for Natural Language Processing";
    let similarity = title_similarity(title, title);
    assert!((similarity - 1.0).abs() < 0.001);
}

#[test]
fn test_fuzzy_match_similar_titles() {
    let title1 = "Deep Learning for Natural Language Processing";
    let title2 = "Deep Learning for NLP";

    let similarity = title_similarity(title1, title2);
    assert!(similarity > 0.5, "Similar titles should have decent similarity");
}

#[test]
fn test_fuzzy_match_different_titles() {
    let title1 = "Deep Learning for Computer Vision";
    let title2 = "Quantum Computing Fundamentals";

    let similarity = title_similarity(title1, title2);
    assert!(similarity < 0.3, "Different titles should have low similarity");
}

#[test]
fn test_titles_match_with_threshold() {
    assert!(titles_match(
        "Machine Learning Basics".into(),
        "Machine Learning Basics".into(),
        0.9
    ));
    assert!(!titles_match(
        "Machine Learning".into(),
        "Deep Learning".into(),
        0.9
    ));
}

// === Author Matching ===

#[test]
fn test_authors_overlap_exact_match() {
    let authors1 = vec![Author::new("Smith, John".into()), Author::new("Doe, Jane".into())];
    let authors2 = vec![Author::new("Smith, John".into()), Author::new("Doe, Jane".into())];

    assert!(authors_overlap(&authors1, &authors2, 0.8));
}

#[test]
fn test_authors_overlap_partial() {
    let authors1 = vec![
        Author::new("Smith, John".into()),
        Author::new("Doe, Jane".into()),
        Author::new("Wilson, Bob".into()),
    ];
    let authors2 = vec![Author::new("Smith, John".into()), Author::new("Brown, Alice".into())];

    // At least one author overlaps
    assert!(authors_overlap(&authors1, &authors2, 0.3));
}

#[test]
fn test_authors_overlap_none() {
    let authors1 = vec![Author::new("Smith, John".into())];
    let authors2 = vec![Author::new("Doe, Jane".into())];

    assert!(!authors_overlap(&authors1, &authors2, 0.5));
}

// === Duplicate Finding ===

#[test]
fn test_find_duplicates_groups_by_doi() {
    let pubs = vec![
        Publication::new("p1", "article", "Paper A").with_identifiers(Identifiers {
            doi: Some("10.1234/a".into()),
            ..Default::default()
        }),
        Publication::new("p2", "article", "Paper B").with_identifiers(Identifiers {
            doi: Some("10.1234/a".into()),
            ..Default::default()
        }),
        Publication::new("p3", "article", "Paper C").with_identifiers(Identifiers {
            doi: Some("10.1234/b".into()),
            ..Default::default()
        }),
    ];

    let groups = find_duplicates(pubs, 0.9);

    // Should have one group with p1 and p2
    assert!(groups.iter().any(|g| g.publication_ids.len() == 2));
}

#[test]
fn test_find_duplicates_no_duplicates() {
    let pubs = vec![
        Publication::new("p1", "article", "Unique Paper 1"),
        Publication::new("p2", "article", "Unique Paper 2"),
        Publication::new("p3", "article", "Unique Paper 3"),
    ];

    let groups = find_duplicates(pubs, 0.9);

    // No groups should have more than 1 publication
    assert!(groups.iter().all(|g| g.publication_ids.len() == 1));
}

// === Property-Based Tests ===

proptest! {
    #[test]
    fn test_title_similarity_symmetric(a in "\\PC{1,50}", b in "\\PC{1,50}") {
        let sim_ab = title_similarity(&a, &b);
        let sim_ba = title_similarity(&b, &a);
        prop_assert!((sim_ab - sim_ba).abs() < 0.001, "Similarity should be symmetric");
    }

    #[test]
    fn test_title_similarity_bounded(a in "\\PC{1,50}", b in "\\PC{1,50}") {
        let sim = title_similarity(&a, &b);
        prop_assert!(sim >= 0.0 && sim <= 1.0, "Similarity should be in [0, 1]");
    }

    #[test]
    fn test_identical_titles_have_similarity_one(title in "[a-zA-Z ]{5,30}") {
        let sim = title_similarity(&title, &title);
        prop_assert!((sim - 1.0).abs() < 0.001, "Identical titles should have similarity 1.0");
    }

    #[test]
    fn test_doi_match_always_high_similarity(
        doi in "10\\.[0-9]{4}/[a-z0-9]{5,10}"
    ) {
        let pub1 = Publication::new("p1", "article", "Title A")
            .with_identifiers(Identifiers { doi: Some(doi.clone()), ..Default::default() });
        let pub2 = Publication::new("p2", "article", "Title B")
            .with_identifiers(Identifiers { doi: Some(doi), ..Default::default() });

        let result = calculate_publication_similarity(&pub1, &pub2);
        prop_assert!(result.score >= 0.99, "DOI match should always be high similarity");
    }
}
```

**Checkpoint:** `cargo test deduplication`

---

### Phase 4.5: Identifier Extraction Tests Migration

**Goal**: Port identifier extraction tests with parameterized testing.

**Sources:**
- `PublicationManagerCore/Tests/PublicationManagerCoreTests/Utilities/IdentifierExtractorTests.swift`
- `PublicationManagerCore/Tests/PublicationManagerCoreTests/DragDrop/IdentifierExtractorTextTests.swift`

**Create `tests/identifier_tests.rs`:**
```rust
//! Identifier extraction integration tests
//!
//! Ported from Swift IdentifierExtractorTests.swift

mod common;

use imbib_core::identifiers::{
    extract_arxiv_ids, extract_bibcodes, extract_dois, extract_isbns, extract_pmids,
    normalize_arxiv_id, normalize_doi,
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
fn test_extract_multiple_dois() {
    let text = "Papers: 10.1234/a and 10.5678/b";
    let dois = extract_dois(text.to_string());
    assert_eq!(dois.len(), 2);
}

#[rstest]
#[case("10.1038/nature12373", "10.1038/nature12373")]
#[case("doi:10.1038/nature12373", "10.1038/nature12373")]
#[case("DOI: 10.1038/nature12373", "10.1038/nature12373")]
#[case("https://doi.org/10.1038/nature12373", "10.1038/nature12373")]
fn test_normalize_doi(#[case] input: &str, #[case] expected: &str) {
    let dois = extract_dois(input.to_string());
    assert!(!dois.is_empty());
    assert_eq!(normalize_doi(&dois[0]), expected);
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
}

#[test]
fn test_extract_arxiv_with_version() {
    let text = "arXiv:2301.12345v3";
    let ids = extract_arxiv_ids(text.to_string());
    assert!(ids.contains(&"2301.12345".to_string()));
}

#[test]
fn test_extract_arxiv_from_url() {
    let text = "https://arxiv.org/abs/2301.12345";
    let ids = extract_arxiv_ids(text.to_string());
    assert!(ids.contains(&"2301.12345".to_string()));
}

#[rstest]
#[case("2301.12345", "2301.12345")]
#[case("arXiv:2301.12345", "2301.12345")]
#[case("ARXIV:2301.12345", "2301.12345")]
#[case("2301.12345v2", "2301.12345")]
#[case("arXiv:2301.12345v3", "2301.12345")]
fn test_normalize_arxiv_id(#[case] input: &str, #[case] expected: &str) {
    assert_eq!(normalize_arxiv_id(input), expected);
}

// === Bibcode Extraction ===

#[test]
fn test_extract_bibcode_astrophysical_journal() {
    let text = "See 2024ApJ...123..456A";
    let bibcodes = extract_bibcodes(text.to_string());
    assert!(bibcodes.contains(&"2024ApJ...123..456A".to_string()));
}

#[test]
fn test_extract_bibcode_from_ads_url() {
    let text = "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456A/abstract";
    let bibcodes = extract_bibcodes(text.to_string());
    assert!(bibcodes.contains(&"2024ApJ...123..456A".to_string()));
}

#[rstest]
#[case(
    "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456A/abstract",
    "2024ApJ...123..456A"
)]
#[case("https://adsabs.harvard.edu/abs/2024ApJ...123..456A", "2024ApJ...123..456A")]
#[case("2024MNRAS.123..456B", "2024MNRAS.123..456B")]
fn test_extract_bibcode_formats(#[case] input: &str, #[case] expected: &str) {
    let bibcodes = extract_bibcodes(input.to_string());
    assert!(
        bibcodes.contains(&expected.to_string()),
        "Expected {} in {:?}",
        expected,
        bibcodes
    );
}

// === PMID Extraction ===

#[test]
fn test_extract_pmid() {
    let text = "PubMed ID: 12345678";
    let pmids = extract_pmids(text.to_string());
    assert!(pmids.contains(&"12345678".to_string()));
}

#[test]
fn test_extract_pmid_from_url() {
    let text = "https://pubmed.ncbi.nlm.nih.gov/12345678/";
    let pmids = extract_pmids(text.to_string());
    assert!(pmids.contains(&"12345678".to_string()));
}

// === ISBN Extraction ===

#[test]
fn test_extract_isbn_10() {
    let text = "ISBN: 0-306-40615-2";
    let isbns = extract_isbns(text.to_string());
    assert!(!isbns.is_empty());
}

#[test]
fn test_extract_isbn_13() {
    let text = "ISBN-13: 978-0-306-40615-7";
    let isbns = extract_isbns(text.to_string());
    assert!(!isbns.is_empty());
}

// === BibTeX Field Extraction ===

#[test]
fn test_extract_from_eprint_field() {
    // Common BibTeX field patterns
    let fields = [
        ("eprint", "2301.12345"),
        ("arxivid", "2301.54321"),
        ("arxiv", "2301.99999"),
    ];

    for (field_name, value) in fields {
        let text = format!("{} = {{{}}}", field_name, value);
        let ids = extract_arxiv_ids(text);
        assert!(
            ids.iter().any(|id| id.contains("2301.")),
            "Should extract from {} field",
            field_name
        );
    }
}

// === Edge Cases ===

#[test]
fn test_extract_from_empty_string() {
    assert!(extract_dois("".to_string()).is_empty());
    assert!(extract_arxiv_ids("".to_string()).is_empty());
    assert!(extract_bibcodes("".to_string()).is_empty());
}

#[test]
fn test_no_false_positives() {
    // Text that looks similar but isn't valid
    let text = "The ratio is 10.5 to 1";
    let dois = extract_dois(text.to_string());
    // Should not extract "10.5" as a DOI (no slash after registrant)
    assert!(dois.is_empty() || !dois.iter().any(|d| d == "10.5"));
}

#[test]
fn test_extract_from_mixed_content() {
    let text = r#"
        Check out arXiv:2301.12345 and DOI:10.1038/nature12373.
        Also see 2024ApJ...123..456A for related work.
        PubMed: 12345678
    "#;

    assert!(!extract_arxiv_ids(text.to_string()).is_empty());
    assert!(!extract_dois(text.to_string()).is_empty());
    assert!(!extract_bibcodes(text.to_string()).is_empty());
    assert!(!extract_pmids(text.to_string()).is_empty());
}
```

**Checkpoint:** `cargo test identifier`

---

### Phase 4.6: Source Plugin Mock Tests

**Goal**: Add tests for source plugin response parsing using mock HTTP responses.

**Create `tests/source_plugin_tests.rs`:**
```rust
//! Source plugin integration tests
//!
//! Tests response parsing without actual network calls

mod common;

use common::fixtures::load_response_fixture;
use imbib_core::sources::{
    ads::ADSSource, arxiv::ArxivSource, crossref::CrossrefSource, pubmed::PubMedSource,
};

// === ADS Tests ===

#[test]
fn test_ads_parse_search_response() {
    let json = load_response_fixture("ads_search.json");
    let results = ADSSource::parse_search_response(&json).unwrap();

    assert!(!results.is_empty());
    // Verify key fields are parsed
    let first = &results[0];
    assert!(!first.title.is_empty());
    assert!(!first.authors.is_empty());
    assert!(first.identifiers.bibcode.is_some());
}

#[test]
fn test_ads_parse_bibtex_export() {
    let json = r#"{"export": "@article{2024ApJ...123..456A,\n  author = {Test Author},\n  title = {Test Title}\n}"}"#;
    let bibtex = ADSSource::parse_bibtex_export(json).unwrap();
    assert!(bibtex.contains("@article"));
}

#[test]
fn test_ads_build_pdf_links() {
    use imbib_core::sources::ads::build_pdf_links;

    let esources = vec!["EPRINT_PDF".to_string(), "PUB_PDF".to_string()];
    let links =
        build_pdf_links(&esources, Some("10.1234/test"), Some("2301.12345"), "2024ApJ...");

    assert!(links.iter().any(|l| l.url.contains("arxiv.org")));
}

// === arXiv Tests ===

#[test]
fn test_arxiv_parse_atom_feed() {
    let xml = load_response_fixture("arxiv_search.xml");
    let results = ArxivSource::parse_atom_feed(&xml).unwrap();

    assert!(!results.is_empty());
    let first = &results[0];
    assert!(!first.title.is_empty());
    assert!(first.identifiers.arxiv_id.is_some());
}

#[test]
fn test_arxiv_extract_id_from_url() {
    let tests = [
        ("https://arxiv.org/abs/2301.12345", "2301.12345"),
        ("https://arxiv.org/pdf/2301.12345.pdf", "2301.12345"),
        ("http://arxiv.org/abs/hep-th/9901001", "hep-th/9901001"),
    ];

    for (url, expected) in tests {
        let id = ArxivSource::extract_id_from_url(url);
        assert_eq!(id, Some(expected.to_string()), "Failed for {}", url);
    }
}

// === Crossref Tests ===

#[test]
fn test_crossref_parse_work_response() {
    let json = load_response_fixture("crossref_work.json");
    let result = CrossrefSource::parse_work_response(&json).unwrap();

    assert!(!result.title.is_empty());
    assert!(result.identifiers.doi.is_some());
}

#[test]
fn test_crossref_parse_search_response() {
    let json = load_response_fixture("crossref_search.json");
    let results = CrossrefSource::parse_search_response(&json).unwrap();

    assert!(!results.is_empty());
}

// === PubMed Tests ===

#[test]
fn test_pubmed_parse_efetch_response() {
    let xml = load_response_fixture("pubmed_efetch.xml");
    let results = PubMedSource::parse_efetch_response(&xml).unwrap();

    assert!(!results.is_empty());
    let first = &results[0];
    assert!(!first.title.is_empty());
    assert!(first.identifiers.pmid.is_some());
}

#[test]
fn test_pubmed_parse_esearch_response() {
    let xml = r#"<?xml version="1.0"?>
<eSearchResult>
    <IdList>
        <Id>12345678</Id>
        <Id>23456789</Id>
    </IdList>
</eSearchResult>"#;

    let ids = PubMedSource::parse_esearch_response(xml).unwrap();
    assert_eq!(ids.len(), 2);
    assert!(ids.contains(&"12345678".to_string()));
}
```

**Create mock response fixtures** by capturing real API responses:
- `test_fixtures/responses/ads_search.json`
- `test_fixtures/responses/arxiv_search.xml`
- `test_fixtures/responses/crossref_work.json`
- `test_fixtures/responses/crossref_search.json`
- `test_fixtures/responses/pubmed_efetch.xml`

**Checkpoint:** `cargo test source`

---

### Phase 4.7: Merge Logic Tests

**Goal**: Port pure merge/conflict logic tests (not Core Data dependent).

**Create `tests/merge_tests.rs`:**
```rust
//! Field merge logic tests
//!
//! Ported from Swift FieldMergerTests.swift (pure logic portions)

use imbib_core::domain::Identifiers;
use imbib_core::merge::{
    merge_field_by_timestamp, merge_identifiers, merge_tags_union, MergeStrategy,
};

// === Scalar Field Merging ===

#[test]
fn test_merge_scalar_newer_wins() {
    let local = "Local Title";
    let remote = "Remote Title";

    // Remote is newer
    let result = merge_field_by_timestamp(local, remote, 1000, 2000);
    assert_eq!(result, "Remote Title");

    // Local is newer
    let result = merge_field_by_timestamp(local, remote, 2000, 1000);
    assert_eq!(result, "Local Title");
}

#[test]
fn test_merge_scalar_same_timestamp() {
    let local = "Local";
    let remote = "Remote";

    // When timestamps equal, prefer the longer/more complete value
    let result = merge_field_by_timestamp(local, remote, 1000, 1000);
    // Implementation-dependent: could be either
    assert!(result == local || result == remote);
}

#[test]
fn test_merge_scalar_with_empty() {
    let local = "Value";
    let remote = "";

    // Non-empty should win regardless of timestamp
    let result = merge_field_by_timestamp(local, remote, 1000, 2000);
    assert_eq!(result, "Value");
}

// === Tag Merging ===

#[test]
fn test_merge_tags_union_no_overlap() {
    let local = vec!["tag1".to_string(), "tag2".to_string()];
    let remote = vec!["tag3".to_string(), "tag4".to_string()];

    let merged = merge_tags_union(&local, &remote);

    assert_eq!(merged.len(), 4);
    assert!(merged.contains(&"tag1".to_string()));
    assert!(merged.contains(&"tag3".to_string()));
}

#[test]
fn test_merge_tags_union_with_overlap() {
    let local = vec!["tag1".to_string(), "tag2".to_string()];
    let remote = vec!["tag2".to_string(), "tag3".to_string()];

    let merged = merge_tags_union(&local, &remote);

    assert_eq!(merged.len(), 3);
    // tag2 should only appear once
    assert_eq!(merged.iter().filter(|t| *t == "tag2").count(), 1);
}

#[test]
fn test_merge_tags_empty() {
    let local: Vec<String> = vec![];
    let remote = vec!["tag1".to_string()];

    let merged = merge_tags_union(&local, &remote);
    assert_eq!(merged, vec!["tag1".to_string()]);
}

// === Identifier Merging ===

#[test]
fn test_merge_identifiers_prefers_complete() {
    let local = Identifiers {
        doi: Some("10.1234/test".into()),
        arxiv_id: None,
        bibcode: None,
        pmid: None,
        isbn: None,
    };
    let remote = Identifiers {
        doi: Some("10.1234/test".into()),
        arxiv_id: Some("2301.12345".into()),
        bibcode: None,
        pmid: None,
        isbn: None,
    };

    let merged = merge_identifiers(&local, &remote);

    assert_eq!(merged.doi, Some("10.1234/test".into()));
    assert_eq!(merged.arxiv_id, Some("2301.12345".into()));
}

#[test]
fn test_merge_identifiers_combines_all() {
    let local = Identifiers {
        doi: Some("10.1234/test".into()),
        arxiv_id: None,
        bibcode: Some("2024ApJ...".into()),
        pmid: None,
        isbn: None,
    };
    let remote = Identifiers {
        doi: None,
        arxiv_id: Some("2301.12345".into()),
        bibcode: None,
        pmid: Some("12345678".into()),
        isbn: None,
    };

    let merged = merge_identifiers(&local, &remote);

    assert!(merged.doi.is_some());
    assert!(merged.arxiv_id.is_some());
    assert!(merged.bibcode.is_some());
    assert!(merged.pmid.is_some());
}

#[test]
fn test_merge_identifiers_conflicting_doi() {
    let local = Identifiers {
        doi: Some("10.1234/local".into()),
        ..Default::default()
    };
    let remote = Identifiers {
        doi: Some("10.1234/remote".into()),
        ..Default::default()
    };

    let merged = merge_identifiers(&local, &remote);

    // When DOIs conflict, implementation decides (could flag for review)
    assert!(merged.doi.is_some());
}

// === Merge Strategy ===

#[test]
fn test_merge_strategy_local_wins() {
    let strategy = MergeStrategy::LocalWins;
    let result = strategy.resolve("local_value", "remote_value");
    assert_eq!(result, "local_value");
}

#[test]
fn test_merge_strategy_remote_wins() {
    let strategy = MergeStrategy::RemoteWins;
    let result = strategy.resolve("local_value", "remote_value");
    assert_eq!(result, "remote_value");
}

#[test]
fn test_merge_strategy_newest_wins() {
    let strategy = MergeStrategy::NewestWins;
    // With timestamps
    let result = strategy.resolve_with_timestamps("local", 1000, "remote", 2000);
    assert_eq!(result, "remote");
}
```

**Checkpoint:** `cargo test merge`

---

### Phase 4.8: Snapshot Tests

**Goal**: Add snapshot tests for format output stability.

**Create `tests/snapshot_tests.rs`:**
```rust
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

    assert_snapshot!(format_entry(&entry));
}

#[test]
fn test_bibtex_book_format() {
    let mut entry = BibTeXEntry::new("Knuth1997".into(), BibTeXEntryType::Book);
    entry.add_field("author", "Donald E. Knuth");
    entry.add_field("title", "The Art of Computer Programming");
    entry.add_field("publisher", "Addison-Wesley");
    entry.add_field("year", "1997");
    entry.add_field("edition", "3rd");

    assert_snapshot!(format_entry(&entry));
}

#[test]
fn test_bibtex_inproceedings_format() {
    let mut entry = BibTeXEntry::new("Turing1950".into(), BibTeXEntryType::InProceedings);
    entry.add_field("author", "Alan M. Turing");
    entry.add_field("title", "Computing Machinery and Intelligence");
    entry.add_field("booktitle", "Mind");
    entry.add_field("year", "1950");
    entry.add_field("pages", "433--460");

    assert_snapshot!(format_entry(&entry));
}

#[test]
fn test_bibtex_with_special_chars() {
    let mut entry = BibTeXEntry::new("Test".into(), BibTeXEntryType::Article);
    entry.add_field("author", "Müller, Hans");
    entry.add_field("title", "Cost is $100 & worth it");
    entry.add_field("year", "2024");

    assert_snapshot!(format_entry(&entry));
}

// === RIS Formatting ===

#[test]
fn test_ris_journal_format() {
    let entry = RISEntry::new(RISType::JOUR)
        .with_title("Test Article")
        .with_author("Smith, John")
        .with_author("Doe, Jane")
        .with_year(2024)
        .with_journal("Nature")
        .with_volume("123")
        .with_pages("456-789")
        .with_doi("10.1038/test");

    assert_snapshot!(format_ris(&entry));
}

#[test]
fn test_ris_book_format() {
    let entry = RISEntry::new(RISType::BOOK)
        .with_title("Important Book")
        .with_author("Author, A")
        .with_year(2020)
        .with_publisher("Publisher Inc");

    assert_snapshot!(format_ris(&entry));
}

#[test]
fn test_ris_with_abstract() {
    let entry = RISEntry::new(RISType::JOUR)
        .with_title("Paper with Abstract")
        .with_author("Researcher, R")
        .with_year(2024)
        .with_abstract("This is a long abstract that describes the paper in detail.");

    assert_snapshot!(format_ris(&entry));
}
```

**Run to generate snapshots:**
```bash
cargo insta test
cargo insta review  # Review and accept snapshots
```

**Checkpoint:** `cargo test snapshot`

---

### Phase 4.9: Performance Benchmarks

**Goal**: Add benchmarks for parsing performance regression detection.

**Create `benches/parsing_bench.rs`:**
```rust
//! Parsing performance benchmarks

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use imbib_core::bibtex::parse as parse_bibtex;
use imbib_core::ris::parse as parse_ris;

fn load_fixture(name: &str) -> String {
    std::fs::read_to_string(format!("test_fixtures/{}", name))
        .unwrap_or_else(|_| panic!("Failed to load fixture: {}", name))
}

fn bibtex_benchmarks(c: &mut Criterion) {
    let simple = load_fixture("bibtex/simple.bib");
    let thesis = load_fixture("bibtex/thesis_ref.bib");

    c.bench_function("bibtex_parse_simple_3_entries", |b| {
        b.iter(|| parse_bibtex(black_box(simple.clone())))
    });

    c.bench_function("bibtex_parse_thesis_377_entries", |b| {
        b.iter(|| parse_bibtex(black_box(thesis.clone())))
    });
}

fn ris_benchmarks(c: &mut Criterion) {
    let sample = load_fixture("ris/sample.ris");

    c.bench_function("ris_parse_sample", |b| {
        b.iter(|| parse_ris(black_box(sample.clone())))
    });
}

fn deduplication_benchmarks(c: &mut Criterion) {
    use imbib_core::deduplication::title_similarity;

    let title1 = "Deep Learning for Natural Language Processing: A Comprehensive Survey";
    let title2 = "Deep Learning in NLP: A Survey";

    c.bench_function("title_similarity", |b| {
        b.iter(|| title_similarity(black_box(title1), black_box(title2)))
    });
}

criterion_group!(benches, bibtex_benchmarks, ris_benchmarks, deduplication_benchmarks);
criterion_main!(benches);
```

**Run:**
```bash
cargo bench
```

**Checkpoint:** Benchmarks complete

---

### Phase 4.10: Swift Test Cleanup

**Goal**: Update Swift tests and create bridge verification tests.

**Keep in Swift (do not migrate):**
- `Tests/PublicationManagerCoreTests/ViewModels/*Tests.swift`
- `Tests/PublicationManagerCoreTests/Performance/*Tests.swift`
- `Tests/PublicationManagerCoreTests/Automation/*Tests.swift`
- `Tests/PublicationManagerCoreTests/Credentials/*Tests.swift`
- `Tests/PublicationManagerCoreTests/PDFManager*Tests.swift`
- `Tests/PublicationManagerCoreTests/Sync/ConflictDetectorTests.swift` (Core Data parts)
- `Tests/PublicationManagerCoreTests/Sync/FieldMergerTests.swift` (Core Data parts)
- All UITests

**Create `RustBridgeVerificationTests.swift`:**
```swift
import XCTest
@testable import PublicationManagerCore
import ImbibRustCore

/// Verifies Swift wrappers produce identical results to Rust
final class RustBridgeVerificationTests: XCTestCase {

    func testBibTeXParserConsistency() throws {
        let input = """
        @article{Test,
            author = {John Smith},
            title = {Test Title},
            year = {2024}
        }
        """

        // Parse with Rust via bridge
        let result = try ImbibRustCore.parseBibTeX(input: input)

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].citeKey, "Test")
    }

    func testRISParserConsistency() throws {
        let input = "TY  - JOUR\nTI  - Test\nER  -"

        let result = try ImbibRustCore.parseRIS(input: input)

        XCTAssertEqual(result.count, 1)
    }

    func testDeduplicationConsistency() async throws {
        // Create test publications
        let pub1 = Publication(citeKey: "p1", title: "Same Title")
        let pub2 = Publication(citeKey: "p2", title: "Same Title")

        // Compare Swift and Rust similarity calculations
        let rustSim = ImbibRustCore.calculateTitleSimilarity(
            pub1.title ?? "",
            pub2.title ?? ""
        )

        XCTAssertGreaterThan(rustSim, 0.99)
    }
}
```

**Mark migrated tests with comments:**
```swift
// BibTeXParserTests.swift
// NOTE: Core logic tests migrated to Rust (imbib-core/tests/bibtex_tests.rs)
// This file retained for Swift-specific edge cases and bridge verification
```

---

## Test Migration Summary

| Phase | Focus | Tests Migrated |
|-------|-------|----------------|
| 4.1 | Infrastructure | 0 (setup) |
| 4.2 | BibTeX Parser | ~35 |
| 4.3 | RIS Format | ~125 |
| 4.4 | Deduplication | ~15 + proptest |
| 4.5 | Identifiers | ~60 |
| 4.6 | Source Plugins | ~20 |
| 4.7 | Merge Logic | ~15 |
| 4.8 | Snapshots | ~10 |
| 4.9 | Benchmarks | N/A |
| 4.10 | Swift Cleanup | N/A |

**Total:** ~280 tests migrated + ~70 new tests = ~350 Rust tests

---

## Final Verification

```bash
# 1. Run all Rust tests
cd imbib-core
cargo test --all-features

# 2. Run benchmarks
cargo bench

# 3. Generate coverage report
cargo tarpaulin --out Html

# 4. Run remaining Swift tests
cd ../PublicationManagerCore
swift test

# 5. Build apps to verify integration
cd ..
xcodebuild -scheme imbib -configuration Debug build
xcodebuild -scheme "imbib iOS" -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 15' build
```

After all phases complete:
- Rust has ~350 comprehensive tests
- Swift retains ~150 platform-specific tests
- Property-based tests catch edge cases
- Snapshot tests prevent format regressions
- Benchmarks detect performance regressions
