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
    #[impress_method(effects())]
    #[impress_example(name = "default", args = r#"{}"#)]
    async fn get_capabilities(&self) -> VwCapabilities;

    /// Ingest a bus, engine, or part photo shared in this ChatGPT conversation
    /// as private, immutable user evidence. Use this when the user asks the
    /// expert to remember/analyze an attached VW photo or clearly supplies it
    /// as diagnostic evidence. Never use it for unrelated images.
    #[impress_method(safety = external, effects(reads = ["vw/diagnostic-session@1.0.0"], writes = ["vw/photo-evidence@1.0.0", "content-blob@1.0.0"], reach = [network, fs]))]
    #[impress_example(
        name = "g3-ingest-photo",
        args = r##"{"photo":{"file_id":"g3-private-url","download_url":"http://127.0.0.1/private.png","mime_type":"image/png","file_name":"private.png"},"title":"Private address refusal","description":"Reject private network access before downloading.","component":null,"diagnostic_session_id":null,"captured_at":null,"tags":[]}"##,
        expect = r##"{"ok":false,"status":"invalid_file_url"}"##,
        tier = "b"
    )]
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
    #[impress_method(effects(reads = ["vw/photo-evidence@1.0.0"]))]
    #[impress_example(
        name = "g3-search-photos",
        args = r##"{"query":"G3 photo","diagnostic_session_id":null,"limit":5}"##,
        expect = r##"{"ok":true}"##
    )]
    async fn search_photos(
        &self,
        query: String,
        diagnostic_session_id: Option<String>,
        limit: u32,
    ) -> PhotoEvidenceSearchResult;

    /// Retrieve one previously ingested VW user photo as MCP image content.
    /// Call search-photos first when the evidence id is unknown.
    #[impress_method(effects(reads = ["vw/photo-evidence@1.0.0", "content-blob@1.0.0"]))]
    #[impress_example(
        name = "g3-get-photo",
        args = r##"{"evidence_id":"{{fixture.vw_photo_id}}"}"##,
        expect = r##"{"ok":true}"##
    )]
    async fn get_photo(&self, evidence_id: String) -> PhotoEvidenceResult;

    /// Create a persistent diagnostic session pinned to the active knowledge
    /// pack. command_id makes retries idempotent.
    #[impress_method(safety = mutating, effects(reads = ["vw/vehicle@1.0.0", "vw/configuration@1.0.0", "vw/diagnostic-session@1.0.0"], writes = ["vw/diagnostic-session@1.0.0", "vw/vehicle@1.0.0", "vw/configuration@1.0.0", "vw/command-receipt@1.0.0"]))]
    #[impress_example(
        name = "g3-create-session",
        args = r##"{"request":{"command_id":"67000000-0000-4000-8000-000000000001","vehicle_name":"G3 fictional vehicle","vin":null,"configuration":{"id":"67000000-0000-4000-8000-000000000002","model_family":"Type 2","model_year":1978,"market":"california","emissions_spec":"California","engine_code":"fixture","fuel_system":"L-Jetronic","transmission":null,"installed_options":[],"installed_components":[],"deviations":[],"verification":"unverified"},"concern":"Record a fictional intermittent starting concern","odometer":null,"notes":"Synthetic example; no diagnosis is asserted."}}"##,
        expect = r##"{"ok":true,"session":{"revision":0}}"##
    )]
    async fn create_session(&self, request: CreateSessionRequest) -> SessionResult;

    /// Load one typed diagnostic session and its current optimistic revision.
    #[impress_method(effects(reads = ["vw/diagnostic-session@1.0.0"]))]
    #[impress_example(
        name = "g3-get-session",
        args = r##"{"session_id":"{{fixture.vw_session_id}}"}"##,
        expect = r##"{"ok":true,"session":{"revision":0}}"##
    )]
    async fn get_session(&self, session_id: String) -> SessionResult;

    /// List recent diagnostic sessions without exposing raw store records.
    #[impress_method(effects(reads = ["vw/diagnostic-session@1.0.0"]))]
    #[impress_example(name = "default", args = r#"{"limit": 5}"#)]
    async fn list_sessions(&self, limit: u32) -> SessionListResult;

    /// Record a controlled observation. The command is rejected if its expected
    /// revision is stale and replayed safely if command_id was already applied.
    #[impress_method(safety = mutating, effects(reads = ["vw/diagnostic-session@1.0.0", "vw/procedure-run@1.0.0"], writes = ["vw/diagnostic-session@1.0.0", "vw/observation@1.0.0", "vw/command-receipt@1.0.0"]))]
    #[impress_example(
        name = "g3-record-observation",
        args = r##"{"command":{"session_id":"{{fixture.vw_session_id}}","expected_revision":0,"command_id":"67000000-0000-4000-8000-000000000003","kind":"symptom","value":{"type":"text","value":"Fictional engine pauses at idle"},"acquisition":{"type":"user_reported"},"confidence":"uncertain","component_key":null,"conditions":[],"notes":null,"supersedes":null}}"##,
        expect = r##"{"ok":true,"session":{"revision":1}}"##
    )]
    async fn record_observation(&self, command: RecordObservationCommand) -> SessionResult;

    /// Record a typed measurement with unit, acquisition method, conditions,
    /// and optional component/terminal context.
    #[impress_method(safety = mutating, effects(reads = ["vw/diagnostic-session@1.0.0", "vw/procedure-run@1.0.0"], writes = ["vw/diagnostic-session@1.0.0", "vw/measurement@1.0.0", "vw/command-receipt@1.0.0"]))]
    #[impress_example(
        name = "g3-record-measurement",
        args = r##"{"command":{"session_id":"{{fixture.vw_session_id}}","expected_revision":0,"command_id":"67000000-0000-4000-8000-000000000004","quantity":"fixture_voltage","value":{"value":12.4,"unit":"V","uncertainty":0.1},"acquisition":{"type":"instrument","kind":"fictional meter","identifier":null},"component_key":null,"terminals":null,"conditions":[],"source_step":null,"notes":"Synthetic measurement; not a diagnostic threshold."}}"##,
        expect = r##"{"ok":true,"session":{"revision":1}}"##
    )]
    async fn record_measurement(&self, command: RecordMeasurementCommand) -> SessionResult;

    /// Evaluate published rules against an explicit session revision and return
    /// ordinal hypothesis priorities, citations, and a deterministic trace.
    #[impress_method]
    #[impress_example(
        name = "g3-evaluate-session",
        args = r##"{"session_id":"{{fixture.vw_session_id}}","expected_revision":0}"##,
        expect = r##"{"ok":true}"##
    )]
    async fn evaluate_session(
        &self,
        session_id: String,
        expected_revision: u64,
    ) -> AssessmentResult;

    /// Return the highest-ranked safe and applicable next diagnostic procedure.
    #[impress_method]
    #[impress_example(
        name = "g3-recommend-next-test",
        args = r##"{"session_id":"{{fixture.vw_session_id}}","expected_revision":0}"##,
        expect = r##"{"ok":true}"##
    )]
    async fn recommend_next_test(
        &self,
        session_id: String,
        expected_revision: u64,
    ) -> NextTestResult;

    /// List published procedures applicable to the session's exact vehicle
    /// configuration.
    #[impress_method(effects(reads = ["vw/diagnostic-session@1.0.0", "vw/procedure-run@1.0.0"]))]
    #[impress_example(
        name = "g3-list-applicable-procedures",
        args = r##"{"session_id":"{{fixture.vw_session_id}}"}"##,
        expect = r##"{"ok":true}"##
    )]
    async fn list_applicable_procedures(&self, session_id: String) -> ProcedureListResult;

    /// Start a published procedure only after required hazards are explicitly
    /// acknowledged.
    #[impress_method(safety = mutating, effects(reads = ["vw/diagnostic-session@1.0.0", "vw/procedure-run@1.0.0"], writes = ["vw/procedure-run@1.0.0", "vw/command-receipt@1.0.0"]))]
    #[impress_example(
        name = "g3-start-procedure",
        args = r##"{"command":{"session_id":"{{fixture.vw_session_id}}","expected_revision":1,"command_id":"67000000-0000-4000-8000-000000000005","procedure_id":"closed-session-guard","acknowledged_hazard_ids":[],"performed_by":"fixture"}}"##,
        expect = r##"{"ok":false,"error":{"code":"invalid_state"}}"##
    )]
    async fn start_procedure(&self, command: StartProcedureCommand) -> SessionResult;

    /// Record the result of exactly the procedure run's current step. The
    /// domain state machine selects the next legal step.
    #[impress_method(safety = mutating, effects(reads = ["vw/diagnostic-session@1.0.0", "vw/procedure-run@1.0.0"], writes = ["vw/procedure-run@1.0.0", "vw/command-receipt@1.0.0"]))]
    #[impress_example(
        name = "g3-record-procedure-step",
        args = r##"{"command":{"session_id":"{{fixture.vw_session_id}}","expected_revision":1,"command_id":"67000000-0000-4000-8000-000000000006","procedure_run_id":"closed-session-guard","step_key":"guard","result":"must not be recorded"}}"##,
        expect = r##"{"ok":false,"error":{"code":"invalid_state"}}"##
    )]
    async fn record_procedure_step(&self, command: RecordProcedureStepCommand) -> SessionResult;

    /// Close a session with a durable outcome; closed sessions reject further
    /// evidence mutations.
    #[impress_method(safety = mutating, effects(reads = ["vw/diagnostic-session@1.0.0"], writes = ["vw/diagnostic-session@1.0.0", "vw/command-receipt@1.0.0"]))]
    #[impress_example(
        name = "g3-close-session",
        args = r##"{"command":{"session_id":"{{fixture.vw_session_id}}","expected_revision":0,"command_id":"67000000-0000-4000-8000-000000000007","outcome":"Fictional example complete; no diagnostic conclusion"}}"##,
        expect = r##"{"ok":true,"session":{"revision":1}}"##
    )]
    async fn close_session(&self, command: CloseSessionCommand) -> SessionResult;
}
