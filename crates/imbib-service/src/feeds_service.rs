//! Feed refresh in Rust: what `PaperFetchService.swift` does for an inbox
//! feed, with no app running, so the web host, the CLI, MCP and a daemon
//! can refresh a feed.
//!
//! A feed is a smart search (`imbib/smart-search`): a query, the sources to
//! ask, a result cap, and whether its papers go to the Inbox. A refresh:
//!
//! 1. runs the query on the feed's sources (`search_sources`, the federated
//!    `bib-source-service` search);
//! 2. drops what a mute rule names (author, DOI, bibcode, venue, arXiv
//!    category — `MuteService.shouldFilter`'s rules exactly);
//! 3. finds the papers the library already holds, by DOI, arXiv id or
//!    bibcode, in one query (a copy in the Dismissed library is not held);
//!    then drops what was dismissed — except, for a search that does not
//!    feed the Inbox, a paper the library holds;
//! 4. imports the rest into the Inbox (or the feed's library when it does
//!    not feed the Inbox) through `import_work`, with the source's record
//!    and no BibTeX export per row, and marks them unread;
//! 5. links every paper it found, new and held, to the feed's collection
//!    (whose id is the smart search's), which is what the feed lists.

use std::collections::{HashMap, HashSet};

use impress_service_core::async_trait;
use impress_service_core::pipeline::context::report_refusal;
use impress_service_core::refusal::codes;
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

use imbib_core::unified::shaped_queries::{MutedItemRow, SmartSearchRow};

use crate::app_service::ExternalPaper;
use crate::store_singleton::store_instance;

/// What one feed refresh did.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct FeedRefresh {
    /// The smart search's id (also its collection's).
    pub feed_id: String,
    /// The feed's name.
    pub name: String,
    /// Rows the sources returned.
    pub fetched: u32,
    /// Rows a mute rule dropped.
    pub muted: u32,
    /// Rows dropped because the paper was dismissed.
    pub dismissed: u32,
    /// Papers imported now.
    pub new: u32,
    /// Papers the library already held, linked to the feed.
    pub existing: u32,
    /// Why the refresh did nothing, when it did nothing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub problem: Option<String>,
}

#[impress_service]
pub trait ImbibFeedsService: Send + Sync + 'static {
    /// Refresh one feed now: search its sources, drop muted and dismissed
    /// papers, import the new ones (into the Inbox for an inbox feed) as
    /// unread, and link every paper found to the feed. Runs without the app.
    /// An empty id is the first feed (the Inbox's feeds first).
    #[impress_method(safety = external, effects(reads = ["imbib/smart-search", "imbib/muted-item", "imbib/dismissed-paper", "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/library", "imbib/collection"], writes = ["imbib/bibliography-entry", "imbib/collection"], reach = [network]))]
    #[impress_example(
        name = "unknown-feed",
        args = r#"{"feed_id":"5c000000-0000-4000-8000-0000000000fe"}"#
    )]
    async fn refresh_feed(&self, feed_id: String) -> FeedRefresh;

    /// Refresh every feed that feeds the Inbox and refreshes automatically,
    /// one after another; one line per feed.
    #[impress_method(safety = external, effects(reads = ["imbib/smart-search", "imbib/muted-item", "imbib/dismissed-paper", "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/library", "imbib/collection"], writes = ["imbib/bibliography-entry", "imbib/collection"], reach = [network]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    async fn refresh_inbox_feeds(&self) -> Vec<FeedRefresh>;
}

#[derive(Default, Clone, Copy)]
pub struct DefaultImbibFeedsService;

#[async_trait::async_trait]
impl ImbibFeedsService for DefaultImbibFeedsService {
    async fn refresh_feed(&self, feed_id: String) -> FeedRefresh {
        let store = store_instance();
        // An empty id is the first feed, as `imbib-view-service_feed-choices`
        // lists them: what a feed picker holding no value shows.
        let feed_id = if feed_id.trim().is_empty() {
            match feeds_in_order().await.into_iter().next() {
                Some((feed, _)) => feed.id,
                None => feed_id,
            }
        } else {
            feed_id
        };
        match store.get_smart_search(feed_id.clone()) {
            Ok(Some(feed)) => refresh(&feed).await,
            Ok(None) => {
                report_refusal(codes::NOT_FOUND, format!("refresh_feed: no feed {feed_id}"));
                FeedRefresh {
                    feed_id,
                    problem: Some("no such feed".into()),
                    ..Default::default()
                }
            }
            Err(e) => {
                report_refusal(codes::VERB_FAILED, format!("refresh_feed: {e}"));
                FeedRefresh {
                    feed_id,
                    problem: Some(e.to_string()),
                    ..Default::default()
                }
            }
        }
    }

    async fn refresh_inbox_feeds(&self) -> Vec<FeedRefresh> {
        let feeds = store_instance()
            .list_smart_searches(None)
            .unwrap_or_default();
        let mut out = Vec::new();
        for feed in feeds
            .iter()
            .filter(|f| f.feeds_to_inbox && f.auto_refresh_enabled)
        {
            out.push(refresh(feed).await);
        }
        tracing::info!(
            target: "feeds",
            "refresh_inbox_feeds: {} feed(s), {} new paper(s)",
            out.len(),
            out.iter().map(|r| r.new).sum::<u32>()
        );
        out
    }
}

/// Every feed with its library's name: the Inbox's feeds first, then the
/// rest by library and name.
pub async fn feeds_in_order() -> Vec<(imbib_core::unified::shaped_queries::SmartSearchRow, String)>
{
    let store = crate::store_singleton::store_instance();
    let libraries: std::collections::HashMap<String, (String, bool)> = store
        .list_libraries()
        .unwrap_or_default()
        .into_iter()
        .map(|l| (l.id.clone(), (l.name.clone(), l.is_inbox)))
        .collect();
    let mut feeds: Vec<_> = store
        .list_smart_searches(None)
        .unwrap_or_default()
        .into_iter()
        .map(|f| {
            let (name, inbox) = f
                .library_id
                .as_ref()
                .and_then(|id| libraries.get(id).cloned())
                .unwrap_or_else(|| (String::from("—"), false));
            (f, name, inbox)
        })
        .collect();
    feeds.sort_by(|a, b| {
        b.2.cmp(&a.2)
            .then_with(|| a.1.cmp(&b.1))
            .then_with(|| a.0.name.cmp(&b.0.name))
    });
    feeds.into_iter().map(|(f, name, _)| (f, name)).collect()
}

/// A group feed (`GROUP_FEED|authors:…|categories:…|crosslist:…`): the
/// authors (surnames) followed within arXiv categories.
#[derive(Debug, Clone, PartialEq)]
pub struct GroupFeed {
    /// Surnames, as the app keeps them (`lastNameOnly`).
    pub authors: Vec<String>,
    /// arXiv categories, sorted.
    pub categories: Vec<String>,
}

/// Read a group feed's query; `None` for an ordinary feed.
/// `GroupFeedRefreshService.parseGroupFeedAuthors`/`Categories`, exactly:
/// `", "` joins a surname and a first name, a bare `,` or a `;` separates
/// authors, and `au:`/`cat:` are the legacy spellings.
pub fn parse_group_feed(query: &str) -> Option<GroupFeed> {
    let rest = query.strip_prefix("GROUP_FEED|")?;
    let parts: Vec<&str> = rest.split('|').map(str::trim).collect();
    let field = |prefixes: &[&str]| {
        parts.iter().find_map(|p| {
            prefixes
                .iter()
                .find_map(|pre| p.strip_prefix(pre))
                .map(str::to_string)
        })
    };
    let authors = field(&["authors:", "au:"])
        .map(|raw| {
            split_author_list(&raw)
                .into_iter()
                .map(|a| a.trim().to_string())
                .filter(|a| !a.is_empty())
                .map(|a| last_name_only(&a))
                .collect()
        })
        .unwrap_or_default();
    let mut categories: Vec<String> = field(&["categories:", "cat:"])
        .map(|raw| {
            raw.split(',')
                .map(|c| c.trim().to_string())
                .filter(|c| !c.is_empty())
                .collect()
        })
        .unwrap_or_default();
    categories.sort();
    categories.dedup();
    Some(GroupFeed {
        authors,
        categories,
    })
}

fn split_author_list(s: &str) -> Vec<String> {
    let chars: Vec<char> = s.chars().collect();
    let mut out = Vec::new();
    let mut current = String::new();
    let mut i = 0;
    while i < chars.len() {
        match chars[i] {
            ';' => out.push(std::mem::take(&mut current)),
            ',' if chars.get(i + 1).is_some_and(|n| n.is_whitespace()) => current.push(','),
            ',' => out.push(std::mem::take(&mut current)),
            c => current.push(c),
        }
        i += 1;
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

fn last_name_only(name: &str) -> String {
    let name = name.trim();
    if let Some((last, _)) = name.split_once(',') {
        return last.trim().to_string();
    }
    let tokens: Vec<&str> = name.split_whitespace().collect();
    match tokens.as_slice() {
        [.., last] if tokens.len() > 1 => (*last).to_string(),
        _ => name.to_string(),
    }
}

/// `SearchFormQueryBuilder.buildArXivAuthorCategoryQuery`: `au:Name AND
/// (cat:a OR cat:b)`, a multi-word name quoted.
fn arxiv_author_query(author: &str, categories: &[String]) -> String {
    let mut parts = Vec::new();
    let author = author.trim();
    if !author.is_empty() {
        if author.contains(' ') {
            parts.push(format!("au:\"{author}\""));
        } else {
            parts.push(format!("au:{author}"));
        }
    }
    if !categories.is_empty() {
        let cats = categories
            .iter()
            .map(|c| format!("cat:{c}"))
            .collect::<Vec<_>>()
            .join(" OR ");
        parts.push(if categories.len() > 1 {
            format!("({cats})")
        } else {
            cats
        });
    }
    parts.join(" AND ")
}

fn normalize_author(name: &str) -> String {
    // `Family, Given` (the koine adapters' form) reads as `Given Family`
    // (arXiv's), so the surname is the last word either way.
    let name = match name.split_once(',') {
        Some((family, given)) if !given.contains(',') => {
            format!("{} {}", given.trim(), family.trim())
        }
        _ => name.to_string(),
    };
    name.to_lowercase()
        .replace('.', "")
        .replace(',', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// `authorMatchesExactly`: the followed author is among a paper's authors,
/// not merely a namesake prefix of someone's surname.
fn author_matches_exactly(target: &str, paper_authors: &[String]) -> bool {
    let t = normalize_author(target);
    let t_parts: Vec<&str> = t.split(' ').filter(|p| p.chars().count() > 1).collect();
    paper_authors.iter().any(|a| {
        let p = normalize_author(a);
        if p == t {
            return true;
        }
        let p_parts: Vec<&str> = p.split(' ').collect();
        let all = t_parts.iter().all(|tp| {
            p_parts
                .iter()
                .any(|pp| pp == tp || pp.starts_with(tp) || tp.starts_with(pp))
        });
        let last_t = t_parts.last();
        let last_p = p_parts.iter().rfind(|x| x.chars().count() > 1);
        all && !t_parts.is_empty() && last_t.is_some() && last_t == last_p
    })
}

/// A group feed's search: each author within its categories on arXiv, newest
/// first, exact author matches only, one row per paper. arXiv's etiquette
/// (one request per three seconds) spaces the searches, as the app's
/// stagger did.
async fn search_group(
    feed: &SmartSearchRow,
    group: &GroupFeed,
) -> (Vec<ExternalPaper>, Option<String>) {
    let mut out: Vec<ExternalPaper> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for (index, author) in group.authors.iter().enumerate() {
        // arXiv limits by IP: after a 429 every further request is refused
        // until the back-off ends, and asking again only lengthens it. Stop,
        // as the app does, and leave the rest for the next refresh.
        let wait = source_service::etiquette::limiter().backoff_remaining("arxiv");
        if !wait.is_zero() {
            let left = group.authors.len() - index;
            let why = format!(
                "arXiv asked imbib to slow down (429); {left} of {} author(s) left for the next refresh (in about {}s)",
                group.authors.len(),
                wait.as_secs().max(1)
            );
            tracing::warn!(target: "feeds", "refresh '{}': {why}", feed.name);
            return (out, Some(why));
        }
        let query = arxiv_author_query(author, &group.categories);
        let found =
            crate::sources::search_sources(query, Some("arxiv".into()), 100, Some("year".into()))
                .await;
        let matched: Vec<ExternalPaper> = found
            .into_iter()
            .filter(|p| author_matches_exactly(author, &p.authors))
            .collect();
        tracing::info!(
            target: "feeds",
            "refresh '{}': group author '{author}': {} exact match(es)",
            feed.name,
            matched.len()
        );
        for p in matched {
            let key = p
                .ids
                .get("doi")
                .or_else(|| p.ids.get("arxiv"))
                .cloned()
                .unwrap_or_else(|| p.title.clone());
            if seen.insert(key) {
                out.push(p);
            }
        }
    }
    (out, None)
}

/// An arXiv id compared without its prefix or version, lower-cased.
fn arxiv_key(id: &str) -> String {
    let id = id
        .trim()
        .trim_start_matches("arXiv:")
        .trim_start_matches("arxiv:");
    let base = match id.rfind('v') {
        Some(i) if i > 0 && id[i + 1..].chars().all(|c| c.is_ascii_digit()) && i + 1 < id.len() => {
            &id[..i]
        }
        _ => id,
    };
    base.to_lowercase()
}

/// Whether a mute rule drops this result: `MuteService.shouldFilter`'s rules.
fn is_muted(p: &ExternalPaper, rules: &[MutedItemRow]) -> bool {
    let doi = p
        .ids
        .get("doi")
        .or(p.doi.as_ref())
        .map(|d| d.to_lowercase());
    let bibcode = p
        .ids
        .get("bibcode")
        .or(p.bibcode.as_ref())
        .map(|b| b.to_lowercase());
    let arxiv = p
        .ids
        .get("arxiv")
        .or(p.arxiv_id.as_ref())
        .map(|a| a.to_lowercase());
    let venue = p.venue.as_deref().map(str::to_lowercase);
    rules.iter().any(|rule| {
        let value = rule.value.to_lowercase();
        match rule.mute_type.as_str() {
            "author" => p.authors.iter().any(|a| a.to_lowercase().contains(&value)),
            "doi" => doi.as_deref() == Some(value.as_str()),
            "bibcode" => bibcode.as_deref() == Some(value.as_str()),
            "venue" => venue.as_deref().is_some_and(|v| v.contains(&value)),
            "arxivCategory" => arxiv.as_deref().is_some_and(|a| a.starts_with(&value)),
            _ => false,
        }
    })
}

/// The name of the library dismissed papers are moved to (the trash).
const DISMISSED_LIBRARY: &str = "Dismissed";

async fn refresh(feed: &SmartSearchRow) -> FeedRefresh {
    let store = store_instance();
    let mut outcome = FeedRefresh {
        feed_id: feed.id.clone(),
        name: feed.name.clone(),
        ..Default::default()
    };
    // 1. Search. A feed's cap is per refresh; the federated search caps a
    // source at its MAX_LIMIT.
    let sources = Some(feed.source_ids.join(",")).filter(|s| !s.is_empty());
    let limit = u32::try_from(feed.max_results.max(1)).unwrap_or(100);
    tracing::info!(
        target: "feeds",
        "refresh '{}': mutation requested: query={:?} sources={:?} limit={limit}",
        feed.name,
        feed.query,
        sources
    );
    let found = match parse_group_feed(&feed.query) {
        Some(group) => {
            let (found, problem) = search_group(feed, &group).await;
            outcome.problem = problem;
            found
        }
        None => crate::sources::search_sources(feed.query.clone(), sources, limit, None).await,
    };
    outcome.fetched = found.len() as u32;

    // 2. Mute rules.
    let rules = store.list_muted_items(None).unwrap_or_default();
    let mut unmuted: Vec<&ExternalPaper> = Vec::new();
    for p in &found {
        if is_muted(p, &rules) {
            outcome.muted += 1;
        } else {
            unmuted.push(p);
        }
    }

    // 3. What the library already holds, in one query. A copy in the
    // Dismissed library is in the trash, not held. Swift keeps that
    // library's id in its own UserDefaults, so it is known here by name,
    // as Swift's SciX sync also knows it.
    let collect = |kind: &str| -> Vec<String> {
        unmuted
            .iter()
            .filter_map(|p| p.ids.get(kind).cloned())
            .filter(|v| !v.is_empty())
            .collect()
    };
    let held_rows = store
        .find_by_identifiers_batch(collect("doi"), collect("arxiv"), collect("bibcode"))
        .unwrap_or_default();
    let trash: Option<String> = store
        .list_libraries()
        .unwrap_or_default()
        .into_iter()
        .find(|l| l.name == DISMISSED_LIBRARY)
        .map(|l| l.id);
    let homes = match &trash {
        Some(_) => store
            .owning_libraries(&held_rows.iter().map(|r| r.id.clone()).collect::<Vec<_>>())
            .unwrap_or_default(),
        None => HashMap::new(),
    };
    let mut held: HashMap<String, String> = HashMap::new();
    for r in held_rows
        .iter()
        .filter(|r| trash.is_none() || homes.get(&r.id) != trash.as_ref())
    {
        if let Some(d) = r.doi.as_deref().filter(|d| !d.is_empty()) {
            held.insert(format!("doi:{}", d.to_lowercase()), r.id.clone());
        }
        if let Some(a) = r.arxiv_id.as_deref().filter(|a| !a.is_empty()) {
            held.insert(format!("arxiv:{}", arxiv_key(a)), r.id.clone());
        }
        if let Some(b) = r.bibcode.as_deref().filter(|b| !b.is_empty()) {
            held.insert(format!("bibcode:{}", b.to_lowercase()), r.id.clone());
        }
    }
    let held_id = |p: &ExternalPaper, held: &HashMap<String, String>| -> Option<String> {
        p.ids
            .get("doi")
            .and_then(|d| held.get(&format!("doi:{}", d.to_lowercase())))
            .or_else(|| {
                p.ids
                    .get("arxiv")
                    .and_then(|a| held.get(&format!("arxiv:{}", arxiv_key(a))))
            })
            .or_else(|| {
                p.ids
                    .get("bibcode")
                    .and_then(|b| held.get(&format!("bibcode:{}", b.to_lowercase())))
            })
            .cloned()
    };

    // 4. Dismissals. Dismissing is an Inbox verdict ("not for my Inbox"),
    // so an Inbox feed never brings a dismissed paper back. A saved search
    // is a question about the literature, and a paper the library holds
    // answers it whether or not a copy was once dismissed from the Inbox
    // (the user's choice, 2026-10-28); one the library does not hold stays
    // out, as it always did.
    let mut kept: Vec<&ExternalPaper> = Vec::new();
    for p in unmuted {
        if !feed.feeds_to_inbox && held_id(p, &held).is_some() {
            kept.push(p);
            continue;
        }
        let dismissed = store
            .is_paper_dismissed(
                p.ids.get("doi").cloned().or_else(|| p.doi.clone()),
                p.ids.get("arxiv").cloned().or_else(|| p.arxiv_id.clone()),
                p.ids.get("bibcode").cloned().or_else(|| p.bibcode.clone()),
                None,
            )
            .unwrap_or(false);
        if dismissed {
            outcome.dismissed += 1;
            continue;
        }
        kept.push(p);
    }

    // 5. Import the rest.
    let target = if feed.feeds_to_inbox {
        store.get_inbox_library().ok().flatten().map(|l| l.id)
    } else {
        feed.library_id.clone()
    }
    .or_else(|| store.get_default_library().ok().flatten().map(|l| l.id));
    let Some(target) = target else {
        report_refusal(
            codes::NOT_FOUND,
            "refresh_feed: no Inbox or library to file into",
        );
        outcome.problem = Some("no Inbox or library to file into".into());
        return outcome;
    };
    let mut existing_ids: Vec<String> = Vec::new();
    let mut new_ids: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for p in kept {
        if let Some(id) = held_id(p, &held) {
            if seen.insert(id.clone()) {
                existing_ids.push(id);
            }
            continue;
        }
        let Some(work) = p.work.clone() else { continue };
        let imported = crate::sources::import_work(work, Some(target.clone()), None, false).await;
        if let Some(id) = imported.imported_id {
            // A later row of this batch with the same paper links to it.
            for (kind, key) in [
                ("doi", p.ids.get("doi").map(|d| d.to_lowercase())),
                ("arxiv", p.ids.get("arxiv").map(|a| arxiv_key(a))),
                ("bibcode", p.ids.get("bibcode").map(|b| b.to_lowercase())),
            ] {
                if let Some(key) = key {
                    held.insert(format!("{kind}:{key}"), id.clone());
                }
            }
            seen.insert(id.clone());
            new_ids.push(id);
        } else if let Some(id) = imported.existing_id {
            if seen.insert(id.clone()) {
                existing_ids.push(id);
            }
        } else if imported.dismissed {
            outcome.dismissed += 1;
        }
    }
    outcome.new = new_ids.len() as u32;
    outcome.existing = existing_ids.len() as u32;

    // 6. New papers are unread; every paper found is linked to the feed.
    if !new_ids.is_empty() {
        if let Err(e) = store.set_read(new_ids.clone(), false) {
            tracing::warn!(target: "feeds", "refresh '{}': set unread failed: {e}", feed.name);
        }
    }
    let linked: Vec<String> = new_ids.iter().chain(existing_ids.iter()).cloned().collect();
    if !linked.is_empty() {
        if let Err(e) = store.add_to_collection(linked.clone(), feed.id.clone()) {
            tracing::warn!(target: "feeds", "refresh '{}': link to feed failed: {e}", feed.name);
        }
    }
    tracing::info!(
        target: "feeds",
        "refresh '{}': save: fetched={} muted={} dismissed={} new={} existing={} linked={}",
        feed.name,
        outcome.fetched,
        outcome.muted,
        outcome.dismissed,
        outcome.new,
        outcome.existing,
        linked.len()
    );
    let listed = store
        .list_collection_members(
            feed.id.clone(),
            "date_added".into(),
            false,
            Some(1),
            Some(0),
        )
        .map(|rows| rows.len())
        .unwrap_or(0);
    tracing::info!(
        target: "feeds",
        "refresh '{}': display: the feed lists papers again: {}",
        feed.name,
        listed > 0
    );
    outcome
}

impress_service_impl! {
    service = ImbibFeedsService,
    safety = external,
    since = "0.1.0",
    effects = {
        reads: ["imbib/smart-search", "imbib/muted-item", "imbib/dismissed-paper", "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/library", "imbib/collection"],
        writes: ["imbib/bibliography-entry", "imbib/collection"],
        reach: [network],
    },
    impl = DefaultImbibFeedsService,
    instance = || DefaultImbibFeedsService,
    methods = [
        /// Refresh one feed now, without the app.
        refresh_feed(
            /// The smart search's UUID; empty is the first feed.
            feed_id: String
        ) -> FeedRefresh,
        /// Refresh every automatically refreshing Inbox feed.
        refresh_inbox_feeds() -> Vec<FeedRefresh>,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(kind: &str, value: &str) -> MutedItemRow {
        MutedItemRow {
            id: "r".into(),
            mute_type: kind.into(),
            value: value.into(),
            date_added: 0,
        }
    }

    fn paper() -> ExternalPaper {
        serde_json::from_value(serde_json::json!({
            "title": "On the first stars",
            "authors": ["Abel, Tom", "Bryan, Greg"],
            "venue": "The Astrophysical Journal",
            "ids": {"doi": "10.1/X", "arxiv": "astro-ph/0112088", "bibcode": "2002Sci...295...93A"}
        }))
        .unwrap()
    }

    #[test]
    fn mute_rules_match_as_the_app_matches_them() {
        let p = paper();
        assert!(is_muted(&p, &[rule("author", "bryan")]));
        assert!(is_muted(&p, &[rule("doi", "10.1/x")]));
        assert!(is_muted(&p, &[rule("bibcode", "2002sci...295...93a")]));
        assert!(is_muted(&p, &[rule("venue", "astrophysical")]));
        assert!(is_muted(&p, &[rule("arxivCategory", "astro-ph")]));
        assert!(!is_muted(
            &p,
            &[rule("author", "norman"), rule("venue", "nature")]
        ));
        assert!(!is_muted(&p, &[rule("someday", "x")]));
    }

    #[test]
    fn a_group_feed_reads_as_the_app_reads_it() {
        let g = parse_group_feed(
            "GROUP_FEED|authors:Springel, Volker;Graham, Peter;Wechsler, Risa|categories:astro-ph.GA,astro-ph.CO|crosslist:true",
        )
        .unwrap();
        assert_eq!(g.authors, vec!["Springel", "Graham", "Wechsler"]);
        assert_eq!(g.categories, vec!["astro-ph.CO", "astro-ph.GA"]);
        // The legacy spellings, and a bare comma between authors.
        let g = parse_group_feed("GROUP_FEED|au:Abel, Tom,Bryan, Greg|cat:astro-ph.CO").unwrap();
        assert_eq!(g.authors, vec!["Abel", "Bryan"]);
        assert_eq!(parse_group_feed("cat:astro-ph.CO"), None);
        assert_eq!(
            arxiv_author_query("Springel", &g.categories),
            "au:Springel AND cat:astro-ph.CO"
        );
        assert_eq!(
            arxiv_author_query("van den Bosch", &["a".into(), "b".into()]),
            "au:\"van den Bosch\" AND (cat:a OR cat:b)"
        );
    }

    #[test]
    fn a_followed_author_matches_only_by_surname_not_by_prefix_of_another() {
        let authors = vec!["Springel, Volker".to_string(), "Smith, J.".to_string()];
        assert!(author_matches_exactly("Springel", &authors));
        assert!(author_matches_exactly(
            "Springel",
            &["Volker Springel".to_string()]
        ));
        assert!(!author_matches_exactly(
            "Spring",
            &["Springer, Anna".to_string()]
        ));
        assert!(!author_matches_exactly("Bryan", &authors));
    }

    #[test]
    fn arxiv_ids_compare_without_prefix_or_version() {
        assert_eq!(arxiv_key("arXiv:2410.15265v2"), "2410.15265");
        assert_eq!(arxiv_key("astro-ph/0112088v1"), "astro-ph/0112088");
        assert_eq!(arxiv_key("2410.15265"), "2410.15265");
    }
}
