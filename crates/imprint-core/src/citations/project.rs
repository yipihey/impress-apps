//! Bibliography projection primitives.
//!
//! Ported from `apps/imprint/macOS/Services/BibliographyProjector.swift`.
//!
//! The Swift `BibliographyProjector` actor walks the manuscript's cite keys,
//! resolves each one against the local store (via
//! `ImprintPublicationService.findByCiteKey`), reads any existing entries
//! out of the destination `.bib` file, and writes back a merged file with
//! resolved entries on top and "preserved" entries (those not in the local
//! store) below.
//!
//! In Rust we split that into two concerns:
//!
//! 1. **Pure projection** (this module): given the set of cite keys and a
//!    function from key → resolved entry, compute the filtered/sorted/grouped
//!    list of `ProjectedEntry` values that should appear in the projection.
//!    No I/O. Trivially testable.
//! 2. **I/O orchestration** (Swift-side `BibliographyProjector` retained, or
//!    a future `imprint-service` actor): pass the projection into the file
//!    writer and merge with existing `.bib` content.
//!
//! Splitting this way means a TUI, MCP tool, or CLI can compute the projection
//! without touching the filesystem.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// A single resolved bibliography entry. Mirrors the data the Swift code
/// emits to disk: cite key + BibTeX source + optional metadata for sort
/// keys.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectedEntry {
    pub cite_key: String,
    pub bibtex: String,
    /// First-author surname for "by-author" sort.
    pub first_author: Option<String>,
    /// Publication year for "by-year" sort.
    pub year: Option<i32>,
    /// "Found in local library", "preserved from existing .bib", "synthesized",
    /// etc. — purely informational, used by [`BibliographyProjection::group_by_status`].
    pub status: EntryStatus,
}

/// Whence does a given projected entry come?
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum EntryStatus {
    /// Resolved from the local imprint/imbib store.
    Local,
    /// Synthesized from minimal row metadata because the local store had no
    /// `rawBibtex` (the Swift code does this in `synthesizeBibTeX`).
    Synthesized,
    /// Carried over from a pre-existing `.bib` file because it wasn't in
    /// the manuscript's cite-key set but was present on disk (the Swift
    /// "preserved entries" pass).
    Preserved,
    /// Cite key was referenced in the manuscript but no resolved entry was
    /// found anywhere. Reported so the caller can prompt the user / try a
    /// remote resolver.
    Missing,
}

/// Sort order options for projections.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SortOrder {
    /// Alphabetical by cite key.
    ByCiteKey,
    /// By first-author surname; ties broken by year, then key.
    ByAuthor,
    /// By publication year (ascending); ties broken by author then key.
    ByYear,
    /// Use the caller-provided order (input order preserved verbatim).
    AsProvided,
}

/// A bibliography projection — a filtered, sorted, and grouped view over a
/// set of cite keys + resolution function.
#[derive(Debug, Clone)]
pub struct BibliographyProjection {
    entries: Vec<ProjectedEntry>,
    missing: Vec<String>,
}

impl BibliographyProjection {
    /// Build a projection from the manuscript cite keys and the existing
    /// pre-loaded `.bib` entries. `resolver` is a callback that the caller
    /// uses to look up entries in their local store. Anything the resolver
    /// returns `None` for falls through to `preserved_keys` and finally to
    /// the missing-list.
    pub fn build<R>(cite_keys: &[String], preserved: &[ProjectedEntry], mut resolver: R) -> Self
    where
        R: FnMut(&str) -> Option<ProjectedEntry>,
    {
        let mut entries: Vec<ProjectedEntry> = Vec::with_capacity(cite_keys.len());
        let mut missing: Vec<String> = Vec::new();

        // Build a fast lookup of preserved entries by key.
        let preserved_by_key: BTreeMap<&str, &ProjectedEntry> =
            preserved.iter().map(|e| (e.cite_key.as_str(), e)).collect();

        for key in cite_keys {
            if let Some(mut entry) = resolver(key) {
                // Trust the resolver's status assignment (it can pick
                // Synthesized vs. Local) — but if it left it at default
                // None-ish, we don't second-guess.
                if entry.cite_key.is_empty() {
                    entry.cite_key = key.clone();
                }
                entries.push(entry);
            } else if let Some(p) = preserved_by_key.get(key.as_str()) {
                // We still treat this as "preserved" because we couldn't
                // resolve it locally.
                let mut clone = (*p).clone();
                clone.status = EntryStatus::Preserved;
                entries.push(clone);
            } else {
                missing.push(key.clone());
            }
        }

        // Append any preserved entries that the manuscript no longer cites.
        // These match the Swift "preserved entries (not in imbib)" tail.
        let cited_set: std::collections::BTreeSet<&str> =
            cite_keys.iter().map(|s| s.as_str()).collect();
        for entry in preserved {
            if !cited_set.contains(entry.cite_key.as_str()) {
                let mut clone = entry.clone();
                clone.status = EntryStatus::Preserved;
                entries.push(clone);
            }
        }

        Self { entries, missing }
    }

    /// All projected entries in their current order.
    pub fn entries(&self) -> &[ProjectedEntry] {
        &self.entries
    }

    /// Cite keys the manuscript references but neither the resolver nor the
    /// preserved set could supply.
    pub fn missing(&self) -> &[String] {
        &self.missing
    }

    /// Apply a filter predicate to the entries.
    pub fn filter<P>(mut self, mut pred: P) -> Self
    where
        P: FnMut(&ProjectedEntry) -> bool,
    {
        self.entries.retain(|e| pred(e));
        self
    }

    /// Sort entries by the chosen order.
    pub fn sorted(mut self, order: SortOrder) -> Self {
        match order {
            SortOrder::AsProvided => {}
            SortOrder::ByCiteKey => {
                self.entries.sort_by(|a, b| a.cite_key.cmp(&b.cite_key));
            }
            SortOrder::ByAuthor => {
                self.entries.sort_by(|a, b| {
                    let aa = a.first_author.as_deref().unwrap_or("");
                    let bb = b.first_author.as_deref().unwrap_or("");
                    aa.cmp(bb)
                        .then(a.year.unwrap_or(0).cmp(&b.year.unwrap_or(0)))
                        .then(a.cite_key.cmp(&b.cite_key))
                });
            }
            SortOrder::ByYear => {
                self.entries.sort_by(|a, b| {
                    a.year
                        .unwrap_or(0)
                        .cmp(&b.year.unwrap_or(0))
                        .then_with(|| {
                            let aa = a.first_author.as_deref().unwrap_or("");
                            let bb = b.first_author.as_deref().unwrap_or("");
                            aa.cmp(bb)
                        })
                        .then(a.cite_key.cmp(&b.cite_key))
                });
            }
        }
        self
    }

    /// Group entries by their [`EntryStatus`], preserving relative order
    /// within each group. Returns a `BTreeMap` so the keys are deterministic.
    pub fn group_by_status(&self) -> BTreeMap<EntryStatus, Vec<&ProjectedEntry>> {
        let mut out: BTreeMap<EntryStatus, Vec<&ProjectedEntry>> = BTreeMap::new();
        for entry in &self.entries {
            out.entry(entry.status).or_default().push(entry);
        }
        out
    }

    /// Convenience: emit the projection as the Swift `BibliographyProjector`
    /// would write to a `.bib` file (resolved entries first, preserved
    /// entries below, with comment headers). The output format intentionally
    /// matches the Swift implementation's structure so a golden test can
    /// compare byte-for-byte (up to the ISO timestamp).
    pub fn to_bib_file(&self, header_note: &str) -> String {
        let mut s = String::new();
        s.push_str("% Generated by imprint BibliographyProjector\n");
        if !header_note.is_empty() {
            s.push_str("% ");
            s.push_str(header_note);
            s.push('\n');
        }
        s.push_str(&format!(
            "% Cite keys extracted from manuscript: {} entries\n",
            self.entries.len()
        ));
        if !self.missing.is_empty() {
            s.push_str(&format!(
                "% Missing from local store: {}\n",
                self.missing.join(", ")
            ));
        }
        s.push('\n');

        let mut local_or_synth: Vec<&ProjectedEntry> = Vec::new();
        let mut preserved: Vec<&ProjectedEntry> = Vec::new();
        for e in &self.entries {
            match e.status {
                EntryStatus::Preserved => preserved.push(e),
                _ => local_or_synth.push(e),
            }
        }

        for e in &local_or_synth {
            s.push_str(&format!("% {}\n", e.cite_key));
            s.push_str(e.bibtex.trim());
            s.push_str("\n\n");
        }

        if !preserved.is_empty() {
            s.push_str("% === Preserved entries (not in local store) ===\n\n");
            for e in &preserved {
                s.push_str(&format!("% {}\n", e.cite_key));
                s.push_str(e.bibtex.trim());
                s.push_str("\n\n");
            }
        }

        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(key: &str, year: i32, author: &str, status: EntryStatus) -> ProjectedEntry {
        ProjectedEntry {
            cite_key: key.to_string(),
            bibtex: format!("@article{{{},\n  year={{{}}}\n}}", key, year),
            first_author: Some(author.to_string()),
            year: Some(year),
            status,
        }
    }

    #[test]
    fn build_resolves_all_keys() {
        let keys = vec!["a".to_string(), "b".to_string()];
        let proj = BibliographyProjection::build(&keys, &[], |k| {
            Some(entry(k, 2020, "Smith", EntryStatus::Local))
        });
        assert_eq!(proj.entries().len(), 2);
        assert!(proj.missing().is_empty());
    }

    #[test]
    fn build_records_missing_keys() {
        let keys = vec!["a".to_string(), "b".to_string()];
        let proj = BibliographyProjection::build(&keys, &[], |k| {
            if k == "a" {
                Some(entry(k, 2020, "Smith", EntryStatus::Local))
            } else {
                None
            }
        });
        assert_eq!(proj.entries().len(), 1);
        assert_eq!(proj.missing(), &["b".to_string()]);
    }

    #[test]
    fn build_falls_back_to_preserved() {
        let keys = vec!["x".to_string()];
        let preserved = vec![entry("x", 1999, "Doe", EntryStatus::Local)];
        let proj = BibliographyProjection::build(&keys, &preserved, |_| None);
        assert_eq!(proj.entries().len(), 1);
        assert_eq!(proj.entries()[0].status, EntryStatus::Preserved);
        assert!(proj.missing().is_empty());
    }

    #[test]
    fn build_appends_uncited_preserved_entries() {
        let keys = vec!["a".to_string()];
        let preserved = vec![
            entry("a", 2000, "Aa", EntryStatus::Local),
            entry("b", 2001, "Bb", EntryStatus::Local), // not cited
        ];
        let proj = BibliographyProjection::build(&keys, &preserved, |k| {
            Some(entry(k, 2020, "Resolver", EntryStatus::Local))
        });
        // Entry "a" came from resolver; entry "b" tagged Preserved.
        assert_eq!(proj.entries().len(), 2);
        assert_eq!(proj.entries()[0].cite_key, "a");
        assert_eq!(proj.entries()[0].status, EntryStatus::Local);
        assert_eq!(proj.entries()[1].cite_key, "b");
        assert_eq!(proj.entries()[1].status, EntryStatus::Preserved);
    }

    #[test]
    fn filter_removes_unwanted_entries() {
        let keys: Vec<String> = vec!["a", "b", "c"].into_iter().map(String::from).collect();
        let proj = BibliographyProjection::build(&keys, &[], |k| {
            Some(entry(k, 2020, "Smith", EntryStatus::Local))
        })
        .filter(|e| e.cite_key != "b");
        let got: Vec<&str> = proj.entries().iter().map(|e| e.cite_key.as_str()).collect();
        assert_eq!(got, vec!["a", "c"]);
    }

    #[test]
    fn sorted_by_cite_key() {
        let keys: Vec<String> = vec!["c", "a", "b"].into_iter().map(String::from).collect();
        let proj = BibliographyProjection::build(&keys, &[], |k| {
            Some(entry(k, 2020, "Smith", EntryStatus::Local))
        })
        .sorted(SortOrder::ByCiteKey);
        let got: Vec<&str> = proj.entries().iter().map(|e| e.cite_key.as_str()).collect();
        assert_eq!(got, vec!["a", "b", "c"]);
    }

    #[test]
    fn sorted_by_year() {
        let mut entries = vec![
            entry("a", 2010, "Zzz", EntryStatus::Local),
            entry("b", 2005, "Aaa", EntryStatus::Local),
            entry("c", 2020, "Mmm", EntryStatus::Local),
        ];
        let proj = BibliographyProjection {
            entries: std::mem::take(&mut entries),
            missing: vec![],
        }
        .sorted(SortOrder::ByYear);
        let years: Vec<i32> = proj.entries().iter().map(|e| e.year.unwrap()).collect();
        assert_eq!(years, vec![2005, 2010, 2020]);
    }

    #[test]
    fn sorted_by_author_ties_break_on_year() {
        let entries = vec![
            entry("a", 2010, "Smith", EntryStatus::Local),
            entry("b", 2005, "Smith", EntryStatus::Local),
            entry("c", 2020, "Adams", EntryStatus::Local),
        ];
        let proj = BibliographyProjection {
            entries,
            missing: vec![],
        }
        .sorted(SortOrder::ByAuthor);
        let keys: Vec<&str> = proj.entries().iter().map(|e| e.cite_key.as_str()).collect();
        assert_eq!(keys, vec!["c", "b", "a"]);
    }

    #[test]
    fn group_by_status() {
        let proj = BibliographyProjection {
            entries: vec![
                entry("a", 2010, "Smith", EntryStatus::Local),
                entry("b", 2005, "Smith", EntryStatus::Preserved),
                entry("c", 2020, "Adams", EntryStatus::Synthesized),
                entry("d", 2021, "Adams", EntryStatus::Local),
            ],
            missing: vec![],
        };
        let groups = proj.group_by_status();
        assert_eq!(groups.get(&EntryStatus::Local).unwrap().len(), 2);
        assert_eq!(groups.get(&EntryStatus::Preserved).unwrap().len(), 1);
        assert_eq!(groups.get(&EntryStatus::Synthesized).unwrap().len(), 1);
    }

    #[test]
    fn to_bib_file_contains_resolved_and_preserved_sections() {
        let proj = BibliographyProjection {
            entries: vec![
                entry("a", 2010, "Smith", EntryStatus::Local),
                entry("b", 2005, "Doe", EntryStatus::Preserved),
            ],
            missing: vec!["c".to_string()],
        };
        let out = proj.to_bib_file("");
        assert!(out.contains("% a"));
        assert!(out.contains("% b"));
        assert!(out.contains("Preserved entries"));
        assert!(out.contains("Missing from local store: c"));
    }

    #[test]
    fn to_bib_file_omits_preserved_section_when_none() {
        let proj = BibliographyProjection {
            entries: vec![entry("a", 2010, "Smith", EntryStatus::Local)],
            missing: vec![],
        };
        let out = proj.to_bib_file("");
        assert!(!out.contains("Preserved entries"));
    }
}
