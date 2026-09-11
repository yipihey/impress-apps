//! Typst over the tree, without a directory (ADR-0030 D5).
//!
//! `TreeFileResolver` serves a project's files to the persistent engine
//! straight from memory: text files as `Source`s at their project paths (so
//! `#include "chapters/a.typ"` and `image("../figures/f.png")` resolve the
//! way they would on disk), binaries as `Bytes`, projected bibliographies as
//! the `.bib` text the resolver was given. Package ids are declined so the
//! offline `CachedPackageResolver` handles `@preview/…`.
//!
//! The engine is built once (fonts loaded, comemo caches kept) and the tree
//! is swapped per compile — the editor's preview path, the CLI's Typst path
//! and iOS all take this route; nothing touches the filesystem.
//!
//! Diagnostics come back in **tree paths with lines**, resolved against the
//! retained `Source` of whichever file the span points into — a broken
//! chapter names the chapter, not the entry.

#![cfg(feature = "typst-render")]

use std::borrow::Cow;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};

use typst::diag::{FileError, FileResult, SourceDiagnostic};
use typst::foundations::Bytes;
use typst::layout::PagedDocument;
use typst::syntax::{FileId, Source, VirtualPath};
use typst_as_lib::file_resolver::FileResolver;
use typst_as_lib::{typst_kit_options::TypstKitFontOptions, TypstEngine, TypstTemplateCollection};

use super::bib::ProjectedBibliography;
use super::graph::{Diagnostic, Severity};
use super::model::{FileBytes, OutputKind, ProjectTree, Target};
use crate::render::line_column_at;

// `TreeCompileOutcome` lives in `graph.rs`: it is plain data (bytes, page
// count, diagnostics) with no Typst types in it, and the service's
// `not(typst-render)` fallback has to name it too.
use super::graph::TreeCompileOutcome;

/// The files the resolver serves: sources by id (kept, so diagnostics can be
/// resolved to lines) and bytes by rootless path.
#[derive(Default)]
struct TreeFiles {
    sources: HashMap<FileId, Source>,
    bytes: HashMap<PathBuf, Bytes>,
}

struct TreeFileResolver {
    files: Arc<RwLock<TreeFiles>>,
}

impl FileResolver for TreeFileResolver {
    fn resolve_binary(&self, id: FileId) -> FileResult<Cow<'_, Bytes>> {
        if id.package().is_some() {
            return Err(FileError::NotFound(
                id.vpath().as_rootless_path().to_path_buf(),
            ));
        }
        let key = id.vpath().as_rootless_path().to_path_buf();
        let files = self.files.read().unwrap();
        if let Some(bytes) = files.bytes.get(&key) {
            return Ok(Cow::Owned(bytes.clone()));
        }
        // A text file read as bytes (`read("data.csv")`, or a `.bib`).
        if let Some(source) = files.sources.get(&id) {
            return Ok(Cow::Owned(Bytes::new(source.text().as_bytes().to_vec())));
        }
        Err(FileError::NotFound(key))
    }

    fn resolve_source(&self, id: FileId) -> FileResult<Cow<'_, Source>> {
        if id.package().is_some() {
            return Err(FileError::NotFound(
                id.vpath().as_rootless_path().to_path_buf(),
            ));
        }
        let files = self.files.read().unwrap();
        match files.sources.get(&id) {
            Some(source) => Ok(Cow::Owned(source.clone())),
            None => Err(FileError::NotFound(
                id.vpath().as_rootless_path().to_path_buf(),
            )),
        }
    }
}

fn file_id(path: &str) -> FileId {
    FileId::new(
        None,
        VirtualPath::new(format!("/{}", path.trim_start_matches('/'))),
    )
}

/// A persistent engine over swappable trees.
pub struct TreeCompiler {
    engine: Option<TypstEngine<TypstTemplateCollection>>,
    files: Arc<RwLock<TreeFiles>>,
}

impl Default for TreeCompiler {
    fn default() -> Self {
        Self::new()
    }
}

impl TreeCompiler {
    pub fn new() -> Self {
        Self {
            engine: None,
            files: Arc::new(RwLock::new(TreeFiles::default())),
        }
    }

    fn ensure_engine(&mut self) {
        if self.engine.is_some() {
            return;
        }
        let t0 = std::time::Instant::now();
        let resolver = TreeFileResolver {
            files: self.files.clone(),
        };
        let mut builder = TypstEngine::builder()
            .add_file_resolver(resolver)
            .add_file_resolver(crate::typst_packages::CachedPackageResolver::discover())
            .search_fonts_with(
                TypstKitFontOptions::default()
                    .include_system_fonts(true)
                    .include_embedded_fonts(true),
            );
        builder.comemo_evict_max_age(Some(30));
        self.engine = Some(builder.build());
        eprintln!(
            "[imprint-core] tree engine built in {:.1}ms",
            t0.elapsed().as_secs_f64() * 1000.0
        );
    }

    /// Load the tree into the resolver. `bibliographies` replace the text of
    /// the bibliography rows they name (projections rendered by
    /// `bib::resolve_bibliographies`); `entry_override` replaces the entry's
    /// text (the editor's live buffer).
    fn load(
        &self,
        tree: &ProjectTree,
        bibliographies: &[ProjectedBibliography],
        entry_override: Option<&str>,
    ) {
        let mut files = TreeFiles::default();
        for file in tree.all_files() {
            let id = file_id(&file.path);
            let projected = bibliographies.iter().find(|b| b.path == file.path);
            match (&file.bytes, projected) {
                (_, Some(bib)) => {
                    // A key the library does not know still compiles: a
                    // placeholder entry names it in the rendered bibliography
                    // (the `missing-reference` warning names it to agents),
                    // instead of Typst refusing the whole document.
                    let mut text = bib.text.clone();
                    for key in &bib.missing {
                        text.push_str(&format!(
                            "\n@misc{{{key},\n  title = {{{key} (not in the library)}},\n  note = {{missing reference}}\n}}\n"
                        ));
                    }
                    files.sources.insert(id, Source::new(id, text));
                }
                (FileBytes::Text(text), None) => {
                    let mut text = if file.path == tree.entry.path {
                        entry_override
                            .map(String::from)
                            .unwrap_or_else(|| text.clone())
                    } else {
                        text.clone()
                    };
                    // The one-file convention (see `bib::implicit_bibliography`):
                    // an entry that cites but never calls `#bibliography(...)`
                    // gets the call appended, so citations Just Work.
                    if file.path == tree.entry.path
                        && !text.contains("#bibliography(")
                        && tree
                            .file(super::bib::IMPLICIT_BIBLIOGRAPHY)
                            .is_some_and(|b| b.bib_source == Some(super::model::BibSource::Cited))
                    {
                        text.push_str(&format!(
                            "\n#bibliography(\"{}\")\n",
                            super::bib::IMPLICIT_BIBLIOGRAPHY
                        ));
                    }
                    files.sources.insert(id, Source::new(id, text));
                }
                (FileBytes::Bytes(bytes), None) => {
                    files.bytes.insert(
                        id.vpath().as_rootless_path().to_path_buf(),
                        Bytes::new(bytes.clone()),
                    );
                }
                (FileBytes::Missing, None) => {}
            }
        }
        *self.files.write().unwrap() = files;
    }

    /// Compile `target` of `tree`.
    pub fn compile(
        &mut self,
        tree: &ProjectTree,
        target: &Target,
        bibliographies: &[ProjectedBibliography],
        entry_override: Option<&str>,
    ) -> TreeCompileOutcome {
        self.ensure_engine();
        self.load(tree, bibliographies, entry_override);
        let engine = self.engine.as_ref().expect("engine built");

        let main_id = file_id(&target.entry);
        let t0 = std::time::Instant::now();
        let compiled: typst::diag::Warned<Result<PagedDocument, typst_as_lib::TypstAsLibError>> =
            engine.compile(main_id);
        let compile_ms = t0.elapsed().as_millis() as u64;

        let files = self.files.read().unwrap();
        let mut diagnostics: Vec<Diagnostic> = compiled
            .warnings
            .iter()
            .map(|d| resolve_diagnostic(d, &files))
            .collect();

        let document = match compiled.output {
            Ok(doc) => doc,
            Err(e) => {
                diagnostics.extend(error_diagnostics(&e, &files));
                diagnostics.sort_by_key(|d| (d.severity, d.file.clone(), d.line));
                return TreeCompileOutcome {
                    pdf: None,
                    svg_pages: vec![],
                    page_count: 0,
                    compile_ms,
                    diagnostics,
                    ok: false,
                };
            }
        };
        drop(files);

        let page_count = document.pages.len() as u32;
        let (pdf, svg_pages) = match target.output_kind {
            OutputKind::Svg => (
                None,
                document
                    .pages
                    .iter()
                    .map(typst_svg::svg)
                    .collect::<Vec<_>>(),
            ),
            OutputKind::Pdf | OutputKind::Png => {
                match typst_pdf::pdf(&document, &typst_pdf::PdfOptions::default()) {
                    Ok(bytes) => (Some(bytes), vec![]),
                    Err(e) => {
                        diagnostics.push(Diagnostic {
                            severity: Severity::Error,
                            code: "pdf-export".into(),
                            message: format!("PDF export failed: {e:?}"),
                            file: None,
                            line: None,
                        });
                        return TreeCompileOutcome {
                            pdf: None,
                            svg_pages: vec![],
                            page_count,
                            compile_ms,
                            diagnostics,
                            ok: false,
                        };
                    }
                }
            }
        };
        diagnostics.sort_by_key(|d| (d.severity, d.file.clone(), d.line));
        TreeCompileOutcome {
            pdf,
            svg_pages,
            page_count,
            compile_ms,
            diagnostics,
            ok: true,
        }
    }
}

fn resolve_diagnostic(d: &SourceDiagnostic, files: &TreeFiles) -> Diagnostic {
    let severity = match d.severity {
        typst::diag::Severity::Error => Severity::Error,
        typst::diag::Severity::Warning => Severity::Warning,
    };
    let mut out = Diagnostic {
        severity,
        code: match severity {
            Severity::Error => "typst-error".into(),
            _ => "typst-warning".into(),
        },
        message: {
            let mut m = d.message.to_string();
            for hint in &d.hints {
                m.push_str(" — hint: ");
                m.push_str(hint);
            }
            m
        },
        file: None,
        line: None,
    };
    if let Some(id) = d.span.id() {
        if id.package().is_some() {
            out.file = id.package().map(|p| p.to_string());
        } else {
            let path = id.vpath().as_rootless_path().to_string_lossy().into_owned();
            out.file = Some(path);
            if let Some(source) = files.sources.get(&id) {
                if let Some(range) = source.range(d.span) {
                    let (line, _column) = line_column_at(source.text(), range.start);
                    out.line = Some(line);
                }
            }
        }
    }
    out
}

fn error_diagnostics(e: &typst_as_lib::TypstAsLibError, files: &TreeFiles) -> Vec<Diagnostic> {
    use typst_as_lib::TypstAsLibError;
    match e {
        TypstAsLibError::TypstSource(diags) => {
            diags.iter().map(|d| resolve_diagnostic(d, files)).collect()
        }
        TypstAsLibError::HintedString(hinted) => vec![Diagnostic {
            severity: Severity::Error,
            code: "typst-error".into(),
            message: {
                let mut m = hinted.message().to_string();
                for hint in hinted.hints() {
                    m.push_str(" — hint: ");
                    m.push_str(hint);
                }
                m
            },
            file: None,
            line: None,
        }],
        other => vec![Diagnostic {
            severity: Severity::Error,
            code: "typst-error".into(),
            message: other.to_string(),
            file: None,
            line: None,
        }],
    }
}

thread_local! {
    static COMPILER: std::cell::RefCell<TreeCompiler> = std::cell::RefCell::new(TreeCompiler::new());
}

/// Compile with the thread's persistent tree engine (fonts loaded once per
/// thread; the Swift layer and the services pin compiles to one thread).
pub fn compile_typst_tree(
    tree: &ProjectTree,
    target: &Target,
    bibliographies: &[ProjectedBibliography],
    entry_override: Option<&str>,
) -> TreeCompileOutcome {
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        COMPILER.with(|c| {
            c.borrow_mut()
                .compile(tree, target, bibliographies, entry_override)
        })
    }));
    match outcome {
        Ok(o) => o,
        Err(panic) => {
            let message = panic
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown panic during Typst compilation".into());
            TreeCompileOutcome {
                pdf: None,
                svg_pages: vec![],
                page_count: 0,
                compile_ms: 0,
                diagnostics: vec![Diagnostic {
                    severity: Severity::Error,
                    code: "typst-panic".into(),
                    message: format!("internal error: {message}"),
                    file: None,
                    line: None,
                }],
                ok: false,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::bib::{resolve_bibliographies, MapResolver};
    use crate::project::graph::BuildGraph;
    use crate::project::model::{BibSource, FileRole, ProjectFile};

    fn tiny_png() -> Vec<u8> {
        // A 1×1 white PNG (valid CRCs: Typst's decoder checks them).
        vec![
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
            0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00,
            0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x78,
            0xDA, 0x63, 0xF8, 0xFF, 0xFF, 0x3F, 0x00, 0x05, 0xFE, 0x02, 0xFE, 0x33, 0x12, 0x95,
            0x14, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ]
    }

    #[test]
    fn a_multi_file_typst_project_compiles_from_memory() {
        let tree = ProjectTree::new(
            "m",
            "T",
            "typst",
            ProjectFile::text(
                "paper/main.typ",
                FileRole::Main,
                "#import \"lib/theme.typ\": greet\n= Paper\n#greet(\"world\")\n#include \"chapters/intro.typ\"\nSee @knuth84.\n#bibliography(\"refs.bib\")",
            ),
            vec![
                ProjectFile::text("paper/lib/theme.typ", FileRole::Style, "#let greet(who) = [Hello #who]"),
                ProjectFile::text(
                    "paper/chapters/intro.typ",
                    FileRole::Chapter,
                    "== Intro\n#figure(image(\"../figures/dot.png\", width: 10pt))\n#let rows = csv(\"/paper/data/x.csv\")\nRows: #rows.len()",
                ),
                ProjectFile::binary("paper/figures/dot.png", FileRole::Figure, tiny_png()),
                ProjectFile::text("paper/data/x.csv", FileRole::Data, "a,b\n1,2\n"),
                ProjectFile::text("paper/refs.bib", FileRole::Bibliography, "").with_bib_source(BibSource::Cited),
            ],
            vec![],
        );
        let graph = BuildGraph::derive(&tree, tree.default_target());
        assert!(!graph.has_errors(), "{:?}", graph.diagnostics);
        let resolver = MapResolver::default().with_raw(
            "knuth84",
            "@book{knuth84, author={Donald Knuth}, title={The TeXbook}, year={1984}, publisher={Addison-Wesley}}",
        );
        let bibs = resolve_bibliographies(&tree, &graph, &resolver);
        let out = compile_typst_tree(&tree, tree.default_target(), &bibs, None);
        assert!(out.ok, "{:?}", out.diagnostics);
        assert!(out.pdf.as_ref().unwrap().starts_with(b"%PDF"));
        assert!(out.page_count >= 1);
        assert!(out.errors().next().is_none());
    }

    #[test]
    fn a_broken_chapter_is_named_with_its_line() {
        let tree = ProjectTree::new(
            "m",
            "T",
            "typst",
            ProjectFile::text("main.typ", FileRole::Main, "= P\n#include \"ch.typ\""),
            vec![ProjectFile::text(
                "ch.typ",
                FileRole::Chapter,
                "fine\n\n#let x = (\nunclosed",
            )],
            vec![],
        );
        let out = compile_typst_tree(&tree, tree.default_target(), &[], None);
        assert!(!out.ok);
        let err = out.errors().next().expect("an error");
        assert_eq!(err.file.as_deref(), Some("ch.typ"));
        assert!(err.line.is_some());
        assert!(err.line.unwrap() >= 3, "{err:?}");
    }

    #[test]
    fn the_entry_override_is_the_live_buffer_and_svg_targets_render_pages() {
        let tree = ProjectTree::new(
            "m",
            "T",
            "typst",
            ProjectFile::text("main.typ", FileRole::Main, "= Stored"),
            vec![],
            vec![],
        );
        let mut target = tree.default_target().clone();
        target.output_kind = OutputKind::Svg;
        let out = compile_typst_tree(&tree, &target, &[], Some("= Live\n#pagebreak()\n= Two"));
        assert!(out.ok, "{:?}", out.diagnostics);
        assert_eq!(
            out.page_count, 2,
            "the override's two pages, not the stored one page"
        );
        assert_eq!(out.svg_pages.len(), 2);
        assert!(out.pdf.is_none());
        assert!(out.svg_pages[0].contains("<svg"));
    }

    #[test]
    fn a_missing_include_is_an_error_in_the_including_file() {
        let tree = ProjectTree::new(
            "m",
            "T",
            "typst",
            ProjectFile::text("main.typ", FileRole::Main, "= P\n\n#include \"nope.typ\""),
            vec![],
            vec![],
        );
        let out = compile_typst_tree(&tree, tree.default_target(), &[], None);
        assert!(!out.ok);
        let err = out.errors().next().unwrap();
        assert_eq!(err.file.as_deref(), Some("main.typ"));
        assert_eq!(err.line, Some(3));
        assert!(
            err.message.contains("nope.typ") || err.message.contains("not found"),
            "{}",
            err.message
        );
    }
}
