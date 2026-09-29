//! App-owned methods await Swift state in the running imbib process.

use std::sync::Arc;

use imbib_service::app_service::{
    ActivityEntry, AppStatus, CitationInput, CitationResolution, ExternalPaper,
    IdentifierImportResult, ImbibAppService, LogEntry, PapersWindowResult, SyncNudgeResult,
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
    async fn import_identifiers(
        &self,
        identifiers: Vec<String>,
        library_id: Option<String>,
        collection_id: Option<String>,
        download_pdfs: bool,
    ) -> IdentifierImportResult {
        self.invoke(
            "import_identifiers",
            json!({
                "identifiers": identifiers,
                "library_id": library_id,
                "collection_id": collection_id,
                "download_pdfs": download_pdfs
            }),
        )
        .await
        .unwrap_or_default()
    }

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
    async fn resolve_citation(
        &self,
        query: Option<String>,
        bibtex: Option<String>,
        citation: Option<CitationInput>,
        library_id: Option<String>,
        download_pdfs: bool,
    ) -> CitationResolution {
        let mut args = json!({
            "query": query,
            "bibtex": bibtex,
            "library_id": library_id,
            "download_pdfs": download_pdfs,
        });
        if let Some(citation) = citation {
            args["citation"] = serde_json::to_value(citation).unwrap_or(Value::Null);
        }
        self.invoke("resolve_citation", args)
            .await
            .unwrap_or_else(|_| CitationResolution::unavailable(
                "Citation resolution was refused by the running imbib app; inspect the refusal details.",
            ))
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

    struct RecordingFixture {
        response: NativeCallResult,
        seen: std::sync::Mutex<Option<(String, Value)>>,
    }

    #[async_trait::async_trait]
    impl ImbibNativeCallbacks for Fixture {
        async fn invoke(&self, _method: String, _args_json: String) -> NativeCallResult {
            self.response.clone()
        }
    }

    #[async_trait::async_trait]
    impl ImbibNativeCallbacks for RecordingFixture {
        async fn invoke(&self, method: String, args_json: String) -> NativeCallResult {
            let args = serde_json::from_str(&args_json).expect("callback arguments are JSON");
            *self.seen.lock().unwrap() = Some((method, args));
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
    async fn external_search_decodes_the_http_import_identifier() {
        let result = service(
            200,
            r#"[{"title":"A paper without DOI","authors":["Ada"],"sourceID":"crossref","identifier":"A paper without DOI"}]"#,
        )
        .search_sources("A paper".into(), None, 5)
        .await;
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].identifier.as_deref(), Some("A paper without DOI"));
        assert_eq!(result[0].source.as_deref(), Some("crossref"));
    }

    #[tokio::test]
    async fn resolve_citation_forwards_all_inputs_and_preserves_ranked_candidates() {
        let callback = Arc::new(RecordingFixture {
            response: NativeCallResult {
                status: 200,
                body_json: r#"{"via":"ads-candidates","candidates":[{"title":"A paper","confidence":0.82},{"title":"Another","confidence":0.71}],"reason":"Choose the matching reference"}"#.into(),
            },
            seen: Default::default(),
        });
        let service = NativeImbibAppService {
            callback: callback.clone(),
        };
        let citation: CitationInput = serde_json::from_value(json!({
            "authors": "Ada Lovelace; Charles Babbage",
            "title": "Analytical engines",
            "year": 1843,
            "rawBibtex": "@article{private-key, title={Analytical engines}}",
            "freeText": "Lovelace 1843",
            "preferredDatabase": "astronomy"
        }))
        .unwrap();
        let resolved = service
            .resolve_citation(
                Some("Lovelace 1843".into()),
                Some("@article{private-key}".into()),
                Some(citation),
                Some("library-uuid".into()),
                true,
            )
            .await;
        assert_eq!(resolved.via, "ads-candidates");
        assert_eq!(resolved.candidates.as_ref().unwrap().len(), 2);
        assert_eq!(resolved.candidates.as_ref().unwrap()[0]["confidence"], 0.82);
        assert_eq!(
            resolved.reason.as_deref(),
            Some("Choose the matching reference")
        );

        let seen = callback.seen.lock().unwrap();
        let (method, args) = seen.as_ref().unwrap();
        assert_eq!(method, "resolve_citation");
        assert_eq!(args["query"], "Lovelace 1843");
        assert_eq!(args["bibtex"], "@article{private-key}");
        assert_eq!(args["library_id"], "library-uuid");
        assert_eq!(args["download_pdfs"], true);
        assert_eq!(
            args["citation"]["authors"],
            json!(["Ada Lovelace", "Charles Babbage"])
        );
        assert_eq!(
            args["citation"]["rawBibtex"],
            "@article{private-key, title={Analytical engines}}"
        );
        assert_eq!(args["citation"]["freeText"], "Lovelace 1843");
        assert_eq!(args["citation"]["preferredDatabase"], "astronomy");
    }

    #[tokio::test]
    async fn headless_citation_resolution_is_an_explicit_unavailable_result() {
        let result = imbib_service::app_service::DefaultImbibAppService::new()
            .resolve_citation(None, None, None, None, false)
            .await;
        assert_eq!(result.via, "unavailable");
        assert!(result
            .reason
            .as_deref()
            .unwrap_or_default()
            .contains("Open imbib"));
        assert!(result.candidates.is_none());
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

    struct ImportFixture {
        response: NativeCallResult,
        received: std::sync::Mutex<Option<(String, String)>>,
    }

    #[async_trait::async_trait]
    impl ImbibNativeCallbacks for ImportFixture {
        async fn invoke(&self, method: String, args_json: String) -> NativeCallResult {
            *self.received.lock().unwrap() = Some((method, args_json));
            self.response.clone()
        }
    }

    #[tokio::test]
    async fn identifier_import_forwards_options_and_preserves_full_added_dictionary() {
        let callback = Arc::new(ImportFixture {
            response: NativeCallResult {
                status: 200,
                body_json: r#"{"added":[{"id":"paper-id","citeKey":"Example2026","title":"Example","authors":["Doe, Jane"],"year":2026,"bibtex":"@article{Example2026}","dateAdded":"2026-09-29T00:00:00Z","collectionIDs":["collection-id"],"libraryIDs":["library-id"]}],"duplicates":["Existing2026"],"failed":{"bad-key":"unsupported identifier"}}"#.into(),
            },
            received: std::sync::Mutex::new(None),
        });
        let service = NativeImbibAppService {
            callback: Arc::clone(&callback) as Arc<dyn ImbibNativeCallbacks>,
        };

        let result = service
            .import_identifiers(
                vec!["10.5555/example".into(), "Existing2026".into()],
                Some("library-id".into()),
                Some("collection-id".into()),
                true,
            )
            .await;

        assert_eq!(result.duplicates, vec!["Existing2026"]);
        assert_eq!(
            result.failed.get("bad-key").map(String::as_str),
            Some("unsupported identifier")
        );
        assert_eq!(result.added[0]["title"], "Example");
        assert_eq!(result.added[0]["collectionIDs"][0], "collection-id");
        assert_eq!(result.added[0]["dateAdded"], "2026-09-29T00:00:00Z");
        let (method, args) = callback.received.lock().unwrap().clone().unwrap();
        assert_eq!(method, "import_identifiers");
        let args: Value = serde_json::from_str(&args).unwrap();
        assert_eq!(args["library_id"], "library-id");
        assert_eq!(args["collection_id"], "collection-id");
        assert_eq!(args["download_pdfs"], true);
        assert_eq!(args["identifiers"][0], "10.5555/example");
    }
}
