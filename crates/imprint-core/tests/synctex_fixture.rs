//! Integration test that parses the on-disk SyncTeX fixture.

use imprint_core::synctex::{lookup_pdf, lookup_source, parse_synctex};

#[test]
fn parses_fixture_file_and_round_trips_lookups() {
    let bytes = std::fs::read("tests/fixtures/minimal.synctex")
        .expect("fixture should exist alongside this test");
    let parsed = parse_synctex(&bytes).expect("fixture must parse");

    assert_eq!(parsed.inputs.len(), 2);
    assert_eq!(parsed.sheets.len(), 2);

    // Source → PDF on a known line.
    let pdf = lookup_pdf(&parsed, "./paper.tex", 10, 0)
        .expect("paper.tex:10 should resolve to a PDF location");
    assert_eq!(pdf.page, 1);

    // PDF → source at a known coordinate.
    let src = lookup_source(&parsed, 1, 1.5, 2.5)
        .expect("(1.5, 2.5) on page 1 should map back to paper.tex");
    assert_eq!(src.file, "./paper.tex");
    assert_eq!(src.line, 10);
}
