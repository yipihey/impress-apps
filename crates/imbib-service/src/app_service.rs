//! `ImbibAppService` — capabilities that live in the running imbib app rather
//! than in the store.
//!
//! Every other `imbib-service` trait models the SQLite store, so its default
//! backend can answer with imbib closed. These cannot:
//!
//! * **Source search** needs the network and the user's API credentials
//!   (ADS, arXiv, Crossref), which live in the app's keychain.
//! * **PDF download** needs the proxy settings and the attachment layout.
//! * **Sync** is a CloudKit engine owned by the app process; a second writer
//!   nudging it from outside would fight its lease.
//! * **Logs and status** describe a running process. There is nothing to
//!   report when it is not running.
//! * **Recent activity** is the user's own viewing trail, recorded by the UI.
//!   Automated ingest deliberately never writes it, which is exactly what makes
//!   it "what was I just reading?" rather than "what arrived?".
//!
//! So the default backend refuses each of these and says to open imbib, the
//! same shape `backup_service`'s restore uses. The HTTP backend in
//! `imbib-service-http` does the real work. Refusing loudly beats returning an
//! empty list that reads like "you have no papers".

use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

/// One hit from an external academic source, before it is imported.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ExternalPaper {
    pub title: String,
    #[serde(default)]
    pub authors: Vec<String>,
    #[serde(default)]
    pub year: Option<i64>,
    #[serde(default)]
    pub venue: Option<String>,
    #[serde(default)]
    pub doi: Option<String>,
    #[serde(default, alias = "arxivID", alias = "arxiv_id")]
    pub arxiv_id: Option<String>,
    #[serde(default)]
    pub bibcode: Option<String>,
    #[serde(default)]
    pub abstract_text: Option<String>,
    /// Which source returned it (`ads`, `arxiv`, `crossref`, …).
    #[serde(default, alias = "sourceID", alias = "source_id")]
    pub source: Option<String>,
}

/// A paper the user themselves touched, with what they did and when.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ActivityEntry {
    pub id: String,
    #[serde(default, alias = "citeKey")]
    pub cite_key: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    /// `viewed` or `added`.
    #[serde(default, alias = "activityKind")]
    pub activity_kind: Option<String>,
    /// Epoch milliseconds.
    #[serde(default, alias = "activityAt")]
    pub activity_at: Option<i64>,
}

/// One line from the app's in-memory log store.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct LogEntry {
    #[serde(default)]
    pub timestamp: Option<String>,
    #[serde(default)]
    pub level: Option<String>,
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub message: String,
}

/// Whether the sync engine accepted an immediate push+pull.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SyncNudgeResult {
    pub accepted: bool,
    /// Why not, when `accepted` is false. A refusal is a normal answer.
    #[serde(default)]
    pub reason: Option<String>,
}

/// Free-form app state. Deliberately a JSON string: `/api/status` and
/// `/api/sync/status` grow fields over time, and re-declaring their shape here
/// would be one more thing to keep in step.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct AppStatus {
    /// `true` when the app answered at all.
    pub running: bool,
    /// The endpoint's JSON body, verbatim, or an explanation when not running.
    pub detail: String,
}

#[impress_service]
pub trait ImbibAppService: Send + Sync + 'static {
    /// Search external academic sources — ADS, arXiv, Crossref and the rest —
    /// for papers NOT yet in the library. This is how you find new work; to
    /// search papers already saved use the library search tools instead.
    /// Results are candidates: import them before citing or tagging.
    /// `sources` is a comma-separated subset (e.g. "arxiv,ads"); empty means
    /// every configured source. Make ONE broad call rather than several narrow
    /// ones.
    #[impress_method]
    async fn search_sources(
        &self,
        query: String,
        sources: Option<String>,
        limit: u32,
    ) -> Vec<ExternalPaper>;

    /// What the USER was recently working on: papers they viewed or added by
    /// hand, most recent first, each carrying `activity_kind` and
    /// `activity_at`. This is imbib's "Recent" virtual library and the right
    /// opener for "what was I just reading?" / "pick up where I left off".
    /// Automated ingest is deliberately excluded — inbox feeds, smart-search
    /// refreshes and group feeds never record activity — so this really is the
    /// user's own trail. For newly ARRIVED papers regardless of who put them
    /// there, use the recent-papers query instead.
    #[impress_method]
    async fn recent_activity(&self, limit: u32, parent_id: Option<String>) -> Vec<ActivityEntry>;

    /// Download PDFs for the given papers, honouring the user's library-proxy
    /// and source-priority settings. Returns how many were fetched. Slow: it
    /// goes out to publishers and preprint servers.
    #[impress_method]
    async fn download_pdfs(&self, publication_ids: Vec<String>) -> u32;

    /// Ask imbib's sync engine for an immediate push+pull instead of waiting
    /// for its schedule. THIS IS WHAT DELIVERS YOUR WORK TO THE USER'S OTHER
    /// DEVICES: every change made through the other tools lands in the local
    /// store first and only reaches their phone on the next pass. Call it
    /// after finishing a batch of edits, and whenever the user asks why they
    /// cannot see something yet. A refusal is a normal answer, not an error —
    /// it reports `accepted: false` with a reason (sync off, not entitled, no
    /// iCloud account, another app holds the lease).
    #[impress_method]
    async fn sync_nudge(&self) -> SyncNudgeResult;

    /// The CloudKit sync engine's real state: whether it is on, when it last
    /// pushed and pulled, and the last error if any. Use this to diagnose a
    /// refused nudge.
    #[impress_method]
    async fn sync_status(&self) -> AppStatus;

    /// Whether imbib is running, and its version, port and library counts.
    /// Cheap; a good first call when a tool has just reported the app
    /// unavailable.
    #[impress_method]
    async fn status(&self) -> AppStatus;

    /// Recent lines from imbib's in-memory log store — the same feed its
    /// Console window shows. The way to find out what a mutation actually did.
    /// `level` is a comma-separated filter (`info,warning,error`), `category`
    /// narrows to one subsystem (e.g. `backup`, `tags`, `sync`).
    #[impress_method]
    async fn get_logs(
        &self,
        limit: u32,
        level: Option<String>,
        category: Option<String>,
        search: Option<String>,
    ) -> Vec<LogEntry>;
}

/// The store-backed default: refuses everything, because none of it exists
/// outside the running app.
#[derive(Clone, Default)]
pub struct DefaultImbibAppService;

impl DefaultImbibAppService {
    pub fn new() -> Self {
        Self
    }
}

const NOT_RUNNING: &str =
    "imbib is not running. This capability lives in the app — network search \
     credentials, the sync engine, the log store and the user's activity trail \
     are all app state, not store rows. Open imbib and try again.";

fn refuse(method: &str) {
    eprintln!("[imbib-app-service] {method}: imbib not running; refused");
}

#[async_trait::async_trait]
impl ImbibAppService for DefaultImbibAppService {
    async fn search_sources(
        &self,
        _query: String,
        _sources: Option<String>,
        _limit: u32,
    ) -> Vec<ExternalPaper> {
        refuse("search_sources");
        vec![]
    }

    async fn recent_activity(&self, _limit: u32, _parent_id: Option<String>) -> Vec<ActivityEntry> {
        refuse("recent_activity");
        vec![]
    }

    async fn download_pdfs(&self, _publication_ids: Vec<String>) -> u32 {
        refuse("download_pdfs");
        0
    }

    async fn sync_nudge(&self) -> SyncNudgeResult {
        refuse("sync_nudge");
        SyncNudgeResult {
            accepted: false,
            reason: Some(NOT_RUNNING.into()),
        }
    }

    async fn sync_status(&self) -> AppStatus {
        refuse("sync_status");
        AppStatus {
            running: false,
            detail: NOT_RUNNING.into(),
        }
    }

    async fn status(&self) -> AppStatus {
        // Not a refusal so much as the honest answer: the question is "is imbib
        // running?" and the answer is no.
        AppStatus {
            running: false,
            detail: "imbib is not running.".into(),
        }
    }

    async fn get_logs(
        &self,
        _limit: u32,
        _level: Option<String>,
        _category: Option<String>,
        _search: Option<String>,
    ) -> Vec<LogEntry> {
        refuse("get_logs");
        vec![]
    }
}

impress_service_impl! {
    service = ImbibAppService,
    impl = DefaultImbibAppService,
    instance = crate::backend::app_service_instance,
    methods = [
        search_sources(query: String, sources: Option<String>, limit: u32) -> Vec<ExternalPaper>,
        recent_activity(limit: u32, parent_id: Option<String>) -> Vec<ActivityEntry>,
        download_pdfs(publication_ids: Vec<String>) -> u32,
        sync_nudge() -> SyncNudgeResult,
        sync_status() -> AppStatus,
        status() -> AppStatus,
        get_logs(
            limit: u32,
            level: Option<String>,
            category: Option<String>,
            search: Option<String>
        ) -> Vec<LogEntry>,
    ],
}
