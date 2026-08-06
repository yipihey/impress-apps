use std::collections::BTreeSet;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::{
    now_timestamp, Acquisition, Confidence, DiagnosticSession, DiagnosticSessionState,
    KnowledgePack, KnowledgeStatus, Measurement, MeasurementId, Observation, ObservationId,
    ObservationKind, ObservationValue, ProcedureRun, ProcedureRunId, ProcedureRunState, Quantity,
    SessionId, StepResult, TerminalPair, Vehicle, VehicleConfiguration, VehicleId,
};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct CreateSessionRequest {
    pub command_id: String,
    pub vehicle_name: String,
    pub vin: Option<String>,
    pub configuration: VehicleConfiguration,
    pub concern: String,
    pub odometer: Option<Quantity>,
    pub notes: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct RecordObservationCommand {
    pub session_id: String,
    pub expected_revision: u64,
    pub command_id: String,
    pub kind: ObservationKind,
    pub value: ObservationValue,
    pub acquisition: Acquisition,
    pub confidence: Confidence,
    pub component_key: Option<String>,
    #[serde(default)]
    pub conditions: Vec<crate::Condition>,
    pub notes: Option<String>,
    pub supersedes: Option<ObservationId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct RecordMeasurementCommand {
    pub session_id: String,
    pub expected_revision: u64,
    pub command_id: String,
    pub quantity: String,
    pub value: Quantity,
    pub acquisition: Acquisition,
    pub component_key: Option<String>,
    pub terminals: Option<TerminalPair>,
    #[serde(default)]
    pub conditions: Vec<crate::Condition>,
    pub source_step: Option<String>,
    pub notes: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct StartProcedureCommand {
    pub session_id: String,
    pub expected_revision: u64,
    pub command_id: String,
    pub procedure_id: String,
    #[serde(default)]
    pub acknowledged_hazard_ids: BTreeSet<String>,
    pub performed_by: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct RecordProcedureStepCommand {
    pub session_id: String,
    pub expected_revision: u64,
    pub command_id: String,
    pub procedure_run_id: String,
    pub step_key: String,
    pub result: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct CloseSessionCommand {
    pub session_id: String,
    pub expected_revision: u64,
    pub command_id: String,
    pub outcome: String,
}

impl DiagnosticSession {
    pub fn open(request: CreateSessionRequest, pack: &KnowledgePack) -> Result<Self, DomainError> {
        pack.validate()?;
        if request.vehicle_name.trim().is_empty() || request.concern.trim().is_empty() {
            return Err(DomainError::InvalidInput(
                "vehicle_name and concern must not be blank".into(),
            ));
        }
        if request.command_id.trim().is_empty() {
            return Err(DomainError::InvalidInput(
                "command_id must not be blank".into(),
            ));
        }
        if let Some(odometer) = &request.odometer {
            odometer.validate()?;
        }
        Ok(Self {
            id: SessionId::new(),
            vehicle: Vehicle {
                id: VehicleId::new(),
                display_name: request.vehicle_name,
                vin: request.vin,
                configuration: request.configuration,
                odometer: request.odometer,
                notes: request.notes,
                created_at: now_timestamp(),
            },
            state: DiagnosticSessionState::Intake,
            concern: request.concern,
            opened_at: now_timestamp(),
            closed_at: None,
            knowledge_pack_id: pack.manifest.id.clone(),
            knowledge_pack_version: pack.manifest.version.clone(),
            inference_engine_version: crate::DETERMINISTIC_ENGINE_VERSION.into(),
            revision: 0,
            observations: vec![],
            measurements: vec![],
            procedure_runs: vec![],
            outcome: None,
        })
    }

    pub fn record_observation(
        &mut self,
        command: &RecordObservationCommand,
    ) -> Result<(), DomainError> {
        self.guard_command(
            &command.session_id,
            command.expected_revision,
            &command.command_id,
        )?;
        self.ensure_open()?;
        if let Some(superseded) = &command.supersedes {
            if !self.observations.iter().any(|item| &item.id == superseded) {
                return Err(DomainError::InvalidInput(format!(
                    "superseded observation {superseded} is not in this session"
                )));
            }
        }
        self.observations.push(Observation {
            id: ObservationId::new(),
            kind: command.kind.clone(),
            value: command.value.clone(),
            acquisition: command.acquisition.clone(),
            confidence: command.confidence.clone(),
            recorded_at: now_timestamp(),
            component_key: command.component_key.clone(),
            conditions: command.conditions.clone(),
            notes: command.notes.clone(),
            supersedes: command.supersedes.clone(),
        });
        self.state = DiagnosticSessionState::Diagnosing;
        self.revision += 1;
        Ok(())
    }

    pub fn record_measurement(
        &mut self,
        command: &RecordMeasurementCommand,
    ) -> Result<(), DomainError> {
        self.guard_command(
            &command.session_id,
            command.expected_revision,
            &command.command_id,
        )?;
        self.ensure_open()?;
        command.value.validate()?;
        if command.quantity.trim().is_empty() {
            return Err(DomainError::InvalidInput(
                "measurement quantity must not be blank".into(),
            ));
        }
        self.measurements.push(Measurement {
            id: MeasurementId::new(),
            quantity: command.quantity.clone(),
            value: command.value.clone(),
            acquisition: command.acquisition.clone(),
            measured_at: now_timestamp(),
            component_key: command.component_key.clone(),
            terminals: command.terminals.clone(),
            conditions: command.conditions.clone(),
            source_step: command.source_step.clone(),
            notes: command.notes.clone(),
        });
        self.state = DiagnosticSessionState::Diagnosing;
        self.revision += 1;
        Ok(())
    }

    pub fn start_procedure(
        &mut self,
        command: &StartProcedureCommand,
        pack: &KnowledgePack,
    ) -> Result<(), DomainError> {
        self.guard_command(
            &command.session_id,
            command.expected_revision,
            &command.command_id,
        )?;
        self.ensure_open()?;
        let procedure = pack
            .procedures
            .iter()
            .find(|procedure| procedure.id == command.procedure_id)
            .ok_or_else(|| DomainError::NotFound(format!("procedure {}", command.procedure_id)))?;
        if procedure.status != KnowledgeStatus::Published {
            return Err(DomainError::KnowledgeNotPublished(procedure.id.clone()));
        }
        if procedure
            .applicability
            .evaluate(&self.vehicle.configuration)
            != crate::ApplicabilityMatch::Applies
        {
            return Err(DomainError::ConfigurationMismatch(procedure.id.clone()));
        }
        let missing: Vec<_> = procedure
            .hazards
            .iter()
            .chain(procedure.steps.iter().flat_map(|step| step.hazards.iter()))
            .filter(|hazard| {
                hazard.acknowledgement_required
                    && !command.acknowledged_hazard_ids.contains(&hazard.id)
            })
            .map(|hazard| hazard.id.clone())
            .collect();
        if !missing.is_empty() {
            return Err(DomainError::UnsafePrecondition(format!(
                "unacknowledged hazards: {}",
                missing.join(", ")
            )));
        }
        self.procedure_runs.push(ProcedureRun {
            id: ProcedureRunId::new(),
            procedure_id: procedure.id.clone(),
            procedure_version: procedure.version.clone(),
            state: ProcedureRunState::Active,
            current_step: procedure.steps.first().map(|step| step.key.clone()),
            acknowledged_hazards: command.acknowledged_hazard_ids.clone(),
            completed_steps: vec![],
            started_at: now_timestamp(),
            completed_at: None,
            performed_by: command.performed_by.clone(),
        });
        self.revision += 1;
        Ok(())
    }

    pub fn record_procedure_step(
        &mut self,
        command: &RecordProcedureStepCommand,
        pack: &KnowledgePack,
    ) -> Result<(), DomainError> {
        self.guard_command(
            &command.session_id,
            command.expected_revision,
            &command.command_id,
        )?;
        self.ensure_open()?;
        if command.result.trim().is_empty() {
            return Err(DomainError::InvalidInput(
                "procedure step result must not be blank".into(),
            ));
        }
        let run = self
            .procedure_runs
            .iter_mut()
            .find(|run| run.id.0 == command.procedure_run_id)
            .ok_or_else(|| {
                DomainError::NotFound(format!("procedure run {}", command.procedure_run_id))
            })?;
        if run.state != ProcedureRunState::Active && run.state != ProcedureRunState::WaitingForInput
        {
            return Err(DomainError::InvalidState(format!(
                "procedure run is {:?}",
                run.state
            )));
        }
        if run.current_step.as_deref() != Some(command.step_key.as_str()) {
            return Err(DomainError::InvalidState(format!(
                "expected step {:?}, received {}",
                run.current_step, command.step_key
            )));
        }
        let procedure = pack
            .procedures
            .iter()
            .find(|procedure| {
                procedure.id == run.procedure_id && procedure.version == run.procedure_version
            })
            .ok_or_else(|| DomainError::NotFound(format!("procedure {}", run.procedure_id)))?;
        let index = procedure
            .steps
            .iter()
            .position(|step| step.key == command.step_key)
            .ok_or_else(|| {
                DomainError::InvalidState("current step is absent from procedure".into())
            })?;
        run.completed_steps.push(StepResult {
            step_key: command.step_key.clone(),
            result: command.result.clone(),
            recorded_at: now_timestamp(),
        });
        if let Some(next) = procedure.steps.get(index + 1) {
            run.current_step = Some(next.key.clone());
            run.state = ProcedureRunState::Active;
        } else {
            run.current_step = None;
            run.state = ProcedureRunState::Completed;
            run.completed_at = Some(now_timestamp());
        }
        self.revision += 1;
        Ok(())
    }

    pub fn close(&mut self, command: &CloseSessionCommand) -> Result<(), DomainError> {
        self.guard_command(
            &command.session_id,
            command.expected_revision,
            &command.command_id,
        )?;
        self.ensure_open()?;
        if command.outcome.trim().is_empty() {
            return Err(DomainError::InvalidInput(
                "session outcome must not be blank".into(),
            ));
        }
        self.state = DiagnosticSessionState::Closed;
        self.closed_at = Some(now_timestamp());
        self.outcome = Some(command.outcome.clone());
        self.revision += 1;
        Ok(())
    }

    fn guard_command(
        &self,
        session_id: &str,
        expected_revision: u64,
        command_id: &str,
    ) -> Result<(), DomainError> {
        if self.id.0 != session_id {
            return Err(DomainError::NotFound(format!("session {session_id}")));
        }
        if command_id.trim().is_empty() {
            return Err(DomainError::InvalidInput(
                "command_id must not be blank".into(),
            ));
        }
        if self.revision != expected_revision {
            return Err(DomainError::StaleRevision {
                expected: expected_revision,
                actual: self.revision,
            });
        }
        Ok(())
    }

    fn ensure_open(&self) -> Result<(), DomainError> {
        if matches!(
            self.state,
            DiagnosticSessionState::Closed | DiagnosticSessionState::Abandoned
        ) {
            Err(DomainError::InvalidState(format!(
                "session is {:?}",
                self.state
            )))
        } else {
            Ok(())
        }
    }
}

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum DomainError {
    #[error("invalid input: {0}")]
    InvalidInput(String),
    #[error("invalid state: {0}")]
    InvalidState(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("stale session revision: expected {expected}, actual {actual}")]
    StaleRevision { expected: u64, actual: u64 },
    #[error("knowledge is not published: {0}")]
    KnowledgeNotPublished(String),
    #[error("knowledge does not apply to this configuration: {0}")]
    ConfigurationMismatch(String),
    #[error("unsafe precondition: {0}")]
    UnsafePrecondition(String),
    #[error("invalid knowledge pack: {0}")]
    InvalidKnowledge(String),
    #[error("knowledge-pack mismatch: session uses {session}, active pack is {active}")]
    KnowledgePackMismatch { session: String, active: String },
    #[error("serialization failed: {0}")]
    Serialization(String),
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{
        Applicability, ApplicabilityPredicate, CitationId, ComparisonOperator, ConditionExpr,
        DiagnosticRule, EvidencePolarity, EvidenceStrength, FaultHypothesis, Hazard,
        KnowledgePackManifest, Market, Procedure, ProcedureStep, RuleEffect, Severity,
        VerificationState,
    };
    use std::collections::{BTreeMap, BTreeSet};

    fn citation() -> CitationId {
        CitationId::named("fixture-citation")
    }

    pub(crate) fn fixture_pack() -> KnowledgePack {
        let applicability = Applicability {
            all: vec![ApplicabilityPredicate::ModelYear {
                min: 1978,
                max: 1978,
            }],
            any: vec![],
            none: vec![],
        };
        KnowledgePack {
            manifest: KnowledgePackManifest {
                id: "fixture-pack".into(),
                version: "1".into(),
                content_hash: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
                    .into(),
                domain_schema_version: "1".into(),
                created_at: now_timestamp(),
                source_hashes: BTreeMap::new(),
                validator_version: "test".into(),
            },
            components: vec![],
            hypotheses: vec![FaultHypothesis {
                id: "fixture-fault".into(),
                title: "Fixture fault".into(),
                system: "fixture".into(),
                component_key: Some("fixture-component".into()),
                applicability: applicability.clone(),
                description: "Test-only; not mechanical knowledge.".into(),
                severity: Severity::Degraded,
                citation_ids: vec![citation()],
                status: KnowledgeStatus::Published,
            }],
            procedures: vec![Procedure {
                id: "fixture.measure-voltage".into(),
                version: "1".into(),
                title: "Measure fixture voltage".into(),
                purpose: "Test deterministic flow only.".into(),
                applicability: applicability.clone(),
                hazards: vec![Hazard {
                    id: "fixture-hazard".into(),
                    summary: "Fixture hazard".into(),
                    consequence: "Fixture consequence".into(),
                    acknowledgement_required: true,
                    citation_id: citation(),
                }],
                prerequisites: vec![],
                required_tools: vec!["fixture meter".into()],
                steps: vec![ProcedureStep {
                    key: "measure".into(),
                    instruction: "Measure the fictional fixture.".into(),
                    capture: None,
                    hazards: vec![],
                    citation_ids: vec![citation()],
                }],
                citation_ids: vec![citation()],
                status: KnowledgeStatus::Published,
            }],
            rules: vec![
                DiagnosticRule {
                    id: "fixture-missing".into(),
                    version: "1".into(),
                    title: "Request fixture measurement".into(),
                    applicability: applicability.clone(),
                    condition: ConditionExpr::MissingMeasurement {
                        quantity: "voltage".into(),
                        component_key: Some("fixture-component".into()),
                    },
                    effects: vec![RuleEffect::SuggestProcedure {
                        procedure_id: "fixture.measure-voltage".into(),
                        discrimination: EvidenceStrength::Strong,
                        rationale: "The fixture voltage is unknown.".into(),
                    }],
                    citation_ids: vec![citation()],
                    status: KnowledgeStatus::Published,
                },
                DiagnosticRule {
                    id: "fixture-low".into(),
                    version: "1".into(),
                    title: "Low fictional voltage".into(),
                    applicability,
                    condition: ConditionExpr::MeasurementCompares {
                        quantity: "voltage".into(),
                        operator: ComparisonOperator::LessThan,
                        threshold: 3.0,
                        unit: "V".into(),
                        component_key: Some("fixture-component".into()),
                    },
                    effects: vec![RuleEffect::Assess {
                        hypothesis_id: "fixture-fault".into(),
                        polarity: EvidencePolarity::Supports,
                        strength: EvidenceStrength::Strong,
                        rationale: "Fictional fixture voltage is low.".into(),
                    }],
                    citation_ids: vec![citation()],
                    status: KnowledgeStatus::Published,
                },
            ],
        }
    }

    pub(crate) fn fixture_session() -> DiagnosticSession {
        DiagnosticSession::open(
            CreateSessionRequest {
                command_id: uuid::Uuid::new_v4().to_string(),
                vehicle_name: "Fixture vehicle".into(),
                vin: None,
                configuration: VehicleConfiguration {
                    id: crate::ConfigurationId::new(),
                    model_family: "Type 2".into(),
                    model_year: 1978,
                    market: Market::California,
                    emissions_spec: "California".into(),
                    engine_code: "fixture".into(),
                    fuel_system: "L-Jetronic".into(),
                    transmission: None,
                    installed_options: BTreeSet::new(),
                    installed_components: BTreeSet::from(["fixture-component".into()]),
                    deviations: vec![],
                    verification: VerificationState::Verified,
                },
                concern: "Fixture concern".into(),
                odometer: None,
                notes: None,
            },
            &fixture_pack(),
        )
        .unwrap()
    }

    #[test]
    fn stale_commands_are_rejected() {
        let mut session = fixture_session();
        let command = RecordObservationCommand {
            session_id: session.id.0.clone(),
            expected_revision: 1,
            command_id: "command".into(),
            kind: ObservationKind::Symptom,
            value: ObservationValue::Present,
            acquisition: Acquisition::UserObserved,
            confidence: Confidence::Confirmed,
            component_key: None,
            conditions: vec![],
            notes: None,
            supersedes: None,
        };
        assert_eq!(
            session.record_observation(&command),
            Err(DomainError::StaleRevision {
                expected: 1,
                actual: 0
            })
        );
    }

    #[test]
    fn procedure_requires_hazard_acknowledgement() {
        let mut session = fixture_session();
        let command = StartProcedureCommand {
            session_id: session.id.0.clone(),
            expected_revision: 0,
            command_id: "command".into(),
            procedure_id: "fixture.measure-voltage".into(),
            acknowledged_hazard_ids: BTreeSet::new(),
            performed_by: "tester".into(),
        };
        assert!(matches!(
            session.start_procedure(&command, &fixture_pack()),
            Err(DomainError::UnsafePrecondition(_))
        ));
    }
}
