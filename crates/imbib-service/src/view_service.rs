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
    /// The paper's tags as list rows (`id` the path, `label` the path), so a
    /// row's menu can name the tag it removes.
    pub tags: Vec<ViewTag>,
    /// The collections holding the paper as list rows (`id` the
    /// collection's id, `label` `Library / Name`), so a row's menu can name
    /// the collection it removes the paper from.
    pub collections: Vec<ViewTag>,
    /// The flag's color, empty when the paper is not flagged.
    pub flag: String,
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

/// A reference resolved for display: what happened, in a sentence, and the
/// scored candidates as rows.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ViewResolution {
    /// How it was found (`local-text`, `search-high-confidence-preview`,
    /// `search-candidates`, `not-found`, …), empty before anything is asked.
    pub via: String,
    /// What happened, for a person (markdown): the paper found in the
    /// library, the match found online, or that no candidate was certain.
    pub verdict: String,
    /// The library's paper when the reference is already there, else empty.
    pub local_id: String,
    /// The scored candidates, best first.
    pub rows: Vec<ViewCandidateRow>,
}

/// One scored candidate. The field names are the column headings.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ViewCandidateRow {
    /// The candidate's canonical identifier, what `import-ids` takes.
    pub id: String,
    /// The scorer's confidence, two decimals.
    #[serde(rename = "Score")]
    pub score: String,
    /// The title.
    #[serde(rename = "Title")]
    pub title: String,
    /// `Abel`, `Abel & Bryan`, or `Abel et al.`.
    #[serde(rename = "Authors")]
    pub authors: String,
    /// The year.
    #[serde(rename = "Year")]
    pub year: String,
    /// The journal or venue.
    #[serde(rename = "Venue")]
    pub venue: String,
    /// The source the candidate came from.
    #[serde(rename = "Source")]
    pub source: String,
}

/// One tag on a paper, as a list row.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ViewTag {
    /// The tag path.
    pub id: String,
    /// The tag path, shown.
    pub label: String,
}

/// One row of the collections table. The field names are the column headings.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ViewCollectionRow {
    /// The collection's id (the row's identity, not a column).
    pub id: String,
    /// The collection's name.
    #[serde(rename = "Collection")]
    pub name: String,
    /// The library that owns it, empty when none does.
    #[serde(rename = "Library")]
    pub library: String,
    /// How many papers it holds.
    #[serde(rename = "Papers")]
    pub papers: String,
}

/// One saved search as a table row. The field names are the column headings.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ViewSmartSearchRow {
    /// The search's id (the row's identity, not a column).
    pub id: String,
    /// The search's name.
    #[serde(rename = "Search")]
    pub name: String,
    /// The query it runs.
    #[serde(rename = "Query")]
    pub query: String,
    /// The sources it asks, `all` when it asks every one.
    #[serde(rename = "Sources")]
    pub sources: String,
    /// The library its results are filed in.
    #[serde(rename = "Library")]
    pub library: String,
    /// How many papers it has found so far.
    #[serde(rename = "Papers")]
    pub papers: String,
}

/// One row of the tag tree widget: `id` is the tag's path, `parent` its
/// parent's path (null at the root), `label` the leaf with its count.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ViewTagNode {
    /// The tag path (`methods/mcmc`).
    pub id: String,
    /// The parent path, null for a top-level tag.
    pub parent: Option<String>,
    /// `mcmc — 12`.
    pub label: String,
    /// The tag has children, whether or not they are among the rows yet
    /// (the tree is lazy: a branch's children come once it is expanded).
    pub has_children: bool,
}

#[impress_service]
pub trait ImbibViewService: Send + Sync + 'static {
    /// The library picker: every library as `library:<id>`, each followed by
    /// its collections as `collection:<id>`, labelled with paper counts.
    #[impress_method(effects(reads = ["imbib/library", "imbib/collection", "imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    async fn library_choices(&self) -> Vec<ViewChoice>;

    /// The paper list of one library or collection (`scope` from
    /// `library-choices`, or `inbox`; empty is the default library, else the
    /// Inbox),
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

    /// The feed picker: every feed (smart search) as `{value: <feed id>,
    /// label: "<library> ▸ <name>"}`, inbox feeds first.
    #[impress_method(effects(reads = ["imbib/smart-search", "imbib/library", "imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    async fn feed_choices(&self) -> Vec<ViewChoice>;

    /// The papers a feed has found (its collection), newest first, filtered
    /// by free text. An empty `feed_id` is the first feed `feed-choices`
    /// lists, which is the one a picker with no value shows.
    #[impress_method(effects(reads = ["imbib/smart-search", "imbib/library", "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/collection"]))]
    #[impress_example(name = "default", args = r#"{"feed_id":"","query":"","limit":20}"#)]
    async fn feed_rows(&self, feed_id: String, query: String, limit: u32) -> Vec<ViewPaperRow>;

    /// The tag tree as tree-widget rows, lazily: the top-level tags and the
    /// children of every path in `expanded` (the widget's own expand state),
    /// with the parents a path implies even when no paper carries the
    /// parent itself. A library can hold thousands of tags; a page asks only
    /// for what is open, and an open node shows its 300 most used children
    /// with a row saying how many more there are. A non-empty `filter`
    /// answers instead the tags whose path contains it, flat, most used first.
    #[impress_method(effects(reads = ["imbib/tag-definition", "imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{"expanded":[],"filter":""}"#)]
    async fn tag_tree(
        &self,
        expanded: Option<Vec<String>>,
        filter: Option<String>,
    ) -> Vec<ViewTagNode>;

    /// The papers carrying a tag, newest publication first. An empty tag
    /// answers no rows.
    #[impress_method(effects(reads = ["imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror"]))]
    #[impress_example(
        name = "default",
        args = r#"{"tag_path":"effects/example","limit":20}"#
    )]
    async fn tag_rows(&self, tag_path: String, limit: u32) -> Vec<ViewPaperRow>;

    /// Every paper collection as table rows — name, owning library, paper
    /// count — libraries in picker order, collections no library owns last.
    #[impress_method(effects(reads = ["imbib/library", "imbib/collection", "imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    async fn collection_rows(&self) -> Vec<ViewCollectionRow>;

    /// Every paper collection as `{value: <collection id>, label:
    /// "<library> / <name>"}`, for a picker that files a paper, after a
    /// first `{value: "", label: "Choose a collection…"}`.
    #[impress_method(effects(reads = ["imbib/library", "imbib/collection", "imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    async fn collection_choices(&self) -> Vec<ViewChoice>;

    /// The saved searches (smart searches that do not feed the Inbox) as
    /// table rows: name, query, sources, library, papers found so far.
    /// `paper-rows` with scope `collection:<id>` lists one's papers, and
    /// `imbib-feeds-service_refresh-feed` runs one.
    #[impress_method(effects(reads = ["imbib/smart-search", "imbib/library", "imbib/collection", "imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    async fn smart_search_rows(&self) -> Vec<ViewSmartSearchRow>;

    /// Every library as `{value: <library id>, label: <name>}`, for the
    /// picker that saves a search, after a first `{value: "", label:
    /// "Choose a library…"}`; the library already holding the most saved
    /// searches comes first.
    #[impress_method(effects(reads = ["imbib/smart-search", "imbib/library", "imbib/collection", "imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    async fn smart_search_libraries(&self) -> Vec<ViewChoice>;

    /// The libraries a triaged paper can be kept in, as `{value: <library
    /// id>, label: <name> — <count>}` after a first `{value: "", label:
    /// "Keep in…"}`: every library but the Inbox and the Dismissed one.
    #[impress_method(effects(reads = ["imbib/library", "imbib/collection", "imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    async fn keep_libraries(&self) -> Vec<ViewChoice>;

    /// The paper that follows `id` in a list (`scope` as `paper-rows` takes
    /// it, or `feed:<id>` for a feed's list, empty id the first feed), so a
    /// page can show it once `id` is triaged away: the next paper, the one
    /// before when `id` is last, and nothing when `id` is alone or absent.
    /// One id or none, so a page can set its selection to the answer.
    #[impress_method(effects(reads = ["imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/library", "imbib/collection", "imbib/smart-search"]))]
    #[impress_example(
        name = "unknown-paper",
        args = r#"{"scope":"inbox","query":"","id":"5c000000-0000-4000-8000-0000000000fc","limit":300}"#,
        expect = r#"[]"#
    )]
    async fn paper_after(
        &self,
        scope: String,
        query: String,
        id: String,
        limit: u32,
    ) -> Vec<String>;

    /// Resolve a reference without importing anything: the library first,
    /// then the online databases, every candidate scored. An empty reference
    /// answers an empty resolution rather than a refusal.
    #[impress_method(safety = external, effects(reads = ["imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/library", "imbib/dismissed-paper"], reach = [network]))]
    #[impress_example(name = "empty-reference", args = r#"{"reference":""}"#)]
    async fn resolve_view(&self, reference: String) -> ViewResolution;
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
            _ if scope == "inbox" => {
                filters.library = library_service_instance()
                    .get_inbox_library()
                    .await
                    .map(|l| l.id)
            }
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
        let mut card = card_of(&detail, bibtex);
        let named: BTreeMap<String, String> = all_collections()
            .await
            .into_iter()
            .map(|c| (c.id.clone(), c.label()))
            .collect();
        card.collections = detail
            .collection_ids
            .iter()
            .filter_map(|id| {
                named.get(id).map(|label| ViewTag {
                    id: id.clone(),
                    label: label.clone(),
                })
            })
            .collect();
        Some(card)
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

    async fn collection_rows(&self) -> Vec<ViewCollectionRow> {
        all_collections()
            .await
            .into_iter()
            .map(|c| ViewCollectionRow {
                id: c.id,
                name: clean(&c.name),
                library: c.library,
                papers: c.count.to_string(),
            })
            .collect()
    }

    async fn collection_choices(&self) -> Vec<ViewChoice> {
        // A picker shows its first entry before anything is chosen, while its
        // bound value is still empty; that entry must say so rather than
        // name a collection the paper would not be filed in.
        let mut out = vec![ViewChoice {
            value: String::new(),
            label: "Choose a collection…".into(),
        }];
        out.extend(all_collections().await.into_iter().map(|c| ViewChoice {
            label: c.label(),
            value: c.id,
        }));
        out
    }

    async fn smart_search_rows(&self) -> Vec<ViewSmartSearchRow> {
        let names: BTreeMap<String, String> = library_service_instance()
            .list_libraries()
            .await
            .into_iter()
            .map(|l| (l.id, l.name))
            .collect();
        let store = crate::store_singleton::store_instance();
        let rows = tokio::task::spawn_blocking(move || {
            let searches = store.list_smart_searches(None).unwrap_or_default();
            searches
                .into_iter()
                .filter(|s| !s.feeds_to_inbox)
                .map(|s| {
                    let found = store
                        .count_collection_members_public(s.id.clone())
                        .unwrap_or(0);
                    (s, found)
                })
                .collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        rows.into_iter()
            .map(|(s, found)| ViewSmartSearchRow {
                name: clean(&s.name),
                query: s.query.clone(),
                sources: if s.source_ids.is_empty() {
                    "all".into()
                } else {
                    s.source_ids.join(", ")
                },
                library: s
                    .library_id
                    .as_ref()
                    .and_then(|id| names.get(id).cloned())
                    .unwrap_or_default(),
                papers: found.to_string(),
                id: s.id,
            })
            .collect()
    }

    async fn smart_search_libraries(&self) -> Vec<ViewChoice> {
        let store = crate::store_singleton::store_instance();
        let searches = tokio::task::spawn_blocking(move || store.list_smart_searches(None))
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default();
        let mut held: BTreeMap<String, usize> = BTreeMap::new();
        for s in searches.iter().filter(|s| !s.feeds_to_inbox) {
            if let Some(id) = &s.library_id {
                *held.entry(id.clone()).or_default() += 1;
            }
        }
        let mut libraries = library_service_instance().list_libraries().await;
        libraries.sort_by_key(|l| std::cmp::Reverse(held.get(&l.id).copied().unwrap_or(0)));
        // As in `collection-choices`: an untouched picker shows its first
        // entry while its bound value is still empty.
        let mut out = vec![ViewChoice {
            value: String::new(),
            label: "Choose a library…".into(),
        }];
        out.extend(libraries.into_iter().map(|l| ViewChoice {
            value: l.id,
            label: l.name,
        }));
        out
    }

    async fn keep_libraries(&self) -> Vec<ViewChoice> {
        let mut out = vec![ViewChoice {
            value: String::new(),
            label: "Keep in…".into(),
        }];
        out.extend(
            library_service_instance()
                .list_libraries()
                .await
                .into_iter()
                .filter(|l| !l.is_inbox && l.name != crate::triage_service::DISMISSED_LIBRARY)
                .map(|l| ViewChoice {
                    label: format!("{} — {}", l.name, l.publication_count),
                    value: l.id,
                }),
        );
        out
    }

    async fn paper_after(
        &self,
        scope: String,
        query: String,
        id: String,
        limit: u32,
    ) -> Vec<String> {
        let rows = match scope.strip_prefix("feed:") {
            Some(feed) => self.feed_rows(feed.to_string(), query, limit).await,
            None => self.paper_rows(scope, query, limit).await,
        };
        let Some(at) = rows.iter().position(|r| r.id == id) else {
            return Vec::new();
        };
        rows.get(at + 1)
            .or_else(|| at.checked_sub(1).and_then(|before| rows.get(before)))
            .map(|r| vec![r.id.clone()])
            .unwrap_or_default()
    }

    async fn feed_choices(&self) -> Vec<ViewChoice> {
        crate::feeds_service::feeds_in_order()
            .await
            .into_iter()
            .map(|(feed, library)| ViewChoice {
                value: feed.id.clone(),
                label: format!("{library} ▸ {}", feed.name),
            })
            .collect()
    }

    async fn feed_rows(&self, feed_id: String, query: String, limit: u32) -> Vec<ViewPaperRow> {
        let feed_id = if feed_id.trim().is_empty() {
            match crate::feeds_service::feeds_in_order()
                .await
                .into_iter()
                .next()
            {
                Some((feed, _)) => feed.id,
                None => return Vec::new(),
            }
        } else {
            feed_id
        };
        self.paper_rows(format!("collection:{feed_id}"), query, limit)
            .await
    }

    async fn tag_tree(
        &self,
        expanded: Option<Vec<String>>,
        filter: Option<String>,
    ) -> Vec<ViewTagNode> {
        const CAP: usize = 300;
        // Every tag: the verb answers 100 unless asked for more.
        let tags = crate::backend::tags_service_instance()
            .list_tags_with_counts(None, Some(u32::MAX))
            .await;
        let filter = filter
            .map(|f| f.trim().to_lowercase())
            .filter(|f| !f.is_empty());
        if let Some(f) = filter {
            let mut hits: Vec<_> = tags
                .iter()
                .filter(|t| t.path.to_lowercase().contains(&f))
                .collect();
            hits.sort_by(|a, b| {
                b.publication_count
                    .cmp(&a.publication_count)
                    .then(a.path.cmp(&b.path))
            });
            return hits
                .into_iter()
                .take(CAP)
                .map(|t| ViewTagNode {
                    id: t.path.clone(),
                    parent: None,
                    label: format!("{} — {}", t.path, t.publication_count),
                    has_children: false,
                })
                .collect();
        }
        let mut count: std::collections::HashMap<String, i32> = std::collections::HashMap::new();
        let mut nodes: std::collections::BTreeMap<String, ViewTagNode> =
            std::collections::BTreeMap::new();
        for t in &tags {
            count.insert(t.path.clone(), t.publication_count);
            nodes.insert(
                t.path.clone(),
                ViewTagNode {
                    id: t.path.clone(),
                    parent: t.parent_path.clone().filter(|p| !p.is_empty()),
                    label: format!("{} — {}", t.leaf_name, t.publication_count),
                    has_children: false,
                },
            );
        }
        // A path implies its parents; one no paper carries still gets a row,
        // or its children would float at the root.
        let paths: Vec<String> = nodes.keys().cloned().collect();
        for path in paths {
            let mut cur = path.as_str();
            while let Some((parent, _)) = cur.rsplit_once('/') {
                nodes
                    .entry(parent.to_string())
                    .or_insert_with(|| ViewTagNode {
                        id: parent.to_string(),
                        parent: parent.rsplit_once('/').map(|(p, _)| p.to_string()),
                        label: parent.rsplit('/').next().unwrap_or(parent).to_string(),
                        has_children: true,
                    });
                cur = parent;
            }
        }
        let open: std::collections::HashSet<String> =
            expanded.unwrap_or_default().into_iter().collect();
        let mut children: std::collections::BTreeMap<Option<String>, Vec<ViewTagNode>> =
            std::collections::BTreeMap::new();
        for n in nodes.into_values() {
            children.entry(n.parent.clone()).or_default().push(n);
        }
        let sizes: std::collections::HashMap<String, usize> = children
            .iter()
            .filter_map(|(k, v)| k.clone().map(|k| (k, v.len())))
            .collect();
        let mut out = Vec::new();
        for (parent, mut kids) in children {
            // A root, or the children of an open node.
            if parent.as_ref().is_some_and(|p| !open.contains(p)) {
                continue;
            }
            kids.sort_by(|a, b| {
                count
                    .get(&b.id)
                    .cmp(&count.get(&a.id))
                    .then(a.id.cmp(&b.id))
            });
            let more = kids.len().saturating_sub(CAP);
            for mut n in kids.into_iter().take(CAP) {
                n.has_children = sizes.contains_key(&n.id);
                out.push(n);
            }
            if more > 0 {
                let p = parent.clone().unwrap_or_default();
                out.push(ViewTagNode {
                    id: format!("{p}/…"),
                    parent,
                    label: format!("… {more} more — type in Filter to find one"),
                    has_children: false,
                });
            }
        }
        out
    }

    async fn tag_rows(&self, tag_path: String, limit: u32) -> Vec<ViewPaperRow> {
        if tag_path.trim().is_empty() {
            return Vec::new();
        }
        let limit = if limit == 0 { 300 } else { limit };
        crate::backend::tags_service_instance()
            // Newest publication first: date added is the import order, which
            // for a bulk import reads as oldest-first.
            .query_by_tag(tag_path, None, "year".into(), false, limit)
            .await
            .iter()
            .map(row_of)
            .collect()
    }

    async fn resolve_view(&self, reference: String) -> ViewResolution {
        if reference.trim().is_empty() {
            return ViewResolution::default();
        }
        let r =
            crate::sources::resolve_citation(Some(reference), None, None, None, false, true).await;
        let local_id = if r.via.starts_with("local") || r.via == "duplicate" {
            r.paper
                .as_ref()
                .and_then(|p| p.get("id"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string()
        } else {
            String::new()
        };
        let mut rows: Vec<ViewCandidateRow> = r
            .candidates
            .as_deref()
            .unwrap_or_default()
            .iter()
            .map(candidate_row)
            .collect();
        // A paper accepted online is the first row, so it can be imported.
        if local_id.is_empty() {
            if let Some(p) = r.paper.as_ref() {
                let first = candidate_row(p);
                if !first.id.is_empty() && !rows.iter().any(|row| row.id == first.id) {
                    rows.insert(0, first);
                }
            }
        }
        // Found online by an identifier the library's copy does not carry
        // (a bibcode, say, where the copy has a DOI): look again by every
        // identifier the found record has, so it reads as held, not new.
        if local_id.is_empty() && r.via.contains("identifier") {
            if let Some(first) = r.candidates.as_deref().and_then(|c| c.first()) {
                if let Some(id) = held_row_id(first) {
                    let title = rows
                        .first()
                        .map(|row| row.title.clone())
                        .unwrap_or_default();
                    return ViewResolution {
                        via: "local-identifier".into(),
                        verdict: format!("**In your library:** {title}"),
                        local_id: id,
                        rows,
                    };
                }
            }
        }
        let accepted = r.paper.clone().or_else(|| {
            (r.via.contains("high-confidence") || r.via.contains("external-identifier"))
                .then(|| r.candidates.as_deref().and_then(|c| c.first()).cloned())
                .flatten()
        });
        ViewResolution {
            verdict: verdict_of(&r.via, accepted.as_ref(), r.reason.as_deref()),
            via: r.via,
            local_id,
            rows,
        }
    }
}

/// The verdict a person reads for one resolution.
fn verdict_of(via: &str, paper: Option<&serde_json::Value>, reason: Option<&str>) -> String {
    let title = paper
        .and_then(|p| p.get("title"))
        .and_then(|t| t.as_str())
        .map(display_text)
        .unwrap_or_default();
    match via {
        "" => String::new(),
        v if v.starts_with("local") || v == "duplicate" || v == "imported-identifier" => {
            format!("**In your library:** {title}")
        }
        v if v.contains("high-confidence") || v.contains("external-identifier") => {
            format!("**Found online:** {title} — import it below.")
        }
        "search-candidates" => {
            "**No candidate is certain enough to accept.** Choose one below if it is the paper."
                .into()
        }
        _ => format!(
            "**Not found.** {}",
            reason.unwrap_or("No source returned a candidate.")
        ),
    }
}

fn candidate_row(c: &serde_json::Value) -> ViewCandidateRow {
    let text = |k: &str| c.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
    let ids = c.get("ids").and_then(|v| v.as_object());
    let id = ["doi", "arxiv", "bibcode", "pmid", "openalex"]
        .iter()
        .find_map(|k| {
            ids.and_then(|m| m.get(*k))
                .and_then(|v| v.as_str())
                .filter(|v| !v.is_empty())
                .map(|v| format!("{k}:{v}"))
        })
        .unwrap_or_else(|| text("identifier"));
    let authors = c
        .get("authors")
        .and_then(|a| a.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str())
                .collect::<Vec<_>>()
                .join("; ")
        })
        .unwrap_or_default();
    ViewCandidateRow {
        id,
        score: c
            .get("confidence")
            .and_then(|v| v.as_f64())
            .map(|x| format!("{x:.2}"))
            .unwrap_or_default(),
        title: display_text(&text("title")),
        authors: short_authors(&authors),
        year: c
            .get("year")
            .and_then(|v| v.as_i64())
            .map(|y| y.to_string())
            .unwrap_or_default(),
        venue: display_text(&text("venue")),
        source: text("sourceID"),
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

/// The library's copy of a candidate, found by any of its DOI, arXiv id or
/// bibcode.
fn held_row_id(candidate: &serde_json::Value) -> Option<String> {
    let ids = candidate.get("ids")?.as_object()?;
    let pick = |k: &str| -> Vec<String> {
        ids.get(k)
            .and_then(|v| v.as_str())
            .filter(|v| !v.is_empty())
            .map(|v| vec![v.to_string()])
            .unwrap_or_default()
    };
    crate::store_singleton::store_instance()
        .find_by_identifiers_batch(pick("doi"), pick("arxiv"), pick("bibcode"))
        .ok()?
        .into_iter()
        .next()
        .map(|row| row.id)
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
        venue: display_text(p.venue.as_deref().unwrap_or("")),
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

/// BibTeX's protective braces (`{{Title}}`, `{ApJ}`) dropped, as the app
/// does when it draws a title; a brace a backslash escapes, and anything
/// inside a TeX code span the math pass left, is kept.
fn strip_bibtex_braces(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_code = false;
    let mut prev = '\0';
    for c in text.chars() {
        match c {
            '`' => {
                in_code = !in_code;
                out.push(c);
            }
            '{' | '}' if !in_code && prev != '\\' => {}
            _ => out.push(c),
        }
        prev = c;
    }
    out
}

/// A title or abstract for display: entities decoded, math as Unicode
/// where it converts whole, inline markup and BibTeX braces removed.
fn display_text(text: &str) -> String {
    strip_bibtex_braces(&strip_markup(&imbib_core::text::abstract_display_text(
        &clean(text),
    )))
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
        venue: display_text(p.venue.as_deref().unwrap_or("")),
    }
}

/// `text` as one URL path segment: everything but the unreserved
/// characters percent-encoded, byte by byte.
fn path_segment(text: &str) -> String {
    let mut out = String::new();
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
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
    let journal = display_text(&first(&["venue", "journal", "booktitle"]));
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
    // The library's own PDFs, served by the host from where imbib keeps
    // them (`/api/blob/<linked-file id>/<filename>`; the browser's viewer
    // opens them).
    let local: Vec<_> = d
        .linked_files
        .iter()
        .filter(|f| f.is_pdf && f.is_locally_materialized)
        .collect();
    for (n, f) in local.iter().enumerate() {
        let label = if local.len() == 1 {
            "📄 Local PDF".to_string()
        } else {
            format!("📄 Local PDF {}", n + 1)
        };
        links.push(link(
            &label,
            &format!("/api/blob/{}/{}", f.id, path_segment(&f.filename)),
        ));
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
        tags: d
            .tags
            .iter()
            .map(|t| ViewTag {
                id: t.clone(),
                label: t.clone(),
            })
            .collect(),
        // The source's own BibTeX when the paper came with it (S-D5),
        // else what the library exports.
        bibtex: d
            .fields
            .get("raw_bibtex")
            .map(|b| b.trim().to_string())
            .filter(|b| b.starts_with('@'))
            .unwrap_or(bibtex),
        collections: Vec::new(),
        flag: d.flag_color.clone().unwrap_or_default(),
        is_read: d.is_read,
        is_starred: d.is_starred,
    }
}

/// A paper collection with the library that owns it.
struct CollectionEntry {
    id: String,
    name: String,
    /// The owning library's name, empty when none owns it.
    library: String,
    count: i32,
}

impl CollectionEntry {
    fn label(&self) -> String {
        let name = clean(&self.name);
        if self.library.is_empty() {
            name
        } else {
            format!("{} / {name}", self.library)
        }
    }
}

/// Every paper collection: each library's own in picker order, then those
/// no library owns (collections made before libraries owned them).
async fn all_collections() -> Vec<CollectionEntry> {
    let library = library_service_instance();
    let home = home_library().await;
    let mut libraries = library.list_libraries().await;
    libraries.sort_by_key(|l| Some(&l.id) != home.as_ref());
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for lib in libraries {
        for coll in library.list_collections(lib.id.clone()).await {
            seen.insert(coll.id.clone());
            out.push(CollectionEntry {
                id: coll.id,
                name: coll.name,
                library: lib.name.clone(),
                count: coll.publication_count,
            });
        }
    }
    let store = crate::store_singleton::store_instance();
    match tokio::task::spawn_blocking(move || store.list_all_collections()).await {
        Ok(Ok(rows)) => {
            for row in rows {
                if seen.insert(row.id.clone()) {
                    out.push(CollectionEntry {
                        id: row.id,
                        name: row.name,
                        library: String::new(),
                        count: row.publication_count,
                    });
                }
            }
        }
        Ok(Err(e)) => tracing::warn!(error = %e, "listing collections no library owns"),
        Err(e) => tracing::warn!(error = %e, "listing collections no library owns"),
    }
    out
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
            /// `library:<uuid>`, `collection:<uuid>`, `inbox`, or empty for the default library.
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
        /// The feed picker.
        feed_choices() -> Vec<ViewChoice>,
        /// A feed's papers as display rows.
        feed_rows(
            /// The feed's (smart search's) UUID; empty is the first feed.
            feed_id: String,
            /// Free text over title, authors and abstract; empty lists the feed.
            query: String,
            /// The most rows; zero means 200.
            limit: u32
        ) -> Vec<ViewPaperRow>,
        /// The open part of the tag tree as tree-widget rows.
        tag_tree(
            /// The paths whose children to include (the tree's expand state).
            expanded: Option<Vec<String>>,
            /// When not empty, the tags whose path contains it, flat.
            filter: Option<String>
        ) -> Vec<ViewTagNode>,
        /// The papers carrying a tag as display rows.
        tag_rows(
            /// The tag path (`methods/mcmc`); empty answers no rows.
            tag_path: String,
            /// The most rows; zero means 300.
            limit: u32
        ) -> Vec<ViewPaperRow>,
        /// Every paper collection as table rows: name, library, count.
        collection_rows() -> Vec<ViewCollectionRow>,
        /// Every paper collection as picker choices, after "Choose a collection…".
        collection_choices() -> Vec<ViewChoice>,
        /// The saved searches as table rows.
        smart_search_rows() -> Vec<ViewSmartSearchRow>,
        /// Libraries a search can be saved in, as picker choices by bare id.
        smart_search_libraries() -> Vec<ViewChoice>,
        /// Libraries a triaged paper can be kept in, as picker choices.
        keep_libraries() -> Vec<ViewChoice>,
        /// The paper after one in a list, to show once it is triaged away.
        paper_after(
            /// As `paper-rows`' scope, or `feed:<id>` (empty id: the first feed).
            scope: String,
            /// The list's free-text filter.
            query: String,
            /// The paper being triaged.
            id: String,
            /// The list's row limit; zero means 200.
            limit: u32
        ) -> Vec<String>,
        /// Resolve a reference for display, importing nothing.
        resolve_view(
            /// A reference as a bibliography prints it, or a DOI, arXiv id, bibcode or BibTeX entry.
            reference: String
        ) -> ViewResolution,
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
    fn a_file_name_becomes_one_path_segment() {
        assert_eq!(path_segment("Abel_2002.pdf"), "Abel_2002.pdf");
        assert_eq!(path_segment("a b(1)/ü.pdf"), "a%20b%281%29%2F%C3%BC.pdf");
    }

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
    fn bibtex_braces_go_but_escaped_braces_and_code_spans_stay() {
        assert_eq!(
            display_text("{Multiscale cosmic curvature: From {L}ocal structures}"),
            "Multiscale cosmic curvature: From Local structures"
        );
        assert_eq!(
            strip_bibtex_braces(r"a \{b\} `\frac{a}{b}`"),
            r"a \{b\} `\frac{a}{b}`"
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
