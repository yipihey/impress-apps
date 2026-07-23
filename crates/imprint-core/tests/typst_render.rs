//! Real Typst → PDF/SVG render tests. Prior coverage only checked
//! `RenderOptions` config; nothing exercised the actual compile path that
//! imprint (macOS AND iOS) depends on for live preview. Runs under the
//! `typst-render` feature (part of `native`), the exact feature set the
//! iOS-simulator xcframework slice is built with.

#![cfg(feature = "typst-render")]

use imprint_core::render::{OutputFormat, PersistentTypstRenderer, RenderOptions, RenderOutput};

const DOC: &str = "= Hello iOS\n\nThe #emph[imprint] renderer runs in-process.\n\n$ E = m c^2 $\n";

#[test]
fn renders_typst_to_pdf() {
    let mut renderer = PersistentTypstRenderer::new();
    let (out, source_map) = renderer
        .render_pdf(DOC, &RenderOptions::default())
        .expect("render_pdf");
    match out {
        RenderOutput::Pdf(bytes) => {
            assert!(bytes.len() > 500, "PDF suspiciously small: {}", bytes.len());
            assert_eq!(&bytes[..5], b"%PDF-", "not a PDF header");
        }
        other => panic!("expected PDF output, got {other:?}"),
    }
    assert!(
        !source_map.is_empty(),
        "real-layout source map should not be empty for a rendered doc"
    );
}

#[test]
fn renders_typst_to_svg() {
    let mut renderer = PersistentTypstRenderer::new();
    let opts = RenderOptions::default().with_format(OutputFormat::Svg);
    let (pages, _warnings, count, _source_map) =
        renderer.render_svg(DOC, &opts).expect("render_svg");
    assert_eq!(count, 1, "single-page doc");
    assert_eq!(pages.len(), 1);
    assert!(pages[0].contains("<svg"), "not SVG markup");
}

#[test]
fn persistent_renderer_recompiles_after_edit() {
    // The engine is reused across compiles (incremental); a second,
    // different source must still produce a fresh, valid PDF.
    let mut renderer = PersistentTypstRenderer::new();
    let opts = RenderOptions::default();
    let first = renderer.render_pdf("= First", &opts).expect("first");
    let second = renderer
        .render_pdf("= Second, longer document body", &opts)
        .expect("second");
    let (a, b) = match (first.0, second.0) {
        (RenderOutput::Pdf(a), RenderOutput::Pdf(b)) => (a, b),
        _ => panic!("expected PDFs"),
    };
    assert_eq!(&a[..5], b"%PDF-");
    assert_eq!(&b[..5], b"%PDF-");
    assert_ne!(a, b, "different sources should yield different PDFs");
}

#[test]
fn invalid_typst_errors_cleanly() {
    // A syntax error must surface as Err, not a panic — the compile path
    // the editor hits on every keystroke of half-typed markup.
    let mut renderer = PersistentTypstRenderer::new();
    let result = renderer.render_pdf("#let x = ", &RenderOptions::default());
    assert!(result.is_err(), "malformed source should error, not panic");
}

#[test]
fn bibliography_resolves_from_virtual_bib() {
    // `@key` + `#bibliography("bibliography.bib")` must compile when the bib
    // is injected in-memory via set_bib_source — the store-backed citation
    // path used by the manuscript chassis (no project directory involved).
    let mut renderer = PersistentTypstRenderer::new();
    let bib = "@article{Einstein1905,\n  author = {Albert Einstein},\n  title = {On the Electrodynamics of Moving Bodies},\n  journal = {Annalen der Physik},\n  year = {1905}\n}\n";
    let src = "= Cited\n\nAs shown in @Einstein1905.\n\n#bibliography(\"bibliography.bib\")\n";

    // Without the bib the compile must fail (file not found).
    assert!(
        renderer.render_pdf(src, &RenderOptions::default()).is_err(),
        "missing bibliography.bib should error"
    );

    renderer.set_bib_source(Some(bib));
    let (out, _) = renderer
        .render_pdf(src, &RenderOptions::default())
        .expect("render with virtual bib");
    match out {
        RenderOutput::Pdf(bytes) => assert_eq!(&bytes[..5], b"%PDF-"),
        _ => panic!("expected PDF"),
    }

    // Clearing removes the virtual file again.
    renderer.set_bib_source(None);
    assert!(
        renderer.render_pdf(src, &RenderOptions::default()).is_err(),
        "cleared bib must not linger"
    );
}
