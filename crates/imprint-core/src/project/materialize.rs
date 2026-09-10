//! Rust materialises; toolchains see a directory (ADR-0030 D5).
//!
//! [`materialize`] writes a tree to a directory idempotently: every file is
//! hash-compared before it is touched, writes go through a temp name and a
//! rename, files the tree no longer has are pruned — but only those a
//! previous materialisation put there (recorded in `.impress-materialized`),
//! never anything else in the directory, and never a path outside it.
//! Projected bibliographies are written as the `.bib` text they resolved to.
//!
//! [`export`] is the same write to a directory the user chose, in one of two
//! layouts; [`pack`] is the same write into a `.tar.zst` archive with the
//! bundle manifest — the revision archive (D2: the manifest is PRODUCED from
//! the tree, never hand-described).

use std::collections::BTreeSet;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use impress_core::schemas::manuscript_bundle_manifest::{
    BundleCompileEngine, BundleCompileSpec, BundleEntry, BundleEntryRole, BundleManifest,
    BundleSourceFormat, BUNDLE_MANIFEST_SCHEMA,
};

use super::bib::ProjectedBibliography;
use super::model::{Engine, FileRole, ProjectTree, Target};

/// The ledger of paths a materialisation wrote, kept in the directory so a
/// later run knows what it may prune.
pub const LEDGER_FILE: &str = ".impress-materialized";

/// What a materialisation did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Materialization {
    pub root: PathBuf,
    /// The entry file, absolute.
    pub entry: PathBuf,
    pub written: Vec<String>,
    pub unchanged: Vec<String>,
    pub removed: Vec<String>,
    /// Files whose bytes the tree does not hold (a blob absent from this
    /// workspace); they are left as they were on disk, if present.
    pub missing: Vec<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum MaterializeError {
    #[error("{path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("path {0:?} escapes the materialisation root")]
    Escapes(String),
    #[error("archive: {0}")]
    Archive(String),
}

fn io(path: &Path, source: std::io::Error) -> MaterializeError {
    MaterializeError::Io {
        path: path.to_path_buf(),
        source,
    }
}

/// `root/path`, refusing any component that could leave `root`.
fn safe_join(root: &Path, path: &str) -> Result<PathBuf, MaterializeError> {
    let mut out = root.to_path_buf();
    for component in path.split('/') {
        match component {
            "" | "." => continue,
            ".." => return Err(MaterializeError::Escapes(path.to_string())),
            c if c.contains('\\') || c.contains('\0') => {
                return Err(MaterializeError::Escapes(path.to_string()))
            }
            c => out.push(c),
        }
    }
    if out == root {
        return Err(MaterializeError::Escapes(path.to_string()));
    }
    Ok(out)
}

/// The bytes a path should have on disk: a projected bibliography's text
/// wins over the row's own bytes.
fn effective_bytes<'a>(
    tree: &'a ProjectTree,
    path: &str,
    bibliographies: &'a [ProjectedBibliography],
) -> Option<&'a [u8]> {
    if let Some(b) = bibliographies.iter().find(|b| b.path == path) {
        return Some(b.text.as_bytes());
    }
    tree.file(path).and_then(|f| f.bytes.as_bytes())
}

fn write_atomic(target: &Path, bytes: &[u8]) -> Result<(), MaterializeError> {
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|e| io(parent, e))?;
    }
    let tmp = target.with_extension(format!(
        "{}.tmp-{}",
        target
            .extension()
            .map(|e| e.to_string_lossy().into_owned())
            .unwrap_or_default(),
        std::process::id()
    ));
    {
        let mut f = fs::File::create(&tmp).map_err(|e| io(&tmp, e))?;
        f.write_all(bytes).map_err(|e| io(&tmp, e))?;
    }
    fs::rename(&tmp, target).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        io(target, e)
    })
}

fn read_ledger(root: &Path) -> BTreeSet<String> {
    fs::read_to_string(root.join(LEDGER_FILE))
        .map(|s| {
            s.lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

fn write_ledger(root: &Path, paths: &BTreeSet<String>) -> Result<(), MaterializeError> {
    let mut text = String::new();
    for p in paths {
        text.push_str(p);
        text.push('\n');
    }
    write_atomic(&root.join(LEDGER_FILE), text.as_bytes())
}

/// Write the tree to `root` (created if needed). Idempotent: unchanged files
/// are not rewritten (so mtimes stay put and incremental toolchains stay
/// fast); files written by an earlier run that the tree no longer has are
/// removed; nothing else in `root` is touched.
pub fn materialize(
    tree: &ProjectTree,
    bibliographies: &[ProjectedBibliography],
    root: &Path,
) -> Result<Materialization, MaterializeError> {
    fs::create_dir_all(root).map_err(|e| io(root, e))?;
    let mut out = Materialization {
        root: root.to_path_buf(),
        entry: safe_join(root, &tree.entry.path)?,
        ..Default::default()
    };
    let previous = read_ledger(root);
    let mut ledger: BTreeSet<String> = BTreeSet::new();

    for file in tree.all_files() {
        let target = safe_join(root, &file.path)?;
        let Some(bytes) = effective_bytes(tree, &file.path, bibliographies) else {
            out.missing.push(file.path.clone());
            continue;
        };
        ledger.insert(file.path.clone());
        let same = match fs::read(&target) {
            Ok(existing) => existing == bytes,
            Err(_) => false,
        };
        if same {
            out.unchanged.push(file.path.clone());
            continue;
        }
        write_atomic(&target, bytes)?;
        out.written.push(file.path.clone());
    }

    for stale in previous.difference(&ledger) {
        if let Ok(path) = safe_join(root, stale) {
            if path.is_file() {
                fs::remove_file(&path).map_err(|e| io(&path, e))?;
                out.removed.push(stale.clone());
                // Prune now-empty directories up to the root.
                let mut dir = path.parent().map(Path::to_path_buf);
                while let Some(d) = dir {
                    if d == root {
                        break;
                    }
                    if fs::remove_dir(&d).is_err() {
                        break;
                    }
                    dir = d.parent().map(Path::to_path_buf);
                }
            }
        }
    }
    write_ledger(root, &ledger)?;
    out.written.sort();
    out.unchanged.sort();
    out.removed.sort();
    out.missing.sort();
    Ok(out)
}

/// How an export lays the tree out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportLayout {
    /// The tree as-is plus `manifest.json` — lossless, what `pack` archives.
    Bundle,
    /// The tree as-is, no manifest — for collaborators who do not run imprint.
    Standalone,
}

/// The bundle manifest for `target`, produced from the tree (D2).
pub fn manifest_for(tree: &ProjectTree, target: &Target) -> BundleManifest {
    let mut entries: Vec<BundleEntry> = tree
        .all_files()
        .map(|f| BundleEntry {
            path: f.path.clone(),
            role: if f.path == target.entry {
                BundleEntryRole::Main
            } else if f.role == FileRole::Main {
                BundleEntryRole::Chapter
            } else {
                f.role
            },
        })
        .collect();
    entries.sort_by(|a, b| a.path.cmp(&b.path));
    BundleManifest {
        schema: BUNDLE_MANIFEST_SCHEMA.to_string(),
        main_source: target.entry.clone(),
        source_format: match target.engine.source_format() {
            "latex" => BundleSourceFormat::Tex,
            "typst" => BundleSourceFormat::Typst,
            "markdown" => BundleSourceFormat::Markdown,
            _ => BundleSourceFormat::Typst,
        },
        entries,
        compile: BundleCompileSpec {
            engine: match target.engine {
                Engine::Typst | Engine::Markdown => BundleCompileEngine::Typst,
                Engine::Tectonic | Engine::Pdflatex => BundleCompileEngine::Pdflatex,
                Engine::Xelatex => BundleCompileEngine::Xelatex,
                Engine::Lualatex => BundleCompileEngine::Lualatex,
                Engine::Latexmk => BundleCompileEngine::Latexmk,
                Engine::None => BundleCompileEngine::None,
            },
            extra_args: target.args.clone(),
        },
        exclude_globs: vec![],
    }
}

/// Export to a user-chosen directory. The directory is not a managed
/// materialisation root: no ledger, no pruning — a one-shot copy.
pub fn export(
    tree: &ProjectTree,
    bibliographies: &[ProjectedBibliography],
    target: &Target,
    dir: &Path,
    layout: ExportLayout,
) -> Result<Materialization, MaterializeError> {
    fs::create_dir_all(dir).map_err(|e| io(dir, e))?;
    let mut out = Materialization {
        root: dir.to_path_buf(),
        entry: safe_join(dir, &tree.entry.path)?,
        ..Default::default()
    };
    for file in tree.all_files() {
        let target = safe_join(dir, &file.path)?;
        let Some(bytes) = effective_bytes(tree, &file.path, bibliographies) else {
            out.missing.push(file.path.clone());
            continue;
        };
        write_atomic(&target, bytes)?;
        out.written.push(file.path.clone());
    }
    if layout == ExportLayout::Bundle {
        let manifest = manifest_for(tree, target);
        let json = manifest
            .to_canonical_json()
            .map_err(|e| MaterializeError::Archive(e.to_string()))?;
        write_atomic(&dir.join("manifest.json"), json.as_bytes())?;
        out.written.push("manifest.json".into());
    }
    out.written.sort();
    Ok(out)
}

/// The revision archive: a `.tar.zst` of the tree plus `manifest.json`,
/// entries in path order with fixed metadata so identical trees pack to
/// identical bytes.
pub fn pack(
    tree: &ProjectTree,
    bibliographies: &[ProjectedBibliography],
    target: &Target,
) -> Result<(Vec<u8>, BundleManifest), MaterializeError> {
    let manifest = manifest_for(tree, target);
    let manifest_json = manifest
        .to_canonical_json()
        .map_err(|e| MaterializeError::Archive(e.to_string()))?;
    let mut tar_bytes: Vec<u8> = Vec::new();
    {
        let mut builder = tar::Builder::new(&mut tar_bytes);
        builder.mode(tar::HeaderMode::Deterministic);
        let mut append = |path: &str, bytes: &[u8]| -> Result<(), MaterializeError> {
            let mut header = tar::Header::new_gnu();
            header.set_size(bytes.len() as u64);
            header.set_mode(0o644);
            header.set_mtime(0);
            header.set_cksum();
            builder
                .append_data(&mut header, path, bytes)
                .map_err(|e| MaterializeError::Archive(format!("{path}: {e}")))
        };
        append("manifest.json", manifest_json.as_bytes())?;
        let mut paths: Vec<&str> = tree.all_files().map(|f| f.path.as_str()).collect();
        paths.sort_unstable();
        for path in paths {
            if let Some(bytes) = effective_bytes(tree, path, bibliographies) {
                append(path, bytes)?;
            }
        }
        builder
            .finish()
            .map_err(|e| MaterializeError::Archive(e.to_string()))?;
    }
    let compressed = zstd::encode_all(&tar_bytes[..], 3)
        .map_err(|e| MaterializeError::Archive(format!("zstd: {e}")))?;
    Ok((compressed, manifest))
}

/// Read a `.tar.zst` back into `(path, bytes)` pairs, manifest first.
pub fn unpack(archive: &[u8]) -> Result<Vec<(String, Vec<u8>)>, MaterializeError> {
    let tar_bytes =
        zstd::decode_all(archive).map_err(|e| MaterializeError::Archive(format!("zstd: {e}")))?;
    let mut ar = tar::Archive::new(&tar_bytes[..]);
    let mut out = Vec::new();
    for entry in ar
        .entries()
        .map_err(|e| MaterializeError::Archive(e.to_string()))?
    {
        let mut entry = entry.map_err(|e| MaterializeError::Archive(e.to_string()))?;
        let path = entry
            .path()
            .map_err(|e| MaterializeError::Archive(e.to_string()))?
            .to_string_lossy()
            .into_owned();
        let mut bytes = Vec::new();
        std::io::Read::read_to_end(&mut entry, &mut bytes)
            .map_err(|e| MaterializeError::Archive(format!("{path}: {e}")))?;
        out.push((path, bytes));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::model::{FileRole, ProjectFile};

    fn tree() -> ProjectTree {
        ProjectTree::new(
            "m",
            "T",
            "typst",
            ProjectFile::text("main.typ", FileRole::Main, "= T\n#include \"ch/a.typ\""),
            vec![
                ProjectFile::text("ch/a.typ", FileRole::Chapter, "== A"),
                ProjectFile::binary("figures/f.png", FileRole::Figure, vec![1, 2, 3]),
                ProjectFile::text("refs.bib", FileRole::Bibliography, ""),
            ],
            vec![],
        )
    }

    #[test]
    fn materialize_is_idempotent_and_prunes_only_its_own_files() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("work");
        let bibs = vec![ProjectedBibliography {
            path: "refs.bib".into(),
            text: "@misc{x,}".into(),
            requested: vec![],
            missing: vec![],
            synthesized: vec![],
        }];
        let t = tree();
        let first = materialize(&t, &bibs, &root).unwrap();
        assert_eq!(
            first.written,
            vec!["ch/a.typ", "figures/f.png", "main.typ", "refs.bib"]
        );
        assert_eq!(
            fs::read_to_string(root.join("refs.bib")).unwrap(),
            "@misc{x,}"
        );
        assert_eq!(first.entry, root.join("main.typ"));

        // A user file the tree does not own survives every run.
        fs::write(root.join("notes.txt"), "mine").unwrap();
        let second = materialize(&t, &bibs, &root).unwrap();
        assert!(second.written.is_empty());
        assert_eq!(second.unchanged.len(), 4);
        assert!(root.join("notes.txt").exists());

        // Drop the chapter: its file goes, its now-empty directory goes.
        let mut t2 = t.clone();
        t2.files.retain(|f| f.path != "ch/a.typ");
        let third = materialize(&t2, &bibs, &root).unwrap();
        assert_eq!(third.removed, vec!["ch/a.typ"]);
        assert!(!root.join("ch").exists());
        assert!(root.join("notes.txt").exists());

        // Escapes are refused before anything is written.
        let mut evil = t.clone();
        evil.files
            .push(ProjectFile::text("../evil.typ", FileRole::Chapter, "x"));
        assert!(matches!(
            materialize(&evil, &bibs, &root),
            Err(MaterializeError::Escapes(_))
        ));
    }

    #[test]
    fn export_bundle_writes_a_manifest_produced_from_the_tree() {
        let dir = tempfile::tempdir().unwrap();
        let t = tree();
        let out = export(
            &t,
            &[],
            t.default_target(),
            dir.path(),
            ExportLayout::Bundle,
        )
        .unwrap();
        assert!(out.written.contains(&"manifest.json".to_string()));
        let manifest =
            BundleManifest::parse(&fs::read_to_string(dir.path().join("manifest.json")).unwrap())
                .unwrap();
        assert_eq!(manifest.main_source, "main.typ");
        assert_eq!(manifest.source_format, BundleSourceFormat::Typst);
        assert_eq!(manifest.compile.engine, BundleCompileEngine::Typst);
        let roles: Vec<(String, &str)> = manifest
            .entries
            .iter()
            .map(|e| (e.path.clone(), e.role.as_str()))
            .collect();
        assert_eq!(
            roles,
            vec![
                ("ch/a.typ".into(), "chapter"),
                ("figures/f.png".into(), "figure"),
                ("main.typ".into(), "main"),
                ("refs.bib".into(), "bibliography"),
            ]
        );
        let standalone = tempfile::tempdir().unwrap();
        let out = export(
            &t,
            &[],
            t.default_target(),
            standalone.path(),
            ExportLayout::Standalone,
        )
        .unwrap();
        assert!(!out.written.contains(&"manifest.json".to_string()));
        assert!(standalone.path().join("ch/a.typ").exists());
    }

    #[test]
    fn pack_is_deterministic_and_round_trips() {
        let t = tree();
        let (a, manifest) = pack(&t, &[], t.default_target()).unwrap();
        let (b, _) = pack(&t, &[], t.default_target()).unwrap();
        assert_eq!(a, b, "identical trees pack to identical bytes");
        assert_eq!(manifest.entries.len(), 4);
        let entries = unpack(&a).unwrap();
        assert_eq!(entries[0].0, "manifest.json");
        let names: Vec<&str> = entries.iter().map(|(p, _)| p.as_str()).collect();
        assert_eq!(
            names,
            vec![
                "manifest.json",
                "ch/a.typ",
                "figures/f.png",
                "main.typ",
                "refs.bib"
            ]
        );
        assert_eq!(
            entries
                .iter()
                .find(|(p, _)| p == "figures/f.png")
                .unwrap()
                .1,
            vec![1, 2, 3]
        );
        assert!(
            a.len() < 4096,
            "a few small files compress small: {}",
            a.len()
        );
    }
}
