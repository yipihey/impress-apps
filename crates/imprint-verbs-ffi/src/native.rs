//! App-owned state callback plus explicit workspace-backed domain services.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use impress_service_core::refusal::codes;
use imprint_service::app_service::{
    AppStatus, CommentRecord, CompiledPdf, ImprintAppService, LogEntry,
};
use imprint_service::backend::ImprintBackend;
use imprint_service::handlers::{
    CitationUsage, CompileOptions, CompileResult, DocumentSummary, LatexCompileResultDto, Outline,
    ReplaceResult, TextMatch,
};
use imprint_service::manuscript_service::{
    DefaultImprintManuscriptService, ImprintManuscriptService, PresentationMutationDto,
    PresentationOutlineDto, SearchHitDto,
};
use imprint_service::project_service::{DefaultImprintProjectService, ImprintProjectService};
use imprint_service::sections::{SectionMetadata, SectionRecord};
use imprint_service::text_service::{DefaultImprintTextService, ImprintTextService};
use imprint_service::throughline::ThroughlineStore;
use imprint_service::throughline_service::{
    DefaultImprintThroughlineService, ImprintThroughlineService,
};
use serde_json::{json, Value};

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct NativeReply {
    pub status: u16,
    pub body_json: String,
}

#[cfg_attr(feature = "native", uniffi::export(callback_interface))]
#[async_trait::async_trait]
pub trait ImprintVerbHost: Send + Sync {
    async fn invoke(&self, method: String, args_json: String) -> NativeReply;
}

struct NativeApp(Arc<dyn ImprintVerbHost>);

/// The shared-store implementation owns document/section reads and all pure
/// helpers. Export is the one manuscript method whose byte-for-byte result
/// still comes from the app's established format handlers.
struct NativeManuscript {
    base: DefaultImprintManuscriptService,
    app: Arc<NativeApp>,
}

#[async_trait::async_trait]
impl ImprintManuscriptService for NativeManuscript {
    async fn list_documents(&self) -> Vec<DocumentSummary> {
        self.base.list_documents().await
    }
    async fn get_document(&self, id: String) -> Option<DocumentSummary> {
        self.base.get_document(id).await
    }
    async fn export_document(&self, id: String, format: String) -> Vec<u8> {
        self.app
            .required("export_document", json!({"id":id,"format":format}), "bytes")
            .await
            .unwrap_or_default()
    }
    async fn list_sections(&self, doc_id: String) -> Vec<SectionRecord> {
        self.base.list_sections(doc_id).await
    }
    async fn get_section(&self, doc_id: String, section_key: String) -> Option<SectionRecord> {
        self.base.get_section(doc_id, section_key).await
    }
    async fn put_section(
        &self,
        doc_id: String,
        section_key: String,
        body: String,
        metadata: SectionMetadata,
    ) -> Option<SectionRecord> {
        self.base
            .put_section(doc_id, section_key, body, metadata)
            .await
    }
    async fn delete_section(&self, doc_id: String, section_key: String) -> bool {
        self.base.delete_section(doc_id, section_key).await
    }
    async fn document_outline(&self, source: String) -> Outline {
        self.base.document_outline(source).await
    }
    async fn document_citations(&self, source: String) -> Vec<CitationUsage> {
        self.base.document_citations(source).await
    }
    async fn search_in_text(
        &self,
        source: String,
        query: String,
        case_sensitive: bool,
    ) -> Vec<TextMatch> {
        self.base
            .search_in_text(source, query, case_sensitive)
            .await
    }
    async fn presentation_outline(&self, source: String) -> PresentationOutlineDto {
        self.base.presentation_outline(source).await
    }
    async fn reorder_presentation_slide(
        &self,
        source: String,
        slide_id: String,
        before_slide_id: String,
    ) -> PresentationMutationDto {
        self.base
            .reorder_presentation_slide(source, slide_id, before_slide_id)
            .await
    }
    async fn set_presentation_slide_beat(
        &self,
        source: String,
        slide_id: String,
        beat: String,
    ) -> PresentationMutationDto {
        self.base
            .set_presentation_slide_beat(source, slide_id, beat)
            .await
    }
    async fn compile_typst(&self, source: String, options: CompileOptions) -> CompileResult {
        self.base.compile_typst(source, options).await
    }
    async fn compile_latex(
        &self,
        source: String,
        filesystem_root: String,
    ) -> LatexCompileResultDto {
        self.base.compile_latex(source, filesystem_root).await
    }
    async fn search(&self, query: String, limit: u32) -> Vec<SearchHitDto> {
        self.base.search(query, limit).await
    }
    async fn replace_in_section(
        &self,
        doc_id: String,
        section_key: String,
        find: String,
        replace: String,
    ) -> ReplaceResult {
        self.base
            .replace_in_section(doc_id, section_key, find, replace)
            .await
    }
}

struct NativeBackend {
    app: Arc<NativeApp>,
    manuscript: Arc<dyn ImprintManuscriptService>,
    project: Arc<dyn ImprintProjectService>,
    throughline: Arc<dyn ImprintThroughlineService>,
}

impl ImprintBackend for NativeBackend {
    fn manuscript(&self) -> Arc<dyn ImprintManuscriptService> {
        self.manuscript.clone()
    }
    fn project(&self) -> Arc<dyn ImprintProjectService> {
        self.project.clone()
    }
    fn throughline(&self) -> Arc<dyn ImprintThroughlineService> {
        self.throughline.clone()
    }
    fn text(&self) -> Arc<dyn ImprintTextService> {
        Arc::new(DefaultImprintTextService)
    }
    fn app(&self) -> Arc<dyn ImprintAppService> {
        self.app.clone()
    }
}

static NATIVE_PATH: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

/// Bind one GUI process to exactly one shared-workspace database. Repeating
/// the same path is safe; a second path is refused before changing the backend.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn install_native_host(
    database_path: String,
    host: Box<dyn ImprintVerbHost>,
) -> Option<String> {
    try_install_native_host(database_path, host).err()
}

fn try_install_native_host(
    database_path: String,
    host: Box<dyn ImprintVerbHost>,
) -> Result<(), String> {
    let requested = Path::new(&database_path);
    if requested.file_name().and_then(|name| name.to_str()) != Some("impress.sqlite")
        || !requested.is_absolute()
    {
        return Err("expected an absolute impress.sqlite database path".into());
    }
    let parent = requested
        .parent()
        .ok_or("database has no workspace parent")?;
    std::fs::create_dir_all(parent).map_err(|e| format!("workspace unavailable: {e}"))?;
    let workspace =
        std::fs::canonicalize(parent).map_err(|e| format!("workspace unavailable: {e}"))?;
    let canonical_db = workspace.join("impress.sqlite");
    let lock = NATIVE_PATH.get_or_init(|| Mutex::new(None));
    let mut bound = lock.lock().map_err(|_| "native path lock poisoned")?;
    if bound.as_ref().is_some_and(|prior| prior != &canonical_db) {
        return Err("imprint native store is already bound to another database".into());
    }

    // Check the actual cached SQLite handle, not only a path hint. A generic
    // service that already opened the App Group database is refused here.
    let store = impress_core::sqlite_store::SqliteItemStore::open(&canonical_db)
        .map_err(|e| format!("cannot open native database: {e}"))?;
    impress_store_service::store::install_store_at(Arc::new(store), &canonical_db)?;

    let service = imprint_service::open(&workspace)
        .map_err(|e| format!("cannot open manuscript workspace: {e}"))?;
    let app = Arc::new(NativeApp(Arc::from(host)));
    let manuscript = Arc::new(NativeManuscript {
        base: DefaultImprintManuscriptService::new(Arc::new(service.handlers)),
        app: app.clone(),
    });
    let throughline = Arc::new(DefaultImprintThroughlineService::new(Arc::new(
        ThroughlineStore::new(service.sections.clone()),
    )));
    let project = Arc::new(
        DefaultImprintProjectService::with_workspace(&workspace)
            .map_err(|e| format!("cannot open project workspace: {e}"))?,
    );
    imprint_service::register_backend(Box::new(NativeBackend {
        app,
        manuscript,
        project,
        throughline,
    }));
    *bound = Some(canonical_db);
    Ok(())
}

fn refusal(method: &str, field: &str) {
    impress_service_core::pipeline::context::report_refusal(
        codes::INTERNAL,
        format!("{method}: native response omitted or invalid {field}"),
    );
}

impl NativeApp {
    async fn call(&self, method: &str, args: Value) -> Option<Value> {
        let reply = self.0.invoke(method.into(), args.to_string()).await;
        let value: Value = match serde_json::from_str(&reply.body_json) {
            Ok(value) => value,
            Err(error) => {
                impress_service_core::pipeline::context::report_refusal(
                    codes::INTERNAL,
                    format!("{method}: invalid native JSON: {error}"),
                );
                return None;
            }
        };
        if !(200..300).contains(&reply.status) {
            let message = value
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("native imprint operation failed");
            let code = match reply.status {
                400 | 422 => codes::INVALID_ARGUMENT,
                404 => codes::NOT_FOUND,
                503 => codes::HOST_UNAVAILABLE,
                _ => codes::VERB_FAILED,
            };
            impress_service_core::pipeline::context::report_refusal(code, message);
            return None;
        }
        if value.get("status").and_then(Value::as_str) == Some("error") {
            impress_service_core::pipeline::context::report_refusal(
                codes::VERB_FAILED,
                value
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("native imprint operation failed"),
            );
            return None;
        }
        Some(value)
    }
    async fn required<T: serde::de::DeserializeOwned>(
        &self,
        method: &str,
        args: Value,
        key: &str,
    ) -> Option<T> {
        let value = self.call(method, args).await?;
        let result = value
            .get(key)
            .cloned()
            .and_then(|item| serde_json::from_value(item).ok());
        if result.is_none() {
            refusal(method, key);
        }
        result
    }
    async fn succeeded(&self, method: &str, args: Value) -> bool {
        self.call(method, args).await.is_some()
    }
}

#[async_trait::async_trait]
impl ImprintAppService for NativeApp {
    async fn status(&self) -> AppStatus {
        match self.call("status", json!({})).await {
            Some(value) => AppStatus {
                running: true,
                detail: value.to_string(),
            },
            None => AppStatus {
                running: false,
                detail: "native imprint status refused".into(),
            },
        }
    }
    async fn get_logs(
        &self,
        limit: u32,
        level: Option<String>,
        category: Option<String>,
    ) -> Vec<LogEntry> {
        self.required(
            "get_logs",
            json!({"limit":limit,"level":level,"category":category}),
            "entries",
        )
        .await
        .unwrap_or_default()
    }
    async fn create_document(&self, title: String, format: Option<String>) -> Option<String> {
        self.required(
            "create_document",
            json!({"title":title,"format":format}),
            "id",
        )
        .await
    }
    async fn update_document(&self, document_id: String, title: Option<String>) -> bool {
        self.succeeded(
            "update_document",
            json!({"document_id":document_id,"title":title}),
        )
        .await
    }
    async fn update_metadata(&self, document_id: String, metadata_json: String) -> bool {
        self.succeeded(
            "update_metadata",
            json!({"document_id":document_id,"metadata_json":metadata_json}),
        )
        .await
    }
    async fn get_content(&self, document_id: String) -> Option<String> {
        self.required("get_content", json!({"document_id":document_id}), "source")
            .await
    }
    async fn insert_text(&self, document_id: String, offset: u32, text: String) -> bool {
        self.succeeded(
            "insert_text",
            json!({"document_id":document_id,"offset":offset,"text":text}),
        )
        .await
    }
    async fn delete_text(&self, document_id: String, offset: u32, length: u32) -> bool {
        self.succeeded(
            "delete_text",
            json!({"document_id":document_id,"offset":offset,"length":length}),
        )
        .await
    }
    async fn replace(&self, document_id: String, find: String, replace: String) -> u32 {
        let Some(value) = self
            .call(
                "replace",
                json!({"document_id":document_id,"find":find,"replace":replace}),
            )
            .await
        else {
            return 0;
        };
        match value
            .get("replaced")
            .and_then(Value::as_u64)
            .and_then(|count| u32::try_from(count).ok())
        {
            Some(count) => count,
            None => {
                refusal("replace", "replaced");
                0
            }
        }
    }
    async fn get_pdf(&self, document_id: String) -> CompiledPdf {
        let value = self
            .call("get_pdf", json!({"document_id":document_id}))
            .await;
        let result = value.and_then(|item| serde_json::from_value(item).ok());
        if result.is_none() {
            refusal("get_pdf", "compiled PDF result");
        }
        result.unwrap_or(CompiledPdf {
            ok: false,
            path: None,
            page_count: None,
            byte_size: None,
            messages: vec!["native PDF operation refused".into()],
        })
    }
    async fn get_bibliography(&self, document_id: String) -> Option<String> {
        self.required(
            "get_bibliography",
            json!({"document_id":document_id}),
            "bibtex",
        )
        .await
    }
    async fn list_comments(&self, document_id: String) -> Vec<CommentRecord> {
        self.required(
            "list_comments",
            json!({"document_id":document_id}),
            "comments",
        )
        .await
        .unwrap_or_default()
    }
    async fn create_comment(
        &self,
        document_id: String,
        body: String,
        anchor: Option<String>,
    ) -> Option<CommentRecord> {
        self.required(
            "create_comment",
            json!({"document_id":document_id,"body":body,"anchor":anchor}),
            "comment",
        )
        .await
    }
    async fn update_comment(
        &self,
        comment_id: String,
        body: Option<String>,
        status: Option<String>,
    ) -> bool {
        self.succeeded(
            "update_comment",
            json!({"comment_id":comment_id,"body":body,"status":status}),
        )
        .await
    }
    async fn delete_comment(&self, comment_id: String) -> bool {
        self.succeeded("delete_comment", json!({"comment_id":comment_id}))
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::manuscript_project::{self as mp, Author, NewManuscript};
    use imprint_service::handlers::CompileOptions;

    struct TestHost;

    #[async_trait::async_trait]
    impl ImprintVerbHost for TestHost {
        async fn invoke(&self, method: String, args_json: String) -> NativeReply {
            if method == "get_content" {
                return NativeReply {
                    status: 404,
                    body_json: json!({"status":"error","error":"scratch document missing"})
                        .to_string(),
                };
            }
            if method == "export_document" {
                let args: Value = serde_json::from_str(&args_json).unwrap();
                if args["id"] == "00000000-0000-0000-0000-000000000000" {
                    return NativeReply {
                        status: 404,
                        body_json: json!({"status":"error","error":"scratch export missing"})
                            .to_string(),
                    };
                }
                let bytes = match args["format"].as_str().unwrap() {
                    "typst" => br#"{"source":"= Scratch","bibliography":[]}"#.to_vec(),
                    "latex" => b"\\section{Scratch}".to_vec(),
                    "text" => b"Scratch".to_vec(),
                    other => panic!("unexpected export format: {other}"),
                };
                return NativeReply {
                    status: 200,
                    body_json: json!({"bytes":bytes}).to_string(),
                };
            }
            NativeReply {
                status: 200,
                body_json: json!({"status":"ok","method":method}).to_string(),
            }
        }
    }

    #[tokio::test]
    async fn native_project_and_generic_store_use_the_exact_scratch_database() {
        let scratch = tempfile::tempdir().unwrap();
        let compile_cache = scratch.path().join("compile-cache");
        std::env::set_var("IMPRINT_COMPILE_CACHE_DIR", &compile_cache);
        let db = scratch.path().join("impress.sqlite");
        let path = db.to_str().unwrap().to_owned();
        try_install_native_host(path.clone(), Box::new(TestHost)).unwrap();
        try_install_native_host(path, Box::new(TestHost)).unwrap();
        assert_eq!(
            impress_store_service::store::store_path(),
            std::fs::canonicalize(scratch.path())
                .unwrap()
                .join("impress.sqlite")
        );
        assert!(try_install_native_host(
            tempfile::tempdir()
                .unwrap()
                .path()
                .join("impress.sqlite")
                .to_str()
                .unwrap()
                .into(),
            Box::new(TestHost)
        )
        .is_err());

        let generic = impress_store_service::store::store_instance();
        assert!(!impress_store_service::store::is_fallback_store(&generic));
        let manuscript = mp::create_manuscript(
            &generic,
            NewManuscript {
                title: "Scratch",
                format: "typst",
                body: "= Scratch",
                entry_path: None,
                collection_ref: None,
            },
            &Author::human("user:test"),
        )
        .unwrap();
        let project = imprint_service::backend::project_service_instance();
        let result = project
            .project_put_file(
                manuscript.id.to_string(),
                "chapter.typ".into(),
                Some("= Chapter".into()),
                None,
                None,
                None,
            )
            .await;
        assert!(result.ok, "{}", result.message);

        // Independent readback from the caller-supplied path proves the
        // project backend did not fall through to the App Group/default store.
        let reopened = impress_core::sqlite_store::SqliteItemStore::open(&db).unwrap();
        let snapshot = mp::load_project(&reopened, manuscript.id).unwrap();
        assert!(snapshot.files.iter().any(|file| file.path == "chapter.typ"));
        let app = imprint_service::backend::app_service_instance();
        assert!(app.status().await.running);
        let result = crate::dispatch_verb_async(
            "imprint-app-service_status".into(),
            "{}".into(),
            r#"{"kind":"app","name":"imprint"}"#.into(),
        )
        .await;
        assert_eq!(result.status, 200, "{}", result.body_json);
        let missing = crate::dispatch_verb_async(
            "imprint-app-service_get-content".into(),
            json!({"document_id": manuscript.id.to_string()}).to_string(),
            r#"{"kind":"app","name":"imprint"}"#.into(),
        )
        .await;
        assert_eq!(missing.status, 404, "{}", missing.body_json);
        assert!(missing.body_json.contains("scratch document missing"));

        for (format, expected) in [
            (
                "typst",
                br#"{"source":"= Scratch","bibliography":[]}"#.as_slice(),
            ),
            ("latex", b"\\section{Scratch}".as_slice()),
            ("text", b"Scratch".as_slice()),
        ] {
            let exported = crate::dispatch_verb_async(
                "imprint-manuscript-service_export-document".into(),
                json!({"id": manuscript.id.to_string(), "format": format}).to_string(),
                r#"{"kind":"app","name":"imprint"}"#.into(),
            )
            .await;
            assert_eq!(exported.status, 200, "{}", exported.body_json);
            let bytes: Vec<u8> = serde_json::from_str(&exported.body_json).unwrap();
            assert_eq!(bytes, expected, "{format}");
        }
        let failed_export = crate::dispatch_verb_async(
            "imprint-manuscript-service_export-document".into(),
            json!({"id": "00000000-0000-0000-0000-000000000000", "format": "text"}).to_string(),
            r#"{"kind":"app","name":"imprint"}"#.into(),
        )
        .await;
        assert_eq!(failed_export.status, 404, "{}", failed_export.body_json);
        assert!(failed_export.body_json.contains("scratch export missing"));

        let compile = crate::dispatch_verb_async(
            "imprint-manuscript-service_compile-typst".into(),
            json!({"source":"= Native proof\n\nA short PDF.\n",
                "options":CompileOptions::default()})
            .to_string(),
            r#"{"kind":"app","name":"imprint"}"#.into(),
        )
        .await;
        assert_eq!(compile.status, 200, "{}", compile.body_json);
        let value: Value = serde_json::from_str(&compile.body_json).unwrap();
        assert!(value["error"].is_null(), "{value}");
        assert!(value["page_count"].as_u64().unwrap_or_default() >= 1);
        let pdf_path = std::path::Path::new(value["pdf_path"].as_str().unwrap());
        assert!(pdf_path.starts_with(&compile_cache));
        assert!(std::fs::read(pdf_path).unwrap().starts_with(b"%PDF"));
    }
}
