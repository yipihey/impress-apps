//! Figures in a project (ADR-0030 D13): a figure is a `figure-source` row
//! whose kind is its format — a Veusz document, a Typst source (a lilaq
//! figure, a lilook document, what the plot inspector wrote), a plot spec
//! (implore's, or impress-plot's), a script — rendered by the runner the
//! kind implies into the `output` rows the text places. A manuscript mixes
//! them freely; the build graph treats every kind the same way.
//!
//! This module names the kinds, guesses one from a path (and a spec's
//! shape), and writes the starter file a new figure begins with.

use serde::{Deserialize, Serialize};

use super::model::{extension_of, figure_stem, spec_kind_of, BuildSpec, Runner, SpecKind};

/// The lilaq package a new figure imports — the version vendored in
/// `vendor/typst-packages`, which the engine resolves offline.
pub const LILAQ_PACKAGE: &str = "@preview/lilaq:0.6.0";

/// What kind of figure a source is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum FigureKind {
    /// A Veusz document (`.vsz`), rendered by `veusz --export`.
    Veusz,
    /// A lilaq figure (`.typ`), compiled by the tree's engine; lilook edits it.
    Lilaq,
    /// Any other Typst figure source (`.typ`), compiled by the tree's engine.
    Typst,
    /// implore's `PlotSpec` (`.plot.json`), turned into lilaq Typst.
    ImplorePlot,
    /// impress-plot's inspector spec (`.plot.json`), rendered natively.
    ImpressPlot,
    /// A script (`.py`, `.jl`, `.R`, `.sh`, `.ipynb`) run by the host.
    Script,
}

impl FigureKind {
    pub fn as_str(self) -> &'static str {
        match self {
            FigureKind::Veusz => "veusz",
            FigureKind::Lilaq => "lilaq",
            FigureKind::Typst => "typst",
            FigureKind::ImplorePlot => "implore",
            FigureKind::ImpressPlot => "impress-plot",
            FigureKind::Script => "script",
        }
    }

    /// How a person names it.
    pub fn label(self) -> &'static str {
        match self {
            FigureKind::Veusz => "Veusz",
            FigureKind::Lilaq => "lilaq (Typst)",
            FigureKind::Typst => "Typst figure",
            FigureKind::ImplorePlot => "implore plot spec",
            FigureKind::ImpressPlot => "native plot spec",
            FigureKind::Script => "script",
        }
    }

    pub fn parse(s: &str) -> Option<FigureKind> {
        Some(match s.trim().to_ascii_lowercase().as_str() {
            "veusz" | "vsz" => FigureKind::Veusz,
            "lilaq" | "lilook" => FigureKind::Lilaq,
            "typst" | "typ" => FigureKind::Typst,
            "implore" | "implore-plot" | "plot-spec" => FigureKind::ImplorePlot,
            "impress-plot" | "native" | "inspector" => FigureKind::ImpressPlot,
            "script" | "shell" | "python" => FigureKind::Script,
            _ => return None,
        })
    }

    pub fn runner(self) -> Runner {
        match self {
            FigureKind::Veusz => Runner::Veusz,
            FigureKind::Lilaq | FigureKind::Typst => Runner::Typst,
            FigureKind::ImplorePlot => Runner::Implore,
            FigureKind::ImpressPlot => Runner::ImpressPlot,
            FigureKind::Script => Runner::Shell,
        }
    }

    /// The extension a new source of this kind gets.
    pub fn extension(self) -> &'static str {
        match self {
            FigureKind::Veusz => "vsz",
            FigureKind::Lilaq | FigureKind::Typst => "typ",
            FigureKind::ImplorePlot | FigureKind::ImpressPlot => "plot.json",
            FigureKind::Script => "py",
        }
    }

    /// Whether an external application edits this kind (the panel offers
    /// "Edit in …" over a materialised working copy).
    pub fn external_editor(self) -> Option<&'static str> {
        match self {
            FigureKind::Veusz => Some("Veusz"),
            FigureKind::Lilaq => Some("lilook"),
            _ => None,
        }
    }

    /// The kind a path (and, for a spec or a `.typ`, its text) implies.
    pub fn detect(path: &str, text: Option<&str>) -> Option<FigureKind> {
        let lower = path.to_ascii_lowercase();
        if lower.ends_with(".vsz") {
            return Some(FigureKind::Veusz);
        }
        if lower.ends_with(".typ") {
            let lilaq = text.is_some_and(|t| t.contains("lilaq"));
            return Some(if lilaq {
                FigureKind::Lilaq
            } else {
                FigureKind::Typst
            });
        }
        if lower.ends_with(".plot.json") || lower.ends_with(".plot") {
            return Some(match text.map(spec_kind_of) {
                Some(SpecKind::ImpressPlot) => FigureKind::ImpressPlot,
                _ => FigureKind::ImplorePlot,
            });
        }
        match extension_of(path).as_deref() {
            Some("py") | Some("jl") | Some("r") | Some("sh") | Some("ipynb") => {
                Some(FigureKind::Script)
            }
            _ => None,
        }
    }
}

/// A starter figure: the source and the build spec that renders it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FigureTemplate {
    pub kind: FigureKind,
    /// Project-relative source path (the caller's, with the kind's extension
    /// when it had none).
    pub path: String,
    pub text: String,
    pub build: BuildSpec,
}

/// The path a new figure of `kind` takes for a requested `path`: the
/// kind's extension is appended when the path has none of its own.
pub fn figure_path(kind: FigureKind, path: &str) -> String {
    let trimmed = path.trim().trim_matches('/');
    let name = trimmed.rsplit('/').next().unwrap_or(trimmed);
    if name.contains('.') {
        trimmed.to_string()
    } else {
        format!("{trimmed}.{}", kind.extension())
    }
}

/// A new figure of `kind` at `path` — the source a person or an agent edits
/// from, and the build spec that turns it into `<stem>.svg` (scripts name
/// their own outputs).
pub fn template(kind: FigureKind, path: &str) -> FigureTemplate {
    let path = figure_path(kind, path);
    let stem = figure_stem(&path);
    let name = stem.rsplit('/').next().unwrap_or(&stem).to_string();
    let svg = format!("{stem}.svg");
    let text = match kind {
        FigureKind::Lilaq => format!(
            "// {name}: a lilaq figure. Edit it here, in lilook, or ask an agent;\n\
             // the manuscript places its rendered output ({svg}).\n\
             // Data from the project, by its project path: #let rows = csv(\"/data/{name}.csv\")\n\
             #import \"{LILAQ_PACKAGE}\" as lq\n\
             #set page(width: auto, height: auto, margin: 2pt)\n\
             \n\
             #let x = (0, 1, 2, 3, 4)\n\
             #let y = (0, 1, 4, 9, 16)\n\
             \n\
             #lq.diagram(\n  width: 8cm, height: 5cm,\n  xlabel: $x$, ylabel: $y$,\n  \
             lq.plot(x, y, mark: \"o\", label: [data]),\n)\n"
        ),
        FigureKind::Typst => format!(
            "// {name}: a Typst figure, compiled with the project as its world\n\
             // (the project's images and data resolve by their project paths, e.g. \"/data/x.csv\").\n\
             #set page(width: auto, height: auto, margin: 2pt)\n\
             \n\
             #box(width: 8cm, height: 5cm, stroke: 0.5pt)[\n  \
             #align(center + horizon)[_{name}_]\n]\n"
        ),
        FigureKind::ImplorePlot => implore_spec_template(&name),
        FigureKind::ImpressPlot => impress_plot_spec_template(&name),
        FigureKind::Veusz => veusz_template(),
        FigureKind::Script => format!(
            "#!/usr/bin/env python3\n\
             \"\"\"{name}: makes {svg}. Runs from the project root when the build\n\
             allows shell steps; declare its outputs in the figure's build spec.\"\"\"\n\
             import matplotlib\n\
             matplotlib.use(\"Agg\")\n\
             import matplotlib.pyplot as plt\n\
             \n\
             fig, ax = plt.subplots(figsize=(4, 3))\n\
             ax.plot([0, 1, 2, 3, 4], [0, 1, 4, 9, 16], marker=\"o\", label=\"data\")\n\
             ax.set_xlabel(\"x\")\n\
             ax.set_ylabel(\"y\")\n\
             ax.legend()\n\
             fig.tight_layout()\n\
             fig.savefig(\"{svg}\")\n"
        ),
    };
    let mut build = BuildSpec {
        runner: kind.runner(),
        outputs: vec![svg.clone()],
        inputs: Vec::new(),
        args: Default::default(),
    };
    if kind == FigureKind::Script {
        build.args.insert(
            "command".into(),
            serde_json::Value::String(format!("python3 {path}")),
        );
    }
    FigureTemplate {
        kind,
        path,
        text,
        build,
    }
}

fn implore_spec_template(name: &str) -> String {
    serde_json::to_string_pretty(&serde_json::json!({
        "title": name,
        "width": 480.0,
        "height": 320.0,
        "x_axis": { "label": "x", "min": null, "max": null, "log_scale": false, "format": null },
        "y_axis": { "label": "y", "min": null, "max": null, "log_scale": false, "format": null },
        "series": [{
            "label": "data",
            "x": [0.0, 1.0, 2.0, 3.0, 4.0],
            "y": [0.0, 1.0, 4.0, 9.0, 16.0],
            "error_low": null,
            "error_high": null,
            "style": "LineScatter",
            "color": "Blue",
            "point_radius": 3.0,
            "line_width": 1.5
        }],
        "legend": { "position": "TopRight", "visible": true },
        "show_grid": true,
        "annotations": []
    }))
    .unwrap_or_default()
        + "\n"
}

fn impress_plot_spec_template(name: &str) -> String {
    serde_json::to_string_pretty(&serde_json::json!({
        "title": name,
        "x": { "scale": "linear", "min": null, "max": null, "label": "x" },
        "y": { "scale": "linear", "min": null, "max": null, "label": "y" },
        "series": [{
            "kind": "scatter",
            "xs": [0.0, 1.0, 2.0, 3.0, 4.0],
            "ys": [0.0, 1.0, 4.0, 9.0, 16.0],
            "color": { "r": 0, "g": 114, "b": 178 }
        }],
        "strategy": "auto",
        "colormap": "viridis",
        "width": 480.0,
        "height": 320.0
    }))
    .unwrap_or_default()
        + "\n"
}

/// A minimal Veusz document: one page, one graph, an `x`/`y` curve from
/// embedded data — what Veusz itself writes for a new plot.
fn veusz_template() -> String {
    "# Veusz saved document (version 3.6)\n\
     # A starter figure; open it in Veusz to edit.\n\
     \n\
     ImportString(u'x(numeric)', u'''\n0\n1\n2\n3\n4\n''')\n\
     ImportString(u'y(numeric)', u'''\n0\n1\n4\n9\n16\n''')\n\
     Add('page', name='page1', autoadd=False)\n\
     To('page1')\n\
     Add('graph', name='graph1', autoadd=False)\n\
     To('graph1')\n\
     Add('axis', name='x', autoadd=False)\n\
     Add('axis', name='y', autoadd=False)\n\
     To('y')\n\
     Set('direction', 'vertical')\n\
     To('..')\n\
     Add('xy', name='xy1', autoadd=False)\n\
     To('xy1')\n\
     Set('xData', u'x')\n\
     Set('yData', u'y')\n\
     To('..')\n\
     To('..')\n\
     To('..')\n"
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_follow_the_name_and_the_shape() {
        assert_eq!(
            FigureKind::detect("figures/a.vsz", None),
            Some(FigureKind::Veusz)
        );
        assert_eq!(
            FigureKind::detect(
                "figures/a.typ",
                Some("#import \"@preview/lilaq:0.6.0\" as lq")
            ),
            Some(FigureKind::Lilaq)
        );
        assert_eq!(
            FigureKind::detect("figures/a.typ", Some("#rect()")),
            Some(FigureKind::Typst)
        );
        assert_eq!(
            FigureKind::detect("figures/a.plot.json", Some(r#"{"x_axis":{},"series":[]}"#)),
            Some(FigureKind::ImplorePlot)
        );
        assert_eq!(
            FigureKind::detect(
                "figures/a.plot.json",
                Some(r#"{"x":{"scale":"log"},"series":[]}"#)
            ),
            Some(FigureKind::ImpressPlot)
        );
        assert_eq!(
            FigureKind::detect("figures/make.py", None),
            Some(FigureKind::Script)
        );
        assert_eq!(FigureKind::detect("figures/a.png", None), None);
        assert_eq!(FigureKind::parse("lilook"), Some(FigureKind::Lilaq));
    }

    #[test]
    fn templates_are_complete_starters() {
        for kind in [
            FigureKind::Veusz,
            FigureKind::Lilaq,
            FigureKind::Typst,
            FigureKind::ImplorePlot,
            FigureKind::ImpressPlot,
            FigureKind::Script,
        ] {
            let t = template(kind, "figures/growth");
            assert!(t.path.starts_with("figures/growth."), "{}", t.path);
            assert_eq!(t.build.runner, kind.runner());
            assert_eq!(t.build.outputs, vec!["figures/growth.svg".to_string()]);
            assert!(!t.text.trim().is_empty());
            // The kind the template's own text implies is the kind asked for.
            let detected = FigureKind::detect(&t.path, Some(&t.text));
            assert_eq!(detected, Some(kind), "{:?} → {:?}", kind, detected);
        }
        assert_eq!(
            figure_path(FigureKind::Lilaq, "figures/a.typ"),
            "figures/a.typ"
        );
        let spec = template(FigureKind::ImpressPlot, "figures/p");
        assert_eq!(spec_kind_of(&spec.text), SpecKind::ImpressPlot);
        let script = template(FigureKind::Script, "figures/make");
        assert_eq!(
            script.build.args.get("command").and_then(|v| v.as_str()),
            Some("python3 figures/make.py")
        );
    }
}
