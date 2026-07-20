//! `ImbibUndoService` method clients.

use serde::Deserialize;

use crate::error::{AppClientError, Result};
use crate::imbib::ImbibClient;
use crate::transport::decode_envelope;

use imbib_service::library_service::MutationResult;
use imbib_service::undo_service::UndoGroupRecord;

#[derive(Deserialize)]
struct StatusEnvelope {
    status: String,
}
fn check(s: &StatusEnvelope) -> Result<()> {
    if s.status == "ok" {
        Ok(())
    } else {
        Err(AppClientError::Api(s.status.clone()))
    }
}

impl ImbibClient {
    pub async fn recent_undo_groups(&self, max_entries: u32) -> Result<Vec<UndoGroupRecord>> {
        let n = if max_entries == 0 { 25 } else { max_entries };
        let mut url = self.base_url.join("/api/undo/recent")?;
        url.query_pairs_mut()
            .append_pair("max_entries", &n.to_string());
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            groups: Vec<UndoGroupRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.groups)
    }

    pub async fn undo_operation(&self, operation_id: String) -> Result<MutationResult> {
        let url = self
            .base_url
            .join(&format!("/api/undo/operation/{}", operation_id))?;
        let resp = self.http.post(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(AppClientError::NotFound(
                "POST /api/undo/operation/{id} (Phase D)".into(),
            ));
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            operation_count: u32,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(MutationResult {
            affected_count: body.operation_count.max(1),
            ok: true,
        })
    }

    pub async fn undo_batch(&self, batch_id: String) -> Result<MutationResult> {
        let url = self
            .base_url
            .join(&format!("/api/undo/batch/{}", batch_id))?;
        let resp = self.http.post(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(AppClientError::NotFound(
                "POST /api/undo/batch/{id} (Phase D)".into(),
            ));
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            operation_count: u32,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(MutationResult {
            affected_count: body.operation_count.max(1),
            ok: true,
        })
    }
}
