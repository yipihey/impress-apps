//! The project tree as the engine sees it (ADR-0030 D1/D2/D9): files with
//! bytes, one entry, one or more targets. Pure data — the store layer
//! (`impress-core::manuscript_project`) knows rows, this knows files, and
//! `imprint-service` converts between them.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The one role vocabulary, shared with the bundle manifest (D2).
pub use impress_core::schemas::manuscript_bundle_manifest::BundleEntryRole as FileRole;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FileKind {
    Text,
    Binary,
}

/// A file's bytes: text, binary, or absent (a blob pruned or not yet synced —
/// the tree still knows the file exists and what it hashes to).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileBytes {
    Text(String),
    Bytes(Vec<u8>),
    Missing,
}

impl FileBytes {
    pub fn as_text(&self) -> Option<&str> {
        match self {
            FileBytes::Text(t) => Some(t),
            _ => None,
        }
    }

    pub fn as_bytes(&self) -> Option<&[u8]> {
        match self {
            FileBytes::Text(t) => Some(t.as_bytes()),
            FileBytes::Bytes(b) => Some(b),
            FileBytes::Missing => None,
        }
    }

    pub fn len(&self) -> usize {
        self.as_bytes().map(|b| b.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Which program turns a `figure-source` into its outputs (D6).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Runner {
    /// A plot-spec file rendered natively through `impress-plot`.
    ImpressPlot,
    /// An implore figure item exported natively.
    Implore,
    /// `veusz.exe --export`, executed by the host.
    Veusz,
    /// An explicit command line, executed by the host only when the build
    /// allows shell steps.
    Shell,
    #[serde(untagged)]
    Unknown(String),
}

impl Runner {
    pub fn as_str(&self) -> &str {
        match self {
            Runner::ImpressPlot => "impress-plot",
            Runner::Implore => "implore",
            Runner::Veusz => "veusz",
            Runner::Shell => "shell",
            Runner::Unknown(s) => s,
        }
    }

    /// Whether the engine runs this itself (no host involvement).
    pub fn is_native(&self) -> bool {
        matches!(self, Runner::ImpressPlot | Runner::Implore)
    }
}

/// `build_json` on a `figure-source` row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BuildSpec {
    pub runner: Runner,
    /// Project-relative paths this step writes (its `figure`/`output` rows).
    #[serde(default)]
    pub outputs: Vec<String>,
    /// Project-relative paths the step reads besides the source itself.
    #[serde(default)]
    pub inputs: Vec<String>,
    /// Runner-specific settings (`{"format":"svg"}`, `{"command":"python make.py"}`).
    #[serde(default)]
    pub args: BTreeMap<String, serde_json::Value>,
}

impl BuildSpec {
    pub fn parse(json: &str) -> Result<Self, String> {
        serde_json::from_str(json).map_err(|e| format!("build_json: {e}"))
    }
}

/// `bib_source_json` on a `bibliography` row (D7).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum BibSource {
    /// Every key cited anywhere in the tree, projected from imbib.
    Cited,
    /// Everything in one imbib collection.
    Collection {
        library_id: String,
        collection_id: String,
    },
    /// Everything in one imbib library.
    Library { library_id: String },
    /// An explicit key list.
    Keys { keys: Vec<String> },
}

impl BibSource {
    pub fn parse(json: &str) -> Result<Self, String> {
        serde_json::from_str(json).map_err(|e| format!("bib_source_json: {e}"))
    }
}

/// One file of the tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectFile {
    pub path: String,
    pub role: FileRole,
    pub kind: FileKind,
    /// The grammar id for text (`typst`, `latex`, `markdown`, `bibtex`, …).
    pub format: Option<String>,
    pub bytes: FileBytes,
    pub content_hash: String,
    pub size: u64,
    pub derived_from: Option<String>,
    pub derived_from_hash: Option<String>,
    pub build: Option<BuildSpec>,
    pub bib_source: Option<BibSource>,
}

impl ProjectFile {
    pub fn text(path: impl Into<String>, role: FileRole, text: impl Into<String>) -> Self {
        let path = path.into();
        let text = text.into();
        let format = extension_of(&path).and_then(|e| format_for_extension(&e).map(String::from));
        Self {
            content_hash: impress_core::blobs::sha256_hex_bytes(text.as_bytes()),
            size: text.len() as u64,
            path,
            role,
            kind: FileKind::Text,
            format,
            bytes: FileBytes::Text(text),
            derived_from: None,
            derived_from_hash: None,
            build: None,
            bib_source: None,
        }
    }

    pub fn binary(path: impl Into<String>, role: FileRole, bytes: Vec<u8>) -> Self {
        let path = path.into();
        Self {
            content_hash: impress_core::blobs::sha256_hex_bytes(&bytes),
            size: bytes.len() as u64,
            path,
            role,
            kind: FileKind::Binary,
            format: None,
            bytes: FileBytes::Bytes(bytes),
            derived_from: None,
            derived_from_hash: None,
            build: None,
            bib_source: None,
        }
    }

    pub fn with_build(mut self, build: BuildSpec) -> Self {
        self.build = Some(build);
        self
    }

    pub fn with_bib_source(mut self, source: BibSource) -> Self {
        self.bib_source = Some(source);
        self
    }

    pub fn with_derived(mut self, from: impl Into<String>, hash: impl Into<String>) -> Self {
        self.derived_from = Some(from.into());
        self.derived_from_hash = Some(hash.into());
        self
    }

    pub fn is_text(&self) -> bool {
        self.kind == FileKind::Text
    }

    /// The directory part of the path (`""` for the root).
    pub fn dir(&self) -> &str {
        dir_of(&self.path)
    }
}

/// The compile engine of a target. The bundle manifest's set plus `markdown`
/// (D10) and `tectonic`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Engine {
    Typst,
    Tectonic,
    Pdflatex,
    Xelatex,
    Lualatex,
    Latexmk,
    Markdown,
    /// Stored only; nothing compiles it.
    None,
}

impl Engine {
    pub fn as_str(self) -> &'static str {
        match self {
            Engine::Typst => "typst",
            Engine::Tectonic => "tectonic",
            Engine::Pdflatex => "pdflatex",
            Engine::Xelatex => "xelatex",
            Engine::Lualatex => "lualatex",
            Engine::Latexmk => "latexmk",
            Engine::Markdown => "markdown",
            Engine::None => "none",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s.trim().to_ascii_lowercase().as_str() {
            "typst" => Engine::Typst,
            "tectonic" => Engine::Tectonic,
            "pdflatex" => Engine::Pdflatex,
            "xelatex" => Engine::Xelatex,
            "lualatex" => Engine::Lualatex,
            "latexmk" => Engine::Latexmk,
            "markdown" => Engine::Markdown,
            "none" => Engine::None,
            _ => return None,
        })
    }

    /// The default engine for a manuscript format: Typst in-process, LaTeX
    /// through Tectonic (self-contained, no system TeX), Markdown through
    /// the Typst path (D10).
    pub fn default_for_format(format: &str) -> Self {
        match format {
            "typst" => Engine::Typst,
            "latex" => Engine::Tectonic,
            "markdown" => Engine::Markdown,
            _ => Engine::None,
        }
    }

    /// The grammar the engine expects its entry to be written in.
    pub fn source_format(self) -> &'static str {
        match self {
            Engine::Typst => "typst",
            Engine::Tectonic
            | Engine::Pdflatex
            | Engine::Xelatex
            | Engine::Lualatex
            | Engine::Latexmk => "latex",
            Engine::Markdown => "markdown",
            Engine::None => "plaintext",
        }
    }

    pub fn is_latex(self) -> bool {
        matches!(
            self,
            Engine::Tectonic
                | Engine::Pdflatex
                | Engine::Xelatex
                | Engine::Lualatex
                | Engine::Latexmk
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OutputKind {
    Pdf,
    Svg,
    Png,
}

/// One buildable output of the tree (D9).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Target {
    pub id: String,
    pub name: String,
    pub entry: String,
    pub engine: Engine,
    #[serde(default = "default_output_kind")]
    pub output_kind: OutputKind,
    #[serde(default)]
    pub args: Vec<String>,
}

fn default_output_kind() -> OutputKind {
    OutputKind::Pdf
}

/// The id of the implicit target a manuscript has when it declares none.
pub const IMPLICIT_TARGET_ID: &str = "main";

impl Target {
    /// The implicit single target: the entry, compiled by the format's
    /// default engine.
    pub fn implicit(format: &str, entry: &str) -> Self {
        Self {
            id: IMPLICIT_TARGET_ID.into(),
            name: "Main".into(),
            entry: entry.to_string(),
            engine: Engine::default_for_format(format),
            output_kind: OutputKind::Pdf,
            args: Vec::new(),
        }
    }

    /// Parse `targets_json`. Missing fields default: `name` = id, `entry` =
    /// the manuscript entry, `engine` = the format's default.
    pub fn parse_list(json: &str, format: &str, entry: &str) -> Result<Vec<Target>, String> {
        let raw: Vec<serde_json::Value> =
            serde_json::from_str(json).map_err(|e| format!("targets_json: {e}"))?;
        let mut out = Vec::with_capacity(raw.len());
        for v in raw {
            let id = v
                .get("id")
                .and_then(|x| x.as_str())
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| "target without an id".to_string())?
                .to_string();
            let name = v
                .get("name")
                .and_then(|x| x.as_str())
                .map(String::from)
                .unwrap_or_else(|| id.clone());
            let entry = v
                .get("entry")
                .and_then(|x| x.as_str())
                .map(String::from)
                .unwrap_or_else(|| entry.to_string());
            let engine = match v.get("engine").and_then(|x| x.as_str()) {
                Some(e) => Engine::parse(e).ok_or_else(|| format!("unknown engine {e:?}"))?,
                None => Engine::default_for_format(format),
            };
            let output_kind = match v.get("output_kind").and_then(|x| x.as_str()) {
                Some("svg") => OutputKind::Svg,
                Some("png") => OutputKind::Png,
                _ => OutputKind::Pdf,
            };
            let args = v
                .get("args")
                .and_then(|x| x.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|s| s.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            out.push(Target {
                id,
                name,
                entry,
                engine,
                output_kind,
                args,
            });
        }
        Ok(out)
    }
}

/// The whole project: entry + files + targets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectTree {
    pub manuscript_id: String,
    pub title: String,
    /// `typst | latex | markdown | plaintext`.
    pub format: String,
    /// The entry file (role `Main`); its text is the manuscript body.
    pub entry: ProjectFile,
    /// Every other file, sorted by path.
    pub files: Vec<ProjectFile>,
    /// At least one; the implicit target when the manuscript declares none.
    pub targets: Vec<Target>,
}

impl ProjectTree {
    /// A tree from its parts; sorts the files and fills the implicit target.
    pub fn new(
        manuscript_id: impl Into<String>,
        title: impl Into<String>,
        format: impl Into<String>,
        entry: ProjectFile,
        mut files: Vec<ProjectFile>,
        targets: Vec<Target>,
    ) -> Self {
        let format = format.into();
        let mut entry = entry;
        entry.role = FileRole::Main;
        files.retain(|f| f.path != entry.path);
        files.sort_by(|a, b| a.path.cmp(&b.path));
        let targets = if targets.is_empty() {
            vec![Target::implicit(&format, &entry.path)]
        } else {
            targets
        };
        Self {
            manuscript_id: manuscript_id.into(),
            title: title.into(),
            format,
            entry,
            files,
            targets,
        }
    }

    /// Every file, entry first.
    pub fn all_files(&self) -> impl Iterator<Item = &ProjectFile> {
        std::iter::once(&self.entry).chain(self.files.iter())
    }

    pub fn file(&self, path: &str) -> Option<&ProjectFile> {
        if self.entry.path == path {
            return Some(&self.entry);
        }
        self.files.iter().find(|f| f.path == path)
    }

    pub fn contains(&self, path: &str) -> bool {
        self.file(path).is_some()
    }

    pub fn text_of(&self, path: &str) -> Option<&str> {
        self.file(path).and_then(|f| f.bytes.as_text())
    }

    pub fn target(&self, id: &str) -> Option<&Target> {
        self.targets.iter().find(|t| t.id == id)
    }

    /// The target to build when none is named: the first declared one.
    pub fn default_target(&self) -> &Target {
        &self.targets[0]
    }

    /// Every path in the tree, sorted, entry included.
    pub fn paths(&self) -> Vec<&str> {
        let mut v: Vec<&str> = self.all_files().map(|f| f.path.as_str()).collect();
        v.sort_unstable();
        v
    }

    /// The bibliography files (declared or by role).
    pub fn bibliographies(&self) -> impl Iterator<Item = &ProjectFile> {
        self.files
            .iter()
            .filter(|f| f.role == FileRole::Bibliography)
    }

    /// The figure sources that declare a build.
    pub fn figure_sources(&self) -> impl Iterator<Item = &ProjectFile> {
        self.files
            .iter()
            .filter(|f| f.role == FileRole::FigureSource && f.build.is_some())
    }

    /// A stamp over every file's identity and bytes plus the target: equal
    /// stamps mean identical builds. Same recipe as the store's
    /// `ProjectSnapshot::input_stamp`.
    pub fn input_stamp(&self, target_id: &str) -> String {
        let mut lines: Vec<String> = self
            .all_files()
            .map(|f| format!("{}\t{}", f.path, f.content_hash))
            .collect();
        lines.sort();
        lines.push(format!("target\t{target_id}"));
        impress_core::blobs::sha256_hex_bytes(lines.join("\n").as_bytes())
    }
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// The directory part of a project path (`""` at the root).
pub fn dir_of(path: &str) -> &str {
    match path.rfind('/') {
        Some(i) => &path[..i],
        None => "",
    }
}

/// The last component.
pub fn file_name_of(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// The lowercased extension without the dot, if any.
pub fn extension_of(path: &str) -> Option<String> {
    let name = file_name_of(path);
    let (stem, ext) = name.rsplit_once('.')?;
    if stem.is_empty() {
        return None;
    }
    Some(ext.to_ascii_lowercase())
}

/// The grammar a text file's extension implies. Manuscript formats come
/// from the shared grammar table; the rest is the project's own table
/// (mirrors `impress_core::manuscript_project::format_for_extension`, kept
/// here so the engine is usable without the store feature).
pub fn format_for_extension(ext: &str) -> Option<&'static str> {
    if let Some(f) = impress_core::manuscript_format::manuscript_format_for_extension(ext) {
        return Some(f);
    }
    Some(match ext.to_ascii_lowercase().as_str() {
        "bib" | "bibtex" => "bibtex",
        "py" => "python",
        "jl" => "julia",
        "r" => "r",
        "sh" => "shell",
        "json" => "json",
        "csv" | "tsv" => "csv",
        "yaml" | "yml" => "yaml",
        "toml" => "toml",
        "xml" => "xml",
        "sty" | "cls" | "bst" | "clo" | "def" => "latex",
        "vsz" => "veusz",
        "plot" => "plot-spec",
        "svg" => "svg",
        "html" | "htm" => "html",
        _ => return None,
    })
}

/// Join `base_dir` and a reference the way a project path is spelled:
/// forward slashes, `.`/`..` folded, a leading `/` meaning the project root.
/// Returns `None` when the reference escapes the root.
pub fn join_relative(base_dir: &str, reference: &str) -> Option<String> {
    let reference = reference.trim().replace('\\', "/");
    let (start, rest): (Vec<&str>, &str) = if let Some(abs) = reference.strip_prefix('/') {
        (Vec::new(), abs)
    } else {
        (
            base_dir.split('/').filter(|c| !c.is_empty()).collect(),
            reference.as_str(),
        )
    };
    let mut parts: Vec<&str> = start;
    for component in rest.split('/') {
        match component {
            "" | "." => continue,
            ".." => {
                parts.pop()?;
            }
            other => parts.push(other),
        }
    }
    if parts.is_empty() {
        return None;
    }
    Some(parts.join("/"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn join_relative_folds_and_refuses_escapes() {
        assert_eq!(
            join_relative("", "chapters/a.tex").as_deref(),
            Some("chapters/a.tex")
        );
        assert_eq!(
            join_relative("chapters", "../figures/f.png").as_deref(),
            Some("figures/f.png")
        );
        assert_eq!(
            join_relative("chapters", "/lib/x.typ").as_deref(),
            Some("lib/x.typ")
        );
        assert_eq!(
            join_relative("chapters", "./b.typ").as_deref(),
            Some("chapters/b.typ")
        );
        assert_eq!(join_relative("", "../outside.tex"), None);
        assert_eq!(join_relative("a", "../../out.tex"), None);
    }

    #[test]
    fn implicit_target_follows_the_format() {
        let t = Target::implicit("latex", "main.tex");
        assert_eq!(t.id, "main");
        assert_eq!(t.engine, Engine::Tectonic);
        assert_eq!(
            Target::implicit("markdown", "notes.md").engine,
            Engine::Markdown
        );
        assert_eq!(Target::implicit("plaintext", "x.txt").engine, Engine::None);
    }

    #[test]
    fn targets_parse_with_defaults() {
        let list = Target::parse_list(
            r#"[{"id":"paper"},{"id":"talk","entry":"talk.typ","engine":"typst","output_kind":"svg","args":["--x"]}]"#,
            "latex",
            "main.tex",
        )
        .unwrap();
        assert_eq!(list[0].entry, "main.tex");
        assert_eq!(list[0].engine, Engine::Tectonic);
        assert_eq!(list[0].name, "paper");
        assert_eq!(list[1].engine, Engine::Typst);
        assert_eq!(list[1].output_kind, OutputKind::Svg);
        assert_eq!(list[1].args, vec!["--x"]);
        assert!(Target::parse_list(r#"[{"id":"a","engine":"docx"}]"#, "typst", "m.typ").is_err());
        assert!(Target::parse_list(r#"[{"name":"no id"}]"#, "typst", "m.typ").is_err());
    }

    #[test]
    fn specs_parse_from_json() {
        let b =
            BuildSpec::parse(r#"{"runner":"impress-plot","outputs":["figures/f.svg"]}"#).unwrap();
        assert_eq!(b.runner, Runner::ImpressPlot);
        assert!(b.runner.is_native());
        let sh = BuildSpec::parse(
            r#"{"runner":"shell","outputs":["f.pdf"],"args":{"command":"python make.py"}}"#,
        )
        .unwrap();
        assert_eq!(sh.runner, Runner::Shell);
        assert!(!sh.runner.is_native());
        let odd = BuildSpec::parse(r#"{"runner":"gnuplot"}"#).unwrap();
        assert_eq!(odd.runner, Runner::Unknown("gnuplot".into()));
        assert_eq!(
            BibSource::parse(r#"{"kind":"cited"}"#).unwrap(),
            BibSource::Cited
        );
        assert!(matches!(
            BibSource::parse(r#"{"kind":"collection","library_id":"l","collection_id":"c"}"#)
                .unwrap(),
            BibSource::Collection { .. }
        ));
    }

    #[test]
    fn a_tree_sorts_files_and_dedups_the_entry() {
        let entry = ProjectFile::text("main.typ", FileRole::Chapter, "= T");
        let tree = ProjectTree::new(
            "m",
            "T",
            "typst",
            entry,
            vec![
                ProjectFile::text("z.typ", FileRole::Chapter, ""),
                ProjectFile::text("main.typ", FileRole::Chapter, "shadow"),
                ProjectFile::text("a.typ", FileRole::Chapter, ""),
            ],
            vec![],
        );
        assert_eq!(tree.entry.role, FileRole::Main);
        assert_eq!(tree.paths(), vec!["a.typ", "main.typ", "z.typ"]);
        assert_eq!(tree.text_of("main.typ"), Some("= T"));
        assert_eq!(tree.targets.len(), 1);
        assert_eq!(tree.default_target().engine, Engine::Typst);
        assert_ne!(tree.input_stamp("main"), tree.input_stamp("talk"));
    }
}
