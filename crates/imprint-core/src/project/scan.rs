//! Reference scanning: what each source file of a project reaches for
//! (ADR-0030 D4). The build graph is DERIVED from source text — rename a
//! chapter and the graph follows — so nothing here is ever stored.
//!
//! Three grammars, one output shape. Every scanner works on a copy of the
//! text whose comments are blanked to spaces (so byte offsets — and hence
//! line numbers — survive), then resolves each reference against the tree
//! the way the toolchain would:
//!
//! * **LaTeX** resolves against the directory TeX runs in, which is the
//!   entry's directory whatever file the reference sits in; `\input{x}` may
//!   omit `.tex`, `\bibliography{a,b}` omits `.bib`, `\includegraphics{f}`
//!   tries the raster/vector extensions in engine order and every
//!   `\graphicspath` prefix. A `\usepackage`/`\documentclass` is a project
//!   edge only when the `.sty`/`.cls` is in the tree — otherwise it is a
//!   system package and not a diagnostic.
//! * **Typst** resolves against the referencing file's directory, `/` being
//!   the project root; extensions are never implied; `@preview`/`@local`
//!   imports are packages, not files.
//! * **Markdown** resolves like Typst; images from `![](…)` and `<img>`,
//!   bibliographies from the front matter, includes from Quarto's
//!   `{{< include … >}}`.
//!
//! Cite keys are collected per text file through the shared extractors
//! (`citations::extract`) so the `cited` bibliography projection (D7) sees
//! every `@key`, `\cite{}` and `[@key]` in the tree.

use std::collections::BTreeSet;
use std::sync::OnceLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

use super::model::{dir_of, extension_of, join_relative, FileRole, ProjectTree};
use crate::citations::extract::{extract_cite_keys, CitationSyntax};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DepKind {
    /// `\input`, `\include`, `#include`, `{{< include >}}` — text spliced in.
    Include,
    /// `#import` of a project file.
    Import,
    /// A figure file.
    Image,
    /// A `.bib` (or the row that projects one).
    Bibliography,
    /// A data file read at compile time (`csv(…)`, `\pgfplotstableread`).
    Data,
    /// A local `.sty` / Typst theme.
    Style,
    /// A local `.cls`.
    Class,
}

impl DepKind {
    pub fn as_str(self) -> &'static str {
        match self {
            DepKind::Include => "include",
            DepKind::Import => "import",
            DepKind::Image => "image",
            DepKind::Bibliography => "bibliography",
            DepKind::Data => "data",
            DepKind::Style => "style",
            DepKind::Class => "class",
        }
    }

    /// Whether an unresolved reference of this kind breaks the compile.
    pub fn is_required(self) -> bool {
        !matches!(self, DepKind::Style | DepKind::Class)
    }
}

/// A reference as written, before resolution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawReference {
    pub reference: String,
    pub kind: DepKind,
    /// 1-based line in the referencing file.
    pub line: u32,
    /// Extensions to try when the reference has none (or as-is fails).
    pub implied_extensions: &'static [&'static str],
    /// Directory prefixes to try (`\graphicspath`), root-relative.
    pub search_prefixes: Vec<String>,
}

/// The result of scanning one text file.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ScanResult {
    pub references: Vec<RawReference>,
    pub cite_keys: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DepEdge {
    pub from: String,
    pub to: String,
    pub kind: DepKind,
    pub line: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Unresolved {
    pub from: String,
    pub reference: String,
    pub kind: DepKind,
    pub line: u32,
}

/// Every edge of the tree, every reference that resolved to nothing, and
/// every cite key any text file uses.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyGraph {
    pub edges: Vec<DepEdge>,
    pub unresolved: Vec<Unresolved>,
    pub cite_keys: BTreeSet<String>,
}

impl DependencyGraph {
    pub fn edges_from<'a>(&'a self, path: &'a str) -> impl Iterator<Item = &'a DepEdge> + 'a {
        self.edges.iter().filter(move |e| e.from == path)
    }

    pub fn edges_to<'a>(&'a self, path: &'a str) -> impl Iterator<Item = &'a DepEdge> + 'a {
        self.edges.iter().filter(move |e| e.to == path)
    }
}

const LATEX_TEXT_EXTS: &[&str] = &["tex", "ltx", "latex"];
const BIB_EXTS: &[&str] = &["bib"];
/// pdfTeX's order first (pdf, png, jpg), then what xelatex/lualatex add.
const LATEX_IMAGE_EXTS: &[&str] = &[
    "pdf", "png", "jpg", "jpeg", "eps", "svg", "tif", "tiff", "gif",
];
const NO_EXTS: &[&str] = &[];

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

/// Scan one text file's source for references and cite keys. `format` is the
/// grammar id (`latex`, `typst`, `markdown`; anything else scans nothing).
pub fn scan_text(format: &str, text: &str) -> ScanResult {
    match format {
        "latex" => scan_latex(text),
        "typst" => scan_typst(text),
        "markdown" => scan_markdown(text),
        _ => ScanResult::default(),
    }
}

/// Scan the whole tree and resolve every reference against it.
pub fn scan(tree: &ProjectTree) -> DependencyGraph {
    let mut graph = DependencyGraph::default();
    let entry_dir = dir_of(&tree.entry.path).to_string();
    for file in tree.all_files() {
        let Some(text) = file.bytes.as_text() else {
            continue;
        };
        let Some(format) = file.format.as_deref() else {
            continue;
        };
        if !matches!(format, "latex" | "typst" | "markdown") {
            continue;
        }
        let result = scan_text(format, text);
        graph.cite_keys.extend(result.cite_keys);
        for raw in result.references {
            // TeX resolves against its working directory — the entry's —
            // whichever file the reference sits in; Typst and Markdown
            // resolve against the referencing file. Both get a second
            // chance against the other base so a `\subfile` or a
            // Typst file reached through a root-relative include still
            // finds its neighbours.
            let own_dir = dir_of(&file.path).to_string();
            let bases: Vec<&str> = if format == "latex" {
                vec![entry_dir.as_str(), own_dir.as_str()]
            } else {
                vec![own_dir.as_str(), entry_dir.as_str()]
            };
            match resolve(tree, &bases, &raw) {
                Some(to) => graph.edges.push(DepEdge {
                    from: file.path.clone(),
                    to,
                    kind: raw.kind,
                    line: raw.line,
                }),
                None if raw.kind.is_required() => graph.unresolved.push(Unresolved {
                    from: file.path.clone(),
                    reference: raw.reference,
                    kind: raw.kind,
                    line: raw.line,
                }),
                None => {}
            }
        }
    }
    graph.edges.sort_by(|a, b| {
        (a.from.as_str(), a.line, a.to.as_str()).cmp(&(b.from.as_str(), b.line, b.to.as_str()))
    });
    graph.edges.dedup();
    graph
}

/// Resolve a raw reference to a path in the tree: each base directory, each
/// search prefix, the reference as written then with each implied
/// extension.
fn resolve(tree: &ProjectTree, bases: &[&str], raw: &RawReference) -> Option<String> {
    let mut prefixes: Vec<String> = vec![String::new()];
    prefixes.extend(raw.search_prefixes.iter().cloned());
    let mut candidates: Vec<String> = vec![raw.reference.clone()];
    if extension_of(&raw.reference).is_none() || !raw.implied_extensions.is_empty() {
        for ext in raw.implied_extensions {
            candidates.push(format!("{}.{}", raw.reference, ext));
        }
    }
    for base in bases {
        for prefix in &prefixes {
            for candidate in &candidates {
                let spelled = if prefix.is_empty() {
                    candidate.clone()
                } else {
                    format!("{}/{}", prefix.trim_end_matches('/'), candidate)
                };
                // A graphicspath prefix is root-relative in practice; try it
                // both from the base and from the root.
                let joined =
                    join_relative(base, &spelled)
                        .into_iter()
                        .chain(if prefix.is_empty() {
                            None
                        } else {
                            join_relative("", &spelled)
                        });
                for path in joined {
                    if tree.contains(&path) {
                        return Some(path);
                    }
                }
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Comment blanking (offsets preserved)
// ---------------------------------------------------------------------------

/// Replace LaTeX comments (`%` to end of line, unless the `%` is escaped)
/// with spaces.
pub fn blank_latex_comments(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = bytes.to_vec();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'\\' {
            // Skip the escaped character (so `\%` is not a comment).
            i += 2;
            continue;
        }
        if b == b'%' {
            while i < bytes.len() && bytes[i] != b'\n' {
                out[i] = b' ';
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    // Blanking only touched ASCII bytes, so the result is still valid UTF-8.
    String::from_utf8(out).unwrap_or_else(|_| text.to_string())
}

/// Replace Typst comments (`//` to end of line, `/* … */` blocks) with
/// spaces, leaving string literals alone.
pub fn blank_typst_comments(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = bytes.to_vec();
    let mut i = 0;
    let mut in_string = false;
    let mut in_raw = false;
    while i < bytes.len() {
        let b = bytes[i];
        if in_string {
            if b == b'\\' {
                i += 2;
                continue;
            }
            if b == b'"' {
                in_string = false;
            }
            i += 1;
            continue;
        }
        if in_raw {
            if b == b'`' {
                in_raw = false;
            }
            i += 1;
            continue;
        }
        match b {
            b'"' => in_string = true,
            b'`' => in_raw = true,
            b'/' if i + 1 < bytes.len() && bytes[i + 1] == b'/' => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    out[i] = b' ';
                    i += 1;
                }
                continue;
            }
            b'/' if i + 1 < bytes.len() && bytes[i + 1] == b'*' => {
                let mut depth = 0usize;
                while i < bytes.len() {
                    if bytes[i] == b'/' && i + 1 < bytes.len() && bytes[i + 1] == b'*' {
                        depth += 1;
                        out[i] = b' ';
                        out[i + 1] = b' ';
                        i += 2;
                        continue;
                    }
                    if bytes[i] == b'*' && i + 1 < bytes.len() && bytes[i + 1] == b'/' {
                        depth -= 1;
                        out[i] = b' ';
                        out[i + 1] = b' ';
                        i += 2;
                        if depth == 0 {
                            break;
                        }
                        continue;
                    }
                    if bytes[i] != b'\n' {
                        out[i] = b' ';
                    }
                    i += 1;
                }
                continue;
            }
            _ => {}
        }
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_string())
}

/// Replace HTML comments in Markdown with spaces.
pub fn blank_markdown_comments(text: &str) -> String {
    let mut out = text.as_bytes().to_vec();
    let bytes = text.as_bytes();
    let mut i = 0;
    while i + 4 <= bytes.len() {
        if &bytes[i..i + 4] == b"<!--" {
            let end = text[i..]
                .find("-->")
                .map(|e| i + e + 3)
                .unwrap_or(bytes.len());
            for (k, byte) in out.iter_mut().enumerate().take(end).skip(i) {
                if bytes[k] != b'\n' {
                    *byte = b' ';
                }
            }
            i = end;
            continue;
        }
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_string())
}

fn line_of(text: &str, byte_offset: usize) -> u32 {
    text.as_bytes()[..byte_offset.min(text.len())]
        .iter()
        .filter(|b| **b == b'\n')
        .count() as u32
        + 1
}

fn regex(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("static scanner regex must compile"))
}

// ---------------------------------------------------------------------------
// LaTeX
// ---------------------------------------------------------------------------

fn scan_latex(text: &str) -> ScanResult {
    static INPUT: OnceLock<Regex> = OnceLock::new();
    static IMPORT: OnceLock<Regex> = OnceLock::new();
    static GRAPHICS: OnceLock<Regex> = OnceLock::new();
    static GRAPHICSPATH: OnceLock<Regex> = OnceLock::new();
    static GRAPHICSPATH_ITEM: OnceLock<Regex> = OnceLock::new();
    static BIBLIOGRAPHY: OnceLock<Regex> = OnceLock::new();
    static ADDBIB: OnceLock<Regex> = OnceLock::new();
    static USEPACKAGE: OnceLock<Regex> = OnceLock::new();
    static DOCUMENTCLASS: OnceLock<Regex> = OnceLock::new();
    static DATA: OnceLock<Regex> = OnceLock::new();
    static MINTED: OnceLock<Regex> = OnceLock::new();

    let blanked = blank_latex_comments(text);
    let mut out = ScanResult::default();

    // \graphicspath{{figures/}{img/}} — collected first, applied to every
    // \includegraphics in the file.
    let mut prefixes: Vec<String> = Vec::new();
    for caps in regex(
        &GRAPHICSPATH,
        r"\\graphicspath\s*\{((?:\s*\{[^}]*\}\s*)+)\}",
    )
    .captures_iter(&blanked)
    {
        for inner in regex(&GRAPHICSPATH_ITEM, r"\{([^}]*)\}").captures_iter(&caps[1]) {
            let p = inner[1].trim().trim_end_matches('/').to_string();
            if !p.is_empty() {
                prefixes.push(p);
            }
        }
    }

    let mut push = |m: regex::Match, reference: &str, kind: DepKind, exts: &'static [&str]| {
        for piece in reference.split(',') {
            let piece = piece.trim();
            if piece.is_empty() || piece.contains('#') || piece.contains('\\') {
                continue;
            }
            out.references.push(RawReference {
                reference: piece.to_string(),
                kind,
                line: line_of(&blanked, m.start()),
                implied_extensions: exts,
                search_prefixes: if kind == DepKind::Image {
                    prefixes.clone()
                } else {
                    Vec::new()
                },
            });
        }
    };

    for caps in regex(
        &INPUT,
        r"\\(?:input|include|subfile|InputIfFileExists)\s*\{([^}]*)\}",
    )
    .captures_iter(&blanked)
    {
        push(
            caps.get(0).unwrap(),
            &caps[1],
            DepKind::Include,
            LATEX_TEXT_EXTS,
        );
    }
    for caps in
        regex(&IMPORT, r"\\(?:sub)?import\s*\{([^}]*)\}\s*\{([^}]*)\}").captures_iter(&blanked)
    {
        let dir = caps[1].trim().trim_end_matches('/');
        let file = caps[2].trim();
        let joined = if dir.is_empty() {
            file.to_string()
        } else {
            format!("{dir}/{file}")
        };
        push(
            caps.get(0).unwrap(),
            &joined,
            DepKind::Include,
            LATEX_TEXT_EXTS,
        );
    }
    for caps in regex(
        &GRAPHICS,
        r"\\includegraphics\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}",
    )
    .captures_iter(&blanked)
    {
        push(
            caps.get(0).unwrap(),
            &caps[1],
            DepKind::Image,
            LATEX_IMAGE_EXTS,
        );
    }
    for caps in regex(&BIBLIOGRAPHY, r"\\bibliography\s*\{([^}]*)\}").captures_iter(&blanked) {
        push(
            caps.get(0).unwrap(),
            &caps[1],
            DepKind::Bibliography,
            BIB_EXTS,
        );
    }
    for caps in
        regex(&ADDBIB, r"\\addbibresource\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}").captures_iter(&blanked)
    {
        push(
            caps.get(0).unwrap(),
            &caps[1],
            DepKind::Bibliography,
            BIB_EXTS,
        );
    }
    for caps in regex(
        &USEPACKAGE,
        r"\\(?:usepackage|RequirePackage)\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}",
    )
    .captures_iter(&blanked)
    {
        push(caps.get(0).unwrap(), &caps[1], DepKind::Style, &["sty"]);
    }
    for caps in regex(
        &DOCUMENTCLASS,
        r"\\documentclass\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}",
    )
    .captures_iter(&blanked)
    {
        push(caps.get(0).unwrap(), &caps[1], DepKind::Class, &["cls"]);
    }
    for caps in regex(
        &DATA,
        r"\\(?:lstinputlisting|verbatiminput|includepdf|pgfplotstableread|csvreader|DTLloaddb\s*\{[^}]*\})\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}",
    )
    .captures_iter(&blanked)
    {
        push(caps.get(0).unwrap(), &caps[1], DepKind::Data, NO_EXTS);
    }
    for caps in regex(
        &MINTED,
        r"\\inputminted\s*(?:\[[^\]]*\])?\s*\{[^}]*\}\s*\{([^}]*)\}",
    )
    .captures_iter(&blanked)
    {
        push(caps.get(0).unwrap(), &caps[1], DepKind::Data, NO_EXTS);
    }

    out.references.sort_by_key(|r| r.line);
    out.cite_keys = extract_cite_keys(&blanked, CitationSyntax::Latex)
        .into_iter()
        .map(|u| u.key)
        .collect();
    out
}

// ---------------------------------------------------------------------------
// Typst
// ---------------------------------------------------------------------------

fn scan_typst(text: &str) -> ScanResult {
    static INCLUDE: OnceLock<Regex> = OnceLock::new();
    static LOADERS: OnceLock<Regex> = OnceLock::new();
    static BIBLIOGRAPHY: OnceLock<Regex> = OnceLock::new();
    static STRINGS: OnceLock<Regex> = OnceLock::new();

    let blanked = blank_typst_comments(text);
    let mut out = ScanResult::default();

    for caps in
        regex(&INCLUDE, r#"(?:^|[^\w@])(include|import)\s+"([^"]+)""#).captures_iter(&blanked)
    {
        let reference = caps[2].trim();
        if reference.starts_with('@') {
            continue; // a package, not a file
        }
        let kind = if &caps[1] == "include" {
            DepKind::Include
        } else {
            DepKind::Import
        };
        out.references.push(RawReference {
            reference: reference.to_string(),
            kind,
            line: line_of(&blanked, caps.get(2).unwrap().start()),
            implied_extensions: NO_EXTS,
            search_prefixes: Vec::new(),
        });
    }
    for caps in regex(
        &LOADERS,
        r#"\b(image|read|json|csv|yaml|toml|xml|cbor|plugin)\s*\(\s*"([^"]+)""#,
    )
    .captures_iter(&blanked)
    {
        let kind = if &caps[1] == "image" {
            DepKind::Image
        } else {
            DepKind::Data
        };
        out.references.push(RawReference {
            reference: caps[2].trim().to_string(),
            kind,
            line: line_of(&blanked, caps.get(2).unwrap().start()),
            implied_extensions: NO_EXTS,
            search_prefixes: Vec::new(),
        });
    }
    for caps in regex(
        &BIBLIOGRAPHY,
        r#"\bbibliography\s*\(\s*(\([^)]*\)|"[^"]+")"#,
    )
    .captures_iter(&blanked)
    {
        let group = caps.get(1).unwrap();
        for s in regex(&STRINGS, r#""([^"]+)""#).captures_iter(group.as_str()) {
            out.references.push(RawReference {
                reference: s[1].trim().to_string(),
                kind: DepKind::Bibliography,
                line: line_of(&blanked, group.start()),
                implied_extensions: NO_EXTS,
                search_prefixes: Vec::new(),
            });
        }
    }

    out.references.sort_by_key(|r| r.line);
    // Cite keys never sit inside string literals, but `@preview/…` package
    // specs do: blank the strings before looking for `@key`.
    out.cite_keys = extract_cite_keys(&blank_typst_strings(&blanked), CitationSyntax::Typst)
        .into_iter()
        .map(|u| u.key)
        .collect();
    out
}

/// Replace the contents of `"…"` literals with spaces (offsets preserved).
pub fn blank_typst_strings(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = bytes.to_vec();
    let mut i = 0;
    let mut in_string = false;
    while i < bytes.len() {
        let b = bytes[i];
        if in_string {
            if b == b'\\' {
                if i + 1 < bytes.len() && bytes[i + 1] != b'\n' {
                    out[i] = b' ';
                    out[i + 1] = b' ';
                }
                i += 2;
                continue;
            }
            if b == b'"' {
                in_string = false;
            } else if b != b'\n' {
                out[i] = b' ';
            }
            i += 1;
            continue;
        }
        if b == b'"' {
            in_string = true;
        }
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_string())
}

// ---------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------

fn scan_markdown(text: &str) -> ScanResult {
    static IMAGE: OnceLock<Regex> = OnceLock::new();
    static IMG_TAG: OnceLock<Regex> = OnceLock::new();
    static QUARTO_INCLUDE: OnceLock<Regex> = OnceLock::new();

    let blanked = blank_markdown_comments(text);
    let mut out = ScanResult::default();

    let is_remote = |r: &str| {
        let lower = r.to_ascii_lowercase();
        lower.starts_with("http://")
            || lower.starts_with("https://")
            || lower.starts_with("data:")
            || lower.starts_with("//")
    };

    for caps in regex(
        &IMAGE,
        r#"!\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#,
    )
    .captures_iter(&blanked)
    {
        let reference = &caps[1];
        if is_remote(reference) {
            continue;
        }
        out.references.push(RawReference {
            reference: reference.to_string(),
            kind: DepKind::Image,
            line: line_of(&blanked, caps.get(1).unwrap().start()),
            implied_extensions: NO_EXTS,
            search_prefixes: Vec::new(),
        });
    }
    for caps in regex(&IMG_TAG, r#"<img\s[^>]*?src\s*=\s*["']([^"']+)["']"#).captures_iter(&blanked)
    {
        let reference = &caps[1];
        if is_remote(reference) {
            continue;
        }
        out.references.push(RawReference {
            reference: reference.to_string(),
            kind: DepKind::Image,
            line: line_of(&blanked, caps.get(1).unwrap().start()),
            implied_extensions: NO_EXTS,
            search_prefixes: Vec::new(),
        });
    }
    for caps in
        regex(&QUARTO_INCLUDE, r#"\{\{<\s*include\s+([^\s>]+)\s*>\}\}"#).captures_iter(&blanked)
    {
        out.references.push(RawReference {
            reference: caps[1].to_string(),
            kind: DepKind::Include,
            line: line_of(&blanked, caps.get(1).unwrap().start()),
            implied_extensions: &["md", "qmd"],
            search_prefixes: Vec::new(),
        });
    }

    // Front matter: `bibliography: refs.bib`, `bibliography: [a.bib, b.bib]`,
    // or a YAML list on the following lines.
    if let Some(front) = front_matter(&blanked) {
        let mut in_list = false;
        for (idx, raw_line) in front.text.lines().enumerate() {
            let line_no = front.first_line + idx as u32;
            let line = raw_line.trim_end();
            if let Some(rest) = line.trim_start().strip_prefix("bibliography:") {
                let rest = rest.trim();
                in_list = rest.is_empty();
                for item in split_yaml_scalars(rest) {
                    out.references.push(RawReference {
                        reference: item,
                        kind: DepKind::Bibliography,
                        line: line_no,
                        implied_extensions: BIB_EXTS,
                        search_prefixes: Vec::new(),
                    });
                }
                continue;
            }
            if in_list {
                if let Some(item) = line.trim_start().strip_prefix("- ") {
                    let item = item.trim().trim_matches('"').trim_matches('\'');
                    if !item.is_empty() {
                        out.references.push(RawReference {
                            reference: item.to_string(),
                            kind: DepKind::Bibliography,
                            line: line_no,
                            implied_extensions: BIB_EXTS,
                            search_prefixes: Vec::new(),
                        });
                    }
                    continue;
                }
                in_list = false;
            }
        }
    }

    out.references.sort_by_key(|r| r.line);
    // Pandoc `[@key]` / `@key` — the Typst extractor's `@key` grammar.
    out.cite_keys = extract_cite_keys(&blanked, CitationSyntax::Typst)
        .into_iter()
        .map(|u| u.key)
        .collect();
    out
}

struct FrontMatter<'a> {
    text: &'a str,
    first_line: u32,
}

/// A leading `---` … `---` block, if any.
fn front_matter(text: &str) -> Option<FrontMatter<'_>> {
    let rest = text.strip_prefix("---")?;
    let rest = rest
        .strip_prefix('\n')
        .or_else(|| rest.strip_prefix("\r\n"))?;
    let end = rest.find("\n---")?;
    Some(FrontMatter {
        text: &rest[..end],
        first_line: 2,
    })
}

/// `a.bib`, `"a.bib"`, `[a.bib, b.bib]` → the items.
fn split_yaml_scalars(s: &str) -> Vec<String> {
    let s = s.trim();
    if s.is_empty() {
        return Vec::new();
    }
    let inner = s
        .strip_prefix('[')
        .and_then(|x| x.strip_suffix(']'))
        .unwrap_or(s);
    inner
        .split(',')
        .map(|p| p.trim().trim_matches('"').trim_matches('\'').to_string())
        .filter(|p| !p.is_empty())
        .collect()
}

/// A role for a path the scanner reached but nobody classified — used by
/// the importer to refine extension-based defaults from how a file is used.
pub fn role_for_kind(kind: DepKind) -> FileRole {
    match kind {
        DepKind::Include | DepKind::Import => FileRole::Chapter,
        DepKind::Image => FileRole::Figure,
        DepKind::Bibliography => FileRole::Bibliography,
        DepKind::Data => FileRole::Data,
        DepKind::Style | DepKind::Class => FileRole::Style,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn latex_comments_are_blanked_but_escaped_percent_is_kept() {
        let src = "a \\% b % comment\nnext";
        let out = blank_latex_comments(src);
        assert_eq!(out.len(), src.len());
        assert_eq!(out, "a \\% b          \nnext");
    }

    #[test]
    fn typst_comments_are_blanked_and_strings_are_safe() {
        let src = "#image(\"https://x/y.png\") // note\n/* block\nmore */ = H";
        let out = blank_typst_comments(src);
        assert_eq!(out.len(), src.len());
        assert!(out.contains("https://x/y.png"), "string content untouched");
        assert!(!out.contains("note"));
        assert!(!out.contains("block"));
        assert!(out.ends_with("= H"));
    }

    #[test]
    fn markdown_html_comments_are_blanked() {
        let out = blank_markdown_comments("a <!-- ![](x.png) --> b");
        assert!(!out.contains("x.png"));
        assert!(out.starts_with("a ") && out.ends_with(" b"));
    }

    #[test]
    fn latex_references_carry_lines_and_kinds() {
        let src = "\\documentclass{aastex}\n\\graphicspath{{figures/}}\n% \\input{ghost}\n\\input{chapters/intro}\n\\includegraphics[width=1in]{fig1}\n\\bibliography{refs,extra}\n\\addbibresource{more.bib}\n\\cite{key1, key2}";
        let r = scan_latex(src);
        let got: Vec<(String, DepKind, u32)> = r
            .references
            .iter()
            .map(|x| (x.reference.clone(), x.kind, x.line))
            .collect();
        assert_eq!(
            got,
            vec![
                ("aastex".into(), DepKind::Class, 1),
                ("chapters/intro".into(), DepKind::Include, 4),
                ("fig1".into(), DepKind::Image, 5),
                ("refs".into(), DepKind::Bibliography, 6),
                ("extra".into(), DepKind::Bibliography, 6),
                ("more.bib".into(), DepKind::Bibliography, 7),
            ]
        );
        assert_eq!(r.references[2].search_prefixes, vec!["figures"]);
        assert_eq!(r.cite_keys, vec!["key1", "key2"]);
    }

    #[test]
    fn typst_references_skip_packages_and_comments() {
        let src = "#import \"@preview/cetz:0.2.0\": canvas\n#import \"lib/util.typ\": *\n#include \"chapters/intro.typ\"\n// #include \"nope.typ\"\n#figure(image(\"figures/fig1.png\"))\n#let d = csv(\"data/x.csv\")\n#bibliography((\"a.bib\", \"b.bib\"))\nSee @knuth84.";
        let r = scan_typst(src);
        let got: Vec<(String, DepKind, u32)> = r
            .references
            .iter()
            .map(|x| (x.reference.clone(), x.kind, x.line))
            .collect();
        assert_eq!(
            got,
            vec![
                ("lib/util.typ".into(), DepKind::Import, 2),
                ("chapters/intro.typ".into(), DepKind::Include, 3),
                ("figures/fig1.png".into(), DepKind::Image, 5),
                ("data/x.csv".into(), DepKind::Data, 6),
                ("a.bib".into(), DepKind::Bibliography, 7),
                ("b.bib".into(), DepKind::Bibliography, 7),
            ]
        );
        assert_eq!(r.cite_keys, vec!["knuth84"]);
    }

    #[test]
    fn markdown_front_matter_and_images() {
        let src = "---\ntitle: T\nbibliography:\n  - refs.bib\n  - \"extra.bib\"\n---\n\n![A](figures/a.png)\n![Remote](https://x/y.png)\n<img src=\"figures/b.svg\">\n{{< include parts/b.md >}}\nAs [@smith2020] said.";
        let r = scan_markdown(src);
        let got: Vec<(String, DepKind)> = r
            .references
            .iter()
            .map(|x| (x.reference.clone(), x.kind))
            .collect();
        assert_eq!(
            got,
            vec![
                ("refs.bib".into(), DepKind::Bibliography),
                ("extra.bib".into(), DepKind::Bibliography),
                ("figures/a.png".into(), DepKind::Image),
                ("figures/b.svg".into(), DepKind::Image),
                ("parts/b.md".into(), DepKind::Include),
            ],
            "line order: the front matter comes first"
        );
        assert_eq!(r.cite_keys, vec!["smith2020"]);
        let inline = scan_markdown("---\nbibliography: [a.bib, b.bib]\n---\n");
        assert_eq!(inline.references.len(), 2);
    }
}
