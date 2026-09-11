//! One build of one target (ADR-0030 D6, D9, D10): the stale figure steps
//! run first, then the document engine — Typst from memory (a Markdown
//! entry is converted to Typst first), LaTeX through a materialised
//! directory and a [`RunnerHost`] — and everything that happened comes
//! back as one report the service records as a `manuscript-build` row.
//!
//! The engine writes into `work_dir` only (outputs, LaTeX residue) and
//! reads figure outputs back from it, so what a step produced becomes rows
//! the tree carries (`derived_from` + `derived_from_hash`), never loose
//! files only one machine has.

use std::borrow::Cow;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use super::bib::ProjectedBibliography;
use super::graph::{BuildGraph, Diagnostic, FigureStep, Severity};
use super::markdown;
use super::materialize::materialize;
use super::model::{
    dir_of, file_name_of, Engine, FileBytes, FileRole, ProjectFile, ProjectTree, Runner, Target,
};
// Only the native (Typst/impress-plot/implore) render path inspects output
// extensions, and that whole function is behind `typst-render`.
#[cfg(feature = "typst-render")]
use super::model::extension_of;
use super::runner::{RunError, RunOutput, RunRequest, RunnerHost};

/// A document engine gets fifteen minutes (a long LaTeX build with
/// bibliography passes), a figure step ten.
pub const ENGINE_TIMEOUT: Duration = Duration::from_secs(900);
pub const STEP_TIMEOUT: Duration = Duration::from_secs(600);

/// What to build.
pub struct BuildRequest<'a> {
    pub tree: &'a ProjectTree,
    pub target: &'a Target,
    pub bibliographies: &'a [ProjectedBibliography],
    /// Where LaTeX engines and figure scripts run (materialised as needed)
    /// and where the outputs are written.
    pub work_dir: PathBuf,
    /// Whether `shell` steps may run.
    pub allow_shell: bool,
    /// The live buffer for the target's entry, replacing the tree's text.
    pub entry_override: Option<&'a str>,
}

/// A file the build wrote into the work directory.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuiltOutput {
    /// pdf | svg | synctex | log
    pub kind: String,
    /// The file name (`main.pdf`, `page-001.svg`).
    pub name: String,
    /// Absolute.
    pub path: String,
    pub size: u64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum StepStatus {
    /// The step ran and its outputs were read back.
    Ran,
    /// Its outputs were already current — nothing to do.
    Fresh,
    /// Not run, by policy or because its runner is not available here.
    Skipped,
    Failed,
}

/// What happened to one figure step.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StepReport {
    pub source: String,
    pub runner: String,
    pub status: StepStatus,
    pub message: String,
    pub duration_ms: u64,
    pub outputs: Vec<String>,
    pub input_hash: String,
    /// The command line that ran, when one did.
    pub command: Option<String>,
}

/// A file a step wrote, read back from the work directory, with the
/// provenance its row should carry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProducedFile {
    pub path: String,
    pub bytes: Vec<u8>,
    pub derived_from: String,
    pub derived_from_hash: String,
}

/// The whole report.
#[derive(Debug, Clone)]
pub struct BuildOutcome {
    pub ok: bool,
    pub engine: Engine,
    pub outputs: Vec<BuiltOutput>,
    pub pdf: Option<Vec<u8>>,
    pub svg_pages: Vec<String>,
    pub diagnostics: Vec<Diagnostic>,
    pub steps: Vec<StepReport>,
    pub produced: Vec<ProducedFile>,
    /// What ran, in order, with what it printed.
    pub log: String,
    pub duration_ms: u64,
    pub message: String,
}

impl BuildOutcome {
    pub fn errors(&self) -> impl Iterator<Item = &Diagnostic> {
        self.diagnostics
            .iter()
            .filter(|d| d.severity == Severity::Error)
    }
}

/// What a document engine produced.
#[derive(Debug, Default)]
struct EngineResult {
    pdf: Option<Vec<u8>>,
    svg_pages: Vec<String>,
    outputs: Vec<BuiltOutput>,
    diagnostics: Vec<Diagnostic>,
    compile_ms: u64,
}

/// Build `req.target` of `req.tree`.
pub fn build(req: &BuildRequest<'_>, host: &dyn RunnerHost) -> BuildOutcome {
    let start = Instant::now();
    let engine = req.target.engine;
    let tree = with_override(req.tree, req.target, req.entry_override);
    let graph = BuildGraph::derive(&tree, req.target);
    let mut diagnostics: Vec<Diagnostic> = graph
        .diagnostics
        .iter()
        .filter(|d| d.code != "unreferenced")
        .cloned()
        .collect();
    let mut log = String::new();
    let mut steps: Vec<StepReport> = Vec::new();
    let mut produced: Vec<ProducedFile> = Vec::new();

    let fail =
        |message: String, log: String, diagnostics: Vec<Diagnostic>, steps: Vec<StepReport>| {
            BuildOutcome {
                ok: false,
                engine,
                outputs: vec![],
                pdf: None,
                svg_pages: vec![],
                diagnostics,
                steps,
                produced: vec![],
                log,
                duration_ms: start.elapsed().as_millis() as u64,
                message,
            }
        };

    // A directory, when something runs in one.
    let dir_steps = graph
        .steps
        .iter()
        .any(|s| s.is_stale() && matches!(s.runner, Runner::Shell | Runner::Veusz));
    if dir_steps || engine.is_latex() {
        match materialize(&tree, req.bibliographies, &req.work_dir) {
            Ok(m) => log.push_str(&format!(
                "materialised {} ({} written, {} unchanged, {} removed)\n",
                req.work_dir.display(),
                m.written.len(),
                m.unchanged.len(),
                m.removed.len()
            )),
            Err(e) => return fail(format!("materialise: {e}"), log, diagnostics, steps),
        }
    }

    // Figure steps, in dependency order.
    for step in &graph.steps {
        let report = run_step(step, &tree, req, host, &mut log, &mut produced, false);
        if report.status == StepStatus::Failed {
            diagnostics.push(Diagnostic {
                severity: Severity::Error,
                code: "step-failed".into(),
                message: report.message.clone(),
                file: Some(step.source.clone()),
                line: None,
            });
        }
        steps.push(report);
    }
    let steps_failed = steps
        .iter()
        .filter(|s| s.status == StepStatus::Failed)
        .count();

    // What the steps produced is part of the tree the engine sees — and of
    // the graph the diagnostics come from: an image a step just made is no
    // longer "not in the project", a step that ran is no longer stale.
    let tree: Cow<'_, ProjectTree> = if produced.is_empty() {
        tree
    } else {
        Cow::Owned(augmented(&tree, &produced))
    };
    if !produced.is_empty() {
        let after = BuildGraph::derive(&tree, req.target);
        diagnostics.retain(|d| d.code == "step-failed");
        diagnostics.extend(
            after
                .diagnostics
                .iter()
                .filter(|d| d.code != "unreferenced")
                .cloned(),
        );
    }

    let result = match engine {
        Engine::Typst => typst_build(&tree, req, None, &mut log),
        Engine::Markdown => markdown_build(&tree, req, &mut log, &mut diagnostics),
        Engine::Tectonic => tectonic_build(&tree, req, host, &mut log),
        Engine::Pdflatex | Engine::Xelatex | Engine::Lualatex | Engine::Latexmk => {
            latex_build(&tree, req, host, &mut log)
        }
        Engine::None => Ok(EngineResult::default()),
    };

    match result {
        Err(message) => {
            diagnostics.push(Diagnostic {
                severity: Severity::Error,
                code: "engine".into(),
                message: message.clone(),
                file: Some(req.target.entry.clone()),
                line: None,
            });
            let mut out = fail(message, log, diagnostics, steps);
            out.produced = produced;
            out
        }
        Ok(r) => {
            diagnostics.extend(r.diagnostics);
            let engine_errors = diagnostics
                .iter()
                .filter(|d| d.severity == Severity::Error)
                .count();
            let has_document = r.pdf.is_some() || !r.svg_pages.is_empty();
            let ok = steps_failed == 0
                && match engine {
                    Engine::None => true,
                    _ => has_document && engine_errors == 0,
                };
            let message = match engine {
                Engine::None => format!(
                    "{} step(s) ran, {} fresh, {} failed",
                    steps.iter().filter(|s| s.status == StepStatus::Ran).count(),
                    steps
                        .iter()
                        .filter(|s| s.status == StepStatus::Fresh)
                        .count(),
                    steps_failed
                ),
                _ if ok => format!(
                    "{} built {} in {} ms",
                    engine.as_str(),
                    r.outputs
                        .iter()
                        .find(|o| o.kind == "pdf" || o.kind == "svg")
                        .map(|o| o.name.clone())
                        .unwrap_or_else(|| "the document".into()),
                    r.compile_ms
                ),
                _ => {
                    let first = diagnostics
                        .iter()
                        .find(|d| d.severity == Severity::Error)
                        .map(|d| d.message.clone())
                        .unwrap_or_else(|| "no document produced".into());
                    format!("{} error(s): {first}", engine_errors.max(1))
                }
            };
            BuildOutcome {
                ok,
                engine,
                outputs: r.outputs,
                pdf: r.pdf,
                svg_pages: r.svg_pages,
                diagnostics,
                steps,
                produced,
                log,
                duration_ms: start.elapsed().as_millis() as u64,
                message,
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The tree the engine sees
// ---------------------------------------------------------------------------

fn replace_text(file: &ProjectFile, text: &str) -> ProjectFile {
    let mut f = ProjectFile::text(file.path.clone(), file.role, text);
    f.derived_from = file.derived_from.clone();
    f.derived_from_hash = file.derived_from_hash.clone();
    f.build = file.build.clone();
    f.bib_source = file.bib_source.clone();
    f
}

/// The tree with the target's entry text replaced by the live buffer.
fn with_override<'a>(
    tree: &'a ProjectTree,
    target: &Target,
    entry_override: Option<&str>,
) -> Cow<'a, ProjectTree> {
    let Some(text) = entry_override else {
        return Cow::Borrowed(tree);
    };
    let mut t = tree.clone();
    if t.entry.path == target.entry {
        t.entry = replace_text(&t.entry, text);
    } else if let Some(f) = t.files.iter_mut().find(|f| f.path == target.entry) {
        *f = replace_text(f, text);
    }
    Cow::Owned(t)
}

/// The tree plus what the steps produced (replacing stale rows).
fn augmented(tree: &ProjectTree, produced: &[ProducedFile]) -> ProjectTree {
    let mut files: Vec<ProjectFile> = tree
        .files
        .iter()
        .filter(|f| !produced.iter().any(|p| p.path == f.path))
        .cloned()
        .collect();
    for p in produced {
        let role = tree
            .file(&p.path)
            .map(|f| f.role)
            .unwrap_or(FileRole::Output);
        files.push(
            ProjectFile::binary(p.path.clone(), role, p.bytes.clone())
                .with_derived(p.derived_from.clone(), p.derived_from_hash.clone()),
        );
    }
    ProjectTree::new(
        tree.manuscript_id.clone(),
        tree.title.clone(),
        tree.format.clone(),
        tree.entry.clone(),
        files,
        tree.targets.clone(),
    )
}

fn entry_text(tree: &ProjectTree, target: &Target) -> Option<String> {
    tree.file(&target.entry).and_then(|f| match &f.bytes {
        FileBytes::Text(t) => Some(t.clone()),
        FileBytes::Bytes(b) => String::from_utf8(b.clone()).ok(),
        FileBytes::Missing => None,
    })
}

// ---------------------------------------------------------------------------
// Figure steps
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
fn run_step(
    step: &FigureStep,
    tree: &ProjectTree,
    req: &BuildRequest<'_>,
    host: &dyn RunnerHost,
    log: &mut String,
    produced: &mut Vec<ProducedFile>,
    force: bool,
) -> StepReport {
    let runner_name = step.runner.as_str().to_string();
    let report = |status: StepStatus,
                  message: String,
                  duration_ms: u64,
                  command: Option<String>| StepReport {
        source: step.source.clone(),
        runner: runner_name.clone(),
        status,
        message,
        duration_ms,
        outputs: step.outputs.clone(),
        input_hash: step.input_hash.clone(),
        command,
    };
    if !force && !step.is_stale() {
        return report(StepStatus::Fresh, "outputs are current".into(), 0, None);
    }
    if !step.missing_inputs.is_empty() {
        return report(
            StepStatus::Failed,
            format!("missing input(s): {}", step.missing_inputs.join(", ")),
            0,
            None,
        );
    }
    let start = Instant::now();
    let runs: Result<Vec<(RunRequest, RunOutput)>, String> = match &step.runner {
        Runner::Shell => {
            if !req.allow_shell {
                return report(
                    StepStatus::Skipped,
                    "shell steps are off for this build (allow_shell)".into(),
                    0,
                    None,
                );
            }
            let Some(command) = step.args.get("command").and_then(|v| v.as_str()) else {
                return report(
                    StepStatus::Failed,
                    "a shell step needs args.command".into(),
                    0,
                    None,
                );
            };
            let request = RunRequest::new("sh", &req.work_dir)
                .args(["-c", command])
                .timeout(STEP_TIMEOUT);
            run_one(host, request).map(|r| vec![r])
        }
        Runner::Veusz => {
            let mut runs = Vec::new();
            let mut failed = None;
            for out in &step.outputs {
                let request = RunRequest::new("veusz", &req.work_dir)
                    .args(["--export", out.as_str(), step.source.as_str()])
                    .timeout(STEP_TIMEOUT);
                match run_one(host, request) {
                    Ok(r) => runs.push(r),
                    Err(e) => {
                        failed = Some(e);
                        break;
                    }
                }
            }
            match failed {
                Some(e) => Err(e),
                None => Ok(runs),
            }
        }
        Runner::ImpressPlot | Runner::Implore | Runner::Typst => {
            // Native: rendered in memory, no directory, no process.
            return match native_outputs(step, tree, log) {
                Ok(files) => {
                    let n = files.len();
                    produced.extend(files);
                    report(
                        StepStatus::Ran,
                        format!("{n} output(s) rendered"),
                        start.elapsed().as_millis() as u64,
                        None,
                    )
                }
                Err(e) => {
                    log.push_str(&format!("step {}: {e}\n", step.source));
                    report(
                        StepStatus::Failed,
                        e,
                        start.elapsed().as_millis() as u64,
                        None,
                    )
                }
            };
        }
        Runner::Unknown(name) => {
            return report(
                StepStatus::Failed,
                format!("unknown runner {name:?} (impress-plot | implore | veusz | shell)"),
                0,
                None,
            );
        }
    };
    let duration_ms = start.elapsed().as_millis() as u64;
    let runs = match runs {
        Ok(r) => r,
        Err(e) => {
            log.push_str(&format!("step {}: {e}\n", step.source));
            return report(StepStatus::Failed, e, duration_ms, None);
        }
    };
    let command = runs
        .iter()
        .map(|(r, _)| r.display())
        .collect::<Vec<_>>()
        .join(" && ");
    for (request, out) in &runs {
        log.push_str(&format!("$ {}\n", request.display()));
        if !out.stdout.trim().is_empty() {
            log.push_str(out.stdout.trim_end());
            log.push('\n');
        }
        if !out.stderr.trim().is_empty() {
            log.push_str(out.stderr.trim_end());
            log.push('\n');
        }
        if !out.ok() {
            return report(
                StepStatus::Failed,
                format!("{}: {}", request.program, out.summary()),
                duration_ms,
                Some(command),
            );
        }
    }
    // Read the declared outputs back.
    for out in &step.outputs {
        let path = req.work_dir.join(out);
        match std::fs::read(&path) {
            Ok(bytes) => produced.push(ProducedFile {
                path: out.clone(),
                bytes,
                derived_from: step.source.clone(),
                derived_from_hash: step.input_hash.clone(),
            }),
            Err(e) => {
                return report(
                    StepStatus::Failed,
                    format!("declared output {out} was not written: {e}"),
                    duration_ms,
                    Some(command),
                )
            }
        }
    }
    report(
        StepStatus::Ran,
        format!("{} output(s) written", step.outputs.len()),
        duration_ms,
        Some(command),
    )
}

fn run_one(host: &dyn RunnerHost, request: RunRequest) -> Result<(RunRequest, RunOutput), String> {
    match host.run(&request) {
        Ok(out) => Ok((request, out)),
        Err(RunError::NotFound { program, .. }) => Err(format!("{program} is not installed here")),
        Err(e) => Err(e.to_string()),
    }
}

#[cfg(feature = "typst-render")]
fn produced_file(step: &FigureStep, path: &str, bytes: Vec<u8>) -> ProducedFile {
    ProducedFile {
        path: path.to_string(),
        bytes,
        derived_from: step.source.clone(),
        derived_from_hash: step.input_hash.clone(),
    }
}

/// The outputs of a native step (D13): an impress-plot spec rendered by
/// `impress-plot`; an implore spec turned into lilaq Typst; a Typst figure
/// source — the last two compiled by the tree's engine with the tree as
/// their world, so the figure's `csv("/data/…")` resolves (project paths are absolute from the root).
#[cfg(feature = "typst-render")]
fn native_outputs(
    step: &FigureStep,
    tree: &ProjectTree,
    log: &mut String,
) -> Result<Vec<ProducedFile>, String> {
    use super::model::OutputKind;
    let source_text = tree
        .file(&step.source)
        .and_then(|f| f.bytes.as_text())
        .ok_or_else(|| format!("{} has no text to render", step.source))?
        .to_string();
    if step.outputs.is_empty() {
        return Err(format!("{} declares no outputs", step.source));
    }
    let mut out = Vec::new();
    match &step.runner {
        Runner::ImpressPlot => {
            let spec = crate::plot_ffi::FfiPlotSpec::from_json(&source_text)
                .map_err(|e| format!("{}: {e}", step.source))?;
            for output in &step.outputs {
                let bytes = match extension_of(output).as_deref() {
                    Some("svg") => crate::plot_ffi::render_spec_svg(&spec)?.into_bytes(),
                    Some("png") => crate::plot_ffi::render_spec_png(&spec)?,
                    Some("pdf") => crate::plot_ffi::render_spec_pdf(&spec)?,
                    other => {
                        return Err(format!(
                            "{output}: impress-plot renders svg, png or pdf, not {other:?}"
                        ))
                    }
                };
                out.push(produced_file(step, output, bytes));
            }
            log.push_str(&format!(
                "impress-plot: {} → {} output(s)\n",
                step.source,
                step.outputs.len()
            ));
        }
        Runner::Implore | Runner::Typst => {
            let typst_source = if step.runner == Runner::Implore {
                let spec: implore_core::plot::types::PlotSpec = serde_json::from_str(&source_text)
                    .map_err(|e| format!("{}: implore plot spec: {e}", step.source))?;
                Some(implore_core::plot::lilaq_render::plot_spec_to_typst(&spec))
            } else {
                None
            };
            let mut svg: Option<String> = None;
            let mut pdf: Option<Vec<u8>> = None;
            for output in &step.outputs {
                let kind = match extension_of(output).as_deref() {
                    Some("svg") => OutputKind::Svg,
                    Some("pdf") => OutputKind::Pdf,
                    other => {
                        return Err(format!(
                            "{output}: a Typst figure renders svg or pdf (a raster export is not \
                             in this engine), not {other:?}"
                        ))
                    }
                };
                let cached = match kind {
                    OutputKind::Svg => svg.clone().map(String::into_bytes),
                    _ => pdf.clone(),
                };
                let bytes = match cached {
                    Some(b) => b,
                    None => {
                        let target = Target {
                            id: format!("figure:{}", step.source),
                            name: step.source.clone(),
                            entry: step.source.clone(),
                            engine: Engine::Typst,
                            output_kind: kind,
                            args: vec![],
                        };
                        let outcome = super::typst::compile_typst_tree(
                            tree,
                            &target,
                            &[],
                            typst_source.as_deref(),
                        );
                        log.push_str(&format!(
                            "{}: {} compiled in {} ms, {} diagnostic(s)\n",
                            step.runner.as_str(),
                            step.source,
                            outcome.compile_ms,
                            outcome.diagnostics.len()
                        ));
                        if !outcome.ok {
                            let first = outcome
                                .errors()
                                .next()
                                .map(|d| match (&d.file, d.line) {
                                    (Some(f), Some(l)) => format!("{f}:{l}: {}", d.message),
                                    (Some(f), None) => format!("{f}: {}", d.message),
                                    _ => d.message.clone(),
                                })
                                .unwrap_or_else(|| "the figure did not compile".into());
                            return Err(first);
                        }
                        match kind {
                            OutputKind::Svg => {
                                let page = outcome
                                    .svg_pages
                                    .into_iter()
                                    .next()
                                    .ok_or_else(|| "no page was rendered".to_string())?;
                                svg = Some(page.clone());
                                page.into_bytes()
                            }
                            _ => {
                                let bytes = outcome
                                    .pdf
                                    .ok_or_else(|| "no PDF was rendered".to_string())?;
                                pdf = Some(bytes.clone());
                                bytes
                            }
                        }
                    }
                };
                out.push(produced_file(step, output, bytes));
            }
        }
        other => return Err(format!("{} is not a native runner", other.as_str())),
    }
    Ok(out)
}

#[cfg(not(feature = "typst-render"))]
fn native_outputs(
    step: &FigureStep,
    _tree: &ProjectTree,
    _log: &mut String,
) -> Result<Vec<ProducedFile>, String> {
    Err(format!(
        "the {} runner needs imprint-core's `typst-render` feature (impress-mcp and the apps have it)",
        step.runner.as_str()
    ))
}

/// One figure step on its own — the Plots panel's Render, and
/// `project-render-figure`.
#[derive(Debug, Clone)]
pub struct FigureRender {
    pub ok: bool,
    pub step: Option<StepReport>,
    pub produced: Vec<ProducedFile>,
    /// The first SVG output, for a preview.
    pub svg: Option<String>,
    pub log: String,
    pub message: String,
    pub duration_ms: u64,
}

/// Run the figure step of `path`: its outputs come back as produced files
/// (the caller records them), `force` re-renders a fresh step. Steps that
/// need a directory (`veusz`, `shell`) get the tree materialised in
/// `work_dir`.
pub fn render_figure(
    tree: &ProjectTree,
    path: &str,
    work_dir: &Path,
    allow_shell: bool,
    force: bool,
    host: &dyn RunnerHost,
) -> FigureRender {
    let start = Instant::now();
    let target = tree.default_target().clone();
    let graph = BuildGraph::derive(tree, &target);
    let Some(step) = graph.steps.iter().find(|s| s.source == path) else {
        let reason = if tree.file(path).is_none() {
            format!("{path} is not in the project")
        } else {
            format!(
                "{path} has no figure build spec — declare one with project-set-figure-build, \
                 or give the file a name that implies its kind (.vsz, .typ, .plot.json, .py)"
            )
        };
        return FigureRender {
            ok: false,
            step: None,
            produced: vec![],
            svg: None,
            log: String::new(),
            message: reason,
            duration_ms: start.elapsed().as_millis() as u64,
        };
    };
    let mut log = String::new();
    let mut produced: Vec<ProducedFile> = Vec::new();
    if matches!(step.runner, Runner::Shell | Runner::Veusz) {
        match materialize(tree, &[], work_dir) {
            Ok(m) => log.push_str(&format!(
                "materialised {} ({} written, {} unchanged)\n",
                work_dir.display(),
                m.written.len(),
                m.unchanged.len()
            )),
            Err(e) => {
                return FigureRender {
                    ok: false,
                    step: None,
                    produced: vec![],
                    svg: None,
                    log,
                    message: format!("materialise: {e}"),
                    duration_ms: start.elapsed().as_millis() as u64,
                }
            }
        }
    }
    let req = BuildRequest {
        tree,
        target: &target,
        bibliographies: &[],
        work_dir: work_dir.to_path_buf(),
        allow_shell,
        entry_override: None,
    };
    let report = run_step(step, tree, &req, host, &mut log, &mut produced, force);
    let svg = produced
        .iter()
        .find(|p| p.path.to_ascii_lowercase().ends_with(".svg"))
        .and_then(|p| String::from_utf8(p.bytes.clone()).ok());
    let ok = matches!(report.status, StepStatus::Ran | StepStatus::Fresh);
    FigureRender {
        ok,
        message: report.message.clone(),
        step: Some(report),
        produced,
        svg,
        log,
        duration_ms: start.elapsed().as_millis() as u64,
    }
}

// ---------------------------------------------------------------------------
// Document engines
// ---------------------------------------------------------------------------

fn stem_of(entry: &str) -> String {
    let name = file_name_of(entry);
    match name.rfind('.') {
        Some(i) if i > 0 => name[..i].to_string(),
        _ => name.to_string(),
    }
}

#[cfg_attr(
    not(any(feature = "typst-render", feature = "tectonic-render")),
    allow(dead_code)
)]
fn write_output(dir: &Path, name: &str, kind: &str, bytes: &[u8]) -> Result<BuiltOutput, String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    let path = dir.join(name);
    std::fs::write(&path, bytes).map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(BuiltOutput {
        kind: kind.into(),
        name: name.into(),
        path: path.display().to_string(),
        size: bytes.len() as u64,
    })
}

#[cfg(feature = "typst-render")]
fn typst_build(
    tree: &ProjectTree,
    req: &BuildRequest<'_>,
    entry_override: Option<&str>,
    log: &mut String,
) -> Result<EngineResult, String> {
    let out =
        super::typst::compile_typst_tree(tree, req.target, req.bibliographies, entry_override);
    log.push_str(&format!(
        "typst: {} page(s) in {} ms, {} diagnostic(s)\n",
        out.page_count,
        out.compile_ms,
        out.diagnostics.len()
    ));
    let mut result = EngineResult {
        diagnostics: out.diagnostics,
        compile_ms: out.compile_ms,
        ..Default::default()
    };
    if !out.ok {
        return Ok(result);
    }
    let stem = stem_of(&req.target.entry);
    if let Some(pdf) = out.pdf {
        result.outputs.push(write_output(
            &req.work_dir,
            &format!("{stem}.pdf"),
            "pdf",
            &pdf,
        )?);
        result.pdf = Some(pdf);
    }
    for (i, svg) in out.svg_pages.iter().enumerate() {
        result.outputs.push(write_output(
            &req.work_dir,
            &format!("page-{:03}.svg", i + 1),
            "svg",
            svg.as_bytes(),
        )?);
    }
    result.svg_pages = out.svg_pages;
    Ok(result)
}

#[cfg(not(feature = "typst-render"))]
fn typst_build(
    _tree: &ProjectTree,
    _req: &BuildRequest<'_>,
    _entry_override: Option<&str>,
    _log: &mut String,
) -> Result<EngineResult, String> {
    Err("Typst rendering requires imprint-core's `typst-render` feature".into())
}

fn markdown_build(
    tree: &ProjectTree,
    req: &BuildRequest<'_>,
    log: &mut String,
    diagnostics: &mut Vec<Diagnostic>,
) -> Result<EngineResult, String> {
    let Some(text) = entry_text(tree, req.target) else {
        return Err(format!("{} has no text to convert", req.target.entry));
    };
    let converted = markdown::to_typst(&text);
    log.push_str(&format!(
        "markdown → typst: {} chars, {} warning(s)\n",
        converted.typst.len(),
        converted.warnings.len()
    ));
    for w in &converted.warnings {
        diagnostics.push(Diagnostic {
            severity: Severity::Warning,
            code: "markdown".into(),
            message: w.clone(),
            file: Some(req.target.entry.clone()),
            line: None,
        });
    }
    typst_build(tree, req, Some(&converted.typst), log)
}

/// `LatexDiagnostic`s in tree paths.
fn latex_diagnostics(
    parsed: &[crate::latex::diagnostics::LatexDiagnostic],
    entry_dir: &str,
) -> Vec<Diagnostic> {
    use crate::latex::diagnostics::Severity as LatexSeverity;
    parsed
        .iter()
        .map(|d| {
            let severity = match d.severity {
                LatexSeverity::Error => Severity::Error,
                LatexSeverity::Warning => Severity::Warning,
                LatexSeverity::Info => Severity::Info,
            };
            let file = d.file.trim_start_matches("./");
            let file = if file.is_empty() {
                None
            } else if entry_dir.is_empty() {
                Some(file.to_string())
            } else {
                Some(format!("{entry_dir}/{file}"))
            };
            Diagnostic {
                severity,
                code: "latex".into(),
                message: d.message.clone(),
                file,
                line: (d.line > 0).then_some(d.line),
            }
        })
        .collect()
}

/// Read what a LaTeX run left in `cwd` for `stem`.
fn collect_latex_outputs(cwd: &Path, stem: &str, result: &mut EngineResult) {
    let pdf_path = cwd.join(format!("{stem}.pdf"));
    if let Ok(pdf) = std::fs::read(&pdf_path) {
        result.outputs.push(BuiltOutput {
            kind: "pdf".into(),
            name: format!("{stem}.pdf"),
            path: pdf_path.display().to_string(),
            size: pdf.len() as u64,
        });
        result.pdf = Some(pdf);
    }
    for (name, kind) in [
        (format!("{stem}.synctex.gz"), "synctex"),
        (format!("{stem}.log"), "log"),
    ] {
        let path = cwd.join(&name);
        if let Ok(meta) = std::fs::metadata(&path) {
            result.outputs.push(BuiltOutput {
                kind: kind.into(),
                name,
                path: path.display().to_string(),
                size: meta.len(),
            });
        }
    }
}

fn run_logged(
    host: &dyn RunnerHost,
    request: RunRequest,
    log: &mut String,
) -> Result<RunOutput, String> {
    log.push_str(&format!("$ {}\n", request.display()));
    let (_, out) = run_one(host, request)?;
    let tail: Vec<&str> = out
        .stdout
        .lines()
        .rev()
        .take(20)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    if !tail.is_empty() {
        log.push_str(&tail.join("\n"));
        log.push('\n');
    }
    if !out.stderr.trim().is_empty() {
        log.push_str(out.stderr.trim_end());
        log.push('\n');
    }
    Ok(out)
}

fn latex_build(
    tree: &ProjectTree,
    req: &BuildRequest<'_>,
    host: &dyn RunnerHost,
    log: &mut String,
) -> Result<EngineResult, String> {
    latex_build_with(tree, req, req.target.engine, host, log)
}

/// A system TeX engine over the materialised directory: the engine's
/// passes, BibTeX/Biber when the aux asks, the log parsed into diagnostics.
fn latex_build_with(
    tree: &ProjectTree,
    req: &BuildRequest<'_>,
    engine: Engine,
    host: &dyn RunnerHost,
    log: &mut String,
) -> Result<EngineResult, String> {
    let target = req.target;
    let entry_dir = dir_of(&target.entry).to_string();
    let cwd = if entry_dir.is_empty() {
        req.work_dir.clone()
    } else {
        req.work_dir.join(&entry_dir)
    };
    let entry_name = file_name_of(&target.entry).to_string();
    let stem = stem_of(&target.entry);
    if tree.file(&target.entry).is_none() {
        return Err(format!("{} is not in the tree", target.entry));
    }
    let program = engine.as_str().to_string();
    if host.which(&program).is_none() {
        return Err(format!(
            "{program} is not installed here (TeX Live puts it in /Library/TeX/texbin); \
             the tectonic engine needs no TeX installation"
        ));
    }
    let common = [
        "-interaction=nonstopmode",
        "-halt-on-error",
        "-file-line-error",
        "-synctex=1",
    ];
    let engine_request = |extra: &[&str]| {
        let mut r = RunRequest::new(&program, &cwd).timeout(ENGINE_TIMEOUT);
        if engine == Engine::Latexmk {
            r = r.arg("-pdf");
        }
        r = r.args(common.iter().copied());
        r = r.args(extra.iter().copied());
        r = r.args(target.args.iter().cloned());
        r.arg(&entry_name)
    };

    let start = Instant::now();
    let mut result = EngineResult::default();
    let first = run_logged(host, engine_request(&[]), log)?;
    let mut last = first;
    if engine != Engine::Latexmk && last.ok() {
        // Bibliography: BibTeX when the aux asks for it, Biber when biblatex
        // left a .bcf; then the passes that settle references.
        let aux = std::fs::read_to_string(cwd.join(format!("{stem}.aux"))).unwrap_or_default();
        let wants_bib = aux.contains("\\citation") || aux.contains("\\bibdata");
        let biber = cwd.join(format!("{stem}.bcf")).is_file();
        if wants_bib || biber {
            let bib_program = if biber { "biber" } else { "bibtex" };
            if host.which(bib_program).is_some() {
                let bib = run_logged(
                    host,
                    RunRequest::new(bib_program, &cwd)
                        .arg(&stem)
                        .timeout(ENGINE_TIMEOUT),
                    log,
                )?;
                if !bib.ok() {
                    log.push_str(&format!("{bib_program}: {}\n", bib.summary()));
                }
                last = run_logged(host, engine_request(&[]), log)?;
            } else {
                log.push_str(&format!(
                    "{bib_program} is not installed here; citations stay unresolved\n"
                ));
            }
        }
        let log_text = std::fs::read_to_string(cwd.join(format!("{stem}.log"))).unwrap_or_default();
        if last.ok() && (wants_bib || biber || log_text.contains("Rerun to get")) {
            last = run_logged(host, engine_request(&[]), log)?;
        }
    }
    result.compile_ms = start.elapsed().as_millis() as u64;

    let log_text = std::fs::read_to_string(cwd.join(format!("{stem}.log"))).unwrap_or_default();
    result.diagnostics =
        latex_diagnostics(&crate::latex::diagnostics::parse_log(&log_text), &entry_dir);
    collect_latex_outputs(&cwd, &stem, &mut result);
    if !last.ok()
        && !result
            .diagnostics
            .iter()
            .any(|d| d.severity == Severity::Error)
    {
        result.diagnostics.push(Diagnostic {
            severity: Severity::Error,
            code: "latex".into(),
            message: format!("{program}: {}", last.summary()),
            file: Some(target.entry.clone()),
            line: None,
        });
    }
    if last.ok() && result.pdf.is_none() {
        result.diagnostics.push(Diagnostic {
            severity: Severity::Error,
            code: "latex".into(),
            message: format!("{program} finished without writing {stem}.pdf"),
            file: Some(target.entry.clone()),
            line: None,
        });
    }
    Ok(result)
}

#[cfg(feature = "tectonic-render")]
fn tectonic_build(
    tree: &ProjectTree,
    req: &BuildRequest<'_>,
    _host: &dyn RunnerHost,
    log: &mut String,
) -> Result<EngineResult, String> {
    let Some(source) = entry_text(tree, req.target) else {
        return Err(format!("{} has no text", req.target.entry));
    };
    let entry_dir = dir_of(&req.target.entry).to_string();
    let root = if entry_dir.is_empty() {
        req.work_dir.clone()
    } else {
        req.work_dir.join(&entry_dir)
    };
    let cache = dirs::cache_dir().map(|c| c.join("impress").join("tectonic"));
    let r = crate::latex::tectonic::compile_latex_tectonic(
        &source,
        true,
        cache.as_ref().and_then(|c| c.to_str()),
        root.to_str(),
    );
    log.push_str(&format!(
        "tectonic (in-process): {} ms, {} diagnostic(s)\n",
        r.compile_ms,
        r.diagnostics.len()
    ));
    let stem = stem_of(&req.target.entry);
    let mut result = EngineResult {
        diagnostics: latex_diagnostics(&r.diagnostics, &entry_dir),
        compile_ms: r.compile_ms,
        ..Default::default()
    };
    if let Some(e) = &r.error {
        if !result
            .diagnostics
            .iter()
            .any(|d| d.severity == Severity::Error)
        {
            result.diagnostics.push(Diagnostic {
                severity: Severity::Error,
                code: "latex".into(),
                message: e.clone(),
                file: Some(req.target.entry.clone()),
                line: None,
            });
        }
    }
    if let Some(pdf) = r.pdf_data {
        result
            .outputs
            .push(write_output(&root, &format!("{stem}.pdf"), "pdf", &pdf)?);
        result.pdf = Some(pdf);
    }
    if let Some(synctex) = r.synctex_data {
        result.outputs.push(write_output(
            &root,
            &format!("{stem}.synctex.gz"),
            "synctex",
            &synctex,
        )?);
    }
    if !r.log.is_empty() {
        result.outputs.push(write_output(
            &root,
            &format!("{stem}.log"),
            "log",
            r.log.as_bytes(),
        )?);
    }
    Ok(result)
}

/// Without the embedded engine: the `tectonic` command, when installed.
#[cfg(not(feature = "tectonic-render"))]
fn tectonic_build(
    tree: &ProjectTree,
    req: &BuildRequest<'_>,
    host: &dyn RunnerHost,
    log: &mut String,
) -> Result<EngineResult, String> {
    let target = req.target;
    if tree.file(&target.entry).is_none() {
        return Err(format!("{} is not in the tree", target.entry));
    }
    if host.which("tectonic").is_none() {
        // No Tectonic anywhere: a system engine, when one is installed,
        // builds the same tree — say so, rather than refusing a build the
        // machine can do.
        for fallback in [Engine::Latexmk, Engine::Pdflatex] {
            if host.which(fallback.as_str()).is_some() {
                log.push_str(&format!(
                    "tectonic is not installed here; building with {} instead\n",
                    fallback.as_str()
                ));
                return latex_build_with(tree, req, fallback, host, log);
            }
        }
        return Err(
            "the embedded Tectonic engine is not in this build and no `tectonic`, `latexmk` or \
             `pdflatex` command is installed (TeX Live puts them in /Library/TeX/texbin)"
                .into(),
        );
    }
    let entry_dir = dir_of(&target.entry).to_string();
    let cwd = if entry_dir.is_empty() {
        req.work_dir.clone()
    } else {
        req.work_dir.join(&entry_dir)
    };
    let stem = stem_of(&target.entry);
    let start = Instant::now();
    let out = run_logged(
        host,
        RunRequest::new("tectonic", &cwd)
            .args(["--keep-logs", "--synctex", "-o", "."])
            .args(target.args.iter().cloned())
            .arg(file_name_of(&target.entry))
            .timeout(ENGINE_TIMEOUT),
        log,
    )?;
    let mut result = EngineResult {
        compile_ms: start.elapsed().as_millis() as u64,
        ..Default::default()
    };
    let log_text = std::fs::read_to_string(cwd.join(format!("{stem}.log"))).unwrap_or_default();
    result.diagnostics =
        latex_diagnostics(&crate::latex::diagnostics::parse_log(&log_text), &entry_dir);
    collect_latex_outputs(&cwd, &stem, &mut result);
    if !out.ok()
        && !result
            .diagnostics
            .iter()
            .any(|d| d.severity == Severity::Error)
    {
        result.diagnostics.push(Diagnostic {
            severity: Severity::Error,
            code: "latex".into(),
            message: format!("tectonic: {}", out.summary()),
            file: Some(target.entry.clone()),
            line: None,
        });
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::model::{BuildSpec, OutputKind};
    use crate::project::runner::ScriptedRunnerHost;
    use std::collections::BTreeMap;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    fn latex_tree() -> ProjectTree {
        let entry = ProjectFile::text(
            "main.tex",
            FileRole::Main,
            "\\documentclass{article}\n\\begin{document}\n\\input{chapters/intro}\n\\cite{knuth84}\n\\bibliography{refs}\n\\end{document}\n",
        );
        let files = vec![
            ProjectFile::text(
                "chapters/intro.tex",
                FileRole::Chapter,
                "\\section{Intro}\n",
            ),
            ProjectFile::text(
                "refs.bib",
                FileRole::Bibliography,
                "@article{knuth84, title={T}}\n",
            ),
        ];
        ProjectTree::new("m", "Paper", "latex", entry, files, vec![])
    }

    fn target(engine: Engine, entry: &str) -> Target {
        Target {
            id: "main".into(),
            name: "main".into(),
            entry: entry.into(),
            engine,
            output_kind: OutputKind::Pdf,
            args: vec![],
        }
    }

    #[test]
    fn a_system_latex_build_materialises_runs_the_passes_and_reads_the_log() {
        let dir = tempfile::tempdir().unwrap();
        let passes = Arc::new(AtomicUsize::new(0));
        let counter = passes.clone();
        let host = ScriptedRunnerHost::new(&["pdflatex", "bibtex"], move |req| {
            if req.program == "pdflatex" {
                let n = counter.fetch_add(1, Ordering::SeqCst);
                let entry = req.args.last().unwrap();
                assert_eq!(entry, "main.tex");
                assert!(req.args.contains(&"-file-line-error".to_string()));
                // The materialised tree is there.
                assert!(req.cwd.join("chapters/intro.tex").is_file());
                std::fs::write(
                    req.cwd.join("main.aux"),
                    "\\citation{knuth84}\n\\bibdata{refs}\n",
                )
                .unwrap();
                std::fs::write(
                    req.cwd.join("main.log"),
                    format!(
                        "This is pdfTeX\n(./main.tex (./chapters/intro.tex\nLaTeX Warning: Citation `knuth84' undefined on input line 4.\n)) pass {n}\n"
                    ),
                )
                .unwrap();
                std::fs::write(req.cwd.join("main.pdf"), b"%PDF-1.4 fake").unwrap();
            }
            ScriptedRunnerHost::success()
        });
        let tree = latex_tree();
        let t = target(Engine::Pdflatex, "main.tex");
        let req = BuildRequest {
            tree: &tree,
            target: &t,
            bibliographies: &[],
            work_dir: dir.path().join("build"),
            allow_shell: false,
            entry_override: None,
        };
        let out = build(&req, &host);
        assert!(out.ok, "{}: {}", out.message, out.log);
        assert_eq!(
            passes.load(Ordering::SeqCst),
            3,
            "engine, bibtex, engine, engine"
        );
        let calls = host.calls();
        assert_eq!(calls[1].program, "bibtex");
        assert_eq!(calls[1].args, vec!["main".to_string()]);
        assert_eq!(
            out.outputs
                .iter()
                .map(|o| o.kind.as_str())
                .collect::<Vec<_>>(),
            vec!["pdf", "log"]
        );
        assert_eq!(out.pdf.as_deref(), Some(&b"%PDF-1.4 fake"[..]));
        assert!(out
            .diagnostics
            .iter()
            .any(|d| d.severity == Severity::Warning
                && d.message.contains("knuth84")
                && d.line == Some(4)));
        assert!(out.log.contains("$ pdflatex -interaction=nonstopmode"));
    }

    #[test]
    fn a_missing_engine_is_a_clear_error_not_a_hang() {
        let dir = tempfile::tempdir().unwrap();
        let host = ScriptedRunnerHost::empty();
        let tree = latex_tree();
        let t = target(Engine::Xelatex, "main.tex");
        let req = BuildRequest {
            tree: &tree,
            target: &t,
            bibliographies: &[],
            work_dir: dir.path().to_path_buf(),
            allow_shell: false,
            entry_override: None,
        };
        let out = build(&req, &host);
        assert!(!out.ok);
        assert!(
            out.message.contains("xelatex is not installed"),
            "{}",
            out.message
        );
        assert!(out.errors().any(|d| d.code == "engine"));
    }

    #[test]
    fn shell_steps_are_gated_and_their_outputs_become_produced_files() {
        let dir = tempfile::tempdir().unwrap();
        let entry = ProjectFile::text("main.typ", FileRole::Main, "#image(\"figures/plot.png\")");
        let source = ProjectFile::text("figures/make.py", FileRole::FigureSource, "print(1)")
            .with_build(BuildSpec {
                runner: Runner::Shell,
                outputs: vec!["figures/plot.png".into()],
                inputs: vec![],
                args: BTreeMap::from([(
                    "command".to_string(),
                    serde_json::Value::String("python figures/make.py".into()),
                )]),
            });
        let tree = ProjectTree::new("m", "Paper", "typst", entry, vec![source], vec![]);
        let t = target(Engine::None, "main.typ");
        let host = ScriptedRunnerHost::new(&["sh"], |req| {
            assert_eq!(
                req.args,
                vec!["-c".to_string(), "python figures/make.py".to_string()]
            );
            std::fs::create_dir_all(req.cwd.join("figures")).unwrap();
            std::fs::write(req.cwd.join("figures/plot.png"), b"\x89PNG").unwrap();
            ScriptedRunnerHost::success()
        });

        // Off by default.
        let req = BuildRequest {
            tree: &tree,
            target: &t,
            bibliographies: &[],
            work_dir: dir.path().join("build"),
            allow_shell: false,
            entry_override: None,
        };
        let out = build(&req, &host);
        assert_eq!(out.steps.len(), 1);
        assert_eq!(out.steps[0].status, StepStatus::Skipped);
        assert!(host.calls().is_empty());
        assert!(out.ok, "a skipped step is not a failure: {}", out.message);

        // Allowed: runs in the materialised directory, output read back.
        let req = BuildRequest {
            allow_shell: true,
            ..req
        };
        let out = build(&req, &host);
        assert!(out.ok, "{}", out.message);
        assert_eq!(out.steps[0].status, StepStatus::Ran);
        assert_eq!(
            out.steps[0].command.as_deref(),
            Some("sh -c \"python figures/make.py\"")
        );
        assert_eq!(out.produced.len(), 1);
        assert_eq!(out.produced[0].path, "figures/plot.png");
        assert_eq!(out.produced[0].derived_from, "figures/make.py");
        assert!(!out.produced[0].derived_from_hash.is_empty());
        assert!(
            dir.path().join("build/figures/make.py").is_file(),
            "materialised for the step"
        );
    }

    #[test]
    fn the_live_buffer_replaces_the_entry_before_anything_runs() {
        let dir = tempfile::tempdir().unwrap();
        let host = ScriptedRunnerHost::new(&["latexmk"], |req| {
            let text = std::fs::read_to_string(req.cwd.join("main.tex")).unwrap();
            assert!(text.contains("LIVE"), "the override was materialised");
            assert!(req.args.contains(&"-pdf".to_string()));
            std::fs::write(req.cwd.join("main.pdf"), b"%PDF").unwrap();
            std::fs::write(req.cwd.join("main.log"), "").unwrap();
            ScriptedRunnerHost::success()
        });
        let tree = latex_tree();
        let t = target(Engine::Latexmk, "main.tex");
        let req = BuildRequest {
            tree: &tree,
            target: &t,
            bibliographies: &[],
            work_dir: dir.path().to_path_buf(),
            allow_shell: false,
            entry_override: Some("\\documentclass{article}\\begin{document}LIVE\\end{document}"),
        };
        let out = build(&req, &host);
        assert!(out.ok, "{}", out.message);
        assert_eq!(host.calls().len(), 1, "latexmk settles its own passes");
    }
}

#[cfg(all(test, feature = "typst-render"))]
mod native_tests {
    use super::*;
    use crate::project::figures::{template, FigureKind};
    use crate::project::model::BuildSpec;
    use crate::project::runner::ScriptedRunnerHost;

    fn lilaq_available() -> bool {
        crate::typst_packages::CachedPackageResolver::discover()
            .has_package("preview", "lilaq", "0.6.0")
    }

    fn tree_with(kind: FigureKind) -> (ProjectTree, String) {
        let t = template(kind, "figures/growth");
        let entry = ProjectFile::text(
            "main.typ",
            FileRole::Main,
            "= Paper\n#figure(image(\"figures/growth.svg\"))",
        );
        let source = ProjectFile::text(t.path.clone(), FileRole::FigureSource, t.text.clone())
            .with_build(t.build.clone());
        (
            ProjectTree::new("m", "Paper", "typst", entry, vec![source], vec![]),
            t.path,
        )
    }

    #[test]
    fn a_typst_figure_source_renders_with_the_tree_as_its_world() {
        let dir = tempfile::tempdir().unwrap();
        let entry = ProjectFile::text("main.typ", FileRole::Main, "#image(\"figures/f.svg\")");
        let source = ProjectFile::text(
            "figures/f.typ",
            FileRole::FigureSource,
            "#set page(width: auto, height: auto, margin: 2pt)\n#let rows = csv(\"/data/x.csv\")\n#box(width: 4cm, height: 2cm, stroke: 1pt)[#rows.len() rows]",
        )
        .with_build(BuildSpec::default_for("figures/f.typ", None).unwrap());
        let data = ProjectFile::text("data/x.csv", FileRole::Data, "a,b\n1,2\n3,4\n");
        let tree = ProjectTree::new("m", "P", "typst", entry, vec![source, data], vec![]);
        let host = ScriptedRunnerHost::empty();
        let r = render_figure(&tree, "figures/f.typ", dir.path(), false, false, &host);
        assert!(r.ok, "{}: {}", r.message, r.log);
        assert_eq!(r.produced.len(), 1);
        assert_eq!(r.produced[0].path, "figures/f.svg");
        assert!(r.svg.as_deref().is_some_and(|s| s.contains("<svg")));
        assert_eq!(r.step.as_ref().unwrap().status, StepStatus::Ran);

        // Rendering again with the output in the tree is fresh; forcing re-renders.
        let mut with_output = tree.clone();
        with_output.upsert_file(
            ProjectFile::binary(
                "figures/f.svg",
                FileRole::Output,
                r.produced[0].bytes.clone(),
            )
            .with_derived("figures/f.typ", r.produced[0].derived_from_hash.clone()),
        );
        let fresh = render_figure(
            &with_output,
            "figures/f.typ",
            dir.path(),
            false,
            false,
            &host,
        );
        assert_eq!(fresh.step.unwrap().status, StepStatus::Fresh);
        let forced = render_figure(
            &with_output,
            "figures/f.typ",
            dir.path(),
            false,
            true,
            &host,
        );
        assert_eq!(forced.step.unwrap().status, StepStatus::Ran);
    }

    #[test]
    fn plot_specs_render_natively_and_through_lilaq() {
        let dir = tempfile::tempdir().unwrap();
        let host = ScriptedRunnerHost::empty();

        let (tree, path) = tree_with(FigureKind::ImpressPlot);
        let r = render_figure(&tree, &path, dir.path(), false, false, &host);
        assert!(r.ok, "{}: {}", r.message, r.log);
        assert!(r.svg.as_deref().is_some_and(|s| s.contains("<svg")));

        if !lilaq_available() {
            eprintln!("skipping the lilaq halves: lilaq 0.6.0 not in a local typst package root");
            return;
        }
        let (tree, path) = tree_with(FigureKind::ImplorePlot);
        let r = render_figure(&tree, &path, dir.path(), false, false, &host);
        assert!(r.ok, "{}: {}", r.message, r.log);
        assert!(r.svg.as_deref().is_some_and(|s| s.contains("<svg")));

        let (tree, path) = tree_with(FigureKind::Lilaq);
        let r = render_figure(&tree, &path, dir.path(), false, false, &host);
        assert!(r.ok, "{}: {}", r.message, r.log);
        assert!(r.svg.as_deref().is_some_and(|s| s.contains("<svg")));

        // A whole build runs the native step and places the figure.
        let t = tree.default_target().clone();
        let out = build(
            &BuildRequest {
                tree: &tree,
                target: &t,
                bibliographies: &[],
                work_dir: dir.path().join("build"),
                allow_shell: false,
                entry_override: None,
            },
            &host,
        );
        assert!(out.ok, "{}: {}", out.message, out.log);
        assert_eq!(out.steps[0].status, StepStatus::Ran);
        assert_eq!(out.produced.len(), 1);
        assert!(out.pdf.is_some());
    }

    #[test]
    fn a_figure_without_a_spec_says_so() {
        let dir = tempfile::tempdir().unwrap();
        let entry = ProjectFile::text("main.typ", FileRole::Main, "= P");
        let tree = ProjectTree::new("m", "P", "typst", entry, vec![], vec![]);
        let r = render_figure(
            &tree,
            "figures/none.typ",
            dir.path(),
            false,
            false,
            &ScriptedRunnerHost::empty(),
        );
        assert!(!r.ok);
        assert!(r.message.contains("not in the project"));
    }
}
