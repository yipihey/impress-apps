//! `ImprintAppService` — capabilities that live in the running imprint app.
//!
//! The mirror of `imbib-service`'s `app_service`, and for the same reason:
//! `imprint-service`'s other traits model the shared store and answer with
//! imprint closed, while these cannot.
//!
//! * **Comments** are review state on a manuscript, owned by the editor.
//! * **Content edits** (`insert_text`, `delete_text`, `replace`) go through the
//!   app so the open editor, its undo stack and its source map stay in step. A
//!   direct store write would leave the editor showing text that is no longer
//!   there.
//! * **The compiled PDF** is a render artifact, produced by the app's
//!   persistent Typst engine.
//! * **The bibliography** is assembled at compile time from `@cite` keys
//!   resolved against the imbib library — it exists only as a compile input.
//! * **Logs and status** describe a running process.
//!
//! The default backend refuses and says so; native callbacks installed by
//! `imprint-verbs-ffi` do the real work in the running app.

use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

/// A reviewer comment anchored in a manuscript.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CommentRecord {
    pub id: String,
    #[serde(default, alias = "documentID", alias = "document_id")]
    pub document_id: Option<String>,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub author: Option<String>,
    #[serde(default, alias = "authorId", alias = "author_id")]
    pub author_id: Option<String>,
    /// The route's original field name, retained alongside `body` for parity.
    #[serde(default)]
    pub content: Option<String>,
    /// `open` or `resolved`, matching the retained route's status projection.
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default, alias = "createdAt")]
    pub created_at: Option<String>,
    #[serde(default, alias = "modifiedAt")]
    pub modified_at: Option<String>,
    #[serde(default, alias = "isResolved")]
    pub is_resolved: Option<bool>,
    #[serde(default, alias = "isSuggestion")]
    pub is_suggestion: Option<bool>,
    #[serde(default, alias = "parentId")]
    pub parent_id: Option<String>,
    #[serde(default, alias = "proposedText")]
    pub proposed_text: Option<String>,
    #[serde(default, alias = "authorAgentId")]
    pub author_agent_id: Option<String>,
    #[serde(default)]
    pub range: Option<CommentRange>,
    /// Where in the source it is anchored, when it is anchored at all.
    #[serde(default)]
    pub anchor: Option<String>,
}

/// Live editor range in UTF-16 code units, matching Foundation's NSRange.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CommentRange {
    pub start: u32,
    pub end: u32,
}

/// Acceptance is applied and saved through the live editor. The operation ID
/// is the same handle returned by the retained HTTP route and can be polled.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SuggestionApplyResult {
    pub accepted: bool,
    #[serde(alias = "commentId")]
    pub comment_id: String,
    #[serde(alias = "documentId")]
    pub document_id: String,
    #[serde(alias = "operationId")]
    pub operation_id: String,
}

#[cfg(test)]
mod comment_contract_tests {
    use super::{CommentRecord, SuggestionApplyResult};

    #[test]
    fn comment_record_reads_the_retained_route_metadata_and_utf16_range() {
        let record: CommentRecord = serde_json::from_value(serde_json::json!({
            "id": "comment-id",
            "document_id": "document-id",
            "body": "Reply text",
            "content": "Reply text",
            "author": "Review Agent",
            "authorId": "agent:reviewer",
            "status": "open",
            "createdAt": "2026-09-29T12:00:00Z",
            "modifiedAt": "2026-09-29T12:00:01Z",
            "isResolved": false,
            "isSuggestion": true,
            "parentId": "parent-id",
            "proposedText": "Revised text",
            "authorAgentId": "reviewer",
            "range": {"start": 12, "end": 19},
            "anchor": "quoted"
        }))
        .expect("retained route comment fields deserialize");

        assert_eq!(record.parent_id.as_deref(), Some("parent-id"));
        assert_eq!(record.proposed_text.as_deref(), Some("Revised text"));
        assert_eq!(record.author_agent_id.as_deref(), Some("reviewer"));
        assert_eq!(record.author_id.as_deref(), Some("agent:reviewer"));
        assert_eq!(record.content.as_deref(), Some("Reply text"));
        assert_eq!(record.is_suggestion, Some(true));
        let range = record.range.expect("route includes the live editor range");
        assert_eq!((range.start, range.end), (12, 19));
    }

    #[test]
    fn comment_record_keeps_older_native_responses_compatible() {
        let record: CommentRecord = serde_json::from_value(serde_json::json!({
            "id": "legacy-comment",
            "body": "Existing comment"
        }))
        .expect("older native records remain valid");

        assert_eq!(record.body, "Existing comment");
        assert!(record.parent_id.is_none());
        assert!(record.proposed_text.is_none());
        assert!(record.author_agent_id.is_none());
        assert!(record.range.is_none());
    }

    #[test]
    fn suggestion_apply_result_accepts_the_retained_route_response() {
        let result: SuggestionApplyResult = serde_json::from_value(serde_json::json!({
            "accepted": true,
            "commentId": "comment-id",
            "documentId": "document-id",
            "operationId": "operation-id"
        }))
        .expect("retained accept route response deserializes");

        assert!(result.accepted);
        assert_eq!(result.comment_id, "comment-id");
        assert_eq!(result.document_id, "document-id");
        assert_eq!(result.operation_id, "operation-id");
    }
}

/// One line from imprint's in-memory log store.
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

/// Free-form app state, returned verbatim so the endpoint can grow fields
/// without this DTO becoming one more thing to keep in step.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct AppStatus {
    pub running: bool,
    pub detail: String,
}

/// A compiled PDF, described rather than embedded.
///
/// The bytes are deliberately NOT returned here. MCP carries images, not
/// PDFs, so a base64 blob would spend the model's context to display nothing.
/// The path is what an agent on the user's Mac can actually open, and it is
/// what a future rasterise step will take as input.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CompiledPdf {
    pub ok: bool,
    /// Absolute path to the PDF on disk, when compilation succeeded.
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub page_count: Option<u32>,
    #[serde(default)]
    pub byte_size: Option<i64>,
    /// Compiler diagnostics. Present even on success (warnings).
    #[serde(default)]
    pub messages: Vec<String>,
}

#[impress_service]
pub trait ImprintAppService: Send + Sync + 'static {
    // G3 Tier B examples require an isolated running imprint host with a
    // scratch manuscript 5b...0001 containing "= G3 fixture\n", an open
    // editor session, and its registered comment service. The fixture must
    // reset before each example. `{{fixture.imprint_comment_id}}` is resolved
    // from a comment created by native setup; an unresolved token fails the
    // isolated runner rather than reaching a user's app.
    /// Whether imprint is running, and its version and port. Cheap; a good
    /// first call when a manuscript tool has reported the app unavailable.
    #[impress_method]
    #[impress_example(
        name = "isolated_app_status",
        tier = "b",
        args = r#"{}"#,
        expect = r#"{"running":true}"#
    )]
    async fn status(&self) -> AppStatus;

    /// Recent lines from imprint's in-memory log store — the same feed its
    /// Console window shows. `level` is a comma-separated filter
    /// (`info,warning,error`); `category` narrows to one subsystem.
    #[impress_method]
    #[impress_example(
        name = "recent_manuscript_logs",
        tier = "b",
        args = r#"{"limit":10,"level":"info,warning,error","category":"manuscripts"}"#
    )]
    async fn get_logs(
        &self,
        limit: u32,
        level: Option<String>,
        category: Option<String>,
    ) -> Vec<LogEntry>;

    /// Create a new imprint document and return its id. For a manuscript
    /// scaffolded from a journal template, use imbib's template tools instead —
    /// manuscripts are shared-store rows and imbib owns their creation.
    #[impress_method]
    #[impress_example(
        name = "create_typst_draft",
        tier = "b",
        args = r#"{"title":"G3 created draft","format":"typst"}"#
    )]
    async fn create_document(&self, title: String, format: Option<String>) -> Option<String>;

    /// Rename a document.
    #[impress_method]
    #[impress_example(
        name = "rename_fixture_document",
        tier = "b",
        args = r#"{"document_id":"5b000000-0000-4000-8000-000000000001","title":"G3 renamed draft"}"#,
        expect = "true"
    )]
    async fn update_document(&self, document_id: String, title: Option<String>) -> bool;

    /// Update supported document metadata fields from a JSON object: title,
    /// status, authors, ORCID, affiliation, funder, or license. The native
    /// editor saves and reads back each supplied field; omitted fields stay.
    #[impress_method]
    #[impress_example(
        name = "set_fixture_authors",
        tier = "b",
        args = r#"{"document_id":"5b000000-0000-4000-8000-000000000001","metadata_json":"{\"authors\":[\"G3 Fixture\"]}"}"#,
        expect = "true"
    )]
    async fn update_metadata(&self, document_id: String, metadata_json: String) -> bool;

    /// The full source text of a manuscript. Use this to read before editing;
    /// section-level reads are cheaper when you know which section you want.
    #[impress_method]
    #[impress_example(
        name = "read_fixture_source",
        tier = "b",
        args = r#"{"document_id":"5b000000-0000-4000-8000-000000000001"}"#,
        expect = r#""= G3 fixture\n""#
    )]
    async fn get_content(&self, document_id: String) -> Option<String>;

    /// Insert text at a UTF-16 editor offset in a manuscript. Goes through the
    /// running app so the open editor, its undo stack and its source map stay
    /// in step. Prefer section-level writes when you are replacing a whole
    /// section — they are compare-and-set and cannot clobber a concurrent edit.
    #[impress_method]
    #[impress_example(
        name = "append_fixture_paragraph",
        tier = "b",
        args = r#"{"document_id":"5b000000-0000-4000-8000-000000000001","offset":13,"text":"A paragraph.\n"}"#,
        expect = "true"
    )]
    async fn insert_text(&self, document_id: String, offset: u32, text: String) -> bool;

    /// Delete a UTF-16 editor range from a manuscript. Offsets are into the source
    /// text; read it first, since they shift with every edit.
    #[impress_method]
    #[impress_example(
        name = "remove_fixture_prefix",
        tier = "b",
        args = r#"{"document_id":"5b000000-0000-4000-8000-000000000001","offset":2,"length":3}"#,
        expect = "true"
    )]
    async fn delete_text(&self, document_id: String, offset: u32, length: u32) -> bool;

    /// Replace every occurrence of `find` with `replace` in a manuscript.
    /// Returns how many were changed. Whole-document and not undoable as a
    /// unit — read the content first and check what you are about to match.
    #[impress_method]
    #[impress_example(
        name = "replace_fixture_word",
        tier = "b",
        args = r#"{"document_id":"5b000000-0000-4000-8000-000000000001","find":"fixture","replace":"example"}"#,
        expect = "1"
    )]
    async fn replace(&self, document_id: String, find: String, replace: String) -> u32;

    /// Compile a manuscript and report where the PDF landed. The bytes are not
    /// returned: MCP carries images, not PDFs, so a base64 blob would spend
    /// context to display nothing. Diagnostics come back either way.
    #[impress_method]
    #[impress_example(
        name = "compile_fixture_pdf",
        tier = "b",
        args = r#"{"document_id":"5b000000-0000-4000-8000-000000000001"}"#,
        expect = r#"{"ok":true}"#
    )]
    async fn get_pdf(&self, document_id: String) -> CompiledPdf;

    /// The BibTeX bibliography a manuscript resolves to: every `@citeKey` in
    /// the source, looked up against the imbib library. This is a compile
    /// input assembled on demand, not a file in the project — which is why a
    /// missing key shows up here rather than as a file-not-found.
    #[impress_method]
    #[impress_example(
        name = "fixture_bibliography",
        tier = "b",
        args = r#"{"document_id":"5b000000-0000-4000-8000-000000000001"}"#,
        expect = r#""""#
    )]
    async fn get_bibliography(&self, document_id: String) -> Option<String>;

    /// Review comments on a manuscript. `filter` accepts the same values as
    /// the retained route (`all`, `unresolved`, `resolved`, `suggestions`);
    /// `author_agent_id` further narrows to comments by that agent.
    #[impress_method]
    #[impress_example(
        name = "fixture_review_comments",
        tier = "b",
        args = r#"{"document_id":"5b000000-0000-4000-8000-000000000001"}"#
    )]
    async fn list_comments(
        &self,
        document_id: String,
        filter: Option<String>,
        author_agent_id: Option<String>,
    ) -> Vec<CommentRecord>;

    /// Add a review comment to a manuscript. Anchor it to a quoted snippet
    /// where you can — an unanchored comment is much harder to act on.
    #[impress_method]
    #[impress_example(
        name = "comment_on_fixture_heading",
        tier = "b",
        args = r#"{"document_id":"5b000000-0000-4000-8000-000000000001","body":"Clarify this heading.","anchor":"G3 fixture"}"#,
        expect = r#"{"body":"Clarify this heading.","status":"open"}"#
    )]
    async fn create_comment(
        &self,
        document_id: String,
        body: String,
        anchor: Option<String>,
        parent_id: Option<String>,
        proposed_text: Option<String>,
        author_agent_id: Option<String>,
        author_name: Option<String>,
    ) -> Option<CommentRecord>;

    /// Edit a comment's body, or set its status to `open` or `resolved`.
    /// Use the dedicated suggestion actions to apply or reject a proposed edit;
    /// this method accepts only `open` and `resolved`.
    #[impress_method]
    #[impress_example(
        name = "resolve_fixture_comment",
        tier = "b",
        args = r#"{"comment_id":"{{fixture.imprint_comment_id}}","status":"resolved"}"#,
        expect = "true"
    )]
    async fn update_comment(
        &self,
        comment_id: String,
        body: Option<String>,
        status: Option<String>,
    ) -> bool;

    /// Delete a comment outright. Resolving one by setting its status is
    /// usually better — it keeps the review trail.
    #[impress_method]
    #[impress_example(
        name = "delete_fixture_comment",
        tier = "b",
        args = r#"{"comment_id":"{{fixture.imprint_comment_id}}"}"#,
        expect = "true"
    )]
    async fn delete_comment(&self, comment_id: String) -> bool;

    /// Accept a proposed replacement. The live editor applies and saves it at
    /// the comment's UTF-16 range and returns its completed operation handle.
    #[impress_method]
    async fn accept_comment_suggestion(&self, comment_id: String) -> SuggestionApplyResult;

    /// Reject a proposed replacement by resolving the comment without editing
    /// the manuscript.
    #[impress_method]
    async fn reject_comment_suggestion(&self, comment_id: String) -> bool;
}

/// The store-backed default: refuses, because none of this exists outside the
/// running app.
#[derive(Clone, Default)]
pub struct DefaultImprintAppService;

impl DefaultImprintAppService {
    pub fn new() -> Self {
        Self
    }
}

const NOT_RUNNING: &str = "imprint is not running. This capability lives in the app — the open \
     editor's undo stack and source map, the Typst render engine, the log \
     store and manuscript review state are all app state, not store rows. \
     Open imprint and try again.";

fn refuse(method: &str) {
    eprintln!("[imprint-app-service] {method}: imprint not running; refused");
}

#[async_trait::async_trait]
impl ImprintAppService for DefaultImprintAppService {
    async fn status(&self) -> AppStatus {
        AppStatus {
            running: false,
            detail: "imprint is not running.".into(),
        }
    }

    async fn get_logs(
        &self,
        _limit: u32,
        _level: Option<String>,
        _category: Option<String>,
    ) -> Vec<LogEntry> {
        refuse("get_logs");
        vec![]
    }

    async fn create_document(&self, _title: String, _format: Option<String>) -> Option<String> {
        refuse("create_document");
        None
    }
    async fn update_document(&self, _document_id: String, _title: Option<String>) -> bool {
        refuse("update_document");
        false
    }
    async fn update_metadata(&self, _document_id: String, _metadata_json: String) -> bool {
        refuse("update_metadata");
        false
    }
    async fn get_content(&self, _document_id: String) -> Option<String> {
        refuse("get_content");
        None
    }

    async fn insert_text(&self, _document_id: String, _offset: u32, _text: String) -> bool {
        refuse("insert_text");
        false
    }

    async fn delete_text(&self, _document_id: String, _offset: u32, _length: u32) -> bool {
        refuse("delete_text");
        false
    }

    async fn replace(&self, _document_id: String, _find: String, _replace: String) -> u32 {
        refuse("replace");
        0
    }

    async fn get_pdf(&self, _document_id: String) -> CompiledPdf {
        refuse("get_pdf");
        CompiledPdf {
            ok: false,
            path: None,
            page_count: None,
            byte_size: None,
            messages: vec![NOT_RUNNING.into()],
        }
    }

    async fn get_bibliography(&self, _document_id: String) -> Option<String> {
        refuse("get_bibliography");
        None
    }

    async fn list_comments(
        &self,
        _document_id: String,
        _filter: Option<String>,
        _author_agent_id: Option<String>,
    ) -> Vec<CommentRecord> {
        refuse("list_comments");
        vec![]
    }

    async fn create_comment(
        &self,
        _document_id: String,
        _body: String,
        _anchor: Option<String>,
        _parent_id: Option<String>,
        _proposed_text: Option<String>,
        _author_agent_id: Option<String>,
        _author_name: Option<String>,
    ) -> Option<CommentRecord> {
        refuse("create_comment");
        None
    }

    async fn update_comment(
        &self,
        _comment_id: String,
        _body: Option<String>,
        _status: Option<String>,
    ) -> bool {
        refuse("update_comment");
        false
    }

    async fn delete_comment(&self, _comment_id: String) -> bool {
        refuse("delete_comment");
        false
    }

    async fn accept_comment_suggestion(&self, comment_id: String) -> SuggestionApplyResult {
        refuse("accept_comment_suggestion");
        SuggestionApplyResult {
            accepted: false,
            comment_id,
            document_id: String::new(),
            operation_id: String::new(),
        }
    }

    async fn reject_comment_suggestion(&self, _comment_id: String) -> bool {
        refuse("reject_comment_suggestion");
        false
    }
}

impress_service_impl! {
    service = ImprintAppService,
    safety = external,
    since = "0.1.0",
    effects = {
        reads: [],
        writes: [],
        reach: [app("imprint")],
    },
    impl = DefaultImprintAppService,
    instance = crate::backend::app_service_instance,
    methods = [
        status() -> AppStatus,
        get_logs(
            /// Maximum recent log entries to return.
            limit: u32,
            /// Comma-separated levels, such as `info,warning,error`; omit for all levels.
            level: Option<String>,
            /// Optional logging subsystem name.
            category: Option<String>
        ) -> Vec<LogEntry>,
        create_document(
            /// Title for the new manuscript.
            title: String,
            /// Manuscript format, such as `typst`; omit for the app default.
            format: Option<String>
        ) -> Option<String>,
        update_document(
            /// UUID of the manuscript to rename.
            document_id: String,
            /// Replacement title; omit to leave it unchanged.
            title: Option<String>
        ) -> bool,
        update_metadata(
            /// UUID of the manuscript whose metadata will be replaced.
            document_id: String,
            /// JSON object encoded as a string, containing supported metadata fields to update.
            metadata_json: String
        ) -> bool,
        get_content(
            /// UUID of the manuscript whose full source is needed.
            document_id: String
        ) -> Option<String>,
        insert_text(
            /// UUID of the manuscript open in the editor.
            document_id: String,
            /// UTF-16 insertion offset in the current source.
            offset: u32,
            /// Text to insert at the editor offset; kept private in call logs.
            #[impress_private] text: String
        ) -> bool,
        delete_text(
            /// UUID of the manuscript open in the editor.
            document_id: String,
            /// UTF-16 start offset of the text to remove.
            offset: u32,
            /// Number of UTF-16 code units to remove.
            length: u32
        ) -> bool,
        replace(
            /// UUID of the manuscript whose source is searched.
            document_id: String,
            /// Exact source text to find throughout the manuscript.
            find: String,
            /// Replacement source text; kept private in call logs.
            #[impress_private] replace: String
        ) -> u32,
        get_pdf(
            /// UUID of the manuscript to compile in the running app.
            document_id: String
        ) -> CompiledPdf,
        get_bibliography(
            /// UUID of the manuscript whose citation keys are resolved.
            document_id: String
        ) -> Option<String>,
        list_comments(
            /// UUID of an open manuscript with a registered comment service.
            document_id: String,
            /// Route-compatible filter: all, unresolved, resolved, or suggestions.
            filter: Option<String>,
            /// Only comments attributed to this agent identifier.
            author_agent_id: Option<String>
        ) -> Vec<CommentRecord>,
        create_comment(
            /// UUID of an open manuscript with a registered comment service.
            document_id: String,
            /// Review comment text; kept private in call logs.
            #[impress_private] body: String,
            /// Optional exact source snippet to anchor the comment.
            anchor: Option<String>,
            /// Optional parent UUID; replies inherit its live text range.
            parent_id: Option<String>,
            /// Proposed replacement text; private in call logs. Applying it is separate.
            #[impress_private] proposed_text: Option<String>,
            /// Agent identity used for comment attribution and author filtering.
            author_agent_id: Option<String>,
            /// Optional display name; defaults to the existing local/agent name.
            author_name: Option<String>
        ) -> Option<CommentRecord>,
        update_comment(
            /// UUID of an existing comment in an open manuscript.
            comment_id: String,
            /// Replacement comment text; omit to keep the current body.
            body: Option<String>,
            /// `open` or `resolved`; `accepted` and `rejected` require suggestion actions.
            status: Option<String>
        ) -> bool,
        delete_comment(
            /// UUID of the comment to remove from an open manuscript.
            comment_id: String
        ) -> bool,
        accept_comment_suggestion(
            /// UUID of an unresolved suggestion to apply in the live editor.
            comment_id: String
        ) -> SuggestionApplyResult,
        reject_comment_suggestion(
            /// UUID of a suggestion to resolve without changing manuscript text.
            comment_id: String
        ) -> bool,
    ],
}
