use std::collections::{BTreeMap, BTreeSet};

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

macro_rules! string_id {
    ($name:ident) => {
        #[derive(
            Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, JsonSchema,
        )]
        #[serde(transparent)]
        pub struct $name(pub String);

        impl $name {
            pub fn new() -> Self {
                Self(uuid::Uuid::new_v4().to_string())
            }

            pub fn named(value: impl Into<String>) -> Self {
                Self(value.into())
            }
        }

        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str(&self.0)
            }
        }
    };
}

string_id!(VehicleId);
string_id!(ConfigurationId);
string_id!(ComponentId);
string_id!(SessionId);
string_id!(ObservationId);
string_id!(MeasurementId);
string_id!(ProcedureRunId);
string_id!(CitationId);

pub type Timestamp = String;

pub fn now_timestamp() -> Timestamp {
    chrono::Utc::now().to_rfc3339()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Market {
    California,
    FederalUs,
    Canada,
    Europe,
    Other(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum VerificationState {
    Unverified,
    PartiallyVerified,
    Verified,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ConfigurationDeviation {
    pub field: String,
    pub expected: String,
    pub observed: String,
    pub citation_id: Option<CitationId>,
    pub note: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct VehicleConfiguration {
    pub id: ConfigurationId,
    pub model_family: String,
    pub model_year: u16,
    pub market: Market,
    pub emissions_spec: String,
    pub engine_code: String,
    pub fuel_system: String,
    pub transmission: Option<String>,
    #[serde(default)]
    pub installed_options: BTreeSet<String>,
    #[serde(default)]
    pub installed_components: BTreeSet<String>,
    #[serde(default)]
    pub deviations: Vec<ConfigurationDeviation>,
    pub verification: VerificationState,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Vehicle {
    pub id: VehicleId,
    pub display_name: String,
    pub vin: Option<String>,
    pub configuration: VehicleConfiguration,
    pub odometer: Option<Quantity>,
    pub notes: Option<String>,
    pub created_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Component {
    pub id: ComponentId,
    pub key: String,
    pub name: String,
    pub system: String,
    pub parent_key: Option<String>,
    #[serde(default)]
    pub part_numbers: BTreeSet<String>,
    pub applicability: crate::Applicability,
    pub description: Option<String>,
    #[serde(default)]
    pub citation_ids: Vec<CitationId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ObservationKind {
    Symptom,
    VisualInspection,
    Sound,
    Smell,
    Leak,
    State,
    ProcedureResult,
    Other(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "snake_case")]
pub enum ObservationValue {
    Present,
    Absent,
    Unknown,
    Category(String),
    Text(String),
    Boolean(bool),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Confidence {
    Uncertain,
    Plausible,
    Confirmed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Acquisition {
    UserReported,
    UserObserved,
    Instrument {
        kind: String,
        identifier: Option<String>,
    },
    Imported {
        source: String,
    },
    SystemDerived {
        algorithm: String,
        version: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Condition {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Observation {
    pub id: ObservationId,
    pub kind: ObservationKind,
    pub value: ObservationValue,
    pub acquisition: Acquisition,
    pub confidence: Confidence,
    pub recorded_at: Timestamp,
    pub component_key: Option<String>,
    #[serde(default)]
    pub conditions: Vec<Condition>,
    pub notes: Option<String>,
    pub supersedes: Option<ObservationId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Quantity {
    pub value: f64,
    pub unit: String,
    pub uncertainty: Option<f64>,
}

impl Quantity {
    pub fn validate(&self) -> Result<(), crate::DomainError> {
        if !self.value.is_finite() {
            return Err(crate::DomainError::InvalidInput(
                "measurement value must be finite".into(),
            ));
        }
        if self.unit.trim().is_empty() {
            return Err(crate::DomainError::InvalidInput(
                "measurement unit must not be blank".into(),
            ));
        }
        if self
            .uncertainty
            .is_some_and(|value| !value.is_finite() || value < 0.0)
        {
            return Err(crate::DomainError::InvalidInput(
                "measurement uncertainty must be finite and non-negative".into(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Measurement {
    pub id: MeasurementId,
    pub quantity: String,
    pub value: Quantity,
    pub acquisition: Acquisition,
    pub measured_at: Timestamp,
    pub component_key: Option<String>,
    pub terminals: Option<(String, String)>,
    #[serde(default)]
    pub conditions: Vec<Condition>,
    pub source_step: Option<String>,
    pub notes: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum KnowledgeStatus {
    Extracted,
    Proposed,
    Verified,
    Published,
    Rejected,
    Superseded,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Informational,
    Degraded,
    Immobilizing,
    Hazardous,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct FaultHypothesis {
    pub id: String,
    pub title: String,
    pub system: String,
    pub component_key: Option<String>,
    pub applicability: crate::Applicability,
    pub description: String,
    pub severity: Severity,
    #[serde(default)]
    pub citation_ids: Vec<CitationId>,
    pub status: KnowledgeStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Hazard {
    pub id: String,
    pub summary: String,
    pub consequence: String,
    pub acknowledgement_required: bool,
    pub citation_id: CitationId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ProcedureStep {
    pub key: String,
    pub instruction: String,
    pub capture: Option<CaptureSpec>,
    #[serde(default)]
    pub hazards: Vec<Hazard>,
    #[serde(default)]
    pub citation_ids: Vec<CitationId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CaptureSpec {
    Observation {
        kind: ObservationKind,
    },
    Measurement {
        quantity: String,
        allowed_units: Vec<String>,
    },
    Choice {
        options: Vec<String>,
    },
    Text,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Procedure {
    pub id: String,
    pub version: String,
    pub title: String,
    pub purpose: String,
    pub applicability: crate::Applicability,
    #[serde(default)]
    pub hazards: Vec<Hazard>,
    #[serde(default)]
    pub prerequisites: Vec<String>,
    #[serde(default)]
    pub required_tools: Vec<String>,
    pub steps: Vec<ProcedureStep>,
    #[serde(default)]
    pub citation_ids: Vec<CitationId>,
    pub status: KnowledgeStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ProcedureRunState {
    Planned,
    Active,
    WaitingForInput,
    StoppedForSafety,
    Completed,
    Abandoned,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct StepResult {
    pub step_key: String,
    pub result: String,
    pub recorded_at: Timestamp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ProcedureRun {
    pub id: ProcedureRunId,
    pub procedure_id: String,
    pub procedure_version: String,
    pub state: ProcedureRunState,
    pub current_step: Option<String>,
    #[serde(default)]
    pub acknowledged_hazards: BTreeSet<String>,
    #[serde(default)]
    pub completed_steps: Vec<StepResult>,
    pub started_at: Timestamp,
    pub completed_at: Option<Timestamp>,
    pub performed_by: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticSessionState {
    Intake,
    Diagnosing,
    RepairPlanned,
    RepairInProgress,
    Verification,
    Closed,
    Abandoned,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct DiagnosticSession {
    pub id: SessionId,
    pub vehicle: Vehicle,
    pub state: DiagnosticSessionState,
    pub concern: String,
    pub opened_at: Timestamp,
    pub closed_at: Option<Timestamp>,
    pub knowledge_pack_id: String,
    pub knowledge_pack_version: String,
    pub inference_engine_version: String,
    pub revision: u64,
    #[serde(default)]
    pub observations: Vec<Observation>,
    #[serde(default)]
    pub measurements: Vec<Measurement>,
    #[serde(default)]
    pub procedure_runs: Vec<ProcedureRun>,
    pub outcome: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct KnowledgePackManifest {
    pub id: String,
    pub version: String,
    pub content_hash: String,
    pub domain_schema_version: String,
    pub created_at: Timestamp,
    #[serde(default)]
    pub source_hashes: BTreeMap<String, String>,
    pub validator_version: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct KnowledgePack {
    pub manifest: KnowledgePackManifest,
    #[serde(default)]
    pub components: Vec<Component>,
    #[serde(default)]
    pub hypotheses: Vec<FaultHypothesis>,
    #[serde(default)]
    pub procedures: Vec<Procedure>,
    #[serde(default)]
    pub rules: Vec<crate::DiagnosticRule>,
}

impl KnowledgePack {
    /// Safe bootstrap pack: correct product scope, no executable mechanical
    /// claims. Real rules are admitted only through a published curated pack.
    pub fn bootstrap() -> Self {
        Self {
            manifest: KnowledgePackManifest {
                id: "vw-type2-1978-ca-ljet-bootstrap".into(),
                version: "0.1.0".into(),
                content_hash: "0000000000000000000000000000000000000000000000000000000000000000"
                    .into(),
                domain_schema_version: "1.0.0".into(),
                created_at: now_timestamp(),
                source_hashes: BTreeMap::new(),
                validator_version: "vw-domain/1".into(),
            },
            components: vec![],
            hypotheses: vec![],
            procedures: vec![],
            rules: vec![],
        }
    }

    pub fn validate(&self) -> Result<(), crate::DomainError> {
        fn valid_hash(value: &str) -> bool {
            value.len() == 64
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        }
        fn unique<'a>(
            kind: &str,
            values: impl Iterator<Item = &'a str>,
        ) -> Result<(), crate::DomainError> {
            let mut seen = BTreeSet::new();
            for value in values {
                if value.trim().is_empty() {
                    return Err(crate::DomainError::InvalidKnowledge(format!(
                        "{kind} id must not be blank"
                    )));
                }
                if !seen.insert(value) {
                    return Err(crate::DomainError::InvalidKnowledge(format!(
                        "duplicate {kind} id {value}"
                    )));
                }
            }
            Ok(())
        }
        if self.manifest.id.trim().is_empty()
            || self.manifest.version.trim().is_empty()
            || !valid_hash(&self.manifest.content_hash)
        {
            return Err(crate::DomainError::InvalidKnowledge(
                "pack id/version must be non-blank and content_hash must be lowercase SHA-256"
                    .into(),
            ));
        }
        if self
            .manifest
            .source_hashes
            .values()
            .any(|hash| !valid_hash(hash))
        {
            return Err(crate::DomainError::InvalidKnowledge(
                "every source hash must be lowercase SHA-256".into(),
            ));
        }
        unique(
            "component",
            self.components.iter().map(|value| value.key.as_str()),
        )?;
        unique(
            "hypothesis",
            self.hypotheses.iter().map(|value| value.id.as_str()),
        )?;
        unique(
            "procedure",
            self.procedures.iter().map(|value| value.id.as_str()),
        )?;
        unique("rule", self.rules.iter().map(|value| value.id.as_str()))?;
        let citations_required = |status: &KnowledgeStatus, ids: &[CitationId], label: &str| {
            if status == &KnowledgeStatus::Published && ids.is_empty() {
                Err(crate::DomainError::InvalidKnowledge(format!(
                    "published {label} has no citations"
                )))
            } else {
                Ok(())
            }
        };
        let hypothesis_ids: BTreeSet<&str> = self
            .hypotheses
            .iter()
            .filter(|value| value.status == KnowledgeStatus::Published)
            .map(|value| value.id.as_str())
            .collect();
        let procedure_ids: BTreeSet<&str> = self
            .procedures
            .iter()
            .filter(|value| value.status == KnowledgeStatus::Published)
            .map(|value| value.id.as_str())
            .collect();
        for hypothesis in &self.hypotheses {
            citations_required(&hypothesis.status, &hypothesis.citation_ids, &hypothesis.id)?;
        }
        for procedure in &self.procedures {
            citations_required(&procedure.status, &procedure.citation_ids, &procedure.id)?;
            if procedure.steps.is_empty() {
                return Err(crate::DomainError::InvalidKnowledge(format!(
                    "procedure {} has no steps",
                    procedure.id
                )));
            }
            unique(
                "procedure step",
                procedure.steps.iter().map(|step| step.key.as_str()),
            )?;
            if procedure.status == KnowledgeStatus::Published
                && procedure
                    .steps
                    .iter()
                    .any(|step| step.citation_ids.is_empty())
            {
                return Err(crate::DomainError::InvalidKnowledge(format!(
                    "published procedure {} has an uncited step",
                    procedure.id
                )));
            }
        }
        for rule in &self.rules {
            citations_required(&rule.status, &rule.citation_ids, &rule.id)?;
            if rule.status == KnowledgeStatus::Published && rule.effects.is_empty() {
                return Err(crate::DomainError::InvalidKnowledge(format!(
                    "published rule {} has no effects",
                    rule.id
                )));
            }
            for effect in &rule.effects {
                match effect {
                    crate::RuleEffect::Assess { hypothesis_id, .. }
                        if rule.status == KnowledgeStatus::Published
                            && !hypothesis_ids.contains(hypothesis_id.as_str()) =>
                    {
                        return Err(crate::DomainError::InvalidKnowledge(format!(
                            "rule {} references missing hypothesis {hypothesis_id}",
                            rule.id
                        )));
                    }
                    crate::RuleEffect::SuggestProcedure { procedure_id, .. }
                        if rule.status == KnowledgeStatus::Published
                            && !procedure_ids.contains(procedure_id.as_str()) =>
                    {
                        return Err(crate::DomainError::InvalidKnowledge(format!(
                            "rule {} references missing procedure {procedure_id}",
                            rule.id
                        )));
                    }
                    _ => {}
                }
            }
        }
        Ok(())
    }
}
