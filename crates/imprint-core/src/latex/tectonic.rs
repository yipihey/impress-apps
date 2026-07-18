//! Self-contained LaTeX compilation via the embedded [Tectonic] engine.
//!
//! This is the in-process alternative to imprint's shell-out to the user's
//! system TeXLive: Tectonic bundles a XeTeX/TeXLive engine and fetches TeX
//! packages on demand, so LaTeX → PDF happens inside the (sandboxed) app with
//! no external `pdflatex` and no `impress-toolbox` hop.
//!
//! Gated behind the `tectonic-render` feature (heavy C dependency tree). The
//! UniFFI surface + `LatexCompileResult` record live in `lib.rs`.
//!
//! [Tectonic]: https://tectonic-typesetting.github.io/

use std::cell::RefCell;
use std::fmt::Arguments;
use std::path::PathBuf;
use std::rc::Rc;

use tectonic::config::PersistentConfig;
use tectonic::driver::{OutputFormat, PassSetting, ProcessingSessionBuilder};
use tectonic::errors::Error as TectonicError;
use tectonic::io::{DigestData, InputHandle, IoProvider, OpenResult};
use tectonic_bundles::Bundle;
// The StatusBackend trait's `report` uses `tectonic_errors::Error`, which is a
// different (anyhow-based) type than `tectonic::errors::Error` (error_chain).
use tectonic_errors::Error as StatusError;
use tectonic_status_base::{MessageKind, StatusBackend};

// ── Persistent bundle (perf) ─────────────────────────────────────────────────
//
// Profiling showed `config.default_bundle()` costs ~2.1s per compile — it
// loads + parses the full TeXLive bundle index — while the actual TeX run is
// only ~0.5s. The bundle is otherwise consumed by each `ProcessingSession`
// (`create(self)` takes ownership), so we can't hand the same `Box<dyn Bundle>`
// to two builders.
//
// `SharedBundle` wraps the real bundle in `Rc<RefCell<…>>` and itself implements
// `Bundle`, so each compile gets a cheap fresh `Box<SharedBundle>` that all
// point at one long-lived bundle. Cached thread-local (mirrors
// `PersistentTypstRenderer`); the Swift layer pins Tectonic compiles to one
// serial executor so the cache hits.

thread_local! {
    static CACHED_BUNDLE: RefCell<Option<Rc<RefCell<Box<dyn Bundle>>>>> =
        const { RefCell::new(None) };
}

/// A cheap, clonable handle onto a single long-lived bundle.
struct SharedBundle {
    inner: Rc<RefCell<Box<dyn Bundle>>>,
}

impl IoProvider for SharedBundle {
    fn input_open_name(
        &mut self,
        name: &str,
        status: &mut dyn StatusBackend,
    ) -> OpenResult<InputHandle> {
        self.inner.borrow_mut().input_open_name(name, status)
    }

    fn input_open_name_with_abspath(
        &mut self,
        name: &str,
        status: &mut dyn StatusBackend,
    ) -> OpenResult<(InputHandle, Option<PathBuf>)> {
        self.inner
            .borrow_mut()
            .input_open_name_with_abspath(name, status)
    }
}

impl Bundle for SharedBundle {
    fn get_digest(&mut self) -> tectonic_errors::Result<DigestData> {
        self.inner.borrow_mut().get_digest()
    }

    fn all_files(&self) -> Vec<String> {
        self.inner.borrow().all_files()
    }
}

/// Get (or lazily build, paying the ~2s index load once) a shared handle onto
/// the default bundle for this thread.
fn shared_bundle(config: &PersistentConfig) -> Result<Box<dyn Bundle>, TectonicError> {
    let rc = CACHED_BUNDLE.with(|cell| -> Result<_, TectonicError> {
        if cell.borrow().is_none() {
            let bundle = config.default_bundle(false)?;
            *cell.borrow_mut() = Some(Rc::new(RefCell::new(bundle)));
        }
        Ok(cell.borrow().as_ref().unwrap().clone())
    })?;
    Ok(Box::new(SharedBundle { inner: rc }))
}

use crate::latex::diagnostics::{parse_log, LatexDiagnostic, Severity};

/// The `tex_input_name` used for the in-memory primary input; drives the
/// output filenames (`texput.pdf`, `texput.log`, `texput.synctex.gz`).
const INPUT_NAME: &str = "texput";

/// Result of a Tectonic compile. Plain Rust (no FFI derives) — the UniFFI
/// record wrapper is built in `lib.rs`.
#[derive(Debug, Clone)]
pub struct TectonicResult {
    pub pdf_data: Option<Vec<u8>>,
    pub synctex_data: Option<Vec<u8>>,
    pub diagnostics: Vec<LatexDiagnostic>,
    pub log: String,
    pub compile_ms: u64,
    /// Set when the engine failed to produce a PDF (fatal error summary).
    pub error: Option<String>,
}

/// A `StatusBackend` that accumulates engine messages so we can surface a
/// fatal-error summary even when no usable `.log` is produced.
#[derive(Default)]
struct CollectingStatus {
    fatal: Vec<String>,
    error_log: Vec<u8>,
}

impl StatusBackend for CollectingStatus {
    fn report(&mut self, kind: MessageKind, args: Arguments, _err: Option<&StatusError>) {
        if matches!(kind, MessageKind::Error) {
            self.fatal.push(format!("{args}"));
        }
    }

    fn dump_error_logs(&mut self, output: &[u8]) {
        self.error_log.extend_from_slice(output);
    }
}

/// Compile a LaTeX source string to a PDF using the embedded Tectonic engine.
///
/// * `source` — the full LaTeX document source.
/// * `synctex` — request SyncTeX output (`texput.synctex.gz`).
/// * `cache_dir` — where Tectonic caches the fetched package bundle. When set,
///   exported as `TECTONIC_CACHE_DIR` (a writable, sandbox-legal location the
///   Swift layer passes in). `None` uses Tectonic's default cache.
/// * `filesystem_root` — directory used to resolve on-disk file references
///   (`\includegraphics{figures/…}`, `\input{…}`). Because the primary input
///   comes from an in-memory buffer (not a file), this MUST be set to the
///   document's working directory or such references fail to load.
///
/// Diagnostics come from parsing the engine's `.log` (reusing the shared
/// [`parse_log`], so they line up with the pdflatex path); a fatal error with
/// no usable log falls back to the `StatusBackend` summary.
///
/// Note on passes: Tectonic's `PassSetting::Tex` (single TeX run) stops at XDV
/// and does not run xdvipdfmx, so it produces no PDF — there is no clean
/// "single pass to PDF" fast path. We always use `PassSetting::Default`, which
/// already runs TeX only once for documents that don't need ref/TOC
/// convergence.
pub fn compile_latex_tectonic(
    source: &str,
    synctex: bool,
    cache_dir: Option<&str>,
    filesystem_root: Option<&str>,
) -> TectonicResult {
    if let Some(dir) = cache_dir {
        // Tectonic reads TECTONIC_CACHE_DIR for its bundle/format cache.
        std::env::set_var("TECTONIC_CACHE_DIR", dir);
    }

    let start = std::time::Instant::now();
    let mut status = CollectingStatus::default();

    let outcome = run_session(source, synctex, filesystem_root, &mut status);
    let compile_ms = start.elapsed().as_millis() as u64;

    match outcome {
        Ok(mut files) => {
            let mut take = |name: &str| files.remove(name).map(|f| f.data);
            let pdf = take(&format!("{INPUT_NAME}.pdf"));
            let synctex_data = take(&format!("{INPUT_NAME}.synctex.gz"))
                .or_else(|| take(&format!("{INPUT_NAME}.synctex")));
            let log_bytes = take(&format!("{INPUT_NAME}.log")).unwrap_or_default();
            let log = String::from_utf8_lossy(&log_bytes).into_owned();
            let diagnostics = parse_log(&log);

            // Engine returned Ok but produced no PDF → treat as failure.
            let error = if pdf.is_none() {
                Some(fatal_summary(&status, &diagnostics))
            } else {
                None
            };

            TectonicResult { pdf_data: pdf, synctex_data, diagnostics, log, compile_ms, error }
        }
        Err(e) => {
            // Fatal engine error. We may still have a partial log via the
            // status backend's error-log dump; parse whatever we captured.
            let log = String::from_utf8_lossy(&status.error_log).into_owned();
            let diagnostics = parse_log(&log);
            let summary = if status.fatal.is_empty() {
                format!("{e}")
            } else {
                fatal_summary(&status, &diagnostics)
            };
            TectonicResult {
                pdf_data: None,
                synctex_data: None,
                diagnostics,
                log,
                compile_ms,
                error: Some(summary),
            }
        }
    }
}

/// Build + run one processing session, returning the in-memory output files.
fn run_session(
    source: &str,
    synctex: bool,
    filesystem_root: Option<&str>,
    status: &mut CollectingStatus,
) -> Result<tectonic::io::memory::MemoryFileCollection, TectonicError> {
    // `auto_create_config_file = false`: never write into the user's config.
    let config = PersistentConfig::open(false)?;
    // Reuse the thread-local bundle handle so the ~2s index load is paid once.
    let bundle = shared_bundle(&config)?;
    let format_cache_path = config.format_cache_path()?;

    let mut builder = ProcessingSessionBuilder::default();
    builder
        .bundle(bundle)
        .primary_input_buffer(source.as_bytes())
        .tex_input_name(&format!("{INPUT_NAME}.tex"))
        .format_name("latex")
        .format_cache_path(format_cache_path)
        .keep_logs(true)
        .keep_intermediates(false)
        .print_stdout(false)
        .synctex(synctex)
        .pass(PassSetting::Default)
        .output_format(OutputFormat::Pdf)
        .do_not_write_output_files();

    // Resolve on-disk file references (figures, \input) against the document's
    // working directory — required since the primary input is an in-memory
    // buffer rather than a file.
    if let Some(root) = filesystem_root {
        builder.filesystem_root(root);
    }

    let mut session = builder.create(status)?;
    session.run(status)?;
    Ok(session.into_file_data())
}

/// Best available human-readable failure summary.
fn fatal_summary(status: &CollectingStatus, diagnostics: &[LatexDiagnostic]) -> String {
    if !status.fatal.is_empty() {
        return status.fatal.join("; ");
    }
    if let Some(first_error) = diagnostics.iter().find(|d| d.severity == Severity::Error) {
        return first_error.message.clone();
    }
    "LaTeX compilation failed (no PDF produced)".to_string()
}
