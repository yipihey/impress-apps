//! Bibliographies are files; projected ones carry their query (ADR-0030 D7).
//!
//! A `bibliography` row either holds literal BibTeX or a [`BibSource`] —
//! `cited` (every key the tree cites), an imbib collection or library, or an
//! explicit key list. Projection happens here, at compile/materialise time,
//! through the [`BibliographyResolver`] port: the engine never learns imbib's
//! store, and the service implements the port over whatever store it has.
//!
//! The port hands back **raw BibTeX per key** when the library holds it and
//! **fields** when it holds only metadata; [`synthesize_entry`] turns fields
//! into an entry so a compile never fails for want of `raw_bibtex` — the
//! synthesized entry is flagged in the report, as `citations::project`'s
//! `EntryStatus::Synthesized` always was.

use std::collections::{BTreeMap, BTreeSet};

use impress_bibtex::{format_entries, BibTeXEntry, BibTeXEntryType};

use super::graph::BuildGraph;
use super::model::{BibSource, FileRole, ProjectFile, ProjectTree};
use super::scan::{scan, DepKind};

/// The one-file convention, carried into the tree: a Typst (or Markdown)
/// manuscript that cites `@keys` without a `.bib` of its own gets a virtual
/// `bibliography.bib` projected from the library — the app has served that
/// file since the citation seam shipped, so a tree must see it too.
pub const IMPLICIT_BIBLIOGRAPHY: &str = "bibliography.bib";

/// The implicit `bibliography.bib` row (a `cited` projection) when the tree
/// needs one: no file at that path, and either something references it or
/// the tree cites keys without naming any bibliography at all. `None` for
/// LaTeX trees (BibTeX needs a real file the engine can read by name) and
/// for trees that already carry their bibliography.
pub fn implicit_bibliography(tree: &ProjectTree) -> Option<ProjectFile> {
    if tree.format == "latex" || tree.contains(IMPLICIT_BIBLIOGRAPHY) {
        return None;
    }
    let deps = scan(tree);
    let references_implicit = deps
        .unresolved
        .iter()
        .any(|u| u.kind == DepKind::Bibliography && u.reference == IMPLICIT_BIBLIOGRAPHY);
    let names_any_bibliography = deps.edges.iter().any(|e| e.kind == DepKind::Bibliography)
        || deps
            .unresolved
            .iter()
            .any(|u| u.kind == DepKind::Bibliography);
    if references_implicit || (!deps.cite_keys.is_empty() && !names_any_bibliography) {
        Some(
            ProjectFile::text(IMPLICIT_BIBLIOGRAPHY, FileRole::Bibliography, "")
                .with_bib_source(BibSource::Cited),
        )
    } else {
        None
    }
}

/// What the resolver knows about one key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolvedEntry {
    /// The library's own BibTeX for the key — used verbatim.
    Raw(String),
    /// Only metadata: `entry_type`, `title`, `authors`, `year`, `journal`,
    /// `doi`, `url`, … as `(field, value)` pairs. Synthesized into an entry.
    Fields {
        entry_type: String,
        fields: BTreeMap<String, String>,
    },
}

/// The port the service implements over its store (imbib's rows), the
/// tests implement over a map, and the CLI implements over the shared
/// store. Every method is total: an unknown key is `None`, never an error
/// — a missing reference is a warning in the build, not a failed build.
pub trait BibliographyResolver {
    /// One key.
    fn entry_for_key(&self, key: &str) -> Option<ResolvedEntry>;

    /// Every key in a collection (for `BibSource::Collection`).
    fn keys_in_collection(&self, library_id: &str, collection_id: &str) -> Vec<String> {
        let _ = (library_id, collection_id);
        Vec::new()
    }

    /// Every key in a library (for `BibSource::Library`).
    fn keys_in_library(&self, library_id: &str) -> Vec<String> {
        let _ = library_id;
        Vec::new()
    }
}

/// A resolver over a map — the tests' and the selftest's.
#[derive(Debug, Clone, Default)]
pub struct MapResolver {
    pub entries: BTreeMap<String, ResolvedEntry>,
    pub collections: BTreeMap<(String, String), Vec<String>>,
    pub libraries: BTreeMap<String, Vec<String>>,
}

impl MapResolver {
    pub fn with_raw(mut self, key: &str, bibtex: &str) -> Self {
        self.entries
            .insert(key.into(), ResolvedEntry::Raw(bibtex.into()));
        self
    }

    pub fn with_fields(mut self, key: &str, entry_type: &str, fields: &[(&str, &str)]) -> Self {
        self.entries.insert(
            key.into(),
            ResolvedEntry::Fields {
                entry_type: entry_type.into(),
                fields: fields
                    .iter()
                    .map(|(k, v)| (k.to_string(), v.to_string()))
                    .collect(),
            },
        );
        self
    }
}

impl BibliographyResolver for MapResolver {
    fn entry_for_key(&self, key: &str) -> Option<ResolvedEntry> {
        self.entries.get(key).cloned()
    }

    fn keys_in_collection(&self, library_id: &str, collection_id: &str) -> Vec<String> {
        self.collections
            .get(&(library_id.to_string(), collection_id.to_string()))
            .cloned()
            .unwrap_or_default()
    }

    fn keys_in_library(&self, library_id: &str) -> Vec<String> {
        self.libraries.get(library_id).cloned().unwrap_or_default()
    }
}

/// A resolver that knows nothing — projections come back empty with every
/// key reported missing. What a compile uses when no store is at hand.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoResolver;

impl BibliographyResolver for NoResolver {
    fn entry_for_key(&self, _key: &str) -> Option<ResolvedEntry> {
        None
    }
}

/// A BibTeX entry from metadata fields, formatted by the shared formatter
/// so it round-trips through the same parser imbib uses.
pub fn synthesize_entry(key: &str, entry_type: &str, fields: &BTreeMap<String, String>) -> String {
    let mut entry = BibTeXEntry::new(key.to_string(), BibTeXEntryType::from_str(entry_type));
    // A stable, conventional field order; everything else after, sorted.
    const ORDER: &[&str] = &[
        "author",
        "title",
        "journal",
        "booktitle",
        "year",
        "volume",
        "number",
        "pages",
        "publisher",
        "doi",
        "eprint",
        "archiveprefix",
        "primaryclass",
        "url",
        "note",
    ];
    let mut done: BTreeSet<&str> = BTreeSet::new();
    for name in ORDER {
        if let Some(v) = fields.get(*name) {
            if !v.trim().is_empty() {
                entry.add_field(*name, v.trim());
                done.insert(name);
            }
        }
    }
    for (name, v) in fields {
        if done.contains(name.as_str()) || v.trim().is_empty() {
            continue;
        }
        entry.add_field(name.as_str(), v.trim());
    }
    format_entries(vec![entry])
}

/// One projected bibliography, ready to write.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectedBibliography {
    pub path: String,
    /// The `.bib` text: literal rows verbatim, projections rendered.
    pub text: String,
    /// Keys the projection asked for; empty for a literal row.
    pub requested: Vec<String>,
    /// Keys the resolver did not know.
    pub missing: Vec<String>,
    /// Keys whose entry was built from fields, not raw BibTeX.
    pub synthesized: Vec<String>,
}

/// The effective text of every bibliography file the target reaches (plus
/// every projected one anywhere in the tree, since a projection with no
/// reference yet is still worth materialising).
pub fn resolve_bibliographies(
    tree: &ProjectTree,
    graph: &BuildGraph,
    resolver: &dyn BibliographyResolver,
) -> Vec<ProjectedBibliography> {
    let cited: Vec<String> = graph.deps.cite_keys.iter().cloned().collect();
    let mut out = Vec::new();
    for file in tree
        .files
        .iter()
        .filter(|f| f.role == FileRole::Bibliography || f.bib_source.is_some())
    {
        let Some(source) = &file.bib_source else {
            out.push(ProjectedBibliography {
                path: file.path.clone(),
                text: file.bytes.as_text().unwrap_or("").to_string(),
                requested: vec![],
                missing: vec![],
                synthesized: vec![],
            });
            continue;
        };
        let requested: Vec<String> = match source {
            BibSource::Cited => cited.clone(),
            BibSource::Collection {
                library_id,
                collection_id,
            } => resolver.keys_in_collection(library_id, collection_id),
            BibSource::Library { library_id } => resolver.keys_in_library(library_id),
            BibSource::Keys { keys } => keys.clone(),
        };
        let mut seen = BTreeSet::new();
        let mut text = String::new();
        let mut missing = Vec::new();
        let mut synthesized = Vec::new();
        for key in &requested {
            if !seen.insert(key.clone()) {
                continue;
            }
            match resolver.entry_for_key(key) {
                Some(ResolvedEntry::Raw(raw)) => {
                    text.push_str(raw.trim_end());
                    text.push_str("\n\n");
                }
                Some(ResolvedEntry::Fields { entry_type, fields }) => {
                    text.push_str(synthesize_entry(key, &entry_type, &fields).trim_end());
                    text.push_str("\n\n");
                    synthesized.push(key.clone());
                }
                None => missing.push(key.clone()),
            }
        }
        // A projected row may also carry hand-written entries below its
        // projection (the old projector's "preserved" section): keep them.
        if let Some(literal) = file.bytes.as_text().filter(|t| !t.trim().is_empty()) {
            text.push_str(literal.trim_end());
            text.push('\n');
        }
        out.push(ProjectedBibliography {
            path: file.path.clone(),
            text,
            requested,
            missing,
            synthesized,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::model::{ProjectFile, ProjectTree};

    #[test]
    fn the_implicit_bibliography_follows_the_one_file_convention() {
        let cites_without_bib = ProjectTree::new(
            "m",
            "T",
            "typst",
            ProjectFile::text("main.typ", FileRole::Main, "= P\nSee @knuth84."),
            vec![],
            vec![],
        );
        let implicit = implicit_bibliography(&cites_without_bib).expect("cites → implicit");
        assert_eq!(implicit.path, IMPLICIT_BIBLIOGRAPHY);
        assert_eq!(implicit.bib_source, Some(BibSource::Cited));

        let names_it = ProjectTree::new(
            "m",
            "T",
            "typst",
            ProjectFile::text(
                "main.typ",
                FileRole::Main,
                "See @knuth84.\n#bibliography(\"bibliography.bib\")",
            ),
            vec![],
            vec![],
        );
        assert!(implicit_bibliography(&names_it).is_some());

        let has_own = ProjectTree::new(
            "m",
            "T",
            "typst",
            ProjectFile::text(
                "main.typ",
                FileRole::Main,
                "See @knuth84.\n#bibliography(\"refs.bib\")",
            ),
            vec![ProjectFile::text(
                "refs.bib",
                FileRole::Bibliography,
                "@misc{knuth84,}",
            )],
            vec![],
        );
        assert!(
            implicit_bibliography(&has_own).is_none(),
            "its own bib, nothing implicit"
        );

        let latex = ProjectTree::new(
            "m",
            "T",
            "latex",
            ProjectFile::text("main.tex", FileRole::Main, "\\cite{knuth84}"),
            vec![],
            vec![],
        );
        assert!(
            implicit_bibliography(&latex).is_none(),
            "LaTeX needs a real file"
        );

        let no_cites = ProjectTree::new(
            "m",
            "T",
            "typst",
            ProjectFile::text("main.typ", FileRole::Main, "= P\nNo citations."),
            vec![],
            vec![],
        );
        assert!(implicit_bibliography(&no_cites).is_none());
    }

    #[test]
    fn synthesized_entries_are_well_formed_bibtex() {
        let fields: BTreeMap<String, String> = [
            ("title", "A Result"),
            ("author", "Smith, J. and Doe, A."),
            ("year", "2020"),
            ("journal", "ApJ"),
            ("doi", "10.1/x"),
            ("zzz_custom", "kept"),
            ("empty", "  "),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        let text = synthesize_entry("smith20", "article", &fields);
        assert!(text.starts_with("@article{smith20,"), "{text}");
        let parsed = impress_bibtex::parse(text.clone()).expect("round-trips through the parser");
        let entry = &parsed.entries[0];
        assert_eq!(entry.cite_key, "smith20");
        assert_eq!(entry.get_field("journal"), Some("ApJ"));
        assert_eq!(entry.get_field("zzz_custom"), Some("kept"));
        assert!(entry.get_field("empty").is_none());
        // Conventional order: author before title before year.
        let a = text.find("author").unwrap();
        let t = text.find("title").unwrap();
        let y = text.find("year").unwrap();
        assert!(a < t && t < y, "{text}");
    }

    #[test]
    fn cited_projection_follows_the_tree_and_reports_gaps() {
        let tree = ProjectTree::new(
            "m",
            "T",
            "typst",
            ProjectFile::text(
                "main.typ",
                FileRole::Main,
                "#include \"ch.typ\"\n@raw1 and @synth2 and @nope3\n#bibliography(\"refs.bib\")",
            ),
            vec![
                ProjectFile::text("ch.typ", FileRole::Chapter, "@raw1 again, @extra4"),
                ProjectFile::text(
                    "refs.bib",
                    FileRole::Bibliography,
                    "@misc{hand5, title={By hand}}",
                )
                .with_bib_source(BibSource::Cited),
                ProjectFile::text("static.bib", FileRole::Bibliography, "@misc{static6,}"),
            ],
            vec![],
        );
        let graph = BuildGraph::derive(&tree, tree.default_target());
        let resolver = MapResolver::default()
            .with_raw("raw1", "@article{raw1, title={Raw}}")
            .with_fields("synth2", "book", &[("title", "Synth"), ("year", "1999")])
            .with_raw("extra4", "@article{extra4, title={From the chapter}}");
        let bibs = resolve_bibliographies(&tree, &graph, &resolver);
        assert_eq!(bibs.len(), 2);
        let refs = bibs.iter().find(|b| b.path == "refs.bib").unwrap();
        assert_eq!(
            refs.requested,
            vec!["extra4", "nope3", "raw1", "synth2"],
            "every key the tree cites, sorted"
        );
        assert_eq!(refs.missing, vec!["nope3"]);
        assert_eq!(refs.synthesized, vec!["synth2"]);
        assert!(refs.text.contains("@article{raw1"));
        assert!(refs.text.contains("@book{synth2"));
        assert!(
            refs.text.contains("@article{extra4"),
            "keys cited in a chapter are projected too"
        );
        assert!(
            refs.text.ends_with("@misc{hand5, title={By hand}}\n"),
            "hand-written entries are preserved below"
        );
        let statik = bibs.iter().find(|b| b.path == "static.bib").unwrap();
        assert_eq!(statik.text, "@misc{static6,}");
        assert!(statik.requested.is_empty());
    }

    #[test]
    fn collection_and_key_projections_ask_the_resolver() {
        let tree = ProjectTree::new(
            "m",
            "T",
            "latex",
            ProjectFile::text("main.tex", FileRole::Main, "\\bibliography{coll,keys}"),
            vec![
                ProjectFile::text("coll.bib", FileRole::Bibliography, "").with_bib_source(
                    BibSource::Collection {
                        library_id: "L".into(),
                        collection_id: "C".into(),
                    },
                ),
                ProjectFile::text("keys.bib", FileRole::Bibliography, "").with_bib_source(
                    BibSource::Keys {
                        keys: vec!["k1".into(), "k1".into(), "k2".into()],
                    },
                ),
            ],
            vec![],
        );
        let graph = BuildGraph::derive(&tree, tree.default_target());
        let mut resolver = MapResolver::default()
            .with_raw("c1", "@misc{c1,}")
            .with_raw("k1", "@misc{k1,}");
        resolver
            .collections
            .insert(("L".into(), "C".into()), vec!["c1".into()]);
        let bibs = resolve_bibliographies(&tree, &graph, &resolver);
        let coll = bibs.iter().find(|b| b.path == "coll.bib").unwrap();
        assert_eq!(coll.requested, vec!["c1"]);
        assert!(coll.text.contains("@misc{c1,}"));
        let keys = bibs.iter().find(|b| b.path == "keys.bib").unwrap();
        assert_eq!(keys.missing, vec!["k2"]);
        assert_eq!(
            keys.text.matches("@misc{k1,}").count(),
            1,
            "duplicates collapse"
        );
        // No resolver: nothing renders; explicit keys are all missing, and a
        // collection projection has nothing to ask for.
        let none = resolve_bibliographies(&tree, &graph, &NoResolver);
        assert!(none.iter().all(|b| b.text.is_empty()));
        let keys = none.iter().find(|b| b.path == "keys.bib").unwrap();
        assert_eq!(keys.missing, vec!["k1", "k2"]);
        let coll = none.iter().find(|b| b.path == "coll.bib").unwrap();
        assert!(coll.requested.is_empty() && coll.missing.is_empty());
    }
}
