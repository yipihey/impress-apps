//! App-owned methods await Swift state in the running imbib process.

use std::sync::Arc;

use imbib_service::app_service::{
    ActivityEntry, AppStatus, ExternalPaper, ImbibAppService, LogEntry, PapersWindowResult,
    SyncNudgeResult,
};
use imbib_service::manuscripts_service::{
    CompileResult, ImbibManuscriptsService, ManuscriptRecord, TemplateRecord, WriteResult,
};
use impress_service_core::pipeline::context::report_refusal;
use impress_service_core::refusal::codes;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct NativeCallResult {
    pub status: u16,
    pub body_json: String,
}

#[cfg_attr(feature = "native", uniffi::export(callback_interface))]
#[async_trait::async_trait]
pub trait ImbibNativeCallbacks: Send + Sync {
    async fn invoke(&self, method: String, args_json: String) -> NativeCallResult;
}

struct NativeImbibAppService {
    callback: Arc<dyn ImbibNativeCallbacks>,
}

impl NativeImbibAppService {
    async fn invoke<T: DeserializeOwned>(&self, method: &str, args: Value) -> Result<T, ()> {
        let response = self.callback.invoke(method.into(), args.to_string()).await;
        if !(200..300).contains(&response.status) {
            let body: Value = serde_json::from_str(&response.body_json).unwrap_or(Value::Null);
            report_refusal(
                body.get("code")
                    .and_then(Value::as_str)
                    .unwrap_or(codes::VERB_FAILED),
                body.get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("imbib native operation failed"),
            );
            return Err(());
        }
        serde_json::from_str(&response.body_json).map_err(|error| {
            report_refusal(
                codes::INTERNAL,
                format!("imbib {method} returned an invalid result: {error}"),
            );
        })
    }
}

#[async_trait::async_trait]
impl ImbibAppService for NativeImbibAppService {
    async fn search_sources(
        &self,
        query: String,
        sources: Option<String>,
        limit: u32,
    ) -> Vec<ExternalPaper> {
        self.invoke(
            "search_sources",
            json!({ "query": query, "sources": sources, "limit": limit }),
        )
        .await
        .unwrap_or_default()
    }
    async fn recent_activity(&self, limit: u32, parent_id: Option<String>) -> Vec<ActivityEntry> {
        self.invoke(
            "recent_activity",
            json!({ "limit": limit, "parent_id": parent_id }),
        )
        .await
        .unwrap_or_default()
    }
    async fn download_pdfs(&self, publication_ids: Vec<String>) -> u32 {
        self.invoke(
            "download_pdfs",
            json!({ "publication_ids": publication_ids }),
        )
        .await
        .unwrap_or_default()
    }
    async fn open_manuscript_papers(&self, manuscript_id: String) -> PapersWindowResult {
        self.invoke(
            "open_manuscript_papers",
            json!({ "manuscript_id": manuscript_id }),
        )
        .await
        .unwrap_or(PapersWindowResult {
            opened: false,
            collection_id: None,
            collection_name: None,
            missing_cite_keys: vec![],
            message: String::new(),
        })
    }
    async fn sync_nudge(&self) -> SyncNudgeResult {
        self.invoke("sync_nudge", json!({}))
            .await
            .unwrap_or(SyncNudgeResult {
                accepted: false,
                reason: None,
            })
    }
    async fn sync_status(&self) -> AppStatus {
        self.invoke("sync_status", json!({}))
            .await
            .unwrap_or(AppStatus {
                running: false,
                detail: String::new(),
            })
    }
    async fn status(&self) -> AppStatus {
        self.invoke("status", json!({})).await.unwrap_or(AppStatus {
            running: false,
            detail: String::new(),
        })
    }
    async fn get_logs(
        &self,
        limit: u32,
        level: Option<String>,
        category: Option<String>,
        search: Option<String>,
    ) -> Vec<LogEntry> {
        self.invoke(
            "get_logs",
            json!({ "limit": limit, "level": level, "category": category, "search": search }),
        )
        .await
        .unwrap_or_default()
    }
    async fn get_notes(&self, cite_key: String) -> Option<String> {
        self.invoke("get_notes", json!({ "cite_key": cite_key }))
            .await
            .unwrap_or(None)
    }
    async fn update_notes(&self, cite_key: String, notes: String) -> bool {
        self.invoke(
            "update_notes",
            json!({ "cite_key": cite_key, "notes": notes }),
        )
        .await
        .unwrap_or(false)
    }
    async fn delete_annotation(&self, annotation_id: String) -> bool {
        self.invoke(
            "delete_annotation",
            json!({ "annotation_id": annotation_id }),
        )
        .await
        .unwrap_or(false)
    }
    async fn delete_comment(&self, comment_id: String) -> bool {
        self.invoke("delete_comment", json!({ "comment_id": comment_id }))
            .await
            .unwrap_or(false)
    }
    async fn delete_collection(&self, collection_id: String) -> bool {
        self.invoke(
            "delete_collection",
            json!({ "collection_id": collection_id }),
        )
        .await
        .unwrap_or(false)
    }
    async fn delete_smart_searches(&self, ids: Vec<String>) -> u32 {
        self.invoke("delete_smart_searches", json!({ "ids": ids }))
            .await
            .unwrap_or_default()
    }
    async fn tag_artifact(&self, artifact_id: String, tags: Vec<String>) -> bool {
        self.invoke(
            "tag_artifact",
            json!({ "artifact_id": artifact_id, "tags": tags }),
        )
        .await
        .unwrap_or(false)
    }
    async fn resolve_identifier(&self, identifier: String, download_pdfs: bool) -> Option<String> {
        self.invoke(
            "resolve_identifier",
            json!({ "identifier": identifier, "download_pdfs": download_pdfs }),
        )
        .await
        .unwrap_or(None)
    }
    async fn add_to_library(&self, publication_ids: Vec<String>, library_id: String) -> u32 {
        self.invoke(
            "add_to_library",
            json!({ "publication_ids": publication_ids, "library_id": library_id }),
        )
        .await
        .unwrap_or_default()
    }
}

struct NativeImbibManuscriptsService {
    app: NativeImbibAppService,
}

#[async_trait::async_trait]
impl ImbibManuscriptsService for NativeImbibManuscriptsService {
    async fn list_manuscripts(&self) -> Vec<ManuscriptRecord> {
        self.app
            .invoke("list_manuscripts", json!({}))
            .await
            .unwrap_or_default()
    }
    async fn get_manuscript(&self, manuscript_id: String) -> Option<ManuscriptRecord> {
        self.app
            .invoke("get_manuscript", json!({ "manuscript_id": manuscript_id }))
            .await
            .unwrap_or(None)
    }
    async fn create_manuscript(
        &self,
        title: String,
        format: Option<String>,
    ) -> Option<ManuscriptRecord> {
        self.app
            .invoke(
                "create_manuscript",
                json!({ "title": title, "format": format }),
            )
            .await
            .unwrap_or(None)
    }
    async fn write_manuscript_body(
        &self,
        manuscript_id: String,
        body: String,
        expected_hash: String,
    ) -> WriteResult {
        self.app
            .invoke(
                "write_manuscript_body",
                json!({
                    "manuscript_id": manuscript_id, "body": body, "expected_hash": expected_hash
                }),
            )
            .await
            .unwrap_or(WriteResult {
                ok: false,
                content_hash: None,
                message: String::new(),
            })
    }
    async fn compile_manuscript(&self, manuscript_id: String) -> CompileResult {
        self.app
            .invoke(
                "compile_manuscript",
                json!({ "manuscript_id": manuscript_id }),
            )
            .await
            .unwrap_or(CompileResult {
                ok: false,
                pdf_path: None,
                page_count: None,
                messages: vec![],
            })
    }
    async fn list_templates(&self) -> Vec<TemplateRecord> {
        self.app
            .invoke("list_templates", json!({}))
            .await
            .unwrap_or_default()
    }
    async fn create_manuscript_from_template(
        &self,
        template_id: String,
        title: String,
    ) -> Option<ManuscriptRecord> {
        self.app
            .invoke(
                "create_manuscript_from_template",
                json!({
                    "template_id": template_id, "title": title
                }),
            )
            .await
            .unwrap_or(None)
    }
}

/// Only install the callback after the GUI's exact store path was pinned.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn register_native_backend(
    callback: Box<dyn ImbibNativeCallbacks>,
) -> Result<(), crate::ImbibVerbStoreError> {
    if crate::INITIALIZED_PATH
        .lock()
        .map_or(true, |path| path.is_none())
    {
        return Err(crate::ImbibVerbStoreError::Initialization {
            message: "initialize_verb_store must succeed before registering the native backend"
                .into(),
        });
    }
    let callback: Arc<dyn ImbibNativeCallbacks> = Arc::from(callback);
    imbib_service::register_app_backend(Box::new(NativeImbibAppService {
        callback: Arc::clone(&callback),
    }));
    imbib_service::register_manuscripts_backend(Box::new(NativeImbibManuscriptsService {
        app: NativeImbibAppService { callback },
    }));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        response: NativeCallResult,
    }

    #[async_trait::async_trait]
    impl ImbibNativeCallbacks for Fixture {
        async fn invoke(&self, _method: String, _args_json: String) -> NativeCallResult {
            self.response.clone()
        }
    }

    fn service(status: u16, body: &str) -> NativeImbibAppService {
        NativeImbibAppService {
            callback: Arc::new(Fixture {
                response: NativeCallResult {
                    status,
                    body_json: body.into(),
                },
            }),
        }
    }

    #[tokio::test]
    async fn native_success_decodes_actual_optional_notes() {
        let result = service(200, r#""Saved note""#)
            .get_notes("Ada2026".into())
            .await;
        assert_eq!(result.as_deref(), Some("Saved note"));
        assert_eq!(service(200, "null").get_notes("missing".into()).await, None);
    }

    #[tokio::test]
    async fn callback_failure_and_invalid_success_cannot_become_success() {
        assert!(service(404, r#"{"code":"not-found","message":"missing"}"#)
            .invoke::<bool>("update_notes", json!({}))
            .await
            .is_err());
        assert!(service(200, "{}")
            .invoke::<u32>("download_pdfs", json!({}))
            .await
            .is_err());
    }

    #[tokio::test]
    async fn manuscript_compile_preserves_parked_pdf_path() {
        let manuscripts = NativeImbibManuscriptsService {
            app: service(
                200,
                r#"{"ok":true,"pdfPath":"/scratch/manuscripts/result.pdf","pageCount":3,"messages":[]}"#,
            ),
        };
        let result = manuscripts.compile_manuscript("manuscript-id".into()).await;
        assert!(result.ok);
        assert_eq!(
            result.pdf_path.as_deref(),
            Some("/scratch/manuscripts/result.pdf")
        );
        assert_eq!(result.page_count, Some(3));
    }
}
