//! A directory becomes one manuscript (ADR-0030 P3): walk it, skip what a
//! build leaves behind, classify every file by extension and then by how the
//! sources use it, find the entry, and hand back a tree the store can write
//! row by row.
//!
//! Pure: this reads the directory and decides; `imprint-service` writes the
//! rows. The entry guess is transparent (`ImportedTree::entry_reason`), and a
//! caller may override it.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use super::model::{extension_of, format_for_extension, FileRole, ProjectFile, ProjectTree};
use super::scan::{scan, DepKind};

/// Names and suffixes a build leaves behind — never imported.
pub const DEFAULT_EXCLUDES: &[&str] = &[
    ".impress-materialized",
    ".git",
    ".hg",
    ".svn",
    ".DS_Store",
    "__pycache__",
    "_minted*",
    "*.aux",
    "*.log",
    "*.out",
    "*.toc",
    "*.lof",
    "*.lot",
    "*.bbl",
    "*.blg",
    "*.fls",
    "*.fdb_latexmk",
    "*.synctex*",
    "*.nav",
    "*.snm",
    "*.vrb",
    "*.xdv",
    "*.bcf",
    "*.run.xml",
    "*.pyc",
    ".impress-materialized",
    ".build",
    ".tmp",
];

/// Bytes above this are not imported (a 300 MB data cube is not part of a
/// manuscript; link it, do not copy it).
pub const MAX_FILE_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct ImportOptions {
    /// Glob-ish patterns (`*.aux`, `.git`, `_minted*`) matched against each
    /// path component; `DEFAULT_EXCLUDES` when empty.
    pub excludes: Vec<String>,
    /// A project-relative path to use as the entry instead of guessing.
    pub entry: Option<String>,
    pub max_file_bytes: u64,
}

impl Default for ImportOptions {
    fn default() -> Self {
        Self {
            excludes: Vec::new(),
            entry: None,
            max_file_bytes: MAX_FILE_BYTES,
        }
    }
}

/// What the walk found.
#[derive(Debug, Clone)]
pub struct ImportedTree {
    pub tree: ProjectTree,
    /// `typst | latex | markdown | plaintext`, from the entry.
    pub format: String,
    pub entry_reason: String,
    /// Paths skipped, with why.
    pub skipped: Vec<(String, String)>,
}

#[derive(Debug, thiserror::Error)]
pub enum ImportError {
    #[error("{0} is not a directory")]
    NotADirectory(PathBuf),
    #[error("{path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("no source file to use as the entry under {0}")]
    NoEntry(PathBuf),
    #[error("entry {0:?} is not among the imported files")]
    EntryNotFound(String),
}

fn matches_pattern(component: &str, pattern: &str) -> bool {
    if let Some(suffix) = pattern.strip_prefix('*') {
        if let Some(stem) = suffix.strip_suffix('*') {
            return component.contains(stem);
        }
        return component.ends_with(suffix);
    }
    if let Some(prefix) = pattern.strip_suffix('*') {
        return component.starts_with(prefix);
    }
    component == pattern
}

fn excluded(rel: &str, patterns: &[String]) -> bool {
    rel.split('/')
        .any(|c| patterns.iter().any(|p| matches_pattern(c, p)))
}

fn walk(
    root: &Path,
    dir: &Path,
    patterns: &[String],
    out: &mut Vec<(String, PathBuf)>,
    skipped: &mut Vec<(String, String)>,
) -> Result<(), ImportError> {
    let entries = fs::read_dir(dir).map_err(|source| ImportError::Io {
        path: dir.to_path_buf(),
        source,
    })?;
    let mut names: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
    names.sort();
    for path in names {
        let rel = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        if excluded(&rel, patterns) {
            skipped.push((rel, "excluded".into()));
            continue;
        }
        let meta = fs::symlink_metadata(&path).map_err(|source| ImportError::Io {
            path: path.clone(),
            source,
        })?;
        if meta.file_type().is_symlink() {
            skipped.push((rel, "symlink".into()));
            continue;
        }
        if meta.is_dir() {
            walk(root, &path, patterns, out, skipped)?;
        } else if meta.is_file() {
            out.push((rel, path));
        }
    }
    Ok(())
}

/// Read a directory into a tree.
pub fn import_directory(root: &Path, options: &ImportOptions) -> Result<ImportedTree, ImportError> {
    if !root.is_dir() {
        return Err(ImportError::NotADirectory(root.to_path_buf()));
    }
    let patterns: Vec<String> = if options.excludes.is_empty() {
        DEFAULT_EXCLUDES.iter().map(|s| s.to_string()).collect()
    } else {
        options.excludes.clone()
    };
    let mut found: Vec<(String, PathBuf)> = Vec::new();
    let mut skipped: Vec<(String, String)> = Vec::new();
    walk(root, root, &patterns, &mut found, &mut skipped)?;

    // Read everything, classify by extension.
    let mut files: Vec<ProjectFile> = Vec::new();
    for (rel, path) in found {
        let meta = fs::metadata(&path).map_err(|source| ImportError::Io {
            path: path.clone(),
            source,
        })?;
        if meta.len() > options.max_file_bytes {
            skipped.push((
                rel,
                format!("{} bytes exceeds the import limit", meta.len()),
            ));
            continue;
        }
        let bytes = fs::read(&path).map_err(|source| ImportError::Io {
            path: path.clone(),
            source,
        })?;
        let role = default_role(&rel);
        let text_like = extension_of(&rel)
            .as_deref()
            .and_then(format_for_extension)
            .is_some()
            || matches!(extension_of(&rel).as_deref(), Some("txt") | None);
        let file = if text_like && !bytes.contains(&0) {
            match String::from_utf8(bytes) {
                Ok(text) => ProjectFile::text(rel, role, text),
                Err(e) => ProjectFile::binary(rel, role, e.into_bytes()),
            }
        } else {
            ProjectFile::binary(rel, role, bytes)
        };
        files.push(file);
    }
    if files.is_empty() {
        return Err(ImportError::NoEntry(root.to_path_buf()));
    }

    // The entry: chosen, else guessed.
    let (entry_path, reason) = match &options.entry {
        Some(e) => {
            let e = e.trim_start_matches("./").to_string();
            if !files.iter().any(|f| f.path == e) {
                return Err(ImportError::EntryNotFound(e));
            }
            (e, "chosen by the caller".to_string())
        }
        None => guess_entry(&files).ok_or_else(|| ImportError::NoEntry(root.to_path_buf()))?,
    };
    let format = files
        .iter()
        .find(|f| f.path == entry_path)
        .and_then(|f| f.format.clone())
        .unwrap_or_else(|| "plaintext".into());
    let entry = files
        .iter()
        .position(|f| f.path == entry_path)
        .map(|i| files.remove(i))
        .expect("entry is among the files");

    // Refine roles by use: a `.tex` some file `\input`s is a chapter even
    // if it looked like a supplement; a `.png` nothing references is still
    // a figure (an unreferenced figure is a diagnostic, not a different role).
    let mut tree = ProjectTree::new("import", "", format.clone(), entry, files, vec![]);
    let deps = scan(&tree);
    let mut referenced_as: std::collections::BTreeMap<String, DepKind> = Default::default();
    for e in &deps.edges {
        referenced_as.entry(e.to.clone()).or_insert(e.kind);
    }
    for file in &mut tree.files {
        if let Some(kind) = referenced_as.get(&file.path) {
            let by_use = super::scan::role_for_kind(*kind);
            let keep_specific =
                matches!(file.role, FileRole::FigureSource | FileRole::Bibliography);
            if !keep_specific {
                file.role = by_use;
            }
        }
    }

    Ok(ImportedTree {
        tree,
        format,
        entry_reason: reason,
        skipped,
    })
}

/// Extension-based role for an imported path (mirrors the store's default).
fn default_role(path: &str) -> FileRole {
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".plot.json") {
        return FileRole::FigureSource;
    }
    let in_figures_dir = lower
        .rsplit_once('/')
        .map(|(dir, _)| {
            dir.split('/')
                .any(|c| matches!(c, "figures" | "figs" | "plots" | "fig"))
        })
        .unwrap_or(false);
    if in_figures_dir && matches!(extension_of(path).as_deref(), Some("typ") | Some("tex")) {
        return FileRole::FigureSource;
    }
    match extension_of(path).as_deref() {
        Some("tex") | Some("typ") | Some("md") | Some("markdown") | Some("txt") | Some("qmd") => {
            FileRole::Chapter
        }
        Some("bib") | Some("bibtex") | Some("bst") => FileRole::Bibliography,
        Some("png") | Some("jpg") | Some("jpeg") | Some("pdf") | Some("svg") | Some("eps")
        | Some("gif") | Some("tif") | Some("tiff") | Some("webp") => FileRole::Figure,
        Some("vsz") | Some("plot") | Some("py") | Some("jl") | Some("r") | Some("sh")
        | Some("ipynb") => FileRole::FigureSource,
        Some("csv") | Some("tsv") | Some("json") | Some("npz") | Some("npy") | Some("h5")
        | Some("hdf5") | Some("fits") | Some("parquet") | Some("yaml") | Some("yml")
        | Some("toml") | Some("dat") => FileRole::Data,
        Some("sty") | Some("cls") | Some("clo") | Some("def") | Some("bbx") | Some("cbx") => {
            FileRole::Style
        }
        _ => FileRole::Aux,
    }
}

/// Which file is the entry, and why. In order: the one `\documentclass`
/// (LaTeX) or the one `.typ` that is included by nothing and includes
/// something; then `main.*`/`paper.*`/`index.*`; then the only source file;
/// then the shallowest, alphabetically first source file.
pub fn guess_entry(files: &[ProjectFile]) -> Option<(String, String)> {
    let sources: Vec<&ProjectFile> = files
        .iter()
        .filter(|f| {
            matches!(
                f.format.as_deref(),
                Some("latex") | Some("typst") | Some("markdown")
            )
        })
        .filter(|f| {
            // A style file is not an entry even when it is `.tex`-adjacent.
            !matches!(
                extension_of(&f.path).as_deref(),
                Some("sty") | Some("cls") | Some("clo") | Some("def")
            )
        })
        .collect();
    if sources.is_empty() {
        return None;
    }
    // LaTeX: the file with \documentclass.
    let with_class: Vec<&&ProjectFile> = sources
        .iter()
        .filter(|f| {
            f.bytes
                .as_text()
                .map(|t| super::scan::blank_latex_comments(t).contains("\\documentclass"))
                .unwrap_or(false)
        })
        .collect();
    if with_class.len() == 1 {
        return Some((
            with_class[0].path.clone(),
            "the one file with \\documentclass".into(),
        ));
    }
    if with_class.len() > 1 {
        let mut c: Vec<&&ProjectFile> = with_class.clone();
        c.sort_by_key(|f| (f.path.matches('/').count(), f.path.clone()));
        return Some((
            c[0].path.clone(),
            format!(
                "{} files carry \\documentclass; the shallowest",
                with_class.len()
            ),
        ));
    }
    // Typst / Markdown: a root that includes others and is included by none.
    let tree = ProjectTree::new(
        "guess",
        "",
        sources[0].format.clone().unwrap_or_default(),
        (*sources[0]).clone(),
        files
            .iter()
            .filter(|f| f.path != sources[0].path)
            .cloned()
            .collect(),
        vec![],
    );
    let deps = scan(&tree);
    let included: BTreeSet<&str> = deps
        .edges
        .iter()
        .filter(|e| matches!(e.kind, DepKind::Include | DepKind::Import))
        .map(|e| e.to.as_str())
        .collect();
    let roots: Vec<&&ProjectFile> = sources
        .iter()
        .filter(|f| !included.contains(f.path.as_str()))
        .filter(|f| {
            deps.edges
                .iter()
                .any(|e| e.from == f.path && matches!(e.kind, DepKind::Include | DepKind::Import))
        })
        .collect();
    if roots.len() == 1 {
        return Some((
            roots[0].path.clone(),
            "includes other files and is included by none".into(),
        ));
    }
    // Conventional names.
    for stem in [
        "main",
        "paper",
        "index",
        "manuscript",
        "thesis",
        "book",
        "README",
    ] {
        let mut named: Vec<&&ProjectFile> = sources
            .iter()
            .filter(|f| {
                let name = super::model::file_name_of(&f.path);
                name.rsplit_once('.')
                    .map(|(s, _)| s == stem)
                    .unwrap_or(false)
            })
            .collect();
        if !named.is_empty() {
            named.sort_by_key(|f| (f.path.matches('/').count(), f.path.clone()));
            return Some((named[0].path.clone(), format!("named {stem}")));
        }
    }
    if sources.len() == 1 {
        return Some((sources[0].path.clone(), "the only source file".into()));
    }
    let mut all: Vec<&&ProjectFile> = sources.iter().collect();
    all.sort_by_key(|f| (f.path.matches('/').count(), f.path.clone()));
    Some((all[0].path.clone(), "the shallowest source file".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(root: &Path, rel: &str, bytes: &[u8]) {
        let p = root.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, bytes).unwrap();
    }

    #[test]
    fn a_latex_directory_imports_with_roles_and_the_documentclass_entry() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        write(root, "paper.tex", b"\\documentclass{article}\n\\input{sections/intro}\n\\includegraphics{figures/f}\n\\bibliography{refs}");
        write(root, "sections/intro.tex", b"\\section{Intro}");
        write(root, "sections/notes.tex", b"% loose notes, not included");
        write(root, "figures/f.pdf", b"%PDF-1.5\0");
        write(root, "figures/make_f.py", b"print()");
        write(root, "refs.bib", b"@misc{a,}");
        write(root, "aastex.cls", b"\\ProvidesClass{aastex}");
        write(root, "paper.aux", b"junk");
        write(root, "paper.log", b"junk");
        write(root, ".git/HEAD", b"ref");
        write(root, "data/rows.csv", b"a,b\n");

        let imported = import_directory(root, &ImportOptions::default()).unwrap();
        assert_eq!(imported.tree.entry.path, "paper.tex");
        assert_eq!(imported.format, "latex");
        assert!(imported.entry_reason.contains("documentclass"));
        let roles: Vec<(String, &str)> = imported
            .tree
            .files
            .iter()
            .map(|f| (f.path.clone(), f.role.as_str()))
            .collect();
        assert_eq!(
            roles,
            vec![
                ("aastex.cls".into(), "style"),
                ("data/rows.csv".into(), "data"),
                ("figures/f.pdf".into(), "figure"),
                ("figures/make_f.py".into(), "figure-source"),
                ("refs.bib".into(), "bibliography"),
                ("sections/intro.tex".into(), "chapter"),
                ("sections/notes.tex".into(), "chapter"),
            ]
        );
        let skipped: Vec<&str> = imported.skipped.iter().map(|(p, _)| p.as_str()).collect();
        assert!(skipped.contains(&".git"));
        assert!(skipped.contains(&"paper.aux"));
        assert!(skipped.contains(&"paper.log"));
        assert!(imported
            .tree
            .file("figures/f.pdf")
            .unwrap()
            .bytes
            .as_bytes()
            .unwrap()
            .starts_with(b"%PDF"));
    }

    #[test]
    fn a_typst_directory_finds_the_root_that_includes_others() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        write(
            root,
            "thesis.typ",
            b"#include \"chapters/one.typ\"\n#include \"chapters/two.typ\"",
        );
        write(root, "chapters/one.typ", b"= One");
        write(root, "chapters/two.typ", b"= Two");
        write(root, "README.md", b"# how to build");
        let imported = import_directory(root, &ImportOptions::default()).unwrap();
        assert_eq!(imported.tree.entry.path, "thesis.typ");
        assert!(imported.entry_reason.contains("included by none"));
        assert_eq!(imported.format, "typst");

        // A chosen entry wins; a wrong one is an error, not a guess.
        let chosen = import_directory(
            root,
            &ImportOptions {
                entry: Some("chapters/one.typ".into()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(chosen.tree.entry.path, "chapters/one.typ");
        assert!(matches!(
            import_directory(
                root,
                &ImportOptions {
                    entry: Some("nope.typ".into()),
                    ..Default::default()
                }
            ),
            Err(ImportError::EntryNotFound(_))
        ));
    }

    #[test]
    fn conventional_names_and_empty_directories() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        write(root, "notes/main.md", b"# Notes");
        write(root, "notes/other.md", b"# Other");
        let imported = import_directory(root, &ImportOptions::default()).unwrap();
        assert_eq!(imported.tree.entry.path, "notes/main.md");
        assert!(imported.entry_reason.contains("named main"));
        assert_eq!(imported.format, "markdown");

        let empty = tempfile::tempdir().unwrap();
        assert!(matches!(
            import_directory(empty.path(), &ImportOptions::default()),
            Err(ImportError::NoEntry(_))
        ));
        assert!(matches!(
            import_directory(&root.join("nope"), &ImportOptions::default()),
            Err(ImportError::NotADirectory(_))
        ));
    }

    #[test]
    fn patterns_match_components() {
        assert!(matches_pattern("paper.aux", "*.aux"));
        assert!(matches_pattern("_minted-paper", "_minted*"));
        assert!(matches_pattern("x.synctex.gz", "*.synctex*"));
        assert!(!matches_pattern("paper.tex", "*.aux"));
        assert!(excluded(".git/HEAD", &[".git".into()]));
        assert!(!excluded("src/git-notes.md", &[".git".into()]));
    }
}
