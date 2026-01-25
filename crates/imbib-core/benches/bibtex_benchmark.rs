//! Parsing and processing benchmarks

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use imbib_core::bibtex;
use imbib_core::deduplication::{calculate_similarity, titles_match};
use imbib_core::identifiers::{extract_all, extract_dois};
use imbib_core::ris;
use std::path::PathBuf;

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("test_fixtures")
        .join(name)
}

#[allow(dead_code)]
fn load_fixture(name: &str) -> String {
    std::fs::read_to_string(fixture_path(name))
        .unwrap_or_else(|_| panic!("Failed to load fixture: {}", name))
}

fn generate_many_bibtex_entries(count: usize) -> String {
    let mut result = String::new();
    for i in 0..count {
        result.push_str(&format!(
            r#"
@article{{Entry{i},
    author = {{Author {i}}},
    title = {{Title of Paper Number {i}}},
    year = {{2024}},
    journal = {{Journal {}}},
    volume = {{{}}},
    pages = {{1--10}},
    doi = {{10.1234/test.{i}}}
}}
"#,
            i % 10,
            i % 50
        ));
    }
    result
}

fn generate_many_ris_entries(count: usize) -> String {
    let mut result = String::new();
    for i in 0..count {
        result.push_str(&format!(
            r#"TY  - JOUR
AU  - Author, {i}
TI  - Title of Paper Number {i}
JF  - Journal {journal}
PY  - 2024
VL  - {volume}
SP  - 1
EP  - 10
DO  - 10.1234/test.{i}
ER  -

"#,
            journal = i % 10,
            volume = i % 50
        ));
    }
    result
}

// === BibTeX Benchmarks ===

fn bench_bibtex_parse_single(c: &mut Criterion) {
    let simple = r#"@article{Smith2024,
    author = {John Smith},
    title = {A Great Paper},
    year = {2024},
    journal = {Nature}
}"#;

    let complex = r#"@article{Einstein1905,
    author = {Albert Einstein},
    title = {Zur Elektrodynamik bewegter K{\"o}rper},
    journal = {Annalen der Physik},
    volume = {322},
    number = {10},
    pages = {891--921},
    year = {1905},
    doi = {10.1002/andp.19053221004},
    abstract = {The paper that introduced special relativity.}
}"#;

    let mut group = c.benchmark_group("bibtex_parse_single");
    group.bench_function("simple", |b| {
        b.iter(|| bibtex::parse(black_box(simple.to_string())))
    });
    group.bench_function("complex", |b| {
        b.iter(|| bibtex::parse(black_box(complex.to_string())))
    });
    group.finish();
}

fn bench_bibtex_parse_many(c: &mut Criterion) {
    let mut group = c.benchmark_group("bibtex_parse_many");

    for count in [10, 100, 1000] {
        let content = generate_many_bibtex_entries(count);
        group.bench_with_input(
            BenchmarkId::from_parameter(count),
            &content,
            |b, content| b.iter(|| bibtex::parse(black_box(content.clone()))),
        );
    }
    group.finish();
}

fn bench_bibtex_parse_fixtures(c: &mut Criterion) {
    let mut group = c.benchmark_group("bibtex_parse_fixtures");

    // Try to load fixtures, skip if not available
    if let Ok(simple) = std::fs::read_to_string(fixture_path("bibtex/simple.bib")) {
        group.bench_function("simple_fixture", |b| {
            b.iter(|| bibtex::parse(black_box(simple.clone())))
        });
    }

    if let Ok(thesis) = std::fs::read_to_string(fixture_path("bibtex/thesis_ref.bib")) {
        group.bench_function("thesis_fixture", |b| {
            b.iter(|| bibtex::parse(black_box(thesis.clone())))
        });
    }

    group.finish();
}

fn bench_bibtex_format(c: &mut Criterion) {
    let input = generate_many_bibtex_entries(100);
    let parsed = bibtex::parse(input).unwrap();

    c.bench_function("bibtex_format_100_entries", |b| {
        b.iter(|| {
            for entry in &parsed.entries {
                bibtex::format_entry(black_box(entry.clone()));
            }
        })
    });
}

// === RIS Benchmarks ===

fn bench_ris_parse_single(c: &mut Criterion) {
    let simple = r#"TY  - JOUR
AU  - Smith, John
TI  - A Great Paper
JF  - Nature
PY  - 2024
ER  -"#;

    let complex = r#"TY  - JOUR
AU  - Einstein, Albert
TI  - On the Electrodynamics of Moving Bodies
JF  - Annalen der Physik
PY  - 1905
VL  - 322
IS  - 10
SP  - 891
EP  - 921
DO  - 10.1002/andp.19053221004
AB  - The paper that introduced special relativity.
KW  - relativity
KW  - physics
ER  -"#;

    let mut group = c.benchmark_group("ris_parse_single");
    group.bench_function("simple", |b| {
        b.iter(|| ris::parse(black_box(simple.to_string())))
    });
    group.bench_function("complex", |b| {
        b.iter(|| ris::parse(black_box(complex.to_string())))
    });
    group.finish();
}

fn bench_ris_parse_many(c: &mut Criterion) {
    let mut group = c.benchmark_group("ris_parse_many");

    for count in [10, 100, 1000] {
        let content = generate_many_ris_entries(count);
        group.bench_with_input(
            BenchmarkId::from_parameter(count),
            &content,
            |b, content| b.iter(|| ris::parse(black_box(content.clone()))),
        );
    }
    group.finish();
}

fn bench_ris_parse_fixtures(c: &mut Criterion) {
    let mut group = c.benchmark_group("ris_parse_fixtures");

    if let Ok(sample) = std::fs::read_to_string(fixture_path("ris/sample.ris")) {
        group.bench_function("sample_fixture", |b| {
            b.iter(|| ris::parse(black_box(sample.clone())))
        });
    }

    if let Ok(multiple) = std::fs::read_to_string(fixture_path("ris/multiple_authors.ris")) {
        group.bench_function("multiple_authors_fixture", |b| {
            b.iter(|| ris::parse(black_box(multiple.clone())))
        });
    }

    group.finish();
}

// === Deduplication Benchmarks ===

fn bench_title_similarity(c: &mut Criterion) {
    let title1 = "Deep Learning for Natural Language Processing: A Comprehensive Survey";
    let title2 = "Deep Learning in NLP: A Survey";

    c.bench_function("title_similarity", |b| {
        b.iter(|| {
            titles_match(
                black_box(title1.to_string()),
                black_box(title2.to_string()),
                0.5,
            )
        })
    });
}

fn bench_entry_similarity(c: &mut Criterion) {
    let mut entry1 =
        bibtex::BibTeXEntry::new("Test1".to_string(), bibtex::BibTeXEntryType::Article);
    entry1.add_field("title", "Deep Learning for Natural Language Processing");
    entry1.add_field("author", "Smith, John and Doe, Jane");
    entry1.add_field("year", "2024");
    entry1.add_field("journal", "Nature");

    let mut entry2 =
        bibtex::BibTeXEntry::new("Test2".to_string(), bibtex::BibTeXEntryType::Article);
    entry2.add_field("title", "Deep Learning for NLP");
    entry2.add_field("author", "J. Smith and J. Doe");
    entry2.add_field("year", "2024");
    entry2.add_field("journal", "Science");

    c.bench_function("entry_similarity", |b| {
        b.iter(|| calculate_similarity(black_box(entry1.clone()), black_box(entry2.clone())))
    });
}

// === Identifier Extraction Benchmarks ===

fn bench_extract_dois(c: &mut Criterion) {
    let text = r#"
        Check out these papers:
        - 10.1038/nature12373 (Nature)
        - doi:10.1126/science.1234567 (Science)
        - https://doi.org/10.1000/test (Test)
        And many more at our library.
    "#;

    c.bench_function("extract_dois", |b| {
        b.iter(|| extract_dois(black_box(text.to_string())))
    });
}

fn bench_extract_all_identifiers(c: &mut Criterion) {
    let text = r#"
        Paper 1: DOI: 10.1038/nature12373, arXiv: 2301.12345
        Paper 2: ISBN: 978-0-321-12521-7
        Paper 3: https://doi.org/10.1126/science.1234567
        Paper 4: arXiv:1905.07890v2
    "#;

    c.bench_function("extract_all_identifiers", |b| {
        b.iter(|| extract_all(black_box(text.to_string())))
    });
}

fn bench_extract_from_large_text(c: &mut Criterion) {
    let mut text = String::new();
    for i in 0..100 {
        text.push_str(&format!(
            "Paper {} has DOI 10.1234/paper{} and arXiv:{:04}.{:05}. ",
            i,
            i,
            i % 24,
            i
        ));
    }

    c.bench_function("extract_from_large_text", |b| {
        b.iter(|| extract_all(black_box(text.clone())))
    });
}

criterion_group!(
    benches,
    bench_bibtex_parse_single,
    bench_bibtex_parse_many,
    bench_bibtex_parse_fixtures,
    bench_bibtex_format,
    bench_ris_parse_single,
    bench_ris_parse_many,
    bench_ris_parse_fixtures,
    bench_title_similarity,
    bench_entry_similarity,
    bench_extract_dois,
    bench_extract_all_identifiers,
    bench_extract_from_large_text,
);
criterion_main!(benches);
