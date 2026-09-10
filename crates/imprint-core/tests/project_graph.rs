//! The project engine over realistic trees (ADR-0030 P1, Tier A): a
//! two-chapter LaTeX paper with a journal class, a graphics path, two
//! bibliographies and a scripted figure; a Typst paper with a local theme, a
//! package import, data files and a talk target. Pure — no store.

use std::collections::BTreeMap;

use imprint_core::project::{
    scan, BuildGraph, BuildSpec, DepKind, FileRole, ProjectFile, ProjectTree, Runner, Target,
};

fn latex_paper() -> ProjectTree {
    let main = ProjectFile::text(
        "paper/main.tex",
        FileRole::Main,
        "\\documentclass[twocolumn]{aastex631}\n\
         \\usepackage{amsmath}\n\
         \\usepackage{ourmacros}\n\
         \\graphicspath{{figures/}{../figures/}}\n\
         \\begin{document}\n\
         \\input{chapters/intro}\n\
         \\include{chapters/methods}\n\
         \\begin{figure}\\includegraphics[width=\\columnwidth]{density}\\end{figure}\n\
         \\includegraphics{../figures/rotation.pdf}\n\
         % \\input{chapters/dropped}\n\
         \\bibliographystyle{aasjournal}\n\
         \\bibliography{refs,shared/collab}\n\
         \\end{document}",
    );
    let files = vec![
        ProjectFile::text("paper/aastex631.cls", FileRole::Style, "\\ProvidesClass{aastex631}"),
        ProjectFile::text("paper/ourmacros.sty", FileRole::Style, "\\newcommand{\\vv}{v}"),
        ProjectFile::text(
            "paper/chapters/intro.tex",
            FileRole::Chapter,
            "\\section{Introduction}\nFollowing \\citet{hubble29}, see \\autoref{fig:density}.\n\\subimport{../appendix/}{tables}",
        ),
        ProjectFile::text(
            "paper/chapters/methods.tex",
            FileRole::Chapter,
            "\\section{Methods}\nWe use \\cite{navarro96,springel05}.\n\\pgfplotstableread{data/profiles.dat}\\tbl",
        ),
        ProjectFile::text("paper/appendix/tables.tex", FileRole::Supplement, "\\begin{table}\\end{table}"),
        ProjectFile::text("paper/data/profiles.dat", FileRole::Data, "r rho\n1 2"),
        ProjectFile::binary("paper/figures/density.pdf", FileRole::Figure, b"%PDF-1.5 d".to_vec()),
        ProjectFile::binary("figures/rotation.pdf", FileRole::Figure, b"%PDF-1.5 r".to_vec()),
        ProjectFile::text(
            "paper/figures/make_density.py",
            FileRole::FigureSource,
            "import numpy\n",
        )
        .with_build(BuildSpec {
            runner: Runner::Shell,
            outputs: vec!["paper/figures/density.pdf".into()],
            inputs: vec!["paper/data/profiles.dat".into()],
            args: BTreeMap::from([(
                "command".to_string(),
                serde_json::Value::String("python make_density.py".into()),
            )]),
        }),
        ProjectFile::text("paper/refs.bib", FileRole::Bibliography, "@article{hubble29,}"),
        ProjectFile::text("paper/shared/collab.bib", FileRole::Bibliography, "@article{navarro96,}"),
        ProjectFile::text("paper/chapters/unused.tex", FileRole::Chapter, "\\section{Unused}"),
        ProjectFile::text("README.md", FileRole::Aux, "# notes"),
    ];
    ProjectTree::new("m-latex", "A LaTeX paper", "latex", main, files, vec![])
}

#[test]
fn a_latex_paper_resolves_the_way_tex_would() {
    let tree = latex_paper();
    let deps = scan(&tree);

    let edge = |from: &str, to: &str| {
        deps.edges
            .iter()
            .find(|e| e.from == from && e.to == to)
            .map(|e| (e.kind, e.line))
    };
    // Includes resolve against the entry's directory with the implied `.tex`.
    assert_eq!(
        edge("paper/main.tex", "paper/chapters/intro.tex"),
        Some((DepKind::Include, 6))
    );
    assert_eq!(
        edge("paper/main.tex", "paper/chapters/methods.tex"),
        Some((DepKind::Include, 7))
    );
    // A local class and style file are edges; `amsmath` (system) is not a diagnostic.
    assert_eq!(
        edge("paper/main.tex", "paper/aastex631.cls"),
        Some((DepKind::Class, 1))
    );
    assert_eq!(
        edge("paper/main.tex", "paper/ourmacros.sty"),
        Some((DepKind::Style, 3))
    );
    assert!(deps.unresolved.iter().all(|u| u.reference != "amsmath"));
    // graphicspath + implied extension; an explicit relative path above the entry dir.
    assert_eq!(
        edge("paper/main.tex", "paper/figures/density.pdf"),
        Some((DepKind::Image, 8))
    );
    assert_eq!(
        edge("paper/main.tex", "figures/rotation.pdf"),
        Some((DepKind::Image, 9))
    );
    // The commented-out input is not an edge and not a diagnostic.
    assert!(deps
        .unresolved
        .iter()
        .all(|u| u.reference != "chapters/dropped"));
    // Two bibliographies from one \bibliography, comma-separated.
    assert_eq!(
        edge("paper/main.tex", "paper/refs.bib"),
        Some((DepKind::Bibliography, 12))
    );
    assert_eq!(
        edge("paper/main.tex", "paper/shared/collab.bib"),
        Some((DepKind::Bibliography, 12))
    );
    // A chapter's own references resolve from the entry's directory too.
    assert_eq!(
        edge("paper/chapters/intro.tex", "paper/appendix/tables.tex"),
        Some((DepKind::Include, 3))
    );
    assert_eq!(
        edge("paper/chapters/methods.tex", "paper/data/profiles.dat"),
        Some((DepKind::Data, 3))
    );
    assert!(deps.unresolved.is_empty(), "{:?}", deps.unresolved);
    assert_eq!(
        deps.cite_keys.iter().cloned().collect::<Vec<_>>(),
        vec!["hubble29", "navarro96", "springel05"]
    );

    let graph = BuildGraph::derive(&tree, tree.default_target());
    assert!(!graph.has_errors(), "{:?}", graph.diagnostics);
    assert!(
        graph.reachable.contains("paper/appendix/tables.tex"),
        "two levels down"
    );
    assert_eq!(graph.unreferenced, vec!["paper/chapters/unused.tex"]);
    assert_eq!(
        graph.bibliographies(),
        vec!["paper/refs.bib", "paper/shared/collab.bib"]
    );
    // The scripted figure: one step, stale because nothing recorded a build.
    assert_eq!(graph.steps.len(), 1);
    let step = &graph.steps[0];
    assert_eq!(step.runner, Runner::Shell);
    assert_eq!(step.stale_outputs, vec!["paper/figures/density.pdf"]);
    assert!(step.missing_inputs.is_empty());
    assert!(graph.diagnostics.iter().any(|d| d.code == "stale-output"));
}

fn typst_paper() -> ProjectTree {
    let main = ProjectFile::text(
        "main.typ",
        FileRole::Main,
        "#import \"@preview/cetz:0.2.0\": canvas\n\
         #import \"theme/ours.typ\": *\n\
         #show: paper.with(title: \"T\")\n\
         #include \"sections/intro.typ\"\n\
         #include \"sections/results.typ\"\n\
         #bibliography((\"refs.bib\", \"shared/collab.bib\"))",
    );
    let files = vec![
        ProjectFile::text(
            "theme/ours.typ",
            FileRole::Style,
            "#let paper(title: none, body) = body",
        ),
        ProjectFile::text(
            "sections/intro.typ",
            FileRole::Chapter,
            "== Intro\nAs @hubble29 found.\n#figure(image(\"../figures/density.svg\"))",
        ),
        ProjectFile::text(
            "sections/results.typ",
            FileRole::Chapter,
            "== Results\n#let rows = csv(\"/data/profiles.csv\")\n#include \"details.typ\"",
        ),
        ProjectFile::text(
            "sections/details.typ",
            FileRole::Chapter,
            "=== Details @navarro96",
        ),
        ProjectFile::text("data/profiles.csv", FileRole::Data, "r,rho\n1,2"),
        ProjectFile::text(
            "figures/density.plot",
            FileRole::FigureSource,
            r#"{"kind":"line"}"#,
        )
        .with_build(BuildSpec {
            runner: Runner::ImpressPlot,
            outputs: vec!["figures/density.svg".into()],
            inputs: vec!["data/profiles.csv".into()],
            args: BTreeMap::new(),
        }),
        ProjectFile::text("figures/density.svg", FileRole::Figure, "<svg/>")
            .with_derived("figures/density.plot", "stale-hash"),
        ProjectFile::text("refs.bib", FileRole::Bibliography, "@article{hubble29,}"),
        ProjectFile::text("shared/collab.bib", FileRole::Bibliography, ""),
        ProjectFile::text(
            "talk.typ",
            FileRole::Supplement,
            "= Talk\n#include \"sections/intro.typ\"",
        ),
    ];
    let targets = Target::parse_list(
        r#"[{"id":"paper","entry":"main.typ"},{"id":"talk","entry":"talk.typ","output_kind":"svg"}]"#,
        "typst",
        "main.typ",
    )
    .unwrap();
    ProjectTree::new("m-typst", "A Typst paper", "typst", main, files, targets)
}

#[test]
fn a_typst_paper_resolves_relative_to_each_file_and_builds_two_targets() {
    let tree = typst_paper();
    let deps = scan(&tree);
    let edge = |from: &str, to: &str| {
        deps.edges
            .iter()
            .find(|e| e.from == from && e.to == to)
            .map(|e| e.kind)
    };
    // The package import is not a file; the local theme is.
    assert!(deps.edges.iter().all(|e| !e.to.contains("@preview")));
    assert!(deps
        .unresolved
        .iter()
        .all(|u| !u.reference.contains("@preview")));
    assert_eq!(edge("main.typ", "theme/ours.typ"), Some(DepKind::Import));
    // Includes resolve from the including file: `details.typ` next to results.
    assert_eq!(
        edge("sections/results.typ", "sections/details.typ"),
        Some(DepKind::Include)
    );
    // `..` from a section, and `/` for the root.
    assert_eq!(
        edge("sections/intro.typ", "figures/density.svg"),
        Some(DepKind::Image)
    );
    assert_eq!(
        edge("sections/results.typ", "data/profiles.csv"),
        Some(DepKind::Data)
    );
    assert_eq!(edge("main.typ", "refs.bib"), Some(DepKind::Bibliography));
    assert_eq!(
        edge("main.typ", "shared/collab.bib"),
        Some(DepKind::Bibliography)
    );
    assert!(deps.unresolved.is_empty(), "{:?}", deps.unresolved);
    assert!(deps.cite_keys.contains("hubble29") && deps.cite_keys.contains("navarro96"));

    let paper = BuildGraph::derive(&tree, tree.target("paper").unwrap());
    assert!(!paper.has_errors(), "{:?}", paper.diagnostics);
    assert!(paper.reachable.contains("sections/details.typ"));
    assert_eq!(
        paper.unreferenced,
        vec!["talk.typ"],
        "the talk is another target's entry"
    );
    // The figure was built from an older input hash: stale, and it says so.
    let step = &paper.steps[0];
    assert_eq!(step.runner, Runner::ImpressPlot);
    assert_eq!(step.stale_outputs, vec!["figures/density.svg"]);
    assert!(paper
        .diagnostics
        .iter()
        .any(|d| d.code == "stale-output" && d.file.as_deref() == Some("figures/density.svg")));

    let talk = BuildGraph::derive(&tree, tree.target("talk").unwrap());
    assert!(!talk.has_errors(), "{:?}", talk.diagnostics);
    assert_eq!(talk.entry, "talk.typ");
    assert!(talk.reachable.contains("sections/intro.typ"));
    assert!(
        talk.reachable.contains("figures/density.svg"),
        "through the intro"
    );
    assert!(!talk.reachable.contains("sections/results.typ"));
    assert!(
        talk.bibliographies().is_empty(),
        "the talk cites nothing by file"
    );

    // Every stamp differs per target and moves with any byte.
    assert_ne!(tree.input_stamp("paper"), tree.input_stamp("talk"));
}

#[test]
fn a_one_file_manuscript_is_a_trivial_graph() {
    let tree = ProjectTree::new(
        "m",
        "Solo",
        "markdown",
        ProjectFile::text("main.md", FileRole::Main, "# Title\n\nJust text, [@key].\n"),
        vec![],
        vec![],
    );
    let graph = BuildGraph::derive(&tree, tree.default_target());
    assert!(!graph.has_errors());
    assert_eq!(graph.reachable.len(), 1);
    assert!(graph.steps.is_empty());
    assert!(graph.unreferenced.is_empty());
    assert_eq!(
        graph.deps.cite_keys.iter().cloned().collect::<Vec<_>>(),
        vec!["key"]
    );
    assert_eq!(
        tree.default_target().engine,
        imprint_core::project::Engine::Markdown
    );
}
