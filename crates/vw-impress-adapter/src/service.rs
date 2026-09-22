use std::sync::{Arc, Mutex, OnceLock};

use impress_service_core::async_trait;
use impress_service_macros::impress_service_impl;
use uuid::Uuid;
use vw_domain::{
    ApplicabilityMatch, CloseSessionCommand, CreateSessionRequest, DeterministicEngine,
    DiagnosticRepository, DiagnosticSession, DomainError, KnowledgePack, KnowledgeStatus,
    RecordMeasurementCommand, RecordObservationCommand, RecordProcedureStepCommand,
    RepositoryError, SessionId, StartProcedureCommand,
};
use vw_service::{
    __IMPRESS_SERVICE_DOCS_VwDiagnosticService, AssessmentResult, ChatGptFile, NextTestResult,
    PhotoEvidenceResult, PhotoEvidenceSearchResult, ProcedureListResult, ServiceError,
    SessionListResult, SessionResult, VwCapabilities, VwDiagnosticService,
};

use crate::{ImpressDiagnosticRepository, PhotoDescription, PhotoEvidenceStore};

#[derive(Clone)]
pub struct DefaultVwDiagnosticService {
    repository: Arc<ImpressDiagnosticRepository>,
    mutation_lock: Arc<Mutex<()>>,
    photo_evidence: Arc<PhotoEvidenceStore>,
}

impl DefaultVwDiagnosticService {
    pub fn new(repository: Arc<ImpressDiagnosticRepository>) -> Self {
        let blob_root = impress_store_service::store_path()
            .parent()
            .unwrap_or_else(|| std::path::Path::new("."))
            .join("blobs");
        Self::with_photo_evidence(
            repository,
            PhotoEvidenceStore::new(blob_root).expect("fixed photo downloader configuration"),
        )
    }

    pub fn with_photo_evidence(
        repository: Arc<ImpressDiagnosticRepository>,
        photo_evidence: PhotoEvidenceStore,
    ) -> Self {
        Self {
            repository,
            mutation_lock: Arc::new(Mutex::new(())),
            photo_evidence: Arc::new(photo_evidence),
        }
    }

    pub fn with_store(
        store: Arc<impress_core::sqlite_store::SqliteItemStore>,
        pack: KnowledgePack,
    ) -> Self {
        Self::new(Arc::new(ImpressDiagnosticRepository::new(store, pack)))
    }

    fn pack(&self) -> Result<KnowledgePack, ServiceError> {
        self.repository.active_knowledge_pack().map_err(repo_error)
    }

    fn load(&self, session_id: &str) -> Result<DiagnosticSession, ServiceError> {
        self.repository
            .get_session(&SessionId::named(session_id))
            .map_err(repo_error)?
            .ok_or_else(|| ServiceError {
                code: "not_found".into(),
                message: format!("diagnostic session {session_id} does not exist"),
                expected_revision: None,
                actual_revision: None,
            })
    }

    fn mutate<F>(
        &self,
        command_id: &str,
        session_id: &str,
        expected_revision: u64,
        apply: F,
    ) -> SessionResult
    where
        F: FnOnce(&mut DiagnosticSession, &KnowledgePack) -> Result<(), DomainError>,
    {
        let _guard = match self.mutation_lock.lock() {
            Ok(guard) => guard,
            Err(error) => return SessionResult::failure(internal(error.to_string())),
        };
        if let Err(error) = validate_command_id(command_id) {
            return SessionResult::failure(error);
        }
        match self.repository.replay_command(command_id) {
            Ok(Some(session)) => {
                let mut result = SessionResult::success(session);
                result.replayed = true;
                return result;
            }
            Ok(None) => {}
            Err(error) => return SessionResult::failure(repo_error(error)),
        }
        let mut session = match self.load(session_id) {
            Ok(session) => session,
            Err(error) => return SessionResult::failure(error),
        };
        let pack = match self.pack() {
            Ok(pack) => pack,
            Err(error) => return SessionResult::failure(error),
        };
        if let Err(error) = apply(&mut session, &pack) {
            return SessionResult::failure(domain_error(error));
        }
        if let Err(error) = self.repository.save_session(&session, expected_revision) {
            return SessionResult::failure(repo_error(error));
        }
        if let Err(error) = self.repository.record_command(command_id, &session) {
            return SessionResult::failure(repo_error(error));
        }
        SessionResult::success(session)
    }

    fn evaluate(
        &self,
        session_id: &str,
        expected_revision: u64,
    ) -> Result<vw_domain::DiagnosticAssessment, ServiceError> {
        let session = self.load(session_id)?;
        if session.revision != expected_revision {
            return Err(stale(expected_revision, session.revision));
        }
        DeterministicEngine
            .evaluate(&session, &self.pack()?)
            .map_err(domain_error)
    }
}

static DEFAULT_SERVICE: OnceLock<Arc<DefaultVwDiagnosticService>> = OnceLock::new();

pub fn default_vw_service() -> Arc<DefaultVwDiagnosticService> {
    DEFAULT_SERVICE
        .get_or_init(|| {
            Arc::new(DefaultVwDiagnosticService::with_store(
                impress_store_service::store_instance(),
                KnowledgePack::bootstrap(),
            ))
        })
        .clone()
}

/// Validate, persist, and activate a curated pack for the focused MCP host.
/// Existing sessions remain pinned and will report a pack mismatch rather than
/// silently changing their diagnostic basis.
pub fn activate_default_pack(pack: KnowledgePack) -> Result<(), RepositoryError> {
    default_vw_service().repository.replace_active_pack(pack)
}

#[async_trait::async_trait]
impl VwDiagnosticService for DefaultVwDiagnosticService {
    async fn get_capabilities(&self) -> VwCapabilities {
        match self.pack() {
            Ok(pack) => VwCapabilities {
                domain: "Volkswagen Type 2 diagnostics".into(),
                supported_configuration:
                    "1978 California-market Type 2 with L-Jetronic; exact applicability is checked per record"
                        .into(),
                knowledge_pack_id: pack.manifest.id.clone(),
                knowledge_pack_version: pack.manifest.version.clone(),
                published_hypotheses: pack
                    .hypotheses
                    .iter()
                    .filter(|value| value.status == KnowledgeStatus::Published)
                    .count(),
                published_procedures: pack
                    .procedures
                    .iter()
                    .filter(|value| value.status == KnowledgeStatus::Published)
                    .count(),
                published_rules: pack
                    .rules
                    .iter()
                    .filter(|value| value.status == KnowledgeStatus::Published)
                    .count(),
                deterministic_engine_version: vw_domain::DETERMINISTIC_ENGINE_VERSION.into(),
                safety_notice:
                    "Research diagnostic assistant. Only published, cited knowledge executes; stop when configuration, evidence, or safety prerequisites are incomplete."
                        .into(),
            },
            Err(error) => VwCapabilities {
                domain: "Volkswagen Type 2 diagnostics".into(),
                supported_configuration: "unavailable".into(),
                knowledge_pack_id: "unavailable".into(),
                knowledge_pack_version: "unavailable".into(),
                published_hypotheses: 0,
                published_procedures: 0,
                published_rules: 0,
                deterministic_engine_version: vw_domain::DETERMINISTIC_ENGINE_VERSION.into(),
                safety_notice: error.message,
            },
        }
    }

    async fn ingest_photo(
        &self,
        photo: ChatGptFile,
        title: String,
        description: String,
        component: Option<String>,
        diagnostic_session_id: Option<String>,
        captured_at: Option<String>,
        tags: Vec<String>,
    ) -> PhotoEvidenceResult {
        self.photo_evidence
            .ingest(
                self.repository.store().clone(),
                photo,
                PhotoDescription {
                    title,
                    description,
                    component,
                    diagnostic_session_id,
                    captured_at,
                    tags,
                },
            )
            .await
    }

    async fn search_photos(
        &self,
        query: String,
        diagnostic_session_id: Option<String>,
        limit: u32,
    ) -> PhotoEvidenceSearchResult {
        self.photo_evidence.search(
            self.repository.store(),
            &query,
            diagnostic_session_id.as_deref(),
            limit,
        )
    }

    async fn get_photo(&self, evidence_id: String) -> PhotoEvidenceResult {
        self.photo_evidence
            .get(self.repository.store(), &evidence_id)
    }

    async fn create_session(&self, request: CreateSessionRequest) -> SessionResult {
        let _guard = match self.mutation_lock.lock() {
            Ok(guard) => guard,
            Err(error) => return SessionResult::failure(internal(error.to_string())),
        };
        if let Err(error) = validate_command_id(&request.command_id) {
            return SessionResult::failure(error);
        }
        match self.repository.replay_command(&request.command_id) {
            Ok(Some(session)) => {
                let mut result = SessionResult::success(session);
                result.replayed = true;
                return result;
            }
            Ok(None) => {}
            Err(error) => return SessionResult::failure(repo_error(error)),
        }
        let deterministic_id = deterministic_session_id(&request.command_id);
        match self
            .repository
            .get_session(&SessionId::named(deterministic_id.clone()))
        {
            Ok(Some(session)) => {
                if let Err(error) = self
                    .repository
                    .record_command(&request.command_id, &session)
                {
                    return SessionResult::failure(repo_error(error));
                }
                let mut result = SessionResult::success(session);
                result.replayed = true;
                return result;
            }
            Ok(None) => {}
            Err(error) => return SessionResult::failure(repo_error(error)),
        }
        let pack = match self.pack() {
            Ok(pack) => pack,
            Err(error) => return SessionResult::failure(error),
        };
        let command_id = request.command_id.clone();
        let mut session = match DiagnosticSession::open(request, &pack) {
            Ok(session) => session,
            Err(error) => return SessionResult::failure(domain_error(error)),
        };
        session.id = SessionId::named(deterministic_id);
        if let Err(error) = self.repository.create_session(&session) {
            return SessionResult::failure(repo_error(error));
        }
        if let Err(error) = self.repository.record_command(&command_id, &session) {
            return SessionResult::failure(repo_error(error));
        }
        SessionResult::success(session)
    }

    async fn get_session(&self, session_id: String) -> SessionResult {
        match self.load(&session_id) {
            Ok(session) => SessionResult::success(session),
            Err(error) => SessionResult::failure(error),
        }
    }

    async fn list_sessions(&self, limit: u32) -> SessionListResult {
        match self.repository.list_sessions(limit as usize) {
            Ok(sessions) => SessionListResult {
                ok: true,
                sessions,
                error: None,
            },
            Err(error) => SessionListResult {
                ok: false,
                sessions: vec![],
                error: Some(repo_error(error)),
            },
        }
    }

    async fn record_observation(&self, command: RecordObservationCommand) -> SessionResult {
        let command_id = command.command_id.clone();
        let session_id = command.session_id.clone();
        let expected = command.expected_revision;
        self.mutate(&command_id, &session_id, expected, move |session, _| {
            session.record_observation(&command)
        })
    }

    async fn record_measurement(&self, command: RecordMeasurementCommand) -> SessionResult {
        let command_id = command.command_id.clone();
        let session_id = command.session_id.clone();
        let expected = command.expected_revision;
        self.mutate(&command_id, &session_id, expected, move |session, _| {
            session.record_measurement(&command)
        })
    }

    async fn evaluate_session(
        &self,
        session_id: String,
        expected_revision: u64,
    ) -> AssessmentResult {
        match self.evaluate(&session_id, expected_revision) {
            Ok(assessment) => AssessmentResult {
                ok: true,
                assessment: Some(assessment),
                error: None,
            },
            Err(error) => AssessmentResult {
                ok: false,
                assessment: None,
                error: Some(error),
            },
        }
    }

    async fn recommend_next_test(
        &self,
        session_id: String,
        expected_revision: u64,
    ) -> NextTestResult {
        match self.evaluate(&session_id, expected_revision) {
            Ok(assessment) => NextTestResult {
                ok: true,
                recommendation: assessment.next_test,
                trace_hash: Some(assessment.trace.trace_hash),
                error: None,
            },
            Err(error) => NextTestResult {
                ok: false,
                recommendation: None,
                trace_hash: None,
                error: Some(error),
            },
        }
    }

    async fn list_applicable_procedures(&self, session_id: String) -> ProcedureListResult {
        let result = self.load(&session_id).and_then(|session| {
            self.pack().map(|pack| {
                pack.procedures
                    .into_iter()
                    .filter(|procedure| {
                        procedure.status == KnowledgeStatus::Published
                            && procedure
                                .applicability
                                .evaluate(&session.vehicle.configuration)
                                == ApplicabilityMatch::Applies
                    })
                    .collect()
            })
        });
        match result {
            Ok(procedures) => ProcedureListResult {
                ok: true,
                procedures,
                error: None,
            },
            Err(error) => ProcedureListResult {
                ok: false,
                procedures: vec![],
                error: Some(error),
            },
        }
    }

    async fn start_procedure(&self, command: StartProcedureCommand) -> SessionResult {
        let command_id = command.command_id.clone();
        let session_id = command.session_id.clone();
        let expected = command.expected_revision;
        self.mutate(&command_id, &session_id, expected, move |session, pack| {
            session.start_procedure(&command, pack)
        })
    }

    async fn record_procedure_step(&self, command: RecordProcedureStepCommand) -> SessionResult {
        let command_id = command.command_id.clone();
        let session_id = command.session_id.clone();
        let expected = command.expected_revision;
        self.mutate(&command_id, &session_id, expected, move |session, pack| {
            session.record_procedure_step(&command, pack)
        })
    }

    async fn close_session(&self, command: CloseSessionCommand) -> SessionResult {
        let command_id = command.command_id.clone();
        let session_id = command.session_id.clone();
        let expected = command.expected_revision;
        self.mutate(&command_id, &session_id, expected, move |session, _| {
            session.close(&command)
        })
    }
}

impress_service_impl! {
    service = VwDiagnosticService,
    impl = DefaultVwDiagnosticService,
    instance = default_vw_service,
    methods = [
        get_capabilities() -> VwCapabilities,
        ingest_photo(photo: ChatGptFile, title: String, description: String, component: Option<String>, diagnostic_session_id: Option<String>, captured_at: Option<String>, tags: Vec<String>) -> PhotoEvidenceResult,
        search_photos(query: String, diagnostic_session_id: Option<String>, limit: u32) -> PhotoEvidenceSearchResult,
        get_photo(evidence_id: String) -> PhotoEvidenceResult,
        create_session(request: CreateSessionRequest) -> SessionResult,
        get_session(session_id: String) -> SessionResult,
        list_sessions(limit: u32) -> SessionListResult,
        record_observation(command: RecordObservationCommand) -> SessionResult,
        record_measurement(command: RecordMeasurementCommand) -> SessionResult,
        evaluate_session(session_id: String, expected_revision: u64) -> AssessmentResult,
        recommend_next_test(session_id: String, expected_revision: u64) -> NextTestResult,
        list_applicable_procedures(session_id: String) -> ProcedureListResult,
        start_procedure(command: StartProcedureCommand) -> SessionResult,
        record_procedure_step(command: RecordProcedureStepCommand) -> SessionResult,
        close_session(command: CloseSessionCommand) -> SessionResult,
    ],
}

fn deterministic_session_id(command_id: &str) -> String {
    let command = Uuid::parse_str(command_id).expect("validated command UUID");
    Uuid::new_v5(
        &Uuid::from_u128(0x3ad03135_06c1_4cb1_8afb_eaa166282e85),
        command.as_bytes(),
    )
    .to_string()
}

fn validate_command_id(command_id: &str) -> Result<(), ServiceError> {
    Uuid::parse_str(command_id)
        .map(|_| ())
        .map_err(|error| ServiceError {
            code: "invalid_input".into(),
            message: format!("command_id must be a UUID: {error}"),
            expected_revision: None,
            actual_revision: None,
        })
}

fn stale(expected: u64, actual: u64) -> ServiceError {
    ServiceError {
        code: "stale_revision".into(),
        message: format!("expected session revision {expected}, actual revision is {actual}"),
        expected_revision: Some(expected),
        actual_revision: Some(actual),
    }
}

fn domain_error(error: DomainError) -> ServiceError {
    match error {
        DomainError::StaleRevision { expected, actual } => stale(expected, actual),
        DomainError::InvalidInput(message) => simple("invalid_input", message),
        DomainError::InvalidState(message) => simple("invalid_state", message),
        DomainError::NotFound(message) => simple("not_found", message),
        DomainError::KnowledgeNotPublished(message) => simple("knowledge_not_published", message),
        DomainError::ConfigurationMismatch(message) => simple("configuration_mismatch", message),
        DomainError::UnsafePrecondition(message) => simple("unsafe_precondition", message),
        DomainError::InvalidKnowledge(message) => simple("invalid_knowledge", message),
        DomainError::KnowledgePackMismatch { session, active } => simple(
            "knowledge_pack_mismatch",
            format!("session uses {session}, active pack is {active}"),
        ),
        DomainError::Serialization(message) => simple("serialization", message),
    }
}

fn repo_error(error: RepositoryError) -> ServiceError {
    match error {
        RepositoryError::NotFound(message) => simple("not_found", message),
        RepositoryError::StaleRevision { expected, actual } => stale(expected, actual),
        RepositoryError::Serialization(message) => simple("serialization", message),
        RepositoryError::Storage(message) => simple("storage", message),
    }
}

fn internal(message: String) -> ServiceError {
    simple("internal", message)
}

fn simple(code: &str, message: String) -> ServiceError {
    ServiceError {
        code: code.into(),
        message,
        expected_revision: None,
        actual_revision: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::query::ItemQuery;
    use impress_core::sqlite_store::SqliteItemStore;
    use impress_core::store::ItemStore;
    use std::collections::BTreeSet;
    use vw_domain::{
        Acquisition, Confidence, ConfigurationId, Market, ObservationKind, ObservationValue,
        VehicleConfiguration, VerificationState,
    };

    fn service() -> DefaultVwDiagnosticService {
        DefaultVwDiagnosticService::with_store(
            Arc::new(SqliteItemStore::open_in_memory().unwrap()),
            KnowledgePack::bootstrap(),
        )
    }

    fn create_request(command_id: String) -> CreateSessionRequest {
        CreateSessionRequest {
            command_id,
            vehicle_name: "1978 Type 2".into(),
            vin: None,
            configuration: VehicleConfiguration {
                id: ConfigurationId::new(),
                model_family: "Type 2".into(),
                model_year: 1978,
                market: Market::California,
                emissions_spec: "California".into(),
                engine_code: "GE".into(),
                fuel_system: "L-Jetronic".into(),
                transmission: Some("manual".into()),
                installed_options: BTreeSet::new(),
                installed_components: BTreeSet::new(),
                deviations: vec![],
                verification: VerificationState::PartiallyVerified,
            },
            concern: "No start".into(),
            odometer: None,
            notes: None,
        }
    }

    #[tokio::test]
    async fn create_and_observe_persists_typed_children() {
        let service = service();
        let created = service
            .create_session(create_request(Uuid::new_v4().to_string()))
            .await;
        let session = created.session.unwrap();
        let command = RecordObservationCommand {
            session_id: session.id.0.clone(),
            expected_revision: 0,
            command_id: Uuid::new_v4().to_string(),
            kind: ObservationKind::Symptom,
            value: ObservationValue::Present,
            acquisition: Acquisition::UserReported,
            confidence: Confidence::Plausible,
            component_key: None,
            conditions: vec![],
            notes: None,
            supersedes: None,
        };
        let updated = service.record_observation(command).await;
        assert!(updated.ok);
        assert_eq!(updated.session.as_ref().unwrap().revision, 1);
        let rows = service
            .repository
            .store()
            .query(&ItemQuery {
                schema: Some(crate::VW_OBSERVATION_SCHEMA.into()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[tokio::test]
    async fn command_retry_returns_original_result() {
        let service = service();
        let command_id = Uuid::new_v4().to_string();
        let first = service
            .create_session(create_request(command_id.clone()))
            .await;
        let second = service.create_session(create_request(command_id)).await;
        assert!(first.ok && second.ok && second.replayed);
        assert_eq!(first.session.unwrap().id, second.session.unwrap().id);
    }

    #[tokio::test]
    async fn bootstrap_evaluation_is_explicitly_empty_and_reproducible() {
        let service = service();
        let session = service
            .create_session(create_request(Uuid::new_v4().to_string()))
            .await
            .session
            .unwrap();
        let result = service.evaluate_session(session.id.0, 0).await;
        assert!(result.ok);
        let assessment = result.assessment.unwrap();
        assert!(assessment.assessments.is_empty());
        assert_eq!(assessment.trace.rules.len(), 0);
        assert_eq!(assessment.trace.trace_hash.len(), 64);
    }
}
