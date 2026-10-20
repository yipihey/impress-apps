//! imbib's adoption of the source convention (koine
//! docs/plan-source-convention.md S-D9, S-D10; work package S6).
//!
//! One path to every online database: koine's `source-service` over the
//! seven adapters, the scorer and cascade of `koine-sources`, and the
//! federation's identifier-only merge. This module is what imbib adds on
//! top of that, and nothing more:
//!
//! - [`link`]: the one-time host wiring — the seven adapters registered, the
//!   kind registered, the secret source installed, the contact set — called
//!   from the linked inventory (`impress-capabilities`), the app's FFI
//!   (`imbib-verbs-ffi`) and every daemon that links `imbib-service`.
//! - [`secrets`]: where the adapters' secrets come from. The app pushes its
//!   keychain items into memory at launch ([`set_secret`], the ADR-0029
//!   pattern); a daemon or a bare CLI reads the same keychain items through
//!   `security`; `KOINE_SECRET_*` overrides both.
//! - [`search_sources`] and [`resolve_citation`]: the two
//!   `imbib-app-service` verbs that used to forward to the running Swift app
//!   and refuse when it was closed. They now run here, with the app closed or
//!   open; the app's HTTP routes call them.
//! - [`import_work`]: `imbib-library-service_import-work` (S-D5) — a
//!   `bibliographic-work@1.0.0` becomes an `imbib/bibliography-entry` row
//!   with its provenance kept: `source_id`, `produced_by`, the source's own
//!   BibTeX, the full `ids` map, after the dismissed check.
//!
//! The scorer runs with [`Scorer::legacy`] — the Swift scorer's recorded
//! quirks — so the Swift goldens stay the proof. Switching to
//! `Scorer::corrected` is a separate decision.

use std::collections::BTreeMap;
use std::sync::{Arc, OnceLock, RwLock};

use impress_service_core::pipeline::context::report_refusal;
use impress_service_core::refusal::codes;
use impress_service_core::secrets::{EnvSource, Secret, SecretError, SecretSource};
use koine_sources::cascade::{self, Identifier, LocalLookup, RemoteSearch, Resolution, Via};
use koine_sources::kind::{Author, Issued, Location, Provenance, Version};
use koine_sources::{CitationInput as ScorerInput, Query, Scorer, Work};
use serde_json::{json, Value};
use source_service::adapter::ExportFormat;
use source_service::service::{DefaultSourceService, SourceService};

use imbib_core::unified::shaped_queries::{BibliographyRow, WorkImportInput, WorkImportOutcome};
use imbib_core::unified::store_api::ImbibStore;

use crate::app_service::{CitationInput, CitationResolution, ExternalPaper};
use crate::store_singleton::store_instance;

// ── Host wiring ─────────────────────────────────────────────────────────────

static LINKED: OnceLock<()> = OnceLock::new();

/// Register the seven adapters, the kind and the secret source, once per
/// process. Idempotent; every host that links `imbib-service` calls it, and
/// the inventory's `force_link` calls it for the MCP server, the CLI and the
/// daemons.
pub fn link() {
    LINKED.get_or_init(|| {
        source_service::ensure_linked();
        source_crossref::register();
        source_arxiv::register();
        source_ads::register();
        source_openalex::register();
        source_pubmed::register();
        source_wos::register();
        source_scix::register();
        impress_service_core::secrets::install(Arc::new(ImbibSecretSource));
        if source_service::etiquette::contact().is_none() {
            if let Some(contact) = secrets::keychain_contact() {
                source_service::etiquette::set_contact(contact);
            }
        }
        tracing::info!(target: "sources", "source adapters registered: {}", source_service::registry::global().sources().join(", "));
    });
}

/// The registered source ids, in registration order.
pub fn sources() -> Vec<String> {
    link();
    source_service::registry::global().sources()
}

// ── Secrets ─────────────────────────────────────────────────────────────────

/// What the app pushes at launch (ADR-0029: secrets in Rust memory, never in
/// a file) and what a daemon reads through `security`.
pub mod secrets {
    use super::*;

    /// koine secret name → the imbib source id whose keychain item holds it.
    /// The items are `com.imbib.credentials.<source>.apiKey`, written by
    /// imbib's `CredentialManager`.
    pub const KEYCHAIN_ITEMS: &[(&str, &str)] = &[
        ("ads-token", "ads"),
        ("scix-token", "scix"),
        ("wos-api-key", "wos"),
        ("ncbi-api-key", "pubmed"),
        ("crossref-plus-token", "crossref"),
    ];

    /// The keychain prefix `CredentialManager` uses.
    pub const KEYCHAIN_PREFIX: &str = "com.imbib.credentials";

    pub(super) static MEMORY: RwLock<BTreeMap<String, String>> = RwLock::new(BTreeMap::new());

    /// The keychain account for a koine secret name, when imbib keeps one.
    pub fn keychain_account(name: &str) -> Option<String> {
        KEYCHAIN_ITEMS
            .iter()
            .find(|(koine, _)| *koine == name)
            .map(|(_, source)| format!("{KEYCHAIN_PREFIX}.{source}.apiKey"))
    }

    /// One `security find-generic-password -a <account> -w`. `None` when the
    /// tool is absent, the item is absent, or this process may not read it
    /// (the items are ACL'd to imbib's signature; another host is prompted
    /// or refused, and a refusal is a miss here, never a hang: stdin is
    /// closed).
    pub fn read_keychain(account: &str) -> Option<String> {
        let security = std::path::Path::new("/usr/bin/security");
        if !security.exists() {
            return None;
        }
        let output = std::process::Command::new(security)
            .args(["find-generic-password", "-a", account, "-w"])
            .stdin(std::process::Stdio::null())
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let text = String::from_utf8(output.stdout).ok()?;
        let value = text.trim().to_string();
        (!value.is_empty()).then_some(value)
    }

    /// The polite-pool contact imbib already keeps: the email stored for
    /// OpenAlex or Crossref (`com.imbib.credentials.<source>.email`).
    pub fn keychain_contact() -> Option<String> {
        ["openalex", "crossref"]
            .iter()
            .find_map(|source| read_keychain(&format!("{KEYCHAIN_PREFIX}.{source}.email")))
    }
}

/// Push one secret into memory (the app, at launch and whenever a credential
/// changes). An empty value clears it.
pub fn set_secret(name: &str, value: &str) {
    let mut slot = secrets::MEMORY.write().unwrap_or_else(|e| e.into_inner());
    if value.trim().is_empty() {
        slot.remove(name);
    } else {
        slot.insert(name.to_string(), value.trim().to_string());
    }
}

/// Name the contact the adapters send (the user's email for polite pools).
pub fn set_contact(contact: &str) {
    source_service::etiquette::set_contact(contact);
}

/// Memory (app-pushed) → environment (`KOINE_SECRET_*`) → imbib's keychain.
#[derive(Default)]
pub struct ImbibSecretSource;

impl SecretSource for ImbibSecretSource {
    fn get(&self, name: &str) -> Option<Secret> {
        if let Some(v) = secrets::MEMORY
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .get(name)
        {
            return Some(Secret::new(v.clone()));
        }
        if let Some(s) = EnvSource.get(name) {
            return Some(s);
        }
        let account = secrets::keychain_account(name)?;
        secrets::read_keychain(&account).map(Secret::new)
    }

    fn names(&self) -> Vec<String> {
        let mut names: Vec<String> = secrets::MEMORY
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .keys()
            .cloned()
            .collect();
        for n in EnvSource.names() {
            if !names.contains(&n) {
                names.push(n);
            }
        }
        names
    }

    fn set(&self, name: &str, value: &str) -> Result<(), SecretError> {
        if !impress_service_core::secrets::is_secret_name(name) {
            return Err(SecretError::InvalidName(name.to_string()));
        }
        set_secret(name, value);
        Ok(())
    }

    fn remove(&self, name: &str) -> Result<(), SecretError> {
        set_secret(name, "");
        Ok(())
    }

    fn source_of(&self, name: &str) -> Option<&'static str> {
        if secrets::MEMORY
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .contains_key(name)
        {
            return Some("app");
        }
        if EnvSource.get(name).is_some() {
            return Some("env");
        }
        secrets::keychain_account(name)
            .and_then(|a| secrets::read_keychain(&a))
            .map(|_| "keychain")
    }
}

// ── Work ↔ imbib shapes ─────────────────────────────────────────────────────

/// The year of a work, from `issued`.
pub fn year_of(work: &Work) -> Option<i32> {
    work.issued
        .as_ref()
        .and_then(|i| i.date_parts.first())
        .and_then(|p| p.first())
        .copied()
}

/// `Family, Given` per author, as imbib's search rows spell them.
pub fn author_strings(work: &Work) -> Vec<String> {
    work.author
        .iter()
        .map(|a| match (&a.family, &a.given) {
            (Some(f), Some(g)) if !g.is_empty() => format!("{f}, {g}"),
            (Some(f), _) => f.clone(),
            (None, Some(g)) => g.clone(),
            (None, None) => String::new(),
        })
        .filter(|s| !s.is_empty())
        .collect()
}

fn id_of<'a>(work: &'a Work, kind: &str) -> Option<&'a str> {
    let v = if kind == "doi" {
        work.doi
            .as_deref()
            .or(work.ids.get("doi").map(String::as_str))
    } else {
        work.ids.get(kind).map(String::as_str)
    };
    v.map(str::trim).filter(|s| !s.is_empty())
}

/// The source a work came from (its provenance, else its primary location).
pub fn source_of(work: &Work) -> String {
    cascade::source_of(work).to_string()
}

/// The identifier `import-identifiers` would take: DOI, then arXiv, then
/// bibcode — the rule the Swift `bestIdentifier` applied.
pub fn best_identifier(work: &Work) -> Option<String> {
    ["doi", "arxiv", "bibcode"]
        .iter()
        .find_map(|k| id_of(work, k).map(str::to_string))
}

/// One search row for the `search_sources` verb.
pub fn work_to_external_paper(work: &Work) -> ExternalPaper {
    ExternalPaper {
        title: work.title.clone().unwrap_or_default(),
        identifier: best_identifier(work).or_else(|| work.title.clone()),
        authors: author_strings(work),
        year: year_of(work).map(i64::from),
        venue: work.container_title.clone(),
        doi: id_of(work, "doi").map(str::to_string),
        arxiv_id: id_of(work, "arxiv").map(str::to_string),
        bibcode: id_of(work, "bibcode").map(str::to_string),
        abstract_text: work.abstract_.clone(),
        source: Some(source_of(work)),
        ids: work.ids.clone(),
        provenance: work.provenance.clone(),
    }
}

/// A library row as a work, so the cascade scores it like a remote hit. The
/// row's id travels in a `local` location, which is how an accepted local
/// hit maps back to its paper.
pub fn row_to_work(row: &BibliographyRow) -> Work {
    let mut ids = BTreeMap::new();
    for (kind, value) in [
        ("doi", &row.doi),
        ("arxiv", &row.arxiv_id),
        ("bibcode", &row.bibcode),
    ] {
        if let Some(v) = value.as_deref().map(str::trim).filter(|v| !v.is_empty()) {
            ids.insert(kind.to_string(), v.to_string());
        }
    }
    let author = row
        .author_string
        .split(" and ")
        .map(|a| a.trim())
        .filter(|a| !a.is_empty())
        .map(|a| match a.split_once(',') {
            Some((family, given)) => Author {
                family: Some(family.trim().to_string()),
                given: Some(given.trim().to_string()).filter(|g| !g.is_empty()),
                orcid: None,
            },
            None => Author {
                family: Some(a.to_string()),
                given: None,
                orcid: None,
            },
        })
        .collect();
    Work {
        ty: "article-journal".into(),
        title: Some(row.title.clone()),
        author,
        issued: row.year.map(|y| Issued {
            date_parts: vec![vec![y]],
        }),
        container_title: row.venue.clone(),
        abstract_: row.abstract_text.clone(),
        doi: ids.get("doi").cloned(),
        ids,
        locations: vec![Location {
            source: "local".into(),
            source_id: row.id.clone(),
            version: Version::Published,
            url: None,
            pdf: None,
            license: None,
            oa_status: None,
            primary: true,
        }],
        provenance: Some(Provenance {
            fetched_at: String::new(),
            source: "local".into(),
            source_id: row.id.clone(),
            query: None,
            sources: vec![],
        }),
        ..Default::default()
    }
}

/// The library row id a local work carries, if it is one.
fn local_row_id(work: &Work) -> Option<String> {
    work.locations
        .iter()
        .find(|l| l.source == "local")
        .map(|l| l.source_id.clone())
}

// ── search ──────────────────────────────────────────────────────────────────

/// The canonical query for one search string: an identifier is an exact
/// clause on its kind, a native ADS string is passed through, anything else
/// is `any any`.
pub fn query_for(text: &str) -> Query {
    let text = text.trim();
    if let Some(id) = source_service::ids::parse(text) {
        return Query::clause(id.kind.clone(), "=", id.value.clone());
    }
    imbib_core::unified::smart_search_query::query_of(text)
}

fn split_sources(sources: Option<String>) -> Option<Vec<String>> {
    let list: Vec<String> = sources?
        .split(',')
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty())
        .collect();
    (!list.is_empty()).then_some(list)
}

/// `imbib-sources-service_search-sources`: one federated search over the
/// registered adapters (S-D7), bounded at 100 rows per source, every row
/// carrying its `ids` and `provenance`. Diagnostics are logged under
/// `sources`; a refused call (an unknown source, an empty query) is reported
/// as a refusal.
pub async fn search_sources(
    query: String,
    sources: Option<String>,
    limit: u32,
) -> Vec<ExternalPaper> {
    link();
    let text = query.trim().to_string();
    if text.is_empty() {
        report_refusal(codes::INVALID_ARGUMENT, "search_sources: `query` is empty");
        return vec![];
    }
    let limit = limit.clamp(1, source_service::service::MAX_LIMIT);
    let wanted = split_sources(sources);
    let canonical = query_for(&text);
    tracing::info!(target: "sources", "search_sources: query={:?} sources={:?} limit={limit}", text, wanted);
    let service = DefaultSourceService::new();
    let result = service
        .search(canonical, wanted, Some(limit), None, None, None)
        .await;
    if !result.outcome.ok {
        report_refusal(
            result
                .outcome
                .code
                .clone()
                .unwrap_or_else(|| codes::VERB_FAILED.to_string()),
            result
                .outcome
                .message
                .clone()
                .unwrap_or_else(|| "search_sources refused".into()),
        );
        return vec![];
    }
    let answer = result.answer.unwrap_or_default();
    for d in &answer.diagnostics {
        tracing::info!(target: "sources", "search_sources: {} {:?} {}", d.source, d.status, d.detail);
    }
    let rows: Vec<ExternalPaper> = answer.rows.iter().map(work_to_external_paper).collect();
    tracing::info!(target: "sources", "search_sources: {} row(s) from {} source(s)", rows.len(), answer.diagnostics.iter().filter(|d| d.status == koine_sources::Status::Done).count());
    rows
}

// ── resolve ─────────────────────────────────────────────────────────────────

/// The library's rows, for the cascade's steps 1 and 2.
struct StoreLookup {
    store: Arc<ImbibStore>,
}

impl LocalLookup for StoreLookup {
    fn by_identifier(&self, id: &Identifier) -> Option<Work> {
        let rows = match id.kind.as_str() {
            "doi" => self.store.find_by_doi(id.value.clone()),
            "arxiv" => self.store.find_by_arxiv(id.value.clone()),
            "bibcode" => self.store.find_by_bibcode(id.value.clone()),
            _ => return None,
        }
        .ok()?;
        rows.first().map(row_to_work)
    }

    fn search_text(&self, query: &str, limit: usize) -> Vec<Work> {
        self.store
            .search_publications(
                query.to_string(),
                None,
                "dateAdded".into(),
                false,
                Some(limit as u32),
                None,
            )
            .map(|rows| rows.iter().map(row_to_work).collect())
            .unwrap_or_default()
    }
}

/// The online sources, for the cascade's steps 1 and 3. The cascade is a
/// pure, synchronous function; it runs on a blocking thread and these
/// methods drive the async service from there.
struct RemoteSources {
    handle: tokio::runtime::Handle,
    service: DefaultSourceService,
    sources: Option<Vec<String>>,
}

impl RemoteSearch for RemoteSources {
    fn fetch(&self, id: &Identifier) -> Option<Work> {
        let canonical = format!("{}:{}", id.kind, id.value);
        let result = self.handle.block_on(self.service.fetch(
            canonical.clone(),
            self.sources.clone(),
            None,
        ));
        match result.answer {
            Some(answer) => {
                tracing::info!(target: "sources", "resolve: fetched {canonical} from {}", source_of(&answer.work));
                Some(answer.work)
            }
            None => {
                tracing::info!(target: "sources", "resolve: {canonical} not fetched: {}", result.outcome.message.unwrap_or_default());
                None
            }
        }
    }

    fn search(&self, citation: &ScorerInput, limit: usize) -> Vec<Work> {
        let Some(query) = structured_query(citation) else {
            return vec![];
        };
        tracing::info!(target: "sources", "resolve: search {}", serde_json::to_string(&query).unwrap_or_default());
        let result = self.handle.block_on(self.service.search(
            query,
            self.sources.clone(),
            Some((limit as u32).clamp(1, source_service::service::MAX_LIMIT)),
            None,
            None,
            None,
        ));
        let Some(answer) = result.answer else {
            tracing::warn!(target: "sources", "resolve: search refused: {}", result.outcome.message.unwrap_or_default());
            return vec![];
        };
        for d in &answer.diagnostics {
            tracing::info!(target: "sources", "resolve: {} {:?} {}", d.source, d.status, d.detail);
        }
        tracing::info!(target: "sources", "resolve: search returned {} row(s)", answer.rows.len());
        answer.rows
    }
}

/// The surname the scorer would use for an author string: the part before
/// the comma, else the last token (the legacy rule).
fn surname(author: &str) -> String {
    let a = author.trim();
    match a.split_once(',') {
        Some((family, _)) => family.trim().to_string(),
        None => a.split_whitespace().last().unwrap_or("").to_string(),
    }
}

/// Title words worth asking a source for: four letters or more, no
/// stopwords — the rule the Swift ADS query builder applied.
fn title_words(title: &str) -> Vec<String> {
    const STOP: &[&str] = &[
        "about", "after", "again", "being", "between", "could", "every", "first", "from", "have",
        "into", "more", "most", "other", "over", "some", "such", "than", "that", "their", "them",
        "then", "there", "these", "they", "this", "through", "under", "using", "very", "what",
        "when", "where", "which", "while", "with", "within", "would", "your", "toward", "towards",
        "based", "study", "analysis",
    ];
    title
        .split(|c: char| !c.is_alphanumeric() && c != '-')
        .map(|w| w.trim_matches('-').to_lowercase())
        .filter(|w| w.chars().count() >= 4 && !STOP.contains(&w.as_str()))
        .collect()
}

/// The structured query of a citation (S-D6 step 3): first author, year,
/// the title's distinctive words; a free-text `any` when the fields are
/// empty.
pub fn structured_query(citation: &ScorerInput) -> Option<Query> {
    let mut parts = Vec::new();
    if let Some(first) = citation.authors.first() {
        let s = surname(first);
        if !s.is_empty() {
            parts.push(Query::clause("author", "any", s));
        }
    }
    if let Some(year) = citation.year {
        parts.push(Query::clause("year", "=", year.to_string()));
    }
    if let Some(title) = citation.title.as_deref() {
        let words = title_words(title);
        if !words.is_empty() {
            parts.push(Query::clause("title", "any", words.join(" ")));
        }
    }
    if parts.is_empty() {
        let text = citation
            .free_text
            .as_deref()
            .or(citation.raw_bibtex.as_deref())
            .map(str::trim)
            .filter(|t| !t.is_empty())?;
        return Some(Query::clause(
            "any",
            "any",
            text.chars().take(200).collect::<String>(),
        ));
    }
    Some(if parts.len() == 1 {
        parts.pop().expect("one part")
    } else {
        Query::And { and: parts }
    })
}

fn scorer_input(
    query: Option<String>,
    bibtex: Option<String>,
    citation: Option<CitationInput>,
) -> ScorerInput {
    match citation {
        Some(c) => ScorerInput {
            authors: c.authors,
            title: c.title,
            year: c.year.and_then(|y| i32::try_from(y).ok()),
            journal: c.journal,
            volume: c.volume,
            pages: c.pages,
            doi: c.doi,
            arxiv: c.arxiv,
            bibcode: c.bibcode,
            raw_bibtex: c.raw_bibtex.or(bibtex),
            free_text: c.free_text.or(query),
        },
        None => {
            let free_text = query.filter(|q| !q.trim().is_empty());
            let (authors, year, journal, title) = free_text
                .as_deref()
                .map(fields_of_reference)
                .unwrap_or_default();
            ScorerInput {
                authors,
                year,
                journal,
                title,
                raw_bibtex: bibtex.filter(|b| !b.trim().is_empty()),
                free_text,
                ..Default::default()
            }
        }
    }
}

/// What the scorer can use of a reference written as one line (`Bromm, V.,
/// Coppi, P. S., & Larson, R. B. 2002, ApJ, 564, 23, The Formation of the
/// First Stars`): the first year, the surnames before it (`Surname, I.`
/// pairs, or `Surname et al.`), the journal (the first short, non-numeric
/// fragment after the year: `ApJ`, `Science 295`), and the first fragment of
/// three or more words after the year as the title. A line that carries none of these
/// stays a free-text search; nothing here is a reference parser.
pub fn fields_of_reference(
    text: &str,
) -> (Vec<String>, Option<i32>, Option<String>, Option<String>) {
    use std::sync::LazyLock;
    static YEAR: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"\b(1[89]\d\d|20\d\d)[a-z]?\b").expect("static regex"));
    static SURNAME: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(
            r"(?:^|[,&;]|\band\b)\s*([A-Z][\p{L}'\-]+(?:\s[A-Z][\p{L}'\-]+)?),\s*(?:[A-Z]\.\s*)+",
        )
        .expect("static regex")
    });
    static ET_AL: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"^\s*([A-Z][\p{L}'\-]+)\s+et\s+al").expect("static regex")
    });
    let text = text.trim();
    let Some(year_match) = YEAR.find(text) else {
        return (vec![], None, None, None);
    };
    let year = year_match.as_str()[..4].parse::<i32>().ok();
    let before = &text[..year_match.start()];
    let after = &text[year_match.end()..];
    let mut authors: Vec<String> = SURNAME
        .captures_iter(before)
        .map(|c| c[1].trim().to_string())
        .collect();
    if authors.is_empty() {
        if let Some(c) = ET_AL.captures(before) {
            authors.push(c[1].to_string());
        }
    }
    let fragments: Vec<&str> = after
        .split([',', ';'])
        .map(str::trim)
        .filter(|f| !f.is_empty())
        .collect();
    let title = fragments
        .iter()
        .flat_map(|f| f.split('.'))
        .map(str::trim)
        .find(|f| f.split_whitespace().count() >= 3)
        .map(|f| f.to_string());
    // The journal: the first fragment before the title that is not a
    // number (volume, pages) and is at most three words (`ApJ`, `Science
    // 295`, `Phys. Rev. D`).
    let is_number = |f: &str| {
        !f.is_empty()
            && f.chars()
                .all(|c| c.is_ascii_digit() || c == '-' || c == '\u{2013}')
    };
    let journal = fragments
        .iter()
        .take_while(|f| {
            title
                .as_deref()
                .is_none_or(|t| !f.trim_end_matches('.').starts_with(t))
        })
        .find(|f| !is_number(f) && f.split_whitespace().count() <= 3)
        .map(|f| f.trim_end_matches('.').to_string());
    (authors, year, journal, title)
}

/// One candidate as the HTTP route has always emitted it (flat, with
/// `confidence`), plus the scorer's `evidence` and the work's `ids`.
fn candidate_json(c: &cascade::Candidate) -> Value {
    let p = work_to_external_paper(&c.work);
    let mut v = json!({
        "title": p.title,
        "authors": p.authors,
        "venue": p.venue.clone().unwrap_or_default(),
        "abstract": p.abstract_text.clone().unwrap_or_default(),
        "sourceID": p.source.clone().unwrap_or_default(),
        "identifier": p.identifier.clone().unwrap_or_default(),
        "confidence": c.score,
        "evidence": c.evidence.terms().into_iter().collect::<BTreeMap<_, _>>(),
        "ids": c.work.ids,
    });
    if let Some(y) = p.year {
        v["year"] = json!(y);
    }
    if let Some(d) = &p.doi {
        v["doi"] = json!(d);
    }
    if let Some(a) = &p.arxiv_id {
        v["arxivID"] = json!(a);
    }
    if let Some(b) = &p.bibcode {
        v["bibcode"] = json!(b);
    }
    v
}

/// The paper dictionary of a library row, in the keys `/api/papers/resolve`
/// has always used (`citeKey`, `arxivID`, …).
fn paper_json(store: &ImbibStore, id: &str) -> Option<Value> {
    let detail = store
        .get_publication_detail(id.to_string())
        .ok()
        .flatten()?;
    let f = |k: &str| detail.fields.get(k).cloned();
    let authors: Vec<String> = detail
        .authors
        .iter()
        .map(|a| match &a.given_name {
            Some(g) if !g.is_empty() => format!("{}, {g}", a.family_name),
            _ => a.family_name.clone(),
        })
        .collect();
    let has_pdf = store
        .count_pdfs(id.to_string())
        .map(|n| n > 0)
        .unwrap_or(false);
    let bibtex = detail
        .raw_bibtex
        .clone()
        .or_else(|| store.export_bibtex(vec![id.to_string()]).ok());
    let mut v = json!({
        "id": detail.id,
        "citeKey": detail.cite_key,
        "title": f("title").unwrap_or_default(),
        "authors": authors,
        "isRead": detail.is_read,
        "isStarred": detail.is_starred,
        "hasPDF": has_pdf,
        "tags": detail.tags.iter().map(|t| t.path.clone()).collect::<Vec<_>>(),
        "collectionIDs": detail.collections,
        "libraryIDs": detail.libraries,
    });
    if let Some(b) = bibtex {
        v["bibtex"] = json!(b);
    }
    if let Some(y) = f("year").and_then(|y| y.parse::<i64>().ok()) {
        v["year"] = json!(y);
    }
    for (key, field) in [
        ("venue", "venue"),
        ("abstract", "abstract_text"),
        ("doi", "doi"),
        ("arxivID", "arxiv_id"),
        ("bibcode", "bibcode"),
        ("pmid", "pmid"),
        ("sourceID", "source_id"),
    ] {
        if let Some(value) = f(field).filter(|s| !s.is_empty()) {
            v[key] = json!(value);
        }
    }
    Some(v)
}

/// `imbib-sources-service_resolve-citation`: koine's cascade (S-D6) over the
/// library and the registered sources, scored with the legacy quirks. An
/// accepted hit that is not yet in the library is imported through
/// [`import_work`] — the contract of `/api/papers/resolve` is that the paper
/// exists after the call — and `download_pdfs` then asks the running app for
/// its PDF (nothing happens with the app closed; the row is still there).
/// Below threshold, the scored candidates come back for a person or an
/// agent to choose.
pub async fn resolve_citation(
    query: Option<String>,
    bibtex: Option<String>,
    citation: Option<CitationInput>,
    library_id: Option<String>,
    download_pdfs: bool,
    preview: bool,
) -> CitationResolution {
    link();
    let store = store_instance();
    // A bare token is first tried as a cite key (`@Abel2002` from a
    // manuscript): cite keys are not searchable text, so the cascade alone
    // would send a key the library holds to the network.
    if citation.is_none() {
        if let Some(key) = query
            .as_deref()
            .map(str::trim)
            .filter(|q| !q.is_empty() && !q.contains(char::is_whitespace))
        {
            let key = key.trim_start_matches('@');
            if let Ok(Some(row)) = store.find_by_cite_key(key.to_string(), None) {
                tracing::info!(target: "sources", "resolve: cite key {key} is in the library");
                return CitationResolution {
                    via: "local-cite-key".into(),
                    paper: paper_json(&store, &row.id),
                    candidates: None,
                    reason: None,
                };
            }
        }
    }
    let input = scorer_input(query, bibtex, citation);
    let empty = input.authors.is_empty()
        && input.title.as_deref().is_none_or(str::is_empty)
        && input.doi.is_none()
        && input.arxiv.is_none()
        && input.bibcode.is_none()
        && input.raw_bibtex.as_deref().is_none_or(str::is_empty)
        && input.free_text.as_deref().is_none_or(str::is_empty);
    if empty {
        return CitationResolution {
            via: "not-found".into(),
            paper: None,
            candidates: None,
            reason: Some(
                "Citation had no authors, title, identifier, rawBibtex, or freeText — nothing to search with"
                    .into(),
            ),
        };
    }
    tracing::info!(
        target: "sources",
        "resolve: authors={} year={:?} title={} id={}",
        input.authors.len(),
        input.year,
        input.title.as_deref().map(|t| !t.is_empty()).unwrap_or(false),
        input.doi.is_some() || input.arxiv.is_some() || input.bibcode.is_some()
    );
    let handle = tokio::runtime::Handle::current();
    let cascade_store = store.clone();
    let cascade_input = input.clone();
    let resolution: Resolution = match tokio::task::spawn_blocking(move || {
        let local = StoreLookup {
            store: cascade_store,
        };
        let remote = RemoteSources {
            handle,
            service: DefaultSourceService::new(),
            sources: None,
        };
        cascade::resolve(&Scorer::legacy(), &cascade_input, &local, &remote)
    })
    .await
    {
        Ok(r) => r,
        Err(e) => {
            report_refusal(codes::INTERNAL, format!("resolve_citation: {e}"));
            return CitationResolution::unavailable(format!("resolve_citation failed: {e}"));
        }
    };
    tracing::info!(
        target: "sources",
        "resolve: via={:?} accepted={:?} rule={:?} candidates={}",
        resolution.via,
        resolution.accepted,
        resolution.rule.map(|r| r.as_str()),
        resolution.candidates.len()
    );

    let accepted = resolution
        .accepted
        .and_then(|i| resolution.candidates.get(i))
        .cloned();
    match (resolution.via, accepted) {
        (Via::NotFound, _) | (_, None) => {
            if resolution.candidates.is_empty() {
                let missing: Vec<String> = ["ads", "scix", "wos"]
                    .iter()
                    .filter(|s| {
                        let name = match **s {
                            "ads" => "ads-token",
                            "scix" => "scix-token",
                            _ => "wos-api-key",
                        };
                        impress_service_core::secrets::get(name).is_none()
                    })
                    .map(|s| s.to_string())
                    .collect();
                let reason = if missing.is_empty() {
                    "No external source returned a confident match for this citation".to_string()
                } else {
                    format!(
                        "No relevant matches. No API key for {} (imbib Settings → Sources). Consider configuring ADS to improve results for astronomy papers.",
                        missing.join(", ")
                    )
                };
                CitationResolution {
                    via: "not-found".into(),
                    paper: None,
                    candidates: None,
                    reason: Some(reason),
                }
            } else {
                CitationResolution {
                    via: "search-candidates".into(),
                    paper: None,
                    candidates: Some(resolution.candidates.iter().map(candidate_json).collect()),
                    reason: None,
                }
            }
        }
        (via, Some(candidate)) => {
            if let Some(row_id) = local_row_id(&candidate.work) {
                let name = match via {
                    Via::Identifier => "local-identifier",
                    _ => "local-text",
                };
                return CitationResolution {
                    via: name.into(),
                    paper: paper_json(&store, &row_id),
                    candidates: None,
                    reason: None,
                };
            }
            if preview {
                // The smart-search paste: nothing is written; the person
                // confirms with Add Selected.
                let name = match via {
                    Via::Identifier => "external-identifier-preview",
                    _ => "search-high-confidence-preview",
                };
                return CitationResolution {
                    via: name.into(),
                    paper: None,
                    candidates: Some(vec![candidate_json(&candidate)]),
                    reason: None,
                };
            }
            // A remote hit: import it with its provenance (S-D5).
            let outcome = import_work(candidate.work.clone(), library_id, None).await;
            let (via_name, id) = match (via, outcome.imported_id, outcome.existing_id) {
                (_, _, Some(existing)) => ("duplicate", Some(existing)),
                (Via::Identifier, Some(id), _) => ("imported-identifier", Some(id)),
                (_, Some(id), _) => ("search-high-confidence", Some(id)),
                _ => ("search-candidates", None),
            };
            let Some(id) = id else {
                let reason = if outcome.dismissed {
                    Some("The matching paper was dismissed; it is not re-imported".to_string())
                } else {
                    None
                };
                return CitationResolution {
                    via: via_name.into(),
                    paper: None,
                    candidates: Some(resolution.candidates.iter().map(candidate_json).collect()),
                    reason,
                };
            };
            if download_pdfs {
                let downloaded = crate::backend::app_service_instance()
                    .download_pdfs(vec![id.clone()])
                    .await;
                tracing::info!(target: "sources", "resolve: pdf download asked for {id}: {downloaded}");
            }
            CitationResolution {
                via: via_name.into(),
                paper: paper_json(&store, &id),
                candidates: None,
                reason: None,
            }
        }
    }
}

// ── import ──────────────────────────────────────────────────────────────────

/// A BibTeX entry built from the work's fields, for a source that exports
/// none. Marked `synthesized`: the row keeps no `raw_bibtex` from it.
pub fn synthesize_bibtex(work: &Work) -> String {
    let year = year_of(work);
    let first = work
        .author
        .first()
        .and_then(|a| a.family.clone())
        .unwrap_or_else(|| "Unknown".into());
    let key = imbib_core::identifiers::generate_cite_key(
        Some(first),
        year.map(|y| y.to_string()),
        work.title.clone(),
    );
    let esc = |s: &str| s.replace('{', "\\{").replace('}', "\\}");
    let mut fields: Vec<(String, String)> = Vec::new();
    if let Some(t) = &work.title {
        fields.push(("title".into(), format!("{{{}}}", t)));
    }
    let authors = author_strings(work);
    if !authors.is_empty() {
        fields.push(("author".into(), authors.join(" and ")));
    }
    if let Some(y) = year {
        fields.push(("year".into(), y.to_string()));
    }
    if let Some(j) = &work.container_title {
        fields.push(("journal".into(), esc(j)));
    }
    if let Some(v) = &work.volume {
        fields.push(("volume".into(), v.clone()));
    }
    if let Some(n) = &work.issue {
        fields.push(("number".into(), n.clone()));
    }
    if let Some(p) = &work.page {
        fields.push(("pages".into(), p.clone()));
    }
    if let Some(d) = id_of(work, "doi") {
        fields.push(("doi".into(), d.to_string()));
    }
    if let Some(a) = id_of(work, "arxiv") {
        fields.push(("eprint".into(), a.to_string()));
        fields.push(("archivePrefix".into(), "arXiv".into()));
    }
    if let Some(b) = id_of(work, "bibcode") {
        fields.push((
            "adsurl".into(),
            format!("https://ui.adsabs.harvard.edu/abs/{b}"),
        ));
    }
    if let Some(abs) = &work.abstract_ {
        fields.push(("abstract".into(), esc(abs)));
    }
    let ty = match work.ty.as_str() {
        "paper-conference" => "inproceedings",
        "book" => "book",
        "chapter" => "incollection",
        "thesis" => "phdthesis",
        "report" => "techreport",
        _ => "article",
    };
    let body: Vec<String> = fields
        .iter()
        .map(|(k, v)| format!("  {k} = {{{v}}}"))
        .collect();
    format!("@{ty}{{{key},\n{}\n}}\n", body.join(",\n"))
}

/// The source's own BibTeX for a work (`source-service_export bibtex`): the
/// id its own source claims first, then any other. `None` when no source
/// exported one.
pub async fn source_bibtex(work: &Work) -> Option<String> {
    let source = source_of(work);
    let mut ids: Vec<String> = Vec::new();
    let mut push = |kind: &str| {
        if let Some(v) = id_of(work, kind) {
            ids.push(format!("{kind}:{v}"));
        }
    };
    match source.as_str() {
        "ads" | "scix" => {
            push("bibcode");
            push("doi");
            push("arxiv");
        }
        "arxiv" => {
            push("arxiv");
            push("doi");
        }
        _ => {
            push("doi");
            push("arxiv");
            push("bibcode");
            push("pmid");
        }
    }
    let service = DefaultSourceService::new();
    for id in ids {
        let result = service.export(vec![id.clone()], ExportFormat::Bibtex).await;
        if let Some(answer) = result.answer {
            let text = answer.text.trim().to_string();
            if answer.count > 0 && text.starts_with('@') {
                tracing::info!(target: "sources", "import: bibtex for {id} from the source");
                return Some(text);
            }
            for d in &answer.diagnostics {
                tracing::info!(target: "sources", "import: export {id}: {} {:?} {}", d.source, d.status, d.detail);
            }
        }
    }
    None
}

/// What the store is handed for a work (S-D5): the BibTeX, whether it was
/// synthesized, the source, the full `ids` map (the top-level `DOI` folded
/// in), the provenance verbatim and the producing call.
pub fn work_import_input(
    work: &Work,
    bibtex: String,
    synthesized: bool,
    produced_by: Option<String>,
) -> WorkImportInput {
    let mut ids = work.ids.clone();
    if let Some(doi) = work.doi.as_deref().map(str::trim).filter(|d| !d.is_empty()) {
        ids.entry("doi".into()).or_insert_with(|| doi.to_string());
    }
    WorkImportInput {
        bibtex,
        synthesized,
        source_id: source_of(work),
        source_record_id: work.provenance.as_ref().map(|p| p.source_id.clone()),
        ids,
        provenance_json: work
            .provenance
            .as_ref()
            .and_then(|p| serde_json::to_string(p).ok()),
        produced_by,
        abstract_text: work.abstract_.clone(),
    }
}

/// `imbib-library-service_import-work` (S-D5): the row is made here, with
/// its provenance. `library` defaults to the default library.
pub async fn import_work(
    work: Work,
    library_id: Option<String>,
    collection_id: Option<String>,
) -> WorkImportOutcome {
    link();
    if let Err(message) = work.validate() {
        report_refusal(codes::INVALID_ARGUMENT, format!("import_work: {message}"));
        return WorkImportOutcome::default();
    }
    let store = store_instance();
    let library_id = match library_id.filter(|l| !l.trim().is_empty()) {
        Some(l) => l,
        None => match store.get_default_library() {
            Ok(Some(lib)) => lib.id,
            _ => {
                report_refusal(
                    codes::NOT_FOUND,
                    "import_work: no default library; pass `library`",
                );
                return WorkImportOutcome::default();
            }
        },
    };
    let source = source_of(&work);
    tracing::info!(
        target: "sources",
        "import: mutation requested: source={source} ids={:?} title={:?} library={library_id}",
        work.ids,
        work.title.as_deref().unwrap_or("")
    );
    let (bibtex, synthesized) = match source_bibtex(&work).await {
        Some(text) => (text, false),
        None => (synthesize_bibtex(&work), true),
    };
    let input = work_import_input(
        &work,
        bibtex,
        synthesized,
        impress_service_core::pipeline::context::current_call_id(),
    );
    let outcome = match store.import_work(input, library_id, collection_id) {
        Ok(o) => o,
        Err(e) => {
            report_refusal(codes::VERB_FAILED, format!("import_work: {e}"));
            return WorkImportOutcome::default();
        }
    };
    tracing::info!(
        target: "sources",
        "import: save: imported={:?} existing={:?} dismissed={} synthesized_bibtex={synthesized}",
        outcome.imported_id,
        outcome.existing_id,
        outcome.dismissed
    );
    if let Some(id) = &outcome.imported_id {
        if let Ok(Some(detail)) = store.get_publication_detail(id.clone()) {
            tracing::info!(
                target: "sources",
                "import: display: {} source_id={:?} raw_bibtex={}",
                detail.cite_key,
                detail.fields.get("source_id"),
                detail.raw_bibtex.is_some()
            );
        }
    }
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    fn work(title: &str, doi: Option<&str>) -> Work {
        let mut w = Work {
            ty: "article-journal".into(),
            title: Some(title.into()),
            author: vec![Author {
                family: Some("Abel".into()),
                given: Some("Tom".into()),
                orcid: None,
            }],
            issued: Some(Issued {
                date_parts: vec![vec![2002]],
            }),
            container_title: Some("Science".into()),
            ..Default::default()
        };
        if let Some(d) = doi {
            w.doi = Some(d.into());
            w.ids.insert("doi".into(), d.into());
        }
        w.provenance = Some(Provenance {
            fetched_at: "2026-10-19T00:00:00Z".into(),
            source: "crossref".into(),
            source_id: doi.unwrap_or("x").into(),
            query: None,
            sources: vec![],
        });
        w
    }

    #[test]
    fn a_work_becomes_a_search_row_with_its_ids_and_provenance() {
        let p = work_to_external_paper(&work(
            "The Formation of the First Star",
            Some("10.1126/science.1063991"),
        ));
        assert_eq!(p.identifier.as_deref(), Some("10.1126/science.1063991"));
        assert_eq!(p.authors, vec!["Abel, Tom".to_string()]);
        assert_eq!(p.year, Some(2002));
        assert_eq!(p.source.as_deref(), Some("crossref"));
        assert_eq!(
            p.ids.get("doi").map(String::as_str),
            Some("10.1126/science.1063991")
        );
        assert_eq!(
            p.provenance.as_ref().map(|p| p.source.as_str()),
            Some("crossref")
        );
    }

    #[test]
    fn free_text_an_identifier_and_a_native_string_become_three_queries() {
        assert_eq!(
            query_for("dark matter halos"),
            Query::clause("any", "any", "dark matter halos")
        );
        assert_eq!(
            query_for("10.1126/science.1063991"),
            Query::clause("doi", "=", "10.1126/science.1063991")
        );
        assert!(matches!(
            query_for("author:\"Abel, T\" year:2002"),
            Query::Native { .. }
        ));
    }

    #[test]
    fn the_structured_query_names_first_author_year_and_title_words() {
        let q = structured_query(&ScorerInput {
            authors: vec!["Abel, T.".into(), "Bryan, G.".into()],
            title: Some("The formation of the first star in the Universe".into()),
            year: Some(2002),
            ..Default::default()
        })
        .expect("a query");
        let Query::And { and } = q else {
            panic!("expected and")
        };
        assert_eq!(and[0], Query::clause("author", "any", "Abel"));
        assert_eq!(and[1], Query::clause("year", "=", "2002"));
        assert_eq!(
            and[2],
            Query::clause("title", "any", "formation star universe")
        );
    }

    #[test]
    fn synthesized_bibtex_parses_and_carries_the_identifiers() {
        let text = synthesize_bibtex(&work("A title", Some("10.1/x")));
        let parsed = imbib_core::bibtex::parse(text.clone()).expect("parses");
        assert_eq!(parsed.entries.len(), 1);
        assert!(text.contains("doi = {10.1/x}"));
        assert!(text.contains("author = {Abel, Tom}"));
    }

    fn scratch_store() -> Arc<ImbibStore> {
        let path = std::env::temp_dir().join(format!(
            "imbib-sources-test-{}-{:?}.sqlite",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_file(&path);
        ImbibStore::open(path.to_string_lossy().into_owned()).expect("store opens")
    }

    /// Tier A for `import-work`'s store half: the row carries `source_id`,
    /// the source's own BibTeX, the full `ids` map and the provenance; a
    /// second import of the same work is `existing_id`; a dismissed work is
    /// never written. (The network half — `source-service_export` for the
    /// BibTeX — is the adapters' own Tier A in koine.)
    #[test]
    fn import_work_keeps_provenance_dedups_by_identifier_and_honours_dismissal() {
        let store = scratch_store();
        let library = store.create_library("Papers".into()).expect("library");
        let mut w = work(
            "The Formation of the First Star in the Universe",
            Some("10.1126/science.1063991"),
        );
        w.ids.insert("arxiv".into(), "astro-ph/0112088".into());
        w.ids.insert("openalex".into(), "W2001".into());
        let call = uuid::Uuid::new_v4().to_string();
        let own_bibtex = "@article{Abel2002,
  title = {The Formation of the First Star in the Universe},
  author = {Abel, Tom and Bryan, Greg},
  journal = {Science},
  year = {2002},
  doi = {10.1126/science.1063991}
}
";
        let input = work_import_input(&w, own_bibtex.into(), false, Some(call.clone()));
        assert_eq!(input.source_id, "crossref");
        assert_eq!(
            input.ids.get("arxiv").map(String::as_str),
            Some("astro-ph/0112088")
        );

        let first = store
            .import_work(input.clone(), library.id.clone(), None)
            .expect("import");
        let id = first.imported_id.clone().expect("a new row");
        assert!(first.existing_id.is_none() && !first.dismissed);
        let detail = store
            .get_publication_detail(id.clone())
            .expect("detail")
            .expect("row");
        assert_eq!(
            detail.fields.get("source_id").map(String::as_str),
            Some("crossref")
        );
        assert_eq!(detail.raw_bibtex.as_deref(), Some(own_bibtex));
        assert_eq!(
            detail.fields.get("doi").map(String::as_str),
            Some("10.1126/science.1063991")
        );
        assert_eq!(
            detail.fields.get("arxiv_id").map(String::as_str),
            Some("astro-ph/0112088")
        );
        let ids_json = detail.fields.get("ids_json").expect("ids_json");
        assert!(ids_json.contains("\"openalex\":\"W2001\""), "{ids_json}");
        let provenance = detail
            .fields
            .get("provenance_json")
            .expect("provenance_json");
        assert!(
            provenance.contains("\"source\":\"crossref\""),
            "{provenance}"
        );
        let item = store
            .get_publication_detail(id.clone())
            .ok()
            .flatten()
            .map(|d| d.id)
            .expect("id");
        assert_eq!(item, id);

        // The same work again: the existing row, nothing written.
        let again = store
            .import_work(input.clone(), library.id.clone(), None)
            .expect("import");
        assert_eq!(again.existing_id.as_deref(), Some(id.as_str()));
        assert!(again.imported_id.is_none());

        // A synthesized BibTeX keeps no raw_bibtex.
        let other = work("Another paper entirely", Some("10.1/other"));
        let synthesized = work_import_input(&other, synthesize_bibtex(&other), true, None);
        let out = store
            .import_work(synthesized, library.id.clone(), None)
            .expect("import");
        let detail = store
            .get_publication_detail(out.imported_id.expect("row"))
            .expect("detail")
            .expect("row");
        assert!(detail.raw_bibtex.is_none());
        assert_eq!(
            detail.fields.get("source_id").map(String::as_str),
            Some("crossref")
        );

        // A dismissed work is never re-imported.
        store
            .dismiss_paper(Some("10.1/dismissed".into()), None, None, None)
            .expect("dismiss");
        let dismissed = work("A dismissed paper", Some("10.1/dismissed"));
        let out = store
            .import_work(
                work_import_input(&dismissed, synthesize_bibtex(&dismissed), true, None),
                library.id.clone(),
                None,
            )
            .expect("import");
        assert!(out.dismissed && out.imported_id.is_none() && out.existing_id.is_none());
    }

    #[test]
    fn a_reference_line_yields_its_surnames_year_and_title() {
        let (authors, year, journal, title) = fields_of_reference(
            "Bromm, V., Coppi, P. S., & Larson, R. B. 2002, ApJ, 564, 23, The Formation of the First Stars. I. The Primordial Star-forming Cloud",
        );
        assert_eq!(authors, vec!["Bromm", "Coppi", "Larson"]);
        assert_eq!(year, Some(2002));
        assert_eq!(journal.as_deref(), Some("ApJ"));
        assert_eq!(title.as_deref(), Some("The Formation of the First Stars"));
        let (authors, year, journal, title) =
            fields_of_reference("Abel et al. 2002, Science 295, 93");
        assert_eq!(authors, vec!["Abel"]);
        assert_eq!(year, Some(2002));
        assert_eq!(journal.as_deref(), Some("Science 295"));
        assert_eq!(title, None);
        assert_eq!(
            fields_of_reference("dark matter halos"),
            (vec![], None, None, None)
        );
    }

    #[test]
    fn the_secret_source_prefers_memory_then_env_then_keychain() {
        let source = ImbibSecretSource;
        set_secret("ads-token", "from-the-app");
        assert_eq!(
            source.get("ads-token").map(|s| s.expose().to_string()),
            Some("from-the-app".into())
        );
        assert_eq!(source.source_of("ads-token"), Some("app"));
        set_secret("ads-token", "");
        assert_eq!(
            secrets::keychain_account("ads-token").as_deref(),
            Some("com.imbib.credentials.ads.apiKey")
        );
        assert_eq!(secrets::keychain_account("not-a-source-secret"), None);
    }
}
