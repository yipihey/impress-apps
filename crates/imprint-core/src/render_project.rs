//! Project-aware Typst compilation for the journal pipeline.
//!
//! `render.rs` provides single-source compilation for the imprint editor.
//! This module adds compilation against a directory tree — the manuscript
//! bundle format introduced in Phase 8 of the journal pipeline (see
//! `docs/plan-journal-pipeline.md`). It uses `typst-as-lib`'s
//! `FileSystemResolver` so `image("figures/x.png")` and
//! `include "chapters/c1.typ"` resolve relative to the project root.
//!
//! Scope note: this module covers ONLY Typst. LaTeX project compile is
//! owned by imprint's Swift `LaTeXCompilationService`
//! (`apps/imprint/macOS/Services/LaTeXCompilationService.swift`), which
//! already supports `pdflatex` / `xelatex` / `lualatex` / `latexmk`,
//! discovers installed TeX distributions via `TeXDistributionManager`,
//! and parses diagnostics via `LaTeXLogParser`. The journal pipeline's
//! bundle compile route calls into that Swift service for `.tex`
//! bundles and into this module's `compile_typst_project_to_pdf` for
//! `.typ` bundles. There is one source of truth for compilation: imprint.

use crate::render::{RenderError, RenderOptions};
use std::path::Path;

/// Result of a project compile.
#[derive(Debug)]
pub struct ProjectRenderOutput {
    pub pdf_bytes: Vec<u8>,
    pub warnings: Vec<String>,
    pub page_count: u32,
    pub compile_ms: u64,
}

/// Compile a Typst project rooted at `project_dir` with `main_file`
/// (relative to the root) as the entry point.
///
/// Multi-file Typst projects work because `typst-as-lib`'s
/// `FileSystemResolver` reads any file under the project root, so
/// `image("figures/x.png")`, `include "chapters/c1.typ"`, and `import`
/// all resolve relative to the project root.
///
/// Note: project compile trusts the user's main source to own page setup
/// via `#set page(...)`; `options` is currently advisory (we accept it
/// for symmetry with the single-source path). A future enhancement could
/// inject a preamble via a virtual override file.
#[cfg(feature = "typst-render")]
pub fn compile_typst_project_to_pdf(
    project_dir: &Path,
    main_file: &str,
    _options: &RenderOptions,
) -> Result<ProjectRenderOutput, RenderError> {
    use std::time::Instant;
    use typst::diag::Warned;
    use typst::layout::PagedDocument;
    use typst::syntax::{FileId, VirtualPath};
    use typst_as_lib::file_resolver::FileSystemResolver;
    use typst_as_lib::{typst_kit_options::TypstKitFontOptions, TypstEngine, TypstTemplateCollection};

    if !project_dir.exists() {
        return Err(RenderError::IoError(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("project_dir does not exist: {}", project_dir.display()),
        )));
    }
    let main_full = project_dir.join(main_file);
    if !main_full.exists() {
        return Err(RenderError::CompilationError(format!(
            "main_file {:?} does not exist under project_dir {}",
            main_file,
            project_dir.display()
        )));
    }

    let fs_resolver = FileSystemResolver::new(project_dir.to_path_buf());

    let mut builder = TypstEngine::<TypstTemplateCollection>::builder()
        .add_file_resolver(fs_resolver)
        .search_fonts_with(
            TypstKitFontOptions::default()
                .include_system_fonts(true)
                .include_embedded_fonts(true),
        );
    builder.comemo_evict_max_age(Some(30));
    let engine = builder.build();

    let main_id = FileId::new(None, VirtualPath::new(format!("/{}", main_file)));

    let t0 = Instant::now();
    let compiled: Warned<Result<PagedDocument, typst_as_lib::TypstAsLibError>> =
        engine.compile(main_id);
    let compile_ms = t0.elapsed().as_millis() as u64;

    let warnings: Vec<String> = compiled
        .warnings
        .iter()
        .map(|w| format!("{:?}", w))
        .collect();

    let document = compiled
        .output
        .map_err(|e| RenderError::CompilationError(format!("{:?}", e)))?;

    let pdf_options = typst_pdf::PdfOptions::default();
    let pdf_bytes = typst_pdf::pdf(&document, &pdf_options)
        .map_err(|e| RenderError::PdfError(format!("{:?}", e)))?;

    Ok(ProjectRenderOutput {
        pdf_bytes,
        warnings,
        page_count: document.pages.len() as u32,
        compile_ms,
    })
}

#[cfg(not(feature = "typst-render"))]
pub fn compile_typst_project_to_pdf(
    _project_dir: &Path,
    _main_file: &str,
    _options: &RenderOptions,
) -> Result<ProjectRenderOutput, RenderError> {
    Err(RenderError::FeatureNotEnabled)
}

// LaTeX project compilation lives in imprint's Swift LaTeXCompilationService,
// not here. The journal pipeline's bundle compile route calls into that
// service directly for .tex bundles. This module exposes only the Typst
// path; trying to call a LaTeX entry point on the Rust side would
// duplicate compile logic that imprint already owns.

#[cfg(test)]
#[cfg(feature = "typst-render")]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn write(path: &Path, contents: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }

    #[test]
    fn project_compile_succeeds_on_simple_main() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        write(&root.join("paper.typ"), "= Hello\n\nA simple Typst document.\n");

        let options = RenderOptions::default();
        let result = compile_typst_project_to_pdf(root, "paper.typ", &options).unwrap();
        assert!(!result.pdf_bytes.is_empty());
        assert!(result.pdf_bytes.starts_with(b"%PDF"));
        assert!(result.page_count >= 1);
    }

    #[test]
    fn project_compile_resolves_include_relative_path() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        write(
            &root.join("paper.typ"),
            "#include \"/chapters/intro.typ\"\n",
        );
        write(&root.join("chapters/intro.typ"), "= Intro\nbody\n");

        let options = RenderOptions::default();
        let result = compile_typst_project_to_pdf(root, "paper.typ", &options).unwrap();
        assert!(!result.pdf_bytes.is_empty());
    }

    #[test]
    fn project_compile_errors_when_main_file_missing() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let options = RenderOptions::default();
        let err =
            compile_typst_project_to_pdf(root, "nope.typ", &options).unwrap_err();
        match err {
            RenderError::CompilationError(msg) => assert!(msg.contains("nope.typ")),
            other => panic!("unexpected error: {:?}", other),
        }
    }

}
