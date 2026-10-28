//! Display-ready reads for a frontend that draws surfaces (koine-web, the
//! TUI, an agent's own page).
//!
//! A surface cannot compute — no expressions, no conditionals (ADR-0033) —
//! so anything a page shows that is not a raw record field is a verb's job:
//! the library picker's `{value, label}` choices, a list row's short author
//! line and decoded venue, a paper's links and its header as markdown, every
//! key present so one missing BibTeX field never blanks a whole block. These
//! verbs read through the library service and change nothing.

use std::collections::BTreeMap;

use impress_service_core::async_trait;
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

use crate::backend::library_service_instance;
use crate::library_service::{
    PublicationDetailRecord, PublicationSearchFilters, PublicationSummary,
};

/// One entry of a `select` field: what is sent, and what is shown.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ViewChoice {
    /// `library:<uuid>` or `collection:<uuid>`: a scope [`paper_rows`] takes.
    pub value: String,
    /// The name with its paper count; a collection is indented under its library.
    pub label: String,
}

/// One row of the paper list. The field names are the column headings.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ViewPaperRow {
    /// The paper's id (the row's identity, not a column).
    pub id: String,
    /// `●` unread, `★` starred, `⚑` flagged, `📄` a PDF is linked.
    #[serde(rename = "•")]
    pub marks: String,
    /// The title, entities decoded.
    #[serde(rename = "Title")]
    pub title: String,
    /// `Abel`, `Abel & Bryan`, or `Abel et al.`.
    #[serde(rename = "Authors")]
    pub authors: String,
    /// The year, empty when unknown.
    #[serde(rename = "Year")]
    pub year: String,
    /// The journal or venue, entities decoded.
    #[serde(rename = "Venue")]
    pub venue: String,
}

/// One paper, ready to draw. Every field is present; an absent value is an
/// empty string, never a missing key.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ViewPaperCard {
    /// The paper's id.
    pub id: String,
    /// Markdown: the title as a heading, the authors, the venue line and the
    /// links (DOI, arXiv, ADS, the publisher's URL).
    pub header: String,
    /// The abstract, entities decoded; empty when there is none.
    #[serde(rename = "abstract")]
    pub abstract_text: String,
    /// Labelled facts for a `kv` node: cite key, type, year, journal, volume,
    /// pages, DOI, arXiv, bibcode, citations, read, starred, flag, libraries.
    pub facts: BTreeMap<String, String>,
    /// The paper's tags.
    pub tags: Vec<String>,
    /// The paper's BibTeX as the library exports it.
    pub bibtex: String,
    /// Whether the paper is read.
    pub is_read: bool,
    /// Whether the paper is starred.
    pub is_starred: bool,
}

/// One row of an online search. The field names are the column headings.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ViewSearchRow {
    /// The record's canonical identifier (`doi:…`, `arxiv:…`, `bibcode:…`),
    /// what `import-ids` takes.
    pub id: String,
    /// `✓` when the paper is already in the library.
    #[serde(rename = "•")]
    pub marks: String,
    /// The title, entities decoded.
    #[serde(rename = "Title")]
    pub title: String,
    /// `Abel`, `Abel & Bryan`, or `Abel et al.`.
    #[serde(rename = "Authors")]
    pub authors: String,
    /// The year, empty when unknown.
    #[serde(rename = "Year")]
    pub year: String,
    /// The journal or venue.
    #[serde(rename = "Venue")]
    pub venue: String,
    /// The source the row came from (`crossref`, `ads`, …).
    #[serde(rename = "Source")]
    pub source: String,
    /// Citations as that source counts them, empty when it does not say.
    #[serde(rename = "Cited")]
    pub cited: String,
}

/// What became of one identifier `import-ids` was given.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ViewImportLine {
    /// The identifier as given.
    #[serde(rename = "Identifier")]
    pub identifier: String,
    /// `imported`, `already in the library`, `dismissed`, or why it was not.
    #[serde(rename = "Outcome")]
    pub outcome: String,
}

#[impress_service]
pub trait ImbibViewService: Send + Sync + 'static {
    /// The library picker: every library as `library:<id>`, each followed by
    /// its collections as `collection:<id>`, labelled with paper counts.
    #[impress_method(effects(reads = ["imbib/library", "imbib/collection", "imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    async fn library_choices(&self) -> Vec<ViewChoice>;

    /// The paper list of one library or collection (`scope` from
    /// `library-choices`; empty is the default library, else the Inbox),
    /// newest first,
    /// filtered by free text, as rows whose fields are the column headings.
    /// A zero limit means 200.
    #[impress_method(effects(reads = ["imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/library", "imbib/collection"]))]
    #[impress_example(name = "default", args = r#"{"scope":"","query":"","limit":20}"#)]
    async fn paper_rows(&self, scope: String, query: String, limit: u32) -> Vec<ViewPaperRow>;

    /// One paper as a card: a markdown header with its links, the abstract,
    /// labelled facts, tags and BibTeX. Null when there is no such paper.
    #[impress_method(effects(reads = ["imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/collection"]))]
    #[impress_example(
        name = "unknown-id",
        args = r#"{"id":"5c000000-0000-4000-8000-0000000000ff"}"#
    )]
    async fn paper_card(&self, id: String) -> Option<ViewPaperCard>;

    /// Search the online databases (all of them, or a comma list of source
    /// ids) and answer display rows, each keyed by its canonical identifier.
    /// An empty query answers no rows rather than a refusal, so a page can
    /// hold it before anything is typed. A zero limit means 25.
    #[impress_method(safety = external, effects(reads = ["imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror"], reach = [network]))]
    #[impress_example(
        name = "empty-query",
        args = r#"{"query":"","sources":"","limit":5}"#,
        expect = r#"[]"#
    )]
    async fn search_rows(
        &self,
        query: String,
        sources: String,
        limit: u32,
        sort: Option<String>,
    ) -> Vec<ViewSearchRow>;

    /// Fetch each identifier from the online databases and import it into
    /// a library or collection (`scope` from `library-choices`; empty is
    /// the default library, else the Inbox), with the source's own BibTeX. A paper already
    /// there, or dismissed, is reported and not imported again.
    #[impress_method(safety = external, effects(reads = ["imbib/bibliography-entry", "imbib/library", "imbib/collection", "imbib/dismissed-paper"], writes = ["imbib/bibliography-entry", "imbib/collection"], reach = [network]))]
    #[impress_example(
        name = "nothing-to-import",
        args = r#"{"scope":"","ids":[]}"#,
        expect = r#"[]"#
    )]
    async fn import_ids(&self, scope: String, ids: Vec<String>) -> Vec<ViewImportLine>;
}

#[derive(Default, Clone, Copy)]
pub struct DefaultImbibViewService;

#[async_trait::async_trait]
impl ImbibViewService for DefaultImbibViewService {
    async fn library_choices(&self) -> Vec<ViewChoice> {
        let library = library_service_instance();
        let mut out = Vec::new();
        // The library an empty scope lists comes first, so a picker that
        // holds no value yet (and so shows its first entry) shows the list
        // it is looking at.
        let home = home_library().await;
        let mut libraries = library.list_libraries().await;
        libraries.sort_by_key(|l| Some(&l.id) != home.as_ref());
        for lib in libraries {
            out.push(ViewChoice {
                value: format!("library:{}", lib.id),
                label: format!("{} — {}", lib.name, lib.publication_count),
            });
            for coll in library.list_collections(lib.id.clone()).await {
                out.push(ViewChoice {
                    value: format!("collection:{}", coll.id),
                    label: format!(
                        "    {} / {} — {}",
                        lib.name, coll.name, coll.publication_count
                    ),
                });
            }
        }
        out
    }

    async fn paper_rows(&self, scope: String, query: String, limit: u32) -> Vec<ViewPaperRow> {
        let limit = if limit == 0 { 200 } else { limit };
        let mut filters = PublicationSearchFilters::default();
        match scope.split_once(':') {
            Some(("library", id)) => filters.library = Some(id.to_string()),
            Some(("collection", id)) => filters.collection = Some(id.to_string()),
            _ => filters.library = home_library().await,
        }
        library_service_instance()
            .search_publications(query, limit, None, Some(filters))
            .await
            .iter()
            .map(row_of)
            .collect()
    }

    async fn paper_card(&self, id: String) -> Option<ViewPaperCard> {
        let library = library_service_instance();
        let detail = library.get_publication_detail(id.clone()).await?;
        let bibtex = library.export_bibtex(vec![id]).await;
        Some(card_of(&detail, bibtex))
    }

    async fn search_rows(
        &self,
        query: String,
        sources: String,
        limit: u32,
        sort: Option<String>,
    ) -> Vec<ViewSearchRow> {
        if query.trim().is_empty() {
            return Vec::new();
        }
        let limit = if limit == 0 { 25 } else { limit };
        let sources = Some(sources).filter(|s| !s.trim().is_empty());
        let sort = sort.filter(|s| !s.trim().is_empty());
        let found = crate::sources::search_sources(query, sources, limit, sort).await;
        let held = held_identifiers(&found);
        found
            .iter()
            // A record with no title (a bare Crossref DOI for a book part,
            // say) is not something a person can choose from a list.
            .filter(|p| !p.title.trim().is_empty())
            .map(|p| search_row_of(p, &held))
            .collect()
    }

    async fn import_ids(&self, scope: String, ids: Vec<String>) -> Vec<ViewImportLine> {
        use source_service::service::{BibSourceService, DefaultBibSourceService};
        let (library, collection) = match scope.split_once(':') {
            Some(("library", id)) => (Some(id.to_string()), None),
            Some(("collection", id)) => (None, Some(id.to_string())),
            _ => (home_library().await, None),
        };
        let service = DefaultBibSourceService::new();
        let mut out = Vec::new();
        for id in ids {
            let fetched = service.fetch(id.clone(), None, None).await;
            let Some(answer) = fetched.answer else {
                out.push(ViewImportLine {
                    identifier: id,
                    outcome: format!("not found: {}", fetched.outcome.message.unwrap_or_default()),
                });
                continue;
            };
            let outcome =
                crate::sources::import_work(answer.work, library.clone(), collection.clone(), true)
                    .await;
            let said = if outcome.dismissed {
                "dismissed".to_string()
            } else if outcome.imported_id.is_some() {
                "imported".to_string()
            } else if outcome.existing_id.is_some() {
                "already in the library".to_string()
            } else {
                "not imported (see the console, category sources)".to_string()
            };
            out.push(ViewImportLine {
                identifier: id,
                outcome: said,
            });
        }
        out
    }
}

/// The identifier `import-ids` fetches by: the first of DOI, arXiv,
/// bibcode, PMID, OpenAlex the record carries, as `kind:value`.
fn canonical_id(p: &crate::app_service::ExternalPaper) -> String {
    for kind in [
        "doi", "arxiv", "bibcode", "pmid", "openalex", "s2", "dblp", "inspire",
    ] {
        if let Some(v) = p.ids.get(kind).filter(|v| !v.is_empty()) {
            return format!("{kind}:{v}");
        }
    }
    p.identifier.clone().unwrap_or_default()
}

/// The DOIs, arXiv ids and bibcodes among `found` the library already
/// holds, lower-cased: one batch query, not one per row.
fn held_identifiers(
    found: &[crate::app_service::ExternalPaper],
) -> std::collections::HashSet<String> {
    let pick = |kind: &str| -> Vec<String> {
        found
            .iter()
            .filter_map(|p| p.ids.get(kind).cloned())
            .filter(|v| !v.is_empty())
            .collect()
    };
    let rows = crate::store_singleton::store_instance()
        .find_by_identifiers_batch(pick("doi"), pick("arxiv"), pick("bibcode"))
        .unwrap_or_default();
    let mut held = std::collections::HashSet::new();
    for r in rows {
        for v in [r.doi, r.arxiv_id, r.bibcode].into_iter().flatten() {
            held.insert(v.to_lowercase());
        }
    }
    held
}

fn search_row_of(
    p: &crate::app_service::ExternalPaper,
    held: &std::collections::HashSet<String>,
) -> ViewSearchRow {
    let in_library = ["doi", "arxiv", "bibcode"].iter().any(|k| {
        p.ids
            .get(*k)
            .is_some_and(|v| held.contains(&v.to_lowercase()))
    });
    // A merged row names every source that answered it.
    let source = p
        .provenance
        .as_ref()
        .map(|pr| pr.sources.join(", "))
        .filter(|s| !s.is_empty())
        .or_else(|| p.source.clone())
        .unwrap_or_default();
    let authors = p
        .authors
        .iter()
        .map(|a| a.as_str())
        .collect::<Vec<_>>()
        .join("; ");
    ViewSearchRow {
        id: canonical_id(p),
        marks: if in_library {
            "✓".into()
        } else {
            String::new()
        },
        title: display_text(&p.title),
        authors: short_authors(&authors),
        year: p.year.map(|y| y.to_string()).unwrap_or_default(),
        venue: clean(p.venue.as_deref().unwrap_or("")),
        source,
        cited: p
            .cited_by
            .filter(|n| *n > 0)
            .map(|n| n.to_string())
            .unwrap_or_default(),
    }
}

/// The library an empty scope means: the default library, else the Inbox
/// (a store with no default flagged would otherwise list nothing).
async fn home_library() -> Option<String> {
    let library = library_service_instance();
    if let Some(lib) = library.get_default_library().await {
        return Some(lib.id);
    }
    library
        .list_libraries()
        .await
        .into_iter()
        .find(|l| l.is_inbox)
        .map(|l| l.id)
}

/// Text without the inline markup sources wrap titles and abstracts in
/// (Crossref's `<i>…</i>` and `<jats:italic>`, `<scp>`): known tag names
/// only, so prose like `a < b` is left alone. Sub- and superscripts are
/// converted to Unicode before this runs (`abstract_display_text`).
fn strip_markup(text: &str) -> String {
    const INLINE: &[&str] = &[
        "i", "b", "em", "strong", "scp", "sc", "u", "span", "small", "tt", "sub", "sup", "p", "br",
        "inf", "it", "bold", "italic", "title", "sec",
    ];
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find('<') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        let end = after.find('>');
        let tag = end.map(|e| &after[..e]);
        let known = tag.is_some_and(|t| {
            let name = t
                .trim_start_matches('/')
                .split(|c: char| c.is_whitespace() || c == '/')
                .next()
                .unwrap_or("")
                .to_ascii_lowercase();
            name.starts_with("jats:") || name.starts_with("mml:") || INLINE.contains(&name.as_str())
        });
        match (known, end) {
            (true, Some(e)) => rest = &after[e + 1..],
            _ => {
                out.push('<');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// A title or abstract for display: entities decoded, math as Unicode
/// where it converts whole, inline markup removed.
fn display_text(text: &str) -> String {
    strip_markup(&imbib_core::text::abstract_display_text(&clean(text)))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// HTML entities decoded (`&amp;` from a BibTeX export, `&#x2013;`), the
/// surrounding whitespace trimmed.
fn clean(text: &str) -> String {
    impress_smart_search::url_extract::decode_html_entities(text.trim())
}

/// `Abel`, `Abel & Bryan`, `Abel et al.` from the summary's
/// `Family, Given; Family, Given` line.
fn short_authors(authors: &str) -> String {
    let families: Vec<&str> = authors
        .split(';')
        .map(|a| a.split(',').next().unwrap_or("").trim())
        .filter(|f| !f.is_empty())
        .collect();
    match families.as_slice() {
        [] => String::new(),
        [one] => clean(one),
        [a, b] => format!("{} & {}", clean(a), clean(b)),
        [first, ..] => format!("{} et al.", clean(first)),
    }
}

fn row_of(p: &PublicationSummary) -> ViewPaperRow {
    let mut marks = String::new();
    if !p.is_read {
        marks.push('●');
    }
    if p.is_starred {
        marks.push('★');
    }
    if p.flag_color.is_some() {
        marks.push('⚑');
    }
    if p.has_pdf {
        marks.push('📄');
    }
    ViewPaperRow {
        id: p.id.clone(),
        marks,
        title: display_text(&p.title),
        authors: short_authors(&p.authors),
        year: p.year.map(|y| y.to_string()).unwrap_or_default(),
        venue: clean(p.venue.as_deref().unwrap_or("")),
    }
}

/// A markdown link label never contains `]`, and its address never `)`.
fn link(label: &str, url: &str) -> String {
    format!("[{label}]({})", url.replace(')', "%29"))
}

fn card_of(d: &PublicationDetailRecord, bibtex: String) -> ViewPaperCard {
    // `fields` holds the store's payload keys (`venue`, `abstract_text`,
    // `arxiv_id`, `raw_bibtex`) and, for papers imported from BibTeX, the
    // BibTeX names too (`journal`, `abstract`, `eprint`): the first present,
    // non-empty spelling wins.
    let field = |k: &str| d.fields.get(k).map(|v| clean(v)).unwrap_or_default();
    let first = |keys: &[&str]| {
        keys.iter()
            .map(|k| field(k))
            .find(|v| !v.is_empty())
            .unwrap_or_default()
    };
    let title = display_text(&field("title"));
    let authors = d
        .authors
        .iter()
        .map(|a| {
            let given = a.given_name.as_deref().unwrap_or("").trim();
            let family = a.family_name.trim();
            if given.is_empty() {
                clean(family)
            } else {
                clean(&format!("{given} {family}"))
            }
        })
        .collect::<Vec<_>>()
        .join(", ");
    let journal = first(&["venue", "journal", "booktitle"]);
    let year = field("year");
    let volume = field("volume");
    let pages = field("pages");
    let doi = field("doi");
    let arxiv = first(&["arxiv_id", "eprint", "arxiv"]);
    let bibcode = {
        let b = field("bibcode");
        if b.is_empty() {
            field("adsurl")
                .rsplit("/abs/")
                .next()
                .filter(|s| s.len() == 19)
                .map(str::to_string)
                .unwrap_or_default()
        } else {
            b
        }
    };
    let url = field("url");

    let mut venue_line = journal.clone();
    if !volume.is_empty() {
        venue_line.push_str(&format!(" {volume}"));
    }
    if !pages.is_empty() {
        venue_line.push_str(&format!(", {pages}"));
    }
    if !year.is_empty() {
        venue_line.push_str(&format!(" ({year})"));
    }

    let mut links = Vec::new();
    if !doi.is_empty() {
        links.push(link("DOI", &format!("https://doi.org/{doi}")));
    }
    if !arxiv.is_empty() {
        links.push(link("arXiv", &format!("https://arxiv.org/abs/{arxiv}")));
        links.push(link("PDF", &format!("https://arxiv.org/pdf/{arxiv}")));
    }
    if !bibcode.is_empty() {
        links.push(link(
            "ADS",
            &format!("https://ui.adsabs.harvard.edu/abs/{bibcode}/abstract"),
        ));
    }
    if !url.is_empty() && url.starts_with("http") {
        links.push(link("Link", &url));
    }

    let mut header = format!(
        "### {}\n\n",
        if title.is_empty() {
            "(untitled)"
        } else {
            &title
        }
    );
    if !authors.is_empty() {
        header.push_str(&format!("{authors}\n\n"));
    }
    if !venue_line.trim().is_empty() {
        header.push_str(&format!("*{}*\n\n", venue_line.trim()));
    }
    if !links.is_empty() {
        header.push_str(&links.join(" · "));
        header.push('\n');
    }

    let mut facts = BTreeMap::new();
    let mut put = |k: &str, v: String| {
        if !v.is_empty() {
            facts.insert(k.to_string(), v);
        }
    };
    put("cite key", d.cite_key.clone());
    put("type", d.entry_type.clone());
    put("year", year);
    put("journal", journal);
    put("volume", volume);
    put("pages", pages);
    put("DOI", doi);
    put("arXiv", arxiv);
    put("bibcode", bibcode);
    if d.citation_count > 0 {
        put("citations", d.citation_count.to_string());
    }
    put("read", if d.is_read { "yes" } else { "no" }.into());
    put("starred", if d.is_starred { "yes" } else { "no" }.into());
    put("flag", d.flag_color.clone().unwrap_or_default());
    put(
        "files",
        d.linked_files
            .iter()
            .map(|f| f.filename.clone())
            .collect::<Vec<_>>()
            .join(", "),
    );

    ViewPaperCard {
        id: d.id.clone(),
        header,
        abstract_text: strip_markup(&imbib_core::text::abstract_display_text(&first(&[
            "abstract_text",
            "abstract",
        ]))),
        facts,
        tags: d.tags.clone(),
        // The source's own BibTeX when the paper came with it (S-D5),
        // else what the library exports.
        bibtex: d
            .fields
            .get("raw_bibtex")
            .map(|b| b.trim().to_string())
            .filter(|b| b.starts_with('@'))
            .unwrap_or(bibtex),
        is_read: d.is_read,
        is_starred: d.is_starred,
    }
}

impress_service_impl! {
    service = ImbibViewService,
    safety = read_only,
    since = "0.1.0",
    effects = {
        reads: ["imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/library", "imbib/collection", "imbib/dismissed-paper"],
        writes: [],
        reach: [],
    },
    impl = DefaultImbibViewService,
    instance = || DefaultImbibViewService,
    methods = [
        /// The library picker: libraries and their collections as `{value, label}`.
        library_choices() -> Vec<ViewChoice>,
        /// The paper list of one library or collection as display rows.
        paper_rows(
            /// `library:<uuid>`, `collection:<uuid>`, or empty for the default library.
            scope: String,
            /// Free text over title, authors and abstract; empty lists the scope.
            query: String,
            /// The most rows to return; zero means 200.
            limit: u32
        ) -> Vec<ViewPaperRow>,
        /// One paper as a display card.
        paper_card(
            /// The paper's UUID.
            id: String
        ) -> Option<ViewPaperCard>,
        /// Online search results as display rows keyed by canonical identifier.
        search_rows(
            /// What to search for: words, an author, a DOI or arXiv id.
            query: String,
            /// A comma list of source ids (`ads,crossref`); empty is every source.
            sources: String,
            /// The most rows per source; zero means 25.
            limit: u32,
            /// `cited_by` (most cited first), `year` (newest first), or empty
            /// for the order the first-listed source returns.
            sort: Option<String>
        ) -> Vec<ViewSearchRow>,
        /// Fetch identifiers online and import them into a library or collection.
        import_ids(
            /// `library:<uuid>`, `collection:<uuid>`, or empty for the default library.
            scope: String,
            /// Canonical identifiers (`doi:…`, `arxiv:…`), as `search-rows` keys its rows.
            ids: Vec<String>
        ) -> Vec<ViewImportLine>,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_authors_names_one_two_or_the_first_et_al() {
        assert_eq!(short_authors(""), "");
        assert_eq!(short_authors("Abel, T."), "Abel");
        assert_eq!(short_authors("Abel, T.; Bryan, G. L."), "Abel & Bryan");
        assert_eq!(
            short_authors("Abel, T.; Bryan, G. L.; Norman, M. L."),
            "Abel et al."
        );
    }

    #[test]
    fn a_row_decodes_entities_and_marks_state() {
        let p: PublicationSummary = serde_json::from_value(serde_json::json!({
            "id": "x",
            "title": "Gas &amp; Dust",
            "authors": "Abel, T.",
            "venue": "Astronomy &amp; Astrophysics",
            "year": 2002,
            "is_read": false,
            "is_starred": true
        }))
        .unwrap();
        let row = row_of(&p);
        assert_eq!(row.title, "Gas & Dust");
        assert_eq!(row.venue, "Astronomy & Astrophysics");
        assert_eq!(row.marks, "●★");
        assert_eq!(row.year, "2002");
    }

    #[test]
    fn a_card_has_every_key_and_links_from_the_identifiers() {
        let d: PublicationDetailRecord = serde_json::from_value(serde_json::json!({
            "id": "p",
            "cite_key": "Abel2002",
            "entry_type": "article",
            "fields": {
                "title": "The Formation of the First Star",
                "doi": "10.1126/science.1063991",
                "eprint": "astro-ph/0112088"
            },
            "is_read": false,
            "is_starred": false,
            "flag_color": null,
            "tags": [],
            "authors": [],
            "linked_files": [],
            "collection_ids": [],
            "library_ids": [],
            "date_added": 0,
            "date_modified": 0,
            "citation_count": 0
        }))
        .unwrap();
        let card = card_of(&d, String::new());
        assert!(card
            .header
            .starts_with("### The Formation of the First Star"));
        assert!(card
            .header
            .contains("[DOI](https://doi.org/10.1126/science.1063991)"));
        assert!(card
            .header
            .contains("[arXiv](https://arxiv.org/abs/astro-ph/0112088)"));
        assert_eq!(card.abstract_text, "");
        assert_eq!(card.facts["cite key"], "Abel2002");
        assert!(
            !card.facts.contains_key("journal"),
            "an absent field is not a fact"
        );
    }

    #[test]
    fn markup_is_stripped_but_prose_comparisons_survive() {
        assert_eq!(
            display_text("<i>ONE HUNDRED FIRST STARS</i>: PROTOSTELLAR"),
            "ONE HUNDRED FIRST STARS: PROTOSTELLAR"
        );
        assert_eq!(
            strip_markup("<jats:p>We find <jats:italic>z</jats:italic> &lt; 6</jats:p>"),
            "We find z &lt; 6"
        );
        assert_eq!(strip_markup("for a < b and c > d"), "for a < b and c > d");
    }

    #[test]
    fn a_card_reads_the_stores_payload_keys() {
        let d: PublicationDetailRecord = serde_json::from_value(serde_json::json!({
            "id": "p", "cite_key": "K2024", "entry_type": "article",
            "fields": {
                "title": "Interpolation techniques",
                "venue": "The Astrophysical Journal",
                "abstract_text": "We compare &lt;b&gt;methods&lt;/b&gt;.",
                "arxiv_id": "2410.15265",
                "year": "2024",
                "raw_bibtex": "@article{K2024, title={Interpolation techniques}}"
            },
            "is_read": true, "is_starred": false, "flag_color": null, "tags": [],
            "authors": [], "linked_files": [], "collection_ids": [], "library_ids": [],
            "date_added": 0, "date_modified": 0, "citation_count": 0
        }))
        .unwrap();
        let card = card_of(&d, "@misc{exported}".into());
        assert!(
            card.header.contains("*The Astrophysical Journal (2024)*"),
            "{}",
            card.header
        );
        assert!(card
            .header
            .contains("[arXiv](https://arxiv.org/abs/2410.15265)"));
        assert_eq!(card.facts["journal"], "The Astrophysical Journal");
        assert!(card.abstract_text.starts_with("We compare"));
        assert!(
            card.bibtex.starts_with("@article{K2024"),
            "the source's own BibTeX wins"
        );
    }
}
