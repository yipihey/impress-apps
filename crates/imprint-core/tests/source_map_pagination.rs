//! Source-map pagination: does a multi-page Typst document produce entries on
//! every page, or does everything collapse onto page 0?
//!
//! This is the load-bearing property for source↔preview position sync. If all
//! entries claim page 0, `SourceMapUtils.sourceToRender` can only ever scroll
//! the preview to page 1, and switching Source→Preview always lands at the
//! beginning of the document regardless of where the caret is.

#![cfg(all(feature = "uniffi", feature = "typst-render"))]

use imprint_core::*;

/// Long enough to be forced across several pages.
fn multipage_source() -> String {
    let mut s = String::from("= Introduction\n\n");
    for section in 1..=6 {
        s.push_str(&format!("== Section {section}\n\n"));
        for para in 0..12 {
            s.push_str(&format!(
                "This is paragraph {para} of section {section}. It exists to consume \
                 vertical space so the document is forced onto multiple pages, which \
                 is the condition under which per-page source mapping matters.\n\n"
            ));
        }
    }
    s
}

fn default_options() -> CompileOptions {
    CompileOptions {
        page_size: FFIPageSize::Letter,
        font_size: 11.0,
        margin_top: 72.0,
        margin_right: 72.0,
        margin_bottom: 72.0,
        margin_left: 72.0,
        figures_root: None,
        bib_source: None,
    }
}

#[test]
fn multipage_document_maps_entries_beyond_page_zero() {
    let source = multipage_source();
    let result = compile_typst_to_pdf(source.clone(), default_options());

    assert!(result.error.is_none(), "compile failed: {:?}", result.error);
    assert!(result.pdf_data.is_some(), "no PDF produced");

    let entries = &result.source_map_entries;
    assert!(
        !entries.is_empty(),
        "source map is empty — no position sync possible"
    );

    let mut pages: Vec<u32> = entries.iter().map(|e| e.page).collect();
    pages.sort_unstable();
    pages.dedup();

    let max_src_end = entries.iter().map(|e| e.source.end).max().unwrap_or(0);

    eprintln!(
        "entries={} pages={:?} max_source_end={} source_len={}",
        entries.len(),
        pages,
        max_src_end,
        source.len()
    );

    // The real defect this pins: a heuristic fallback that hardcodes page 0
    // yields exactly [0] here, and every caret position then resolves to page 1.
    assert!(
        pages.len() > 1,
        "every source-map entry claims page {:?} — a document this long spans \
         several pages, so forward sync can only ever scroll to page 1",
        pages
    );
}

#[test]
fn source_map_covers_the_tail_of_the_document() {
    let source = multipage_source();
    let result = compile_typst_to_pdf(source.clone(), default_options());
    let entries = &result.source_map_entries;
    assert!(!entries.is_empty(), "source map is empty");

    let max_src_end = entries.iter().map(|e| e.source.end).max().unwrap_or(0) as usize;

    // Text near the end of the buffer must map somewhere, otherwise a caret in
    // the last section falls back to the nearest (early) entry and the preview
    // scrolls to the wrong place.
    assert!(
        max_src_end > source.len() / 2,
        "source map only covers up to byte {max_src_end} of {} — the tail of the \
         document is unmapped",
        source.len()
    );
}
