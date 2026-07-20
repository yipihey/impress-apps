//! Integration tests for the embedded Tectonic LaTeX engine
//! (`imprint_core::latex::compile_latex_tectonic`). Gated on `tectonic-render`.
//!
//! Run: `cargo test -p imprint-core --features tectonic-render --test tectonic_spike`
//! (needs network on first run to fetch the default bundle.)

#![cfg(feature = "tectonic-render")]

use imprint_core::latex::compile_latex_tectonic;

const GOOD: &str = r"\documentclass{article}
\begin{document}
\section{Introduction}
Hello from the embedded Tectonic engine.
\end{document}";

#[test]
fn compiles_to_pdf_with_synctex() {
    let r = compile_latex_tectonic(GOOD, true, None, None);
    assert!(r.error.is_none(), "unexpected error: {:?}", r.error);
    let pdf = r.pdf_data.expect("no PDF produced");
    assert!(
        pdf.len() > 500,
        "PDF suspiciously small: {} bytes",
        pdf.len()
    );
    assert_eq!(&pdf[..5], b"%PDF-", "output does not start with %PDF-");
    assert!(
        r.synctex_data.is_some(),
        "SyncTeX data was requested but not produced"
    );
    eprintln!(
        "Tectonic: {}-byte PDF, synctex={}B, {} diagnostics, {}ms",
        pdf.len(),
        r.synctex_data.as_ref().map(|d| d.len()).unwrap_or(0),
        r.diagnostics.len(),
        r.compile_ms
    );
}

#[test]
fn second_compile_reuses_bundle_and_is_faster() {
    // The bundle-index load (~2s) is paid on the first compile; the thread-local
    // shared bundle makes subsequent compiles on the same thread much faster.
    let first = compile_latex_tectonic(GOOD, false, None, None);
    assert!(
        first.pdf_data.is_some(),
        "first compile failed: {:?}",
        first.error
    );
    let second = compile_latex_tectonic(GOOD, false, None, None);
    assert!(
        second.pdf_data.is_some(),
        "second compile failed: {:?}",
        second.error
    );
    eprintln!(
        "bundle-reuse: first={}ms second={}ms",
        first.compile_ms, second.compile_ms
    );
    // The second compile should be materially faster (bundle already loaded).
    // Generous bound to avoid CI flakiness; the real win is ~4x.
    assert!(
        second.compile_ms < first.compile_ms,
        "expected 2nd compile faster (first={}ms second={}ms)",
        first.compile_ms,
        second.compile_ms
    );
}

#[test]
fn reports_error_on_broken_source() {
    // `\undefinedcommand` and a missing \end{document} → fatal error, no PDF.
    let broken = r"\documentclass{article}\begin{document}\undefinedmacro{x}";
    let r = compile_latex_tectonic(broken, false, None, None);
    assert!(r.pdf_data.is_none(), "expected no PDF for broken source");
    assert!(
        r.error.is_some(),
        "expected an error summary for broken source"
    );
    eprintln!("broken-source error: {:?}", r.error);
}

#[test]
fn resolves_on_disk_input_via_filesystem_root() {
    // Write an auxiliary file next to a working dir and `\input` it; without
    // filesystem_root this fails, with it the content is pulled in.
    let dir = tempfile::tempdir().expect("tempdir");
    std::fs::write(dir.path().join("chapter.tex"), r"Included chapter body.").expect("write aux");
    let src = r"\documentclass{article}\begin{document}\input{chapter}\end{document}";

    // Without filesystem_root → the \input can't be found → no PDF.
    let without = compile_latex_tectonic(src, false, None, None);
    assert!(
        without.pdf_data.is_none(),
        "expected failure without filesystem_root"
    );

    // With filesystem_root → resolves the on-disk file → PDF.
    let with = compile_latex_tectonic(src, false, None, dir.path().to_str());
    assert!(
        with.error.is_none(),
        "unexpected error with root: {:?}",
        with.error
    );
    assert!(
        with.pdf_data.is_some(),
        "expected a PDF once filesystem_root is set"
    );
    eprintln!(
        "filesystem_root: without_pdf={} with={}B {}ms",
        without.pdf_data.is_some(),
        with.pdf_data.as_ref().map(|d| d.len()).unwrap_or(0),
        with.compile_ms
    );
}
