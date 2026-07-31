//! The bibliography interchange-format grammar table (ADR-0023 D1).
//!
//! [`manuscript_format`] already did this for `.typ`/`.tex`/`.md`/`.txt`: one
//! row per format, in Rust, read by Swift over the FFI. The bibliography half
//! had no such table. Before this file, "which file extensions are a
//! bibliography?" was answered by **twenty-three independent inline literals**
//! across the tree — `["bib", "bibtex", "ris"]` in imbib's sidebar drop
//! handler, `["bib", "bibtex", "ris"]` again in `DragDropCoordinator`,
//! `case "bib", "bibtex":` in four separate import switches, a `.bib`-only
//! open panel here, a `.bib`/`.ris` one there — plus one named-but-unused
//! Swift enum (`BibFileFormat`) that no call site consults.
//!
//! ADR-0023 D1 requires the watchable file types to be *declared, not coded*,
//! and to reference the authority where it already lives rather than restate
//! it. For manuscripts that authority existed. For `.bib`/`.ris` it did not, so
//! this is it: **the** table, next to the manuscript one, in the crate the
//! parsers' callers already depend on.
//!
//! ## Scope
//!
//! Extensions, UTIs and MIME types — the *identification* of a bibliography
//! file. Nothing about its contents: BibTeX parsing is `im_bibtex`, RIS
//! parsing is imbib-core, and neither moves here.
//!
//! ## The UTI column is honest about a real gap
//!
//! `.bib` has an exported UTI (`com.impress.bibtex-entry`, declared by imbib's
//! `project.yml` with `public.filename-extension: [bib]`). **`.ris` has none**,
//! anywhere in the suite — `UTType(filenameExtension: "ris")` resolves to a
//! dynamic `dyn.…` type, which is useless as a Spotlight predicate. So the
//! column is `Option`, and a discovery query built from this table must OR the
//! UTI clause with a filename clause rather than assuming every row has a type
//! to match on. A table that pretended `.ris` had a UTI would produce a
//! Spotlight scope that silently never matches a RIS file — the ADR-0023 D6
//! failure mode, arriving through the front door.
//!
//! [`manuscript_format`]: crate::manuscript_format

/// Everything the suite needs to *identify* one bibliography interchange
/// format on disk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BibliographyFormatGrammar {
    /// Format id, and the value imbib's importers/exporters already use
    /// (`"bibtex"` / `"ris"`).
    pub id: &'static str,
    /// Human-facing name ("BibTeX", not "bibtex").
    pub display_name: &'static str,
    /// Canonical extension used when writing a file of this format.
    pub file_extension: &'static str,
    /// Every extension that identifies this format, canonical one first.
    /// Lowercase; matching lowercases its input.
    pub extensions: &'static [&'static str],
    /// The declared UTI, or `None` when the suite declares none. See the module
    /// note: `None` is a real state, not a placeholder.
    pub uti: Option<&'static str>,
    /// MIME type used by the exporters (`MboxExporter`, `ROCrateExporter`).
    pub mime_type: &'static str,
}

/// One row per bibliography interchange format. **This is the table.**
///
/// Order is BibTeX first because imbib ADR-002 makes BibTeX the source of
/// truth; RIS is the interchange import path.
pub const BIBLIOGRAPHY_FORMAT_GRAMMAR: [BibliographyFormatGrammar; 2] = [
    BibliographyFormatGrammar {
        id: "bibtex",
        display_name: "BibTeX",
        file_extension: "bib",
        // `.bibtex` is accepted on import (every import switch in the tree
        // spells `case "bib", "bibtex":`) but never written.
        extensions: &["bib", "bibtex"],
        uti: Some("com.impress.bibtex-entry"),
        mime_type: "text/x-bibtex",
    },
    BibliographyFormatGrammar {
        id: "ris",
        display_name: "RIS",
        file_extension: "ris",
        extensions: &["ris"],
        // No app declares a UTI for RIS. See the module note.
        uti: None,
        mime_type: "application/x-research-info-systems",
    },
];

/// Format id for a bare file extension (no dot), or `None`.
///
/// Case-insensitive, driven by the table's `extensions` column — the exact
/// shape of [`crate::manuscript_format::manuscript_format_for_extension`].
pub fn bibliography_format_for_extension(ext: &str) -> Option<&'static str> {
    let lowered = ext.to_lowercase();
    BIBLIOGRAPHY_FORMAT_GRAMMAR
        .iter()
        .find(|g| g.extensions.contains(&lowered.as_str()))
        .map(|g| g.id)
}

/// The grammar row for a format id, or `None` if unknown.
pub fn bibliography_format_grammar(id: &str) -> Option<&'static BibliographyFormatGrammar> {
    BIBLIOGRAPHY_FORMAT_GRAMMAR.iter().find(|g| g.id == id)
}

/// Every bibliography extension, table order, canonical-first within a format.
///
/// This is what a `FileDiscoveryCapability` for the publication kind is pinned
/// against (ADR-0023 D1). Returned as a `Vec` rather than a const slice because
/// the flattening is what callers want and a second const would be a second
/// place to forget an extension.
pub fn bibliography_extensions() -> Vec<&'static str> {
    BIBLIOGRAPHY_FORMAT_GRAMMAR
        .iter()
        .flat_map(|g| g.extensions.iter().copied())
        .collect()
}

/// Every DECLARED bibliography UTI, in table order. Formats with no UTI
/// contribute nothing — the list is shorter than the format list on purpose.
pub fn bibliography_utis() -> Vec<&'static str> {
    BIBLIOGRAPHY_FORMAT_GRAMMAR
        .iter()
        .filter_map(|g| g.uti)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_row_is_internally_consistent() {
        for g in BIBLIOGRAPHY_FORMAT_GRAMMAR.iter() {
            assert!(!g.display_name.is_empty(), "{} has no display name", g.id);
            assert!(!g.file_extension.is_empty(), "{} has no extension", g.id);
            assert_eq!(
                g.extensions.first(),
                Some(&g.file_extension),
                "{}: file_extension must lead the extensions list",
                g.id
            );
            for ext in g.extensions {
                assert_eq!(*ext, ext.to_lowercase(), "{}: {ext} is not lowercase", g.id);
                assert!(
                    !ext.starts_with('.'),
                    "{}: extensions are bare, no leading dot",
                    g.id
                );
            }
            assert!(!g.mime_type.is_empty(), "{} has no mime type", g.id);
        }
    }

    #[test]
    fn extensions_are_unambiguous() {
        let mut seen: Vec<&str> = vec![];
        for g in BIBLIOGRAPHY_FORMAT_GRAMMAR.iter() {
            for ext in g.extensions {
                assert!(!seen.contains(ext), "{ext} claimed by two formats");
                seen.push(ext);
            }
        }
    }

    /// The frozen shape. This table is the authority a Swift
    /// `FileDiscoveryCapability` is pinned against, so a change here is a
    /// deliberate change to what the suite watches — and it must fail here
    /// first, loudly, rather than in a Spotlight scope nobody reads.
    #[test]
    fn the_table_is_the_frozen_bibtex_ris_pair() {
        let ids: Vec<&str> = BIBLIOGRAPHY_FORMAT_GRAMMAR.iter().map(|g| g.id).collect();
        assert_eq!(ids, vec!["bibtex", "ris"]);
        assert_eq!(bibliography_extensions(), vec!["bib", "bibtex", "ris"]);
    }

    /// `.ris` has no UTI in the suite and this table says so. If someone adds
    /// one (a `UTExportedTypeDeclarations` entry with
    /// `public.filename-extension: [ris]`), this test is where they find out
    /// the table needs updating too.
    #[test]
    fn only_bibtex_declares_a_uti() {
        assert_eq!(bibliography_utis(), vec!["com.impress.bibtex-entry"]);
        assert_eq!(
            bibliography_format_grammar("ris").unwrap().uti,
            None,
            "no app declares a RIS UTI; a discovery query must fall back to the \
             filename for RIS files"
        );
    }

    #[test]
    fn extension_lookup_is_case_insensitive() {
        assert_eq!(bibliography_format_for_extension("BIB"), Some("bibtex"));
        assert_eq!(bibliography_format_for_extension("bibtex"), Some("bibtex"));
        assert_eq!(bibliography_format_for_extension("Ris"), Some("ris"));
        assert_eq!(bibliography_format_for_extension("md"), None);
        assert_eq!(bibliography_format_for_extension(""), None);
        // Bare extensions only — a caller that passes ".bib" has a bug, and
        // silently accepting it would hide the bug at every other call site.
        assert_eq!(bibliography_format_for_extension(".bib"), None);
    }

    /// The two grammar tables must not both claim an extension: a `.bib` that
    /// also detected as a manuscript would be ingested twice, by two apps,
    /// under two units.
    #[test]
    fn no_extension_is_claimed_by_both_grammar_tables() {
        for ext in bibliography_extensions() {
            assert_eq!(
                crate::manuscript_format::manuscript_format_for_extension(ext),
                None,
                "{ext} is claimed by BOTH the bibliography and manuscript tables"
            );
        }
    }
}
