//! Manuscript bundle manifest — the JSON sidecar that describes a manuscript
//! stored as a directory tree (`.tar.zst` archive) rather than a single file.
//!
//! Design comes from the Phase 8 plan in `docs/plan-journal-pipeline.md`.
//! The manifest lives at `manifest.json` in the bundle root AND is mirrored
//! into the `bundle_manifest_json` field of `manuscript-submission@1.0.0` and
//! `manuscript-revision@1.0.0` payloads, so the UI/exporters can list a
//! manuscript's files without unpacking the archive.
//!
//! Roles are advisory (for UI/exporters), not authoritative for compile.
//! Compile dispatch keys off `source_format` + `compile.engine`.

use serde::{Deserialize, Serialize};

/// Canonical schema identifier. Embedded in every manifest so future
/// versions can be detected and migrated.
pub const BUNDLE_MANIFEST_SCHEMA: &str = "manuscript-bundle-manifest@1.0.0";

/// Per-entry role classification. Advisory — UI/exporters use this to
/// display icons and group files. The compile pipeline ignores it and
/// dispatches purely from `source_format` + `compile.engine` + `main_source`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BundleEntryRole {
    /// The main source file (one per bundle); matches `main_source`.
    Main,
    /// `.bib`/`.bbl`/`.json` reference databases.
    Bibliography,
    /// Image or graphic referenced by the manuscript.
    Figure,
    /// Supplementary material (appendices, supporting info).
    Supplement,
    /// Sub-document (chapter included via `\input` / `#include`).
    Chapter,
    /// Auxiliary file (`.cls`, `.sty`, fonts, build configuration).
    Aux,
}

impl BundleEntryRole {
    pub fn as_str(self) -> &'static str {
        match self {
            BundleEntryRole::Main => "main",
            BundleEntryRole::Bibliography => "bibliography",
            BundleEntryRole::Figure => "figure",
            BundleEntryRole::Supplement => "supplement",
            BundleEntryRole::Chapter => "chapter",
            BundleEntryRole::Aux => "aux",
        }
    }
}

/// Source format of the main entry. Compile engines map to formats:
/// `typst` → typst engine, `tex` → tectonic, `markdown` and `html` are
/// stored without compile in v1 (per Phase 8 scope).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BundleSourceFormat {
    Tex,
    Typst,
    Markdown,
    Html,
}

impl BundleSourceFormat {
    pub fn as_str(self) -> &'static str {
        match self {
            BundleSourceFormat::Tex => "tex",
            BundleSourceFormat::Typst => "typst",
            BundleSourceFormat::Markdown => "markdown",
            BundleSourceFormat::Html => "html",
        }
    }
}

/// The compile engine to use, if any. `None` → store-only (no compile).
///
/// LaTeX engine names mirror imprint's existing
/// `LaTeXCompilationService.LaTeXEngine` (in
/// `apps/imprint/macOS/Services/LaTeXCompilationService.swift`) so the
/// bundle compile route dispatches directly to that service without
/// translation. Compilation is owned by imprint; this enum names the
/// engine but does not implement it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BundleCompileEngine {
    /// Typst via the imprint-core renderer.
    Typst,
    /// pdfLaTeX (the default LaTeX engine).
    Pdflatex,
    /// XeLaTeX (handles Unicode + system fonts well).
    Xelatex,
    /// LuaLaTeX (Lua-extensible engine).
    Lualatex,
    /// latexmk (build-tool that orchestrates engines and biber).
    Latexmk,
    /// Stored only; no compile attempted (markdown / html / unsupported).
    None,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BundleEntry {
    /// Path relative to the bundle root (POSIX, forward-slash).
    pub path: String,
    /// Role classification (advisory).
    pub role: BundleEntryRole,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BundleCompileSpec {
    pub engine: BundleCompileEngine,
    /// Engine-specific extra args. Pass-through; the compile dispatcher is
    /// responsible for sanitising. May be empty.
    #[serde(default)]
    pub extra_args: Vec<String>,
}

/// The manifest itself. Round-trip serialisable with `serde_json`. Field
/// order is fixed so deterministic packing produces identical bytes for
/// identical inputs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BundleManifest {
    /// Always `BUNDLE_MANIFEST_SCHEMA`.
    pub schema: String,
    /// Relative path of the main source file inside the archive.
    pub main_source: String,
    pub source_format: BundleSourceFormat,
    /// All files included in the bundle, sorted by `path` for determinism.
    pub entries: Vec<BundleEntry>,
    pub compile: BundleCompileSpec,
    /// Globs that were excluded during packing (e.g. `*.aux`, `*.log`).
    /// Stored for audit / re-packing reproducibility.
    #[serde(default)]
    pub exclude_globs: Vec<String>,
}

/// Errors a manifest can fail validation with. Surfaced at submission time
/// so malformed bundles never reach the snapshot stage.
#[derive(Debug, thiserror::Error)]
pub enum BundleManifestError {
    #[error("manifest JSON parse failed: {0}")]
    ParseError(#[from] serde_json::Error),
    #[error(
        "manifest schema mismatch: expected {expected}, got {actual}"
    )]
    SchemaMismatch { expected: String, actual: String },
    #[error("manifest main_source must be non-empty")]
    EmptyMainSource,
    #[error(
        "manifest main_source {path:?} not present in entries list"
    )]
    MainSourceNotInEntries { path: String },
    #[error("manifest entries list must be non-empty")]
    EmptyEntries,
    #[error("manifest entry path {path:?} contains absolute or parent component")]
    UnsafePath { path: String },
}

impl BundleManifest {
    /// Parse + validate a manifest from JSON bytes.
    pub fn parse(json: &str) -> Result<Self, BundleManifestError> {
        let manifest: BundleManifest = serde_json::from_str(json)?;
        manifest.validate()?;
        Ok(manifest)
    }

    /// Structural validation — independent of any archive contents.
    /// Verifies schema string, non-empty main_source, main_source is in
    /// entries, and no entry path escapes via `..` or starts with `/`.
    pub fn validate(&self) -> Result<(), BundleManifestError> {
        if self.schema != BUNDLE_MANIFEST_SCHEMA {
            return Err(BundleManifestError::SchemaMismatch {
                expected: BUNDLE_MANIFEST_SCHEMA.to_string(),
                actual: self.schema.clone(),
            });
        }
        if self.main_source.is_empty() {
            return Err(BundleManifestError::EmptyMainSource);
        }
        if self.entries.is_empty() {
            return Err(BundleManifestError::EmptyEntries);
        }
        let main = &self.main_source;
        if !self.entries.iter().any(|e| &e.path == main) {
            return Err(BundleManifestError::MainSourceNotInEntries {
                path: main.clone(),
            });
        }
        for entry in &self.entries {
            if entry.path.starts_with('/') || entry.path.contains("..") {
                return Err(BundleManifestError::UnsafePath {
                    path: entry.path.clone(),
                });
            }
        }
        Ok(())
    }

    /// Serialise to canonical JSON: sorted entries, fixed key order via
    /// the struct field order, no trailing whitespace. Used by the bundle
    /// builder so identical inputs produce identical archive bytes.
    pub fn to_canonical_json(&self) -> Result<String, serde_json::Error> {
        let mut canonical = self.clone();
        canonical.entries.sort_by(|a, b| a.path.cmp(&b.path));
        canonical.exclude_globs.sort();
        serde_json::to_string_pretty(&canonical)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_manifest() -> BundleManifest {
        BundleManifest {
            schema: BUNDLE_MANIFEST_SCHEMA.to_string(),
            main_source: "paper.tex".to_string(),
            source_format: BundleSourceFormat::Tex,
            entries: vec![
                BundleEntry {
                    path: "paper.tex".to_string(),
                    role: BundleEntryRole::Main,
                },
                BundleEntry {
                    path: "references.bib".to_string(),
                    role: BundleEntryRole::Bibliography,
                },
                BundleEntry {
                    path: "figures/fig1.pdf".to_string(),
                    role: BundleEntryRole::Figure,
                },
            ],
            compile: BundleCompileSpec {
                engine: BundleCompileEngine::Pdflatex,
                extra_args: vec![],
            },
            exclude_globs: vec!["*.aux".to_string(), "*.log".to_string()],
        }
    }

    #[test]
    fn round_trip_preserves_structure() {
        let m = sample_manifest();
        let json = serde_json::to_string(&m).unwrap();
        let back: BundleManifest = serde_json::from_str(&json).unwrap();
        assert_eq!(m, back);
    }

    #[test]
    fn validate_accepts_well_formed() {
        let m = sample_manifest();
        m.validate().unwrap();
    }

    #[test]
    fn validate_rejects_schema_mismatch() {
        let mut m = sample_manifest();
        m.schema = "manuscript-bundle-manifest@2.0.0".to_string();
        let err = m.validate().unwrap_err();
        matches!(err, BundleManifestError::SchemaMismatch { .. });
    }

    #[test]
    fn validate_rejects_empty_main_source() {
        let mut m = sample_manifest();
        m.main_source.clear();
        let err = m.validate().unwrap_err();
        matches!(err, BundleManifestError::EmptyMainSource);
    }

    #[test]
    fn validate_rejects_main_not_in_entries() {
        let mut m = sample_manifest();
        m.main_source = "missing.tex".to_string();
        let err = m.validate().unwrap_err();
        matches!(err, BundleManifestError::MainSourceNotInEntries { .. });
    }

    #[test]
    fn validate_rejects_absolute_path() {
        let mut m = sample_manifest();
        m.entries.push(BundleEntry {
            path: "/etc/passwd".to_string(),
            role: BundleEntryRole::Aux,
        });
        let err = m.validate().unwrap_err();
        matches!(err, BundleManifestError::UnsafePath { .. });
    }

    #[test]
    fn validate_rejects_parent_traversal() {
        let mut m = sample_manifest();
        m.entries.push(BundleEntry {
            path: "../escape.tex".to_string(),
            role: BundleEntryRole::Aux,
        });
        let err = m.validate().unwrap_err();
        matches!(err, BundleManifestError::UnsafePath { .. });
    }

    #[test]
    fn validate_rejects_empty_entries() {
        let mut m = sample_manifest();
        m.entries.clear();
        let err = m.validate().unwrap_err();
        matches!(err, BundleManifestError::EmptyEntries);
    }

    #[test]
    fn parse_validates() {
        let m = sample_manifest();
        let json = serde_json::to_string(&m).unwrap();
        let parsed = BundleManifest::parse(&json).unwrap();
        assert_eq!(parsed, m);
    }

    #[test]
    fn parse_rejects_malformed_json() {
        let err = BundleManifest::parse("{not json").unwrap_err();
        matches!(err, BundleManifestError::ParseError(_));
    }

    #[test]
    fn canonical_json_sorts_entries() {
        let mut m = sample_manifest();
        m.entries.reverse();
        let json = m.to_canonical_json().unwrap();
        let back: BundleManifest = serde_json::from_str(&json).unwrap();
        let paths: Vec<&str> = back.entries.iter().map(|e| e.path.as_str()).collect();
        assert_eq!(paths, ["figures/fig1.pdf", "paper.tex", "references.bib"]);
    }

    #[test]
    fn canonical_json_is_deterministic() {
        let m = sample_manifest();
        let a = m.to_canonical_json().unwrap();
        let b = m.to_canonical_json().unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn role_serialization_is_lowercase() {
        let entry = BundleEntry {
            path: "x.tex".to_string(),
            role: BundleEntryRole::Bibliography,
        };
        let s = serde_json::to_string(&entry).unwrap();
        assert!(s.contains("\"bibliography\""));
    }

    #[test]
    fn engine_serialization_is_lowercase() {
        let spec = BundleCompileSpec {
            engine: BundleCompileEngine::Pdflatex,
            extra_args: vec![],
        };
        let s = serde_json::to_string(&spec).unwrap();
        assert!(s.contains("\"pdflatex\""));
    }
}
