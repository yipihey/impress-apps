//! The build graph (ADR-0030 D4/D6): what a target reaches, which figure
//! steps must run first, which outputs are stale, and every diagnostic a
//! build would hit before it starts. Derived from the tree and its scan —
//! never stored, so it cannot drift from the source.

use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};

use serde::{Deserialize, Serialize};

use super::model::{FileKind, FileRole, ProjectTree, Runner, Target};
use super::scan::{scan, DepKind, DependencyGraph};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Error,
    Warning,
    Info,
}

/// A structured message in tree paths, so a click lands in the right file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Diagnostic {
    pub severity: Severity,
    /// A stable code (`unresolved-include`, `include-cycle`, `stale-output`, …).
    pub code: String,
    pub message: String,
    pub file: Option<String>,
    pub line: Option<u32>,
}

impl Diagnostic {
    fn new(severity: Severity, code: &str, message: String) -> Self {
        Self {
            severity,
            code: code.into(),
            message,
            file: None,
            line: None,
        }
    }

    fn at(mut self, file: &str, line: Option<u32>) -> Self {
        self.file = Some(file.to_string());
        self.line = line;
        self
    }
}

/// One figure step the build must run before compiling (D6).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FigureStep {
    pub source: String,
    pub runner: Runner,
    pub outputs: Vec<String>,
    pub inputs: Vec<String>,
    pub args: BTreeMap<String, serde_json::Value>,
    /// sha256 over (source bytes, each input's bytes, canonical build spec)
    /// — what `derived_from_hash` on the outputs is compared against.
    pub input_hash: String,
    /// Outputs whose recorded hash is not this step's `input_hash`, or that
    /// do not exist yet.
    pub stale_outputs: Vec<String>,
    /// Declared outputs with no row in the tree.
    pub missing_outputs: Vec<String>,
    /// Declared inputs with no row in the tree.
    pub missing_inputs: Vec<String>,
}

impl FigureStep {
    pub fn is_stale(&self) -> bool {
        !self.stale_outputs.is_empty() || !self.missing_outputs.is_empty()
    }
}

/// Everything a build needs to know before it runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BuildGraph {
    pub target_id: String,
    pub entry: String,
    pub deps: DependencyGraph,
    /// In the order they should run (a step whose output another step
    /// reads comes first).
    pub steps: Vec<FigureStep>,
    /// Files the target's entry reaches, transitively.
    pub reachable: BTreeSet<String>,
    /// Text and figure files nothing reaches from the entry.
    pub unreferenced: Vec<String>,
    pub diagnostics: Vec<Diagnostic>,
}

impl BuildGraph {
    /// Derive the graph for `target` over `tree`.
    pub fn derive(tree: &ProjectTree, target: &Target) -> Self {
        let deps = scan(tree);
        Self::from_scan(tree, target, deps)
    }

    /// Derive from a scan the caller already has (the verbs scan once and
    /// derive per target).
    pub fn from_scan(tree: &ProjectTree, target: &Target, deps: DependencyGraph) -> Self {
        let mut diagnostics: Vec<Diagnostic> = Vec::new();

        // --- the entry ---------------------------------------------------
        let entry_ok = tree.contains(&target.entry);
        if !entry_ok {
            diagnostics.push(Diagnostic::new(
                Severity::Error,
                "missing-entry",
                format!(
                    "target {:?} names entry {:?}, which is not in the project",
                    target.id, target.entry
                ),
            ));
        } else if let Some(file) = tree.file(&target.entry) {
            let wanted = target.engine.source_format();
            if let Some(have) = file.format.as_deref() {
                if wanted != "plaintext" && have != wanted {
                    diagnostics.push(
                        Diagnostic::new(
                            Severity::Warning,
                            "engine-format-mismatch",
                            format!(
                                "target {:?} compiles {:?} with {}, but the file is {}",
                                target.id,
                                target.entry,
                                target.engine.as_str(),
                                have
                            ),
                        )
                        .at(&target.entry, None),
                    );
                }
            }
        }

        // --- unresolved references ---------------------------------------
        for u in &deps.unresolved {
            diagnostics.push(
                Diagnostic::new(
                    Severity::Error,
                    &format!("unresolved-{}", u.kind.as_str()),
                    format!(
                        "{} {:?} is not in the project",
                        u.kind.as_str(),
                        u.reference
                    ),
                )
                .at(&u.from, Some(u.line)),
            );
        }

        // --- reachability from the entry ---------------------------------
        let mut reachable: BTreeSet<String> = BTreeSet::new();
        if entry_ok {
            let mut queue: VecDeque<String> = VecDeque::new();
            queue.push_back(target.entry.clone());
            reachable.insert(target.entry.clone());
            while let Some(current) = queue.pop_front() {
                for edge in deps.edges_from(&current) {
                    if reachable.insert(edge.to.clone()) {
                        queue.push_back(edge.to.clone());
                    }
                }
            }
        }

        // --- include cycles (text splicing only) --------------------------
        if let Some(cycle) = find_include_cycle(&deps, &target.entry) {
            let first = cycle.first().cloned().unwrap_or_default();
            let line = deps
                .edges
                .iter()
                .find(|e| {
                    e.from == first
                        && cycle.get(1).map(|n| n == &e.to).unwrap_or(false)
                        && matches!(e.kind, DepKind::Include | DepKind::Import)
                })
                .map(|e| e.line);
            diagnostics.push(
                Diagnostic::new(
                    Severity::Error,
                    "include-cycle",
                    format!("include cycle: {}", cycle.join(" → ")),
                )
                .at(&first, line),
            );
        }

        // --- figure steps -------------------------------------------------
        let mut steps: Vec<FigureStep> = Vec::new();
        for source in tree.figure_sources() {
            let Some(spec) = &source.build else {
                continue;
            };
            if let Runner::Unknown(name) = &spec.runner {
                diagnostics.push(
                    Diagnostic::new(
                        Severity::Error,
                        "unknown-runner",
                        format!(
                            "{:?} names runner {:?}, which nothing here can run",
                            source.path, name
                        ),
                    )
                    .at(&source.path, None),
                );
            }
            if spec.outputs.is_empty() {
                diagnostics.push(
                    Diagnostic::new(
                        Severity::Warning,
                        "no-outputs",
                        format!("{:?} declares a build with no outputs", source.path),
                    )
                    .at(&source.path, None),
                );
            }
            let missing_inputs: Vec<String> = spec
                .inputs
                .iter()
                .filter(|p| !tree.contains(p))
                .cloned()
                .collect();
            for p in &missing_inputs {
                diagnostics.push(
                    Diagnostic::new(
                        Severity::Error,
                        "missing-input",
                        format!(
                            "{:?} reads {:?}, which is not in the project",
                            source.path, p
                        ),
                    )
                    .at(&source.path, None),
                );
            }
            let input_hash = step_input_hash(tree, &source.path);
            let mut stale_outputs = Vec::new();
            let mut missing_outputs = Vec::new();
            for out in &spec.outputs {
                match tree.file(out) {
                    None => missing_outputs.push(out.clone()),
                    Some(f) => {
                        if f.derived_from_hash.as_deref() != Some(input_hash.as_str()) {
                            stale_outputs.push(out.clone());
                        }
                    }
                }
            }
            for p in &missing_outputs {
                diagnostics.push(
                    Diagnostic::new(
                        Severity::Warning,
                        "output-not-built",
                        format!("{:?} has not been built from {:?} yet", p, source.path),
                    )
                    .at(&source.path, None),
                );
            }
            for p in &stale_outputs {
                diagnostics.push(
                    Diagnostic::new(
                        Severity::Warning,
                        "stale-output",
                        format!(
                            "{:?} is stale: {:?} or its inputs changed since it was built",
                            p, source.path
                        ),
                    )
                    .at(p, None),
                );
            }
            steps.push(FigureStep {
                source: source.path.clone(),
                runner: spec.runner.clone(),
                outputs: spec.outputs.clone(),
                inputs: spec.inputs.clone(),
                args: spec.args.clone(),
                input_hash,
                stale_outputs,
                missing_outputs,
                missing_inputs,
            });
        }
        order_steps(&mut steps);

        // --- unreferenced files -------------------------------------------
        let step_paths: BTreeSet<&str> = steps
            .iter()
            .flat_map(|s| {
                std::iter::once(s.source.as_str())
                    .chain(s.outputs.iter().map(String::as_str))
                    .chain(s.inputs.iter().map(String::as_str))
            })
            .collect();
        let mut unreferenced: Vec<String> = Vec::new();
        for file in &tree.files {
            if reachable.contains(&file.path) || step_paths.contains(file.path.as_str()) {
                continue;
            }
            let worth_noting = match file.role {
                FileRole::Chapter | FileRole::Figure | FileRole::Bibliography | FileRole::Data => {
                    true
                }
                FileRole::Supplement => file.kind == FileKind::Text,
                _ => false,
            };
            if worth_noting {
                unreferenced.push(file.path.clone());
                diagnostics.push(
                    Diagnostic::new(
                        Severity::Info,
                        "unreferenced",
                        format!("{:?} is not referenced from {:?}", file.path, target.entry),
                    )
                    .at(&file.path, None),
                );
            }
        }

        diagnostics.sort_by(|a, b| {
            (
                a.severity,
                a.file.as_deref().unwrap_or(""),
                a.line.unwrap_or(0),
            )
                .cmp(&(
                    b.severity,
                    b.file.as_deref().unwrap_or(""),
                    b.line.unwrap_or(0),
                ))
        });

        Self {
            target_id: target.id.clone(),
            entry: target.entry.clone(),
            deps,
            steps,
            reachable,
            unreferenced,
            diagnostics,
        }
    }

    pub fn has_errors(&self) -> bool {
        self.diagnostics
            .iter()
            .any(|d| d.severity == Severity::Error)
    }

    pub fn errors(&self) -> impl Iterator<Item = &Diagnostic> {
        self.diagnostics
            .iter()
            .filter(|d| d.severity == Severity::Error)
    }

    pub fn stale_steps(&self) -> impl Iterator<Item = &FigureStep> {
        self.steps.iter().filter(|s| s.is_stale())
    }

    /// The bibliography files the target reaches (declared by reference),
    /// in first-reference order.
    pub fn bibliographies(&self) -> Vec<String> {
        let mut seen = BTreeSet::new();
        let mut out = Vec::new();
        for e in &self.deps.edges {
            if e.kind == DepKind::Bibliography
                && self.reachable.contains(&e.from)
                && seen.insert(e.to.clone())
            {
                out.push(e.to.clone());
            }
        }
        out
    }
}

/// sha256 over the source's bytes, each declared input's bytes (in the
/// declared order, missing ones as empty) and the canonical build spec.
pub fn step_input_hash(tree: &ProjectTree, source_path: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    let Some(source) = tree.file(source_path) else {
        return String::new();
    };
    hasher.update(b"source\0");
    hasher.update(source.content_hash.as_bytes());
    if let Some(spec) = &source.build {
        for input in &spec.inputs {
            hasher.update(b"\0input\0");
            hasher.update(input.as_bytes());
            hasher.update(b"\0");
            match tree.file(input) {
                Some(f) => hasher.update(f.content_hash.as_bytes()),
                None => hasher.update(b"missing"),
            }
        }
        hasher.update(b"\0spec\0");
        let canonical = serde_json::to_string(spec).unwrap_or_default();
        hasher.update(canonical.as_bytes());
    }
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect()
}

/// Topological order over "step A writes what step B reads"; ties keep
/// path order. A cycle among steps is left in path order (the build reports
/// it when a step's input is another's output and vice versa).
fn order_steps(steps: &mut [FigureStep]) {
    let n = steps.len();
    if n < 2 {
        return;
    }
    let produces: HashMap<&str, usize> = steps
        .iter()
        .enumerate()
        .flat_map(|(i, s)| s.outputs.iter().map(move |o| (o.as_str(), i)))
        .collect();
    let mut indegree = vec![0usize; n];
    let mut successors: Vec<Vec<usize>> = vec![Vec::new(); n];
    for (i, step) in steps.iter().enumerate() {
        for input in &step.inputs {
            if let Some(&producer) = produces.get(input.as_str()) {
                if producer != i {
                    successors[producer].push(i);
                    indegree[i] += 1;
                }
            }
        }
    }
    let mut ready: Vec<usize> = (0..n).filter(|i| indegree[*i] == 0).collect();
    let mut order: Vec<usize> = Vec::with_capacity(n);
    while !ready.is_empty() {
        ready.sort_unstable_by(|a, b| b.cmp(a));
        let i = ready.pop().unwrap();
        order.push(i);
        for &s in &successors[i] {
            indegree[s] -= 1;
            if indegree[s] == 0 {
                ready.push(s);
            }
        }
    }
    if order.len() != n {
        return; // a cycle: leave the path order
    }
    let reordered: Vec<FigureStep> = order.iter().map(|&i| steps[i].clone()).collect();
    steps.clone_from_slice(&reordered);
}

/// A cycle among include/import edges reachable from `entry`, as the path
/// of nodes (first node repeated at the end).
fn find_include_cycle(deps: &DependencyGraph, entry: &str) -> Option<Vec<String>> {
    #[derive(Clone, Copy, PartialEq)]
    enum Mark {
        White,
        Grey,
        Black,
    }
    let mut marks: HashMap<&str, Mark> = HashMap::new();
    let mut stack: Vec<&str> = Vec::new();

    fn visit<'a>(
        node: &'a str,
        deps: &'a DependencyGraph,
        marks: &mut HashMap<&'a str, Mark>,
        stack: &mut Vec<&'a str>,
    ) -> Option<Vec<String>> {
        marks.insert(node, Mark::Grey);
        stack.push(node);
        for edge in deps.edges_from(node) {
            if !matches!(edge.kind, DepKind::Include | DepKind::Import) {
                continue;
            }
            match marks.get(edge.to.as_str()).copied().unwrap_or(Mark::White) {
                Mark::Grey => {
                    let start = stack.iter().position(|n| *n == edge.to).unwrap_or(0);
                    let mut cycle: Vec<String> =
                        stack[start..].iter().map(|s| s.to_string()).collect();
                    cycle.push(edge.to.clone());
                    return Some(cycle);
                }
                Mark::White => {
                    if let Some(c) = visit(edge.to.as_str(), deps, marks, stack) {
                        return Some(c);
                    }
                }
                Mark::Black => {}
            }
        }
        stack.pop();
        marks.insert(node, Mark::Black);
        None
    }

    visit(entry, deps, &mut marks, &mut stack)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::model::{BuildSpec, ProjectFile};

    fn tree(entry: ProjectFile, files: Vec<ProjectFile>) -> ProjectTree {
        ProjectTree::new("m", "T", "typst", entry, files, vec![])
    }

    #[test]
    fn reachability_and_unresolved_and_unreferenced() {
        let t = tree(
            ProjectFile::text(
                "main.typ",
                FileRole::Chapter,
                "#include \"chapters/a.typ\"\n#image(\"figures/f.png\")\n#include \"chapters/gone.typ\"",
            ),
            vec![
                ProjectFile::text("chapters/a.typ", FileRole::Chapter, "#image(\"../figures/g.png\")"),
                ProjectFile::text("chapters/orphan.typ", FileRole::Chapter, "= O"),
                ProjectFile::binary("figures/f.png", FileRole::Figure, vec![1]),
                ProjectFile::binary("figures/g.png", FileRole::Figure, vec![2]),
                ProjectFile::text("Makefile", FileRole::Aux, "all:"),
            ],
        );
        let g = BuildGraph::derive(&t, t.default_target());
        assert!(g.reachable.contains("chapters/a.typ"));
        assert!(
            g.reachable.contains("figures/g.png"),
            "reached through the chapter"
        );
        assert!(!g.reachable.contains("chapters/orphan.typ"));
        assert_eq!(
            g.unreferenced,
            vec!["chapters/orphan.typ"],
            "aux files are not noted"
        );
        let errors: Vec<&Diagnostic> = g.errors().collect();
        assert_eq!(errors.len(), 1);
        assert_eq!(errors[0].code, "unresolved-include");
        assert_eq!(errors[0].file.as_deref(), Some("main.typ"));
        assert_eq!(errors[0].line, Some(3));
        assert!(g.has_errors());
    }

    #[test]
    fn include_cycles_are_one_error_with_the_path() {
        let t = tree(
            ProjectFile::text("main.typ", FileRole::Chapter, "#include \"a.typ\""),
            vec![
                ProjectFile::text("a.typ", FileRole::Chapter, "#include \"b.typ\""),
                ProjectFile::text("b.typ", FileRole::Chapter, "#include \"a.typ\""),
            ],
        );
        let g = BuildGraph::derive(&t, t.default_target());
        let cycle = g
            .errors()
            .find(|d| d.code == "include-cycle")
            .expect("cycle reported");
        assert_eq!(cycle.message, "include cycle: a.typ → b.typ → a.typ");
        assert_eq!(cycle.file.as_deref(), Some("a.typ"));
        assert_eq!(cycle.line, Some(1));
    }

    #[test]
    fn figure_steps_report_staleness_and_order() {
        let spec_a = BuildSpec {
            runner: Runner::ImpressPlot,
            outputs: vec!["figures/a.svg".into()],
            inputs: vec!["data/a.csv".into()],
            args: BTreeMap::new(),
        };
        let spec_b = BuildSpec {
            runner: Runner::Shell,
            outputs: vec!["figures/b.svg".into()],
            inputs: vec!["figures/a.svg".into()],
            args: BTreeMap::new(),
        };
        let mut t = tree(
            ProjectFile::text(
                "main.typ",
                FileRole::Chapter,
                "#image(\"figures/a.svg\")\n#image(\"figures/b.svg\")",
            ),
            vec![
                // b sorts before a by path, but reads a's output: a must run first.
                ProjectFile::text("figures/b.py", FileRole::FigureSource, "b").with_build(spec_b),
                ProjectFile::text("figures/a.plot", FileRole::FigureSource, "{}")
                    .with_build(spec_a),
                ProjectFile::text("data/a.csv", FileRole::Data, "1,2"),
                ProjectFile::binary("figures/a.svg", FileRole::Figure, vec![1]),
            ],
        );
        let g = BuildGraph::derive(&t, t.default_target());
        assert_eq!(
            g.steps
                .iter()
                .map(|s| s.source.as_str())
                .collect::<Vec<_>>(),
            vec!["figures/a.plot", "figures/b.py"]
        );
        let a = &g.steps[0];
        assert_eq!(
            a.stale_outputs,
            vec!["figures/a.svg"],
            "never recorded as built"
        );
        let b = &g.steps[1];
        assert_eq!(b.missing_outputs, vec!["figures/b.svg"]);
        assert!(b.is_stale());
        // b.svg is unresolved from main.typ until it is built.
        assert!(g.errors().any(|d| d.code == "unresolved-image"));

        // Record a as built from its current inputs: no longer stale.
        let hash = a.input_hash.clone();
        let idx = t
            .files
            .iter()
            .position(|f| f.path == "figures/a.svg")
            .unwrap();
        t.files[idx] = ProjectFile::binary("figures/a.svg", FileRole::Figure, vec![1])
            .with_derived("figures/a.plot", hash);
        let g2 = BuildGraph::derive(&t, t.default_target());
        assert!(!g2.steps[0].is_stale());
        // Change the data file: stale again.
        let didx = t.files.iter().position(|f| f.path == "data/a.csv").unwrap();
        t.files[didx] = ProjectFile::text("data/a.csv", FileRole::Data, "1,3");
        let g3 = BuildGraph::derive(&t, t.default_target());
        assert!(g3.steps[0].is_stale());
        assert!(g3.diagnostics.iter().any(|d| d.code == "stale-output"));
    }

    #[test]
    fn engine_and_entry_are_checked() {
        let t = ProjectTree::new(
            "m",
            "T",
            "latex",
            ProjectFile::text("main.tex", FileRole::Chapter, "\\documentclass{article}"),
            vec![],
            vec![Target {
                id: "odd".into(),
                name: "Odd".into(),
                entry: "main.tex".into(),
                engine: crate::project::model::Engine::Typst,
                output_kind: crate::project::model::OutputKind::Pdf,
                args: vec![],
            }],
        );
        let g = BuildGraph::derive(&t, t.default_target());
        assert!(g
            .diagnostics
            .iter()
            .any(|d| d.code == "engine-format-mismatch"));
        let missing = Target {
            entry: "nope.tex".into(),
            ..t.targets[0].clone()
        };
        let g2 = BuildGraph::derive(&t, &missing);
        assert!(g2.errors().any(|d| d.code == "missing-entry"));
    }
}
