//! Inbox triage in Rust: what `PublicationListMutations.dismiss`/`save` and
//! `InboxManager` do in the app, with no app running, so the web host, the
//! CLI, MCP and a daemon can triage.
//!
//! A triage verb is told where the papers are being looked at (`scope`),
//! because that decides the bookkeeping:
//!
//! - `inbox` (or empty): the Inbox.
//! - `feed:<id>`: a feed's list (empty id: the first feed, as the feed
//!   picker shows it). The papers leave that feed's list.
//! - `library:<id>`: a plain library. Nothing is recorded: taking a paper
//!   out of a library is not a verdict on it.
//!
//! From the Inbox or a feed, both dismissing and keeping record the paper as
//! dismissed — it has been seen, and no feed brings it to the Inbox again —
//! and send its other Inbox copies to the Dismissed library. Then dismissing
//! moves the papers to the Dismissed library (the trash) and keeping moves
//! them to the library chosen.

use std::collections::HashSet;

use impress_service_core::async_trait;
use impress_service_core::pipeline::context::report_refusal;
use impress_service_core::refusal::codes;
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

use imbib_core::unified::store_api::ImbibStore;

use crate::store_singleton::store_instance;

/// The library dismissed papers are moved to. Swift keeps its id in the
/// app's own defaults, so it is found by name, as the app's SciX sync finds
/// it, and made when it is missing, as `getOrCreateDismissedLibrary` does.
pub const DISMISSED_LIBRARY: &str = "Dismissed";

/// What one triage call did.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct TriageResult {
    /// True when the papers were moved.
    pub ok: bool,
    /// Papers moved to the target library.
    pub moved: u32,
    /// Papers newly recorded as dismissed (already recorded ones are not
    /// counted again).
    pub recorded: u32,
    /// Other Inbox copies of the same papers sent to the Dismissed library.
    pub copies: u32,
    /// What went wrong, when something did.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub problem: Option<String>,
}

#[impress_service]
pub trait ImbibTriageService: Send + Sync + 'static {
    /// Dismiss papers: from the Inbox or a feed, record them as dismissed
    /// (no feed brings them to the Inbox again) and send their other Inbox
    /// copies along; take them out of the feed's list; move them to the
    /// Dismissed library, which is the trash — nothing is deleted. `scope`
    /// is `inbox`, `feed:<id>` or `library:<id>`.
    #[impress_method(safety = mutating, effects(reads = ["imbib/bibliography-entry", "imbib/library", "imbib/smart-search", "imbib/dismissed-paper", "imbib/collection"], writes = ["imbib/bibliography-entry", "imbib/library", "imbib/dismissed-paper", "imbib/collection"]))]
    #[impress_example(
        name = "dismiss-from-a-library",
        args = r#"{"ids":["63000000-0000-4000-8000-00000000000b"],"scope":"library:63000000-0000-4000-8000-000000000001"}"#,
        expect = r#"{"ok":true,"moved":1,"recorded":0}"#
    )]
    async fn dismiss(&self, ids: Vec<String>, scope: String) -> TriageResult;

    /// Keep papers in a library: from the Inbox or a feed, record them as
    /// seen (as dismissing does, so no feed brings them back to the Inbox)
    /// and send their other Inbox copies to the Dismissed library; take them
    /// out of the feed's list; move them to `library_id`.
    #[impress_method(safety = mutating, effects(reads = ["imbib/bibliography-entry", "imbib/library", "imbib/smart-search", "imbib/dismissed-paper", "imbib/collection"], writes = ["imbib/bibliography-entry", "imbib/library", "imbib/dismissed-paper", "imbib/collection"]))]
    #[impress_example(
        name = "keep-in-another-library",
        args = r#"{"ids":["63000000-0000-4000-8000-00000000000b"],"library_id":"63000000-0000-4000-8000-00000000000c","scope":"library:63000000-0000-4000-8000-000000000001"}"#,
        expect = r#"{"ok":true,"moved":1,"recorded":0}"#
    )]
    async fn keep(&self, ids: Vec<String>, library_id: String, scope: String) -> TriageResult;
}

#[derive(Default, Clone, Copy)]
pub struct DefaultImbibTriageService;

#[async_trait::async_trait]
impl ImbibTriageService for DefaultImbibTriageService {
    async fn dismiss(&self, ids: Vec<String>, scope: String) -> TriageResult {
        // Nothing to do makes nothing, not even the Dismissed library.
        if ids.is_empty() {
            return TriageResult {
                ok: true,
                ..Default::default()
            };
        }
        let feed = feed_of(&scope).await;
        let store = store_instance();
        tokio::task::spawn_blocking(move || {
            let target = match dismissed_library(&store) {
                Ok(id) => id,
                Err(e) => return failed("dismiss", e),
            };
            triage(&store, "dismiss", &ids, &scope, feed, &target)
        })
        .await
        .unwrap_or_else(|e| failed("dismiss", e.to_string()))
    }

    async fn keep(&self, ids: Vec<String>, library_id: String, scope: String) -> TriageResult {
        if library_id.trim().is_empty() && !ids.is_empty() {
            report_refusal(codes::INVALID_ARGUMENT, "keep: choose a library to keep in");
            return TriageResult {
                problem: Some("choose a library to keep in".into()),
                ..Default::default()
            };
        }
        let feed = feed_of(&scope).await;
        let store = store_instance();
        tokio::task::spawn_blocking(move || triage(&store, "keep", &ids, &scope, feed, &library_id))
            .await
            .unwrap_or_else(|e| failed("keep", e.to_string()))
    }
}

fn failed(verb: &str, why: impl std::fmt::Display) -> TriageResult {
    report_refusal(codes::VERB_FAILED, format!("{verb}: {why}"));
    TriageResult {
        problem: Some(why.to_string()),
        ..Default::default()
    }
}

/// The feed a `feed:<id>` scope names; an empty id is the first feed.
async fn feed_of(scope: &str) -> Option<String> {
    let id = scope.strip_prefix("feed:")?.trim();
    if id.is_empty() {
        crate::feeds_service::feeds_in_order()
            .await
            .into_iter()
            .next()
            .map(|(feed, _)| feed.id)
    } else {
        Some(id.to_string())
    }
}

/// Whether looking at papers in `scope` makes a triage verdict on them.
fn records_verdict(scope: &str) -> bool {
    let scope = scope.trim();
    scope.is_empty() || scope == "inbox" || scope.starts_with("feed:")
}

/// The Dismissed library's id, made when there is none yet.
fn dismissed_library(store: &ImbibStore) -> Result<String, String> {
    let libraries = store.list_libraries().map_err(|e| e.to_string())?;
    if let Some(l) = libraries.iter().find(|l| l.name == DISMISSED_LIBRARY) {
        return Ok(l.id.clone());
    }
    store
        .create_library(DISMISSED_LIBRARY.into())
        .map(|l| l.id)
        .map_err(|e| e.to_string())
}

fn triage(
    store: &ImbibStore,
    verb: &str,
    ids: &[String],
    scope: &str,
    feed: Option<String>,
    target: &str,
) -> TriageResult {
    let mut out = TriageResult::default();
    if ids.is_empty() {
        out.ok = true;
        return out;
    }
    tracing::info!(
        target: "triage",
        "{verb}: mutation requested: {} paper(s), scope={scope:?}, target={target}",
        ids.len()
    );
    let chosen: HashSet<&str> = ids.iter().map(String::as_str).collect();
    if records_verdict(scope) {
        let inbox = store.get_inbox_library().ok().flatten().map(|l| l.id);
        let inbox_members: HashSet<String> = inbox
            .as_ref()
            .and_then(|id| store.query_publication_ids(id.clone()).ok())
            .unwrap_or_default()
            .into_iter()
            .collect();
        let mut stray_copies: Vec<String> = Vec::new();
        let mut feed_copies: Vec<String> = Vec::new();
        for id in ids {
            let Ok(Some(paper)) = store.get_publication(id.clone()) else {
                continue;
            };
            let cite_key = Some(paper.cite_key.clone()).filter(|k| !k.is_empty());
            let known = store
                .is_paper_dismissed(
                    paper.doi.clone(),
                    paper.arxiv_id.clone(),
                    paper.bibcode.clone(),
                    cite_key.clone(),
                )
                .unwrap_or(false);
            let identified = paper.doi.is_some()
                || paper.arxiv_id.is_some()
                || paper.bibcode.is_some()
                || cite_key.is_some();
            if !known && identified {
                match store.dismiss_paper(
                    paper.doi.clone(),
                    paper.arxiv_id.clone(),
                    paper.bibcode.clone(),
                    cite_key,
                ) {
                    Ok(_) => out.recorded += 1,
                    Err(e) => tracing::warn!(target: "triage", "{verb}: record {id}: {e}"),
                }
            }
            // The paper's other copies: Inbox ones go to the trash, and none
            // of them stays in the feed's list (`cleanupDismissedCopies`).
            if paper.doi.is_some() || paper.arxiv_id.is_some() || paper.bibcode.is_some() {
                // The batch lookup, because it matches an arXiv id across
                // its versions.
                let copies = store
                    .find_by_identifiers_batch(
                        paper.doi.into_iter().collect(),
                        paper.arxiv_id.into_iter().collect(),
                        paper.bibcode.into_iter().collect(),
                    )
                    .unwrap_or_default();
                for copy in copies {
                    if chosen.contains(copy.id.as_str()) {
                        continue;
                    }
                    if inbox_members.contains(&copy.id) {
                        stray_copies.push(copy.id.clone());
                    }
                    feed_copies.push(copy.id);
                }
            }
        }
        if !stray_copies.is_empty() {
            stray_copies.sort();
            stray_copies.dedup();
            match dismissed_library(store).and_then(|trash| {
                store
                    .move_publications(stray_copies.clone(), trash)
                    .map_err(|e| e.to_string())
            }) {
                Ok(_) => out.copies = stray_copies.len() as u32,
                Err(e) => tracing::warn!(target: "triage", "{verb}: inbox copies: {e}"),
            }
        }
        if let Some(feed) = &feed {
            if !feed_copies.is_empty() {
                let _ = store.remove_from_collection(feed_copies, feed.clone());
            }
        }
    }
    if let Some(feed) = &feed {
        if let Err(e) = store.remove_from_collection(ids.to_vec(), feed.clone()) {
            tracing::warn!(target: "triage", "{verb}: leave feed {feed}: {e}");
        }
    }
    match store.move_publications(ids.to_vec(), target.to_string()) {
        Ok(_) => {
            out.ok = true;
            out.moved = ids.len() as u32;
        }
        Err(e) => {
            report_refusal(codes::VERB_FAILED, format!("{verb}: move: {e}"));
            out.problem = Some(e.to_string());
        }
    }
    tracing::info!(
        target: "triage",
        "{verb}: save: moved={} recorded={} copies={}",
        out.moved,
        out.recorded,
        out.copies
    );
    out
}

impress_service_impl! {
    service = ImbibTriageService,
    safety = mutating,
    since = "0.1.0",
    effects = {
        reads: ["imbib/bibliography-entry", "imbib/library", "imbib/smart-search", "imbib/dismissed-paper", "imbib/collection"],
        writes: ["imbib/bibliography-entry", "imbib/library", "imbib/dismissed-paper", "imbib/collection"],
        reach: [],
    },
    impl = DefaultImbibTriageService,
    instance = || DefaultImbibTriageService,
    methods = [
        /// Dismiss papers to the Dismissed library, recording the verdict.
        dismiss(
            /// The papers' UUIDs.
            ids: Vec<String>,
            /// Where they are being triaged: `inbox`, `feed:<id>` (empty id: the
            /// first feed) or `library:<id>`.
            scope: String
        ) -> TriageResult,
        /// Keep papers in a library, recording that they were seen.
        keep(
            /// The papers' UUIDs.
            ids: Vec<String>,
            /// The library to keep them in.
            library_id: String,
            /// Where they are being triaged: `inbox`, `feed:<id>` (empty id: the
            /// first feed) or `library:<id>`.
            scope: String
        ) -> TriageResult,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_inbox_and_feeds_record_a_verdict() {
        assert!(records_verdict(""));
        assert!(records_verdict("inbox"));
        assert!(records_verdict("feed:"));
        assert!(records_verdict("feed:5c000000-0000-4000-8000-0000000000fe"));
        assert!(!records_verdict(
            "library:5c000000-0000-4000-8000-0000000000fd"
        ));
    }

    #[test]
    fn dismissing_moves_to_a_dismissed_library_it_makes_and_records_the_paper() {
        let store = ImbibStore::open_in_memory().unwrap();
        let inbox = store.create_inbox_library("Inbox".into()).unwrap();
        let ids = store
            .import_bibtex(
                "@article{A, title={A}, doi={10.1/a}}\n@article{B, title={B}, doi={10.1/a}}".into(),
                inbox.id.clone(),
            )
            .unwrap();
        let trash = dismissed_library(&store).unwrap();
        let out = triage(&store, "dismiss", &ids[..1], "inbox", None, &trash);
        assert!(out.ok, "{out:?}");
        assert_eq!((out.moved, out.recorded, out.copies), (1, 1, 1));
        let in_trash = store.query_publication_ids(trash).unwrap();
        assert!(in_trash.contains(&ids[0]) && in_trash.contains(&ids[1]));
        assert!(store
            .is_paper_dismissed(Some("10.1/a".into()), None, None, None)
            .unwrap());
    }

    #[test]
    fn moving_out_of_a_plain_library_records_nothing() {
        let store = ImbibStore::open_in_memory().unwrap();
        let from = store.create_library("From".into()).unwrap();
        let to = store.create_library("To".into()).unwrap();
        let ids = store
            .import_bibtex(
                "@article{A, title={A}, doi={10.1/b}}".into(),
                from.id.clone(),
            )
            .unwrap();
        let out = triage(
            &store,
            "keep",
            &ids,
            &format!("library:{}", from.id),
            None,
            &to.id,
        );
        assert_eq!((out.moved, out.recorded, out.copies), (1, 0, 0));
        assert!(!store
            .is_paper_dismissed(Some("10.1/b".into()), None, None, None)
            .unwrap());
        assert_eq!(store.query_publication_ids(to.id).unwrap(), ids);
    }
}
