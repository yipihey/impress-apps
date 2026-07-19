//! Property-based tests for BibTeX round-trip fidelity (ADR-002)
//!
//! Encodes the load-bearing invariants of the parser + formatter pair:
//! 1. parse -> format -> parse is a fixpoint (cite key, entry type, fields)
//! 2. format is deterministic and byte-stable under re-parsing
//! 3. The parser is total: arbitrary input never panics
//! 4. Field VALUES survive round-trips exactly, including pathological
//!    content (braces, escapes, math, unicode, @, newlines)

use im_bibtex::{
    decode_latex, escape_value, expand_journal_macro, format_complete, format_entries,
    format_entry, parse, parse_entry, BibTeXEntry, BibTeXEntryType,
};
use proptest::prelude::*;

// === Generators ===

/// All canonical entry types except Unknown (Unknown formats as "misc",
/// so it is not expected to survive a round-trip as Unknown).
fn entry_type_strategy() -> impl Strategy<Value = BibTeXEntryType> {
    prop_oneof![
        Just(BibTeXEntryType::Article),
        Just(BibTeXEntryType::Book),
        Just(BibTeXEntryType::Booklet),
        Just(BibTeXEntryType::InBook),
        Just(BibTeXEntryType::InCollection),
        Just(BibTeXEntryType::InProceedings),
        Just(BibTeXEntryType::Manual),
        Just(BibTeXEntryType::MastersThesis),
        Just(BibTeXEntryType::Misc),
        Just(BibTeXEntryType::PhdThesis),
        Just(BibTeXEntryType::Proceedings),
        Just(BibTeXEntryType::TechReport),
        Just(BibTeXEntryType::Unpublished),
        Just(BibTeXEntryType::Online),
        Just(BibTeXEntryType::Software),
        Just(BibTeXEntryType::Dataset),
    ]
}

/// Cite keys the parser accepts: non-whitespace, no comma or braces.
/// Includes ADS-style keys with '&', ':' and '.' (e.g. "2024A&A...686A.276A").
fn cite_key_strategy() -> impl Strategy<Value = String> {
    "[A-Za-z0-9][A-Za-z0-9&:./_+-]{0,19}"
}

/// Field keys the parser accepts: ASCII alphanumeric plus '_' and '-'.
fn field_key_strategy() -> impl Strategy<Value = String> {
    "[a-zA-Z][a-zA-Z0-9_-]{0,14}"
}

/// Fragments of "structurally valid" field values: balanced braces,
/// backslash escapes always followed by a character, plus deliberately
/// nasty content (math, unicode, @, %, #, quotes, newlines).
fn value_fragment() -> impl Strategy<Value = String> {
    prop_oneof![
        // Plain printable ASCII words (no braces/backslash)
        "[A-Za-z0-9 .,;:!?'()<>*+=|~^-]{1,12}".prop_map(|s| s),
        Just("Müller-Straße".to_string()),
        Just("Λαμβδα λogic".to_string()),
        Just("советская наука".to_string()),
        Just("量子力学".to_string()),
        Just("🚀 emoji".to_string()),
        Just("$E = mc^2$".to_string()),
        Just("$\\alpha_{ij}^2$".to_string()),
        Just("someone@example.org".to_string()),
        Just("50\\% of \\$100 \\& more".to_string()),
        Just("{LaTeX}".to_string()),
        Just("A {B}ook about {Nested {Deep {Braces}}}".to_string()),
        Just("line one\nline two".to_string()),
        Just("tab\there".to_string()),
        Just("Schr\\\"odinger".to_string()),
        Just("\\{literal braces\\}".to_string()),
        Just("\"double quoted\"".to_string()),
        Just("hash # concat".to_string()),
        Just("comma, and = equals".to_string()),
    ]
}

/// A structurally valid field value: concatenation of 0..5 fragments.
fn field_value_strategy() -> impl Strategy<Value = String> {
    prop::collection::vec(value_fragment(), 0..5).prop_map(|v| v.concat())
}

prop_compose! {
    fn arb_entry()(
        cite_key in cite_key_strategy(),
        entry_type in entry_type_strategy(),
        fields in prop::collection::vec((field_key_strategy(), field_value_strategy()), 0..8),
    ) -> BibTeXEntry {
        let mut entry = BibTeXEntry::new(cite_key, entry_type);
        for (key, value) in fields {
            entry.add_field(key, value);
        }
        entry
    }
}

/// Extract (key, value) pairs for comparison (raw_bibtex differs by design).
fn field_pairs(entry: &BibTeXEntry) -> Vec<(String, String)> {
    entry
        .fields
        .iter()
        .map(|f| (f.key.clone(), f.value.clone()))
        .collect()
}

// === Property 1: parse -> format -> parse fixpoint ===

proptest! {
    #[test]
    fn prop_format_then_parse_preserves_entry(entry in arb_entry()) {
        let formatted = format_entry(entry.clone());
        let reparsed = parse_entry(formatted.clone());
        prop_assert!(
            reparsed.is_ok(),
            "format_entry produced unparseable BibTeX:\n{}",
            formatted
        );
        let reparsed = reparsed.unwrap();
        prop_assert_eq!(&reparsed.cite_key, &entry.cite_key);
        prop_assert_eq!(&reparsed.entry_type, &entry.entry_type);
        prop_assert_eq!(field_pairs(&reparsed), field_pairs(&entry));
    }

    // === Property 2: format is deterministic and byte-stable ===

    #[test]
    fn prop_format_deterministic_and_byte_stable(entry in arb_entry()) {
        let first = format_entry(entry.clone());
        let second = format_entry(entry.clone());
        prop_assert_eq!(&first, &second, "format_entry is not deterministic");

        let reparsed = parse_entry(first.clone()).expect("first format must parse");
        let third = format_entry(reparsed);
        prop_assert_eq!(third, first, "format(parse(format(e))) != format(e)");
    }

    // === Property 1b: multi-entry round-trip preserves order and content ===

    #[test]
    fn prop_multi_entry_roundtrip(entries in prop::collection::vec(arb_entry(), 0..4)) {
        let formatted = format_entries(entries.clone());
        let result = parse(formatted.clone()).expect("parse must not error");
        prop_assert_eq!(
            result.errors.len(), 0,
            "parse reported errors on formatter output:\n{}", formatted
        );
        prop_assert_eq!(result.entries.len(), entries.len());
        for (parsed, original) in result.entries.iter().zip(entries.iter()) {
            prop_assert_eq!(&parsed.cite_key, &original.cite_key);
            prop_assert_eq!(&parsed.entry_type, &original.entry_type);
            prop_assert_eq!(field_pairs(parsed), field_pairs(original));
        }
    }

    // === Property 3: parser totality (no panic on arbitrary input) ===

    #[test]
    fn prop_parse_total_on_arbitrary_unicode(input in any::<String>()) {
        let _ = parse(input.clone());
        let _ = parse_entry(input);
    }

    #[test]
    fn prop_parse_total_on_bibtex_soup(
        input in proptest::string::string_regex(
            "[@{}\"=,#\\\\%$ \\n\\r\\tabcXYZ019üé中]{0,200}"
        ).unwrap()
    ) {
        let _ = parse(input.clone());
        let _ = parse_entry(input);
    }

    #[test]
    fn prop_decoders_total_on_arbitrary_input(input in any::<String>()) {
        let _ = decode_latex(input.clone());
        let _ = expand_journal_macro(input.clone());
        let _ = escape_value(&input);
    }

    // === Property 4: quoted-value fidelity ===

    // Printable ASCII (no quote, backslash, or braces) survives quoted parsing.
    #[test]
    fn prop_quoted_ascii_values_parse_exactly(
        value in "[ !#-\\[\\]-~&&[^\"\\\\{}]]{0,20}"
    ) {
        let input = format!("@article{{key,\n    title = \"{}\",\n}}", value);
        let entry = parse_entry(input).expect("quoted ASCII entry must parse");
        prop_assert_eq!(entry.get_field("title"), Some(value.as_str()));
    }

    // Non-ASCII content inside quoted values must survive parsing unchanged.
    #[test]
    fn prop_quoted_unicode_values_parse_exactly(
        value in "[A-Za-zÀ-ÖØ-öø-ÿΑ-Ωα-ωА-Яа-я ]{1,16}"
    ) {
        let input = format!("@article{{key,\n    title = \"{}\",\n}}", value);
        let entry = parse_entry(input).expect("quoted unicode entry must parse");
        prop_assert_eq!(entry.get_field("title"), Some(value.as_str()));
    }

    // Braced values are the formatter's canonical delimiter — they must
    // preserve arbitrary unicode exactly.
    #[test]
    fn prop_braced_unicode_values_parse_exactly(
        value in "[A-Za-zÀ-ÖØ-öø-ÿΑ-Ωα-ωА-Яа-я 中文🚀]{0,16}"
    ) {
        let input = format!("@article{{key,\n    title = {{{}}},\n}}", value);
        let entry = parse_entry(input).expect("braced unicode entry must parse");
        prop_assert_eq!(entry.get_field("title"), Some(value.as_str()));
    }

    // === format_complete: strings/preambles/entries survive a full-file round-trip ===

    #[test]
    fn prop_format_complete_roundtrip_entries(
        entries in prop::collection::vec(arb_entry(), 0..3),
        preamble in "[A-Za-z0-9 ]{0,20}",
    ) {
        let text = format_complete(&[], &[preamble.clone()], &entries);
        let result = parse(text.clone()).expect("parse must not error");
        prop_assert_eq!(result.errors.len(), 0, "errors parsing:\n{}", text);
        prop_assert_eq!(result.preambles.len(), 1);
        prop_assert_eq!(&result.preambles[0], &preamble);
        prop_assert_eq!(result.entries.len(), entries.len());
        for (parsed, original) in result.entries.iter().zip(entries.iter()) {
            prop_assert_eq!(field_pairs(parsed), field_pairs(original));
        }
    }
}

// === Minimized regression tripwires (hand-reduced from property failures) ===

/// Minimized counterexample for `prop_quoted_unicode_values_parse_exactly`.
/// The parser used to read quoted values byte-by-byte and cast each byte to
/// `char`, decoding multi-byte UTF-8 sequences as Latin-1 mojibake.
#[test]
fn regression_quoted_value_utf8_mojibake() {
    let input = "@article{k,\n    title = \"ü\",\n}".to_string();
    let entry = parse_entry(input).expect("entry must parse");
    assert_eq!(entry.get_field("title"), Some("ü"));
}

/// Control for the bug above: the identical value in braces is preserved.
#[test]
fn regression_braced_value_utf8_preserved() {
    let input = "@article{k,\n    title = {ü},\n}".to_string();
    let entry = parse_entry(input).expect("entry must parse");
    assert_eq!(entry.get_field("title"), Some("ü"));
}

/// Tricky-content round-trips that must keep working (pinned exact values).
#[test]
fn regression_tricky_values_roundtrip_exactly() {
    let tricky = [
        "A {B}ook about {LaTeX}",
        "$E = mc^2$ and $\\alpha$",
        "email@example.org and @misc inside",
        "50\\% of \\$100 \\& more\\_stuff",
        "line one\nline two\nline three",
        "Schr\\\"odinger and {\\'e}clair",
        "\\{literal\\}",
        "quoted \"inside\" value",
        "trailing spaces   ",
        "   leading spaces",
        "",
        "0042",
        "中文 колонка ヴェイパー",
    ];
    let mut entry = BibTeXEntry::new("Key2024".to_string(), BibTeXEntryType::Article);
    for (i, value) in tricky.iter().enumerate() {
        entry.add_field(format!("field{}", i), *value);
    }
    let formatted = format_entry(entry.clone());
    let reparsed = parse_entry(formatted.clone())
        .unwrap_or_else(|e| panic!("failed to reparse:\n{}\nerror: {:?}", formatted, e));
    for (i, value) in tricky.iter().enumerate() {
        assert_eq!(
            reparsed.get_field(&format!("field{}", i)),
            Some(*value),
            "field{} did not round-trip",
            i
        );
    }
}
