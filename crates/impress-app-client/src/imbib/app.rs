//! `ImbibAppService` method clients — the endpoints that only the running app
//! can answer (source search, PDFs, sync, logs, the user's activity trail).

use serde::Deserialize;
use serde_json::json;

use crate::error::Result;
use crate::imbib::ImbibClient;
use crate::transport::decode_envelope;

use imbib_service::app_service::{
    ActivityEntry, AppStatus, ExternalPaper, LogEntry, SyncNudgeResult,
};

impl ImbibClient {
    /// `GET /api/search/external`
    pub async fn search_sources(
        &self,
        query: String,
        sources: Option<String>,
        limit: u32,
    ) -> Result<Vec<ExternalPaper>> {
        let mut url = self.base_url.join("/api/search/external")?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("q", &query);
            if let Some(s) = sources.as_deref().filter(|s| !s.is_empty()) {
                q.append_pair("source", s);
            }
            if limit > 0 {
                q.append_pair("limit", &limit.to_string());
            }
        }
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            results: Vec<ExternalPaper>,
            #[serde(default)]
            papers: Vec<ExternalPaper>,
        }
        let body: R = decode_envelope(self.http.get(url).send().await?).await?;
        // The endpoint has used both keys across versions; accept either rather
        // than silently returning nothing when it changes again.
        Ok(if body.results.is_empty() {
            body.papers
        } else {
            body.results
        })
    }

    /// `GET /api/papers/recent-activity`
    pub async fn recent_activity(
        &self,
        limit: u32,
        parent_id: Option<String>,
    ) -> Result<Vec<ActivityEntry>> {
        let mut url = self.base_url.join("/api/papers/recent-activity")?;
        {
            let mut q = url.query_pairs_mut();
            if limit > 0 {
                q.append_pair("limit", &limit.to_string());
            }
            if let Some(p) = parent_id.as_deref().filter(|p| !p.is_empty()) {
                q.append_pair("parentId", p);
            }
        }
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            papers: Vec<ActivityEntry>,
        }
        let body: R = decode_envelope(self.http.get(url).send().await?).await?;
        Ok(body.papers)
    }

    /// `POST /api/papers/download-pdfs`
    pub async fn download_pdfs(&self, publication_ids: Vec<String>) -> Result<u32> {
        let url = self.base_url.join("/api/papers/download-pdfs")?;
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            downloaded: u32,
        }
        let body: R = decode_envelope(
            self.http
                .post(url)
                .json(&json!({ "ids": publication_ids }))
                .send()
                .await?,
        )
        .await?;
        Ok(body.downloaded)
    }

    /// `POST /api/sync/nudge`
    pub async fn sync_nudge(&self) -> Result<SyncNudgeResult> {
        let url = self.base_url.join("/api/sync/nudge")?;
        let body: SyncNudgeResult = decode_envelope(self.http.post(url).send().await?).await?;
        Ok(body)
    }

    /// `GET /api/sync/status` — returned verbatim; the shape grows over time
    /// and re-declaring it here would be one more thing to keep in step.
    pub async fn sync_status_raw(&self) -> Result<AppStatus> {
        self.raw_status("/api/sync/status").await
    }

    /// `GET /api/status`
    pub async fn app_status_raw(&self) -> Result<AppStatus> {
        self.raw_status("/api/status").await
    }

    async fn raw_status(&self, path: &str) -> Result<AppStatus> {
        let url = self.base_url.join(path)?;
        let text = self.http.get(url).send().await?.text().await?;
        Ok(AppStatus {
            running: true,
            detail: text,
        })
    }

    /// `GET /api/logs`
    pub async fn get_logs(
        &self,
        limit: u32,
        level: Option<String>,
        category: Option<String>,
        search: Option<String>,
    ) -> Result<Vec<LogEntry>> {
        let mut url = self.base_url.join("/api/logs")?;
        {
            let mut q = url.query_pairs_mut();
            if limit > 0 {
                q.append_pair("limit", &limit.to_string());
            }
            for (key, value) in [("level", level), ("category", category), ("search", search)] {
                if let Some(v) = value.as_deref().filter(|v| !v.is_empty()) {
                    q.append_pair(key, v);
                }
            }
        }
        // `/api/logs` nests one level deeper than its neighbours:
        // `{status, data: {count, entries: [...]}}`. Reading the top level
        // returns an empty list, which looks exactly like "no logs" — the kind
        // of wrong answer that survives a review because it is not an error.
        #[derive(Deserialize)]
        struct Data {
            #[serde(default)]
            entries: Vec<LogEntry>,
        }
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            data: Option<Data>,
            #[serde(default)]
            entries: Vec<LogEntry>,
        }
        let body: R = decode_envelope(self.http.get(url).send().await?).await?;
        Ok(match body.data {
            Some(d) if !d.entries.is_empty() => d.entries,
            _ => body.entries,
        })
    }
}
