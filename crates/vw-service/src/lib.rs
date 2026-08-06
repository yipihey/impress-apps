//! Semantic service contract for the VW diagnostic application.
//!
//! The contract exposes domain commands and assessments, never item CRUD,
//! arbitrary queries, or database representations.

#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::impress_service;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
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

#[impress_service]
pub trait VwDiagnosticService: Send + Sync + 'static {
    /// Describe supported vehicle scope, active curated knowledge, deterministic
    /// engine version, and the assistant's safety boundary.
    #[impress_method]
    async fn get_capabilities(&self) -> VwCapabilities;

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
