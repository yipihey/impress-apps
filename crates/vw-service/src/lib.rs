//! Semantic service contract for the VW diagnostic application.
//!
//! The contract exposes domain commands and assessments, never item CRUD,
//! arbitrary queries, or database representations.

#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::impress_service;
use schemars::gen::SchemaGenerator;
use schemars::schema::{InstanceType, ObjectValidation, Schema, SchemaObject, SingleOrVec};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use vw_domain::{
    CloseSessionCommand, CreateSessionRequest, DiagnosticAssessment, DiagnosticSession,
    NextTestRecommendation, Procedure, RecordMeasurementCommand, RecordObservationCommand,
    RecordProcedureStepCommand, StartProcedureCommand,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ServiceError {
    pub code: String,
    pub message: String,
    pub expected_revision: Option<u64>,
    pub actual_revision: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct SessionResult {
    pub ok: bool,
    pub session: Option<DiagnosticSession>,
    pub error: Option<ServiceError>,
    pub replayed: bool,
}

impl SessionResult {
    pub fn success(session: DiagnosticSession) -> Self {
        Self {
            ok: true,
            session: Some(session),
            error: None,
            replayed: false,
        }
    }

    pub fn failure(error: ServiceError) -> Self {
        Self {
            ok: false,
            session: None,
            error: Some(error),
            replayed: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct AssessmentResult {
    pub ok: bool,
    pub assessment: Option<DiagnosticAssessment>,
    pub error: Option<ServiceError>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct NextTestResult {
    pub ok: bool,
    pub recommendation: Option<NextTestRecommendation>,
    pub trace_hash: Option<String>,
    pub error: Option<ServiceError>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ProcedureListResult {
    pub ok: bool,
    pub procedures: Vec<Procedure>,
    pub error: Option<ServiceError>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct SessionListResult {
    pub ok: bool,
    pub sessions: Vec<DiagnosticSession>,
    pub error: Option<ServiceError>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct VwCapabilities {
    pub domain: String,
    pub supported_configuration: String,
    pub knowledge_pack_id: String,
    pub knowledge_pack_version: String,
    pub published_hypotheses: usize,
    pub published_procedures: usize,
    pub published_rules: usize,
    pub deterministic_engine_version: String,
    pub safety_notice: String,
}

/// A file authorized by ChatGPT for this plugin. Its handoff URL is temporary
/// transport and is never persisted in the Impress graph.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatGptFile {
    pub download_url: String,
    pub file_id: String,
    pub mime_type: Option<String>,
    pub file_name: Option<String>,
}

// OpenAI's file-input scanner requires optional properties to be omittable
// strings rather than `string | null`, so this intentionally differs from
// schemars' default representation of `Option<String>`.
impl JsonSchema for ChatGptFile {
    fn schema_name() -> String {
        "OpenAIFile".into()
    }

    fn json_schema(_generator: &mut SchemaGenerator) -> Schema {
        let string = || {
            Schema::Object(SchemaObject {
                instance_type: Some(SingleOrVec::Single(Box::new(InstanceType::String))),
                ..SchemaObject::default()
            })
        };
        let mut object = ObjectValidation::default();
        for property in ["download_url", "file_id", "mime_type", "file_name"] {
            object.properties.insert(property.into(), string());
        }
        object.required = BTreeSet::from(["download_url".into(), "file_id".into()]);
        object.additional_properties = Some(Box::new(Schema::Bool(false)));
        Schema::Object(SchemaObject {
            instance_type: Some(SingleOrVec::Single(Box::new(InstanceType::Object))),
            object: Some(Box::new(object)),
            ..SchemaObject::default()
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PhotoEvidence {
    pub id: String,
    pub source_item_id: String,
    pub content_blob_id: String,
    pub source_content_hash: String,
    pub external_file_id: String,
    pub file_name: Option<String>,
    pub mime_type: String,
    pub byte_length: u64,
    pub pixel_width: Option<u32>,
    pub pixel_height: Option<u32>,
    pub title: String,
    pub description: String,
    pub component: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub captured_at: Option<String>,
    pub received_at: String,
    pub diagnostic_session_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct VwMcpImageBlock {
    #[serde(rename = "type")]
    pub kind: String,
    pub data: String,
    #[serde(rename = "mimeType")]
    pub mime_type: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PhotoEvidenceResult {
    pub ok: bool,
    pub status: String,
    pub message: String,
    pub evidence: Option<PhotoEvidence>,
    #[serde(
        rename = "_mcp_content",
        default,
        skip_serializing_if = "Vec::is_empty"
    )]
    pub mcp_content: Vec<VwMcpImageBlock>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PhotoEvidenceSearchResult {
    pub ok: bool,
    pub message: String,
    pub hits: Vec<PhotoEvidence>,
}

#[impress_service]
pub trait VwDiagnosticService: Send + Sync + 'static {
    /// Describe supported vehicle scope, active curated knowledge, deterministic
    /// engine version, and the assistant's safety boundary.
    #[impress_method]
    async fn get_capabilities(&self) -> VwCapabilities;

    /// Ingest a bus, engine, or part photo shared in this ChatGPT conversation
    /// as private, immutable user evidence. Use this when the user asks the
    /// expert to remember/analyze an attached VW photo or clearly supplies it
    /// as diagnostic evidence. Never use it for unrelated images.
    #[impress_method]
    async fn ingest_photo(
        &self,
        photo: ChatGptFile,
        title: String,
        description: String,
        component: Option<String>,
        diagnostic_session_id: Option<String>,
        captured_at: Option<String>,
        tags: Vec<String>,
    ) -> PhotoEvidenceResult;

    /// Search private photos previously ingested as VW user evidence. Search
    /// titles, descriptions, component names, filenames, and tags; optionally
    /// constrain results to one diagnostic session.
    #[impress_method]
    async fn search_photos(
        &self,
        query: String,
        diagnostic_session_id: Option<String>,
        limit: u32,
    ) -> PhotoEvidenceSearchResult;

    /// Retrieve one previously ingested VW user photo as MCP image content.
    /// Call search-photos first when the evidence id is unknown.
    #[impress_method]
    async fn get_photo(&self, evidence_id: String) -> PhotoEvidenceResult;

    /// Create a persistent diagnostic session pinned to the active knowledge
    /// pack. command_id makes retries idempotent.
    #[impress_method]
    async fn create_session(&self, request: CreateSessionRequest) -> SessionResult;

    /// Load one typed diagnostic session and its current optimistic revision.
    #[impress_method]
    async fn get_session(&self, session_id: String) -> SessionResult;

    /// List recent diagnostic sessions without exposing raw store records.
    #[impress_method]
    async fn list_sessions(&self, limit: u32) -> SessionListResult;

    /// Record a controlled observation. The command is rejected if its expected
    /// revision is stale and replayed safely if command_id was already applied.
    #[impress_method]
    async fn record_observation(&self, command: RecordObservationCommand) -> SessionResult;

    /// Record a typed measurement with unit, acquisition method, conditions,
    /// and optional component/terminal context.
    #[impress_method]
    async fn record_measurement(&self, command: RecordMeasurementCommand) -> SessionResult;

    /// Evaluate published rules against an explicit session revision and return
    /// ordinal hypothesis priorities, citations, and a deterministic trace.
    #[impress_method]
    async fn evaluate_session(
        &self,
        session_id: String,
        expected_revision: u64,
    ) -> AssessmentResult;

    /// Return the highest-ranked safe and applicable next diagnostic procedure.
    #[impress_method]
    async fn recommend_next_test(
        &self,
        session_id: String,
        expected_revision: u64,
    ) -> NextTestResult;

    /// List published procedures applicable to the session's exact vehicle
    /// configuration.
    #[impress_method]
    async fn list_applicable_procedures(&self, session_id: String) -> ProcedureListResult;

    /// Start a published procedure only after required hazards are explicitly
    /// acknowledged.
    #[impress_method]
    async fn start_procedure(&self, command: StartProcedureCommand) -> SessionResult;

    /// Record the result of exactly the procedure run's current step. The
    /// domain state machine selects the next legal step.
    #[impress_method]
    async fn record_procedure_step(&self, command: RecordProcedureStepCommand) -> SessionResult;

    /// Close a session with a durable outcome; closed sessions reject further
    /// evidence mutations.
    #[impress_method]
    async fn close_session(&self, command: CloseSessionCommand) -> SessionResult;
}
