//! HTML `<meta>` scraping and filename-based artifact typing.
//!
//! Port of the pure-logic half of
//! `PublicationManagerCore/Artifacts/ArtifactMetadataExtractor.swift`:
//! `extractMetaContent(from:property:)`, `extractMetaContent(from:name:)`, and
//! the filename/extension half of `inferArtifactType(from:)`.
//!
//! Lives under `pdf/` rather than a module of its own because that is where the
//! sibling Stage 7 port (`title_quality`) lives and both are wired through the
//! same `pdf/mod.rs`; the code has nothing to do with PDF rendering.
//!
//! **What is NOT here:** `inferArtifactType`'s `UTType.conforms(to:)` tail.
//! `UTType` is the system's declared-type database — third-party apps register
//! types into it at install time, so its answers are a property of the machine,
//! not of the input. Re-deriving it from a hardcoded table in Rust would be a
//! copy that silently drifts from the OS. [`infer_artifact_type_from_filename`]
//! returns `None` for those inputs, meaning "undecided, ask `UTType`", and the
//! parity test asserts the exempted row count exactly so the exemption cannot
//! widen quietly.
//!
//! Pinned by `tests/stage7_pdf_parity.rs` against
//! `test_fixtures/golden/artifact_meta_content.json` and
//! `artifact_infer_type.json`.

use impress_smart_search::foundation::trim_ws_nl;
use regex::Regex;

// ── <meta> content extraction ───────────────────────────────────────────────

/// Swift `extractMetaContent(from:property:)` — reads `<meta property=… content=…>`.
///
/// Tries `property` before `content`, then the reversed attribute order. Two
/// preserved quirks, both load-bearing for the corpus:
///
/// * `[^>]+` is a *negated* class, so it happily matches newlines even though
///   Swift did not pass `.dotMatchesLineSeparators`. A `<meta>` tag split across
///   lines is still found (`og-multiline-tag`), while the class's refusal to
///   cross `>` is what stops the pattern from pairing one tag's `property` with
///   the next tag's `content` (`first-match-wins`, `all-three`).
/// * `content=["']([^"']+)["']` requires at least ONE character, so
///   `content=""` does not match at all and yields `None`, whereas
///   `content="   "` matches and then trims to `Some("")`. Two different
///   answers for two spellings of "no title". Preserved because the caller
///   (`extractFromURL`) assigns `metadata.title = ogTitle` unconditionally on
///   `Some`, so "fixing" it changes which of `<title>` or `og:title` wins for
///   real pages — a product decision, not a conformance one.
pub fn extract_meta_content_property(html: &str, property: &str) -> Option<String> {
    let escaped = regex::escape(property);

    // Swift built these with `NSRegularExpression(options: .caseInsensitive)`;
    // Rust needs the inline `(?i)` flag for the same thing. Case-insensitivity
    // covers the tag name, the attribute names AND the property value, which is
    // why `<META PROPERTY="OG:TITLE" …>` matches (`og-uppercase`).
    let forward = Regex::new(&format!(
        r#"(?i)<meta[^>]+property=["']{escaped}["'][^>]+content=["']([^"']+)["']"#
    ))
    .ok()?;
    if let Some(caps) = forward.captures(html) {
        return Some(trim_ws_nl(caps.get(1)?.as_str()).to_string());
    }

    let reversed = Regex::new(&format!(
        r#"(?i)<meta[^>]+content=["']([^"']+)["'][^>]+property=["']{escaped}["']"#
    ))
    .ok()?;
    let caps = reversed.captures(html)?;
    Some(trim_ws_nl(caps.get(1)?.as_str()).to_string())
}

/// Swift `extractMetaContent(from:name:)` — reads `<meta name=… content=…>`.
///
/// The `name:` overload has only the FORWARD pattern; the `property:` overload
/// has two. So `<meta content="John Roe" name="author">` returns `None` while
/// the same reversal on `og:title` is found (corpus cases
/// `meta-name-author-reversed` vs `og-content-then-property`). Preserved: it is
/// the Swift asymmetry, it costs an author name on some pages, and adding the
/// reversed pattern is a recall change that this corpus cannot adjudicate — it
/// records the absence, not a preference.
pub fn extract_meta_content_name(html: &str, name: &str) -> Option<String> {
    let escaped = regex::escape(name);
    let forward = Regex::new(&format!(
        r#"(?i)<meta[^>]+name=["']{escaped}["'][^>]+content=["']([^"']+)["']"#
    ))
    .ok()?;
    let caps = forward.captures(html)?;
    Some(trim_ws_nl(caps.get(1)?.as_str()).to_string())
}

// ── Artifact typing ─────────────────────────────────────────────────────────

/// The `ArtifactType` taxonomy, mirroring Swift's `enum ArtifactType: String`
/// in `Domain/ResearchArtifact.swift`.
///
/// The raw strings are `schema_ref` values that reach the store, so they are
/// spelled out rather than derived from the variant name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ArtifactType {
    /// Slide decks, talks, lectures.
    Presentation,
    /// Conference posters.
    Poster,
    /// Tabular / binary research data.
    Dataset,
    /// Saved web pages and bookmarks.
    Webpage,
    /// Freeform text notes.
    Note,
    /// Images, video, audio.
    Media,
    /// Source code and notebooks.
    Code,
    /// Anything unclassified.
    General,
}

impl ArtifactType {
    /// The Swift `rawValue`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Presentation => "impress/artifact/presentation",
            Self::Poster => "impress/artifact/poster",
            Self::Dataset => "impress/artifact/dataset",
            Self::Webpage => "impress/artifact/webpage",
            Self::Note => "impress/artifact/note",
            Self::Media => "impress/artifact/media",
            Self::Code => "impress/artifact/code",
            Self::General => "impress/artifact/general",
        }
    }
}

/// Foundation `URL.lastPathComponent`, reduced to what this function needs.
fn last_path_component(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Foundation `URL.pathExtension`.
///
/// Empty when there is no dot, when the dot is the whole leading character
/// (a dotfile has no extension), or when nothing follows the dot. Takes the
/// LAST dot, so `weird.name.with.dots.pdf` has extension `pdf`.
fn path_extension(path: &str) -> &str {
    let name = last_path_component(path);
    match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() && !ext.is_empty() => ext,
        _ => "",
    }
}

/// The pure half of Swift `inferArtifactType(from url: URL)`.
///
/// `Some(t)` means the filename hints or the extension table decided it.
/// `None` means Swift would have fallen through to `UTType.conforms(to:)` —
/// the platform half — and the caller must ask the system. `None` is NOT
/// `General`: Swift's `.general` is the *last* line of that platform block, and
/// collapsing the two would classify every image as `General`.
///
/// The filename hints run FIRST and win over the extension table, which is why
/// `slide-data.csv` is a presentation and not a dataset, `poster.csv` is a
/// poster, `readme.py` is a dataset and not code, and `README.md` is a dataset
/// and not a note. Preserved: the hints exist precisely because researchers
/// name a slide deck `slides.pdf` and the extension cannot tell.
pub fn infer_artifact_type_from_filename(path: &str) -> Option<ArtifactType> {
    let lowercase_name = last_path_component(path).to_lowercase();

    if lowercase_name.contains("slide")
        || lowercase_name.contains("talk")
        || lowercase_name.contains("presentation")
        || lowercase_name.contains("lecture")
    {
        return Some(ArtifactType::Presentation);
    }
    if lowercase_name.contains("poster") {
        return Some(ArtifactType::Poster);
    }
    if lowercase_name.contains("readme")
        || lowercase_name.contains("codebook")
        || lowercase_name.contains("dataset")
    {
        return Some(ArtifactType::Dataset);
    }

    match path_extension(path).to_lowercase().as_str() {
        "pptx" | "ppt" | "key" | "odp" => Some(ArtifactType::Presentation),
        "csv" | "tsv" | "parquet" | "hdf5" | "h5" | "fits" | "nc" | "netcdf" => {
            Some(ArtifactType::Dataset)
        }
        // `m` is MATLAB here, not Objective-C; `ts` is TypeScript, not MPEG-TS.
        // Swift's table made those calls and the store rows depend on them.
        "py" | "r" | "jl" | "m" | "sh" | "swift" | "rs" | "c" | "cpp" | "java" | "js" | "ts" => {
            Some(ArtifactType::Code)
        }
        "ipynb" => Some(ArtifactType::Code),
        "html" | "htm" | "mhtml" | "webloc" => Some(ArtifactType::Webpage),
        "md" | "txt" | "rtf" => Some(ArtifactType::Note),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filename_hints_outrank_the_extension_table() {
        assert_eq!(
            infer_artifact_type_from_filename("slide-data.csv"),
            Some(ArtifactType::Presentation)
        );
        assert_eq!(
            infer_artifact_type_from_filename("data.csv"),
            Some(ArtifactType::Dataset)
        );
    }

    #[test]
    fn undecided_is_none_not_general() {
        // `.png` reaches Swift's `UTType.conforms(to: .image)` branch. Answering
        // `General` here would mis-type every figure a researcher drops in.
        assert_eq!(infer_artifact_type_from_filename("figure.png"), None);
        assert_eq!(infer_artifact_type_from_filename("noextension"), None);
    }

    #[test]
    fn path_extension_matches_foundation() {
        assert_eq!(path_extension("weird.name.with.dots.pdf"), "pdf");
        assert_eq!(path_extension("noextension"), "");
        assert_eq!(path_extension(".hidden"), "");
        assert_eq!(path_extension("trailing."), "");
        assert_eq!(path_extension("/tmp/a/b/UPPER.PDF"), "PDF");
    }

    #[test]
    fn empty_and_whitespace_content_are_different_answers() {
        assert_eq!(
            extract_meta_content_property(r#"<meta property="og:title" content="">"#, "og:title"),
            None
        );
        assert_eq!(
            extract_meta_content_property(
                r#"<meta property="og:title" content="   ">"#,
                "og:title"
            ),
            Some(String::new())
        );
    }

    #[test]
    fn property_name_is_regex_escaped() {
        // A caller-supplied property with regex metacharacters must be matched
        // literally, as `NSRegularExpression.escapedPattern(for:)` did.
        assert_eq!(
            extract_meta_content_property(r#"<meta property="a.b" content="X">"#, "a?b"),
            None
        );
        assert_eq!(
            extract_meta_content_property(r#"<meta property="a.b" content="X">"#, "a.b"),
            Some("X".to_string())
        );
    }
}
