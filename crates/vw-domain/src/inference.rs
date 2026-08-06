use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{
    ApplicabilityMatch, ApplicabilityPredicate, CitationId, DiagnosticSession, FaultHypothesis,
    KnowledgePack, KnowledgeStatus, ObservationKind, ObservationValue, Procedure, Severity,
};

pub const DETERMINISTIC_ENGINE_VERSION: &str = "vw-rules/1.0.0";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum TruthValue {
    True,
    False,
    Unknown,
}

impl TruthValue {
    fn not(self) -> Self {
        match self {
            Self::True => Self::False,
            Self::False => Self::True,
            Self::Unknown => Self::Unknown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ComparisonOperator {
    LessThan,
    LessOrEqual,
    Equal,
    GreaterOrEqual,
    GreaterThan,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ConditionExpr {
    All {
        conditions: Vec<ConditionExpr>,
    },
    Any {
        conditions: Vec<ConditionExpr>,
    },
    Not {
        condition: Box<ConditionExpr>,
    },
    ObservationMatches {
        kind: ObservationKind,
        value: ObservationValue,
        component_key: Option<String>,
    },
    MeasurementCompares {
        quantity: String,
        operator: ComparisonOperator,
        threshold: f64,
        unit: String,
        component_key: Option<String>,
    },
    ConfigurationMatches {
        predicate: ApplicabilityPredicate,
    },
    ProcedureCompleted {
        procedure_id: String,
    },
    MissingObservation {
        kind: ObservationKind,
        component_key: Option<String>,
    },
    MissingMeasurement {
        quantity: String,
        component_key: Option<String>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum EvidencePolarity {
    Supports,
    Contradicts,
    Excludes,
    Neutral,
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum EvidenceStrength {
    Weak,
    Moderate,
    Strong,
}

impl EvidenceStrength {
    pub fn ordinal_weight(self) -> i32 {
        match self {
            Self::Weak => 1,
            Self::Moderate => 2,
            Self::Strong => 4,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RuleEffect {
    Assess {
        hypothesis_id: String,
        polarity: EvidencePolarity,
        strength: EvidenceStrength,
        rationale: String,
    },
    SuggestProcedure {
        procedure_id: String,
        discrimination: EvidenceStrength,
        rationale: String,
    },
    RaiseSafetyGate {
        hazard_id: String,
        rationale: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct DiagnosticRule {
    pub id: String,
    pub version: String,
    pub title: String,
    pub applicability: crate::Applicability,
    pub condition: ConditionExpr,
    pub effects: Vec<RuleEffect>,
    #[serde(default)]
    pub citation_ids: Vec<CitationId>,
    pub status: KnowledgeStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct EvidenceAssessment {
    pub rule_id: String,
    pub hypothesis_id: String,
    pub polarity: EvidencePolarity,
    pub strength: EvidenceStrength,
    pub rationale: String,
    #[serde(default)]
    pub citation_ids: Vec<CitationId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct HypothesisAssessment {
    pub hypothesis_id: String,
    pub title: String,
    pub severity: Severity,
    pub excluded: bool,
    /// Ordinal investigation priority. This is not a probability.
    pub priority_score: i32,
    #[serde(default)]
    pub supporting: Vec<EvidenceAssessment>,
    #[serde(default)]
    pub contradicting: Vec<EvidenceAssessment>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct RuleTrace {
    pub rule_id: String,
    pub rule_version: String,
    pub applicability: ApplicabilityMatch,
    pub condition: TruthValue,
    pub emitted_effects: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct InferenceTrace {
    pub engine_version: String,
    pub session_id: String,
    pub session_revision: u64,
    pub knowledge_pack_id: String,
    pub knowledge_pack_version: String,
    pub rules: Vec<RuleTrace>,
    pub trace_hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct NextTestRecommendation {
    pub procedure_id: String,
    pub procedure_version: String,
    pub title: String,
    pub rationale: String,
    pub discrimination: EvidenceStrength,
    pub priority_score: i32,
    #[serde(default)]
    pub prerequisites: Vec<String>,
    #[serde(default)]
    pub hazard_summaries: Vec<String>,
    #[serde(default)]
    pub citation_ids: Vec<CitationId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct DiagnosticAssessment {
    pub assessments: Vec<HypothesisAssessment>,
    pub next_test: Option<NextTestRecommendation>,
    pub trace: InferenceTrace,
    #[serde(default)]
    pub warnings: Vec<String>,
}

#[derive(Debug, Default)]
pub struct DeterministicEngine;

impl DeterministicEngine {
    pub fn evaluate(
        &self,
        session: &DiagnosticSession,
        pack: &KnowledgePack,
    ) -> Result<DiagnosticAssessment, crate::DomainError> {
        pack.validate()?;
        if session.knowledge_pack_id != pack.manifest.id
            || session.knowledge_pack_version != pack.manifest.version
        {
            return Err(crate::DomainError::KnowledgePackMismatch {
                session: format!(
                    "{}@{}",
                    session.knowledge_pack_id, session.knowledge_pack_version
                ),
                active: format!("{}@{}", pack.manifest.id, pack.manifest.version),
            });
        }

        let mut rules: Vec<&DiagnosticRule> = pack
            .rules
            .iter()
            .filter(|rule| rule.status == KnowledgeStatus::Published)
            .collect();
        rules.sort_by(|left, right| (&left.id, &left.version).cmp(&(&right.id, &right.version)));

        let mut by_hypothesis: BTreeMap<&str, HypothesisAssessment> = pack
            .hypotheses
            .iter()
            .filter(|hypothesis| {
                hypothesis.status == KnowledgeStatus::Published
                    && hypothesis
                        .applicability
                        .evaluate(&session.vehicle.configuration)
                        == ApplicabilityMatch::Applies
            })
            .map(|hypothesis| (hypothesis.id.as_str(), empty_assessment(hypothesis)))
            .collect();
        let mut traces = Vec::with_capacity(rules.len());
        let mut candidates = Vec::new();
        let mut warnings = Vec::new();

        for rule in rules {
            let applicability = rule.applicability.evaluate(&session.vehicle.configuration);
            let condition = if applicability == ApplicabilityMatch::Applies {
                evaluate_condition(&rule.condition, session)
            } else {
                TruthValue::False
            };
            let emitted_effects = if applicability == ApplicabilityMatch::Applies
                && condition == TruthValue::True
            {
                for effect in &rule.effects {
                    match effect {
                        RuleEffect::Assess {
                            hypothesis_id,
                            polarity,
                            strength,
                            rationale,
                        } => {
                            if let Some(assessment) = by_hypothesis.get_mut(hypothesis_id.as_str())
                            {
                                apply_evidence(
                                    assessment,
                                    EvidenceAssessment {
                                        rule_id: rule.id.clone(),
                                        hypothesis_id: hypothesis_id.clone(),
                                        polarity: *polarity,
                                        strength: *strength,
                                        rationale: rationale.clone(),
                                        citation_ids: rule.citation_ids.clone(),
                                    },
                                );
                            }
                        }
                        RuleEffect::SuggestProcedure {
                            procedure_id,
                            discrimination,
                            rationale,
                        } => candidates.push((
                            procedure_id.clone(),
                            *discrimination,
                            rationale.clone(),
                        )),
                        RuleEffect::RaiseSafetyGate { rationale, .. } => {
                            warnings.push(rationale.clone())
                        }
                    }
                }
                rule.effects.len()
            } else {
                0
            };
            traces.push(RuleTrace {
                rule_id: rule.id.clone(),
                rule_version: rule.version.clone(),
                applicability,
                condition,
                emitted_effects,
            });
        }

        let mut assessments: Vec<_> = by_hypothesis.into_values().collect();
        assessments.sort_by(|left, right| {
            left.excluded
                .cmp(&right.excluded)
                .then_with(|| right.priority_score.cmp(&left.priority_score))
                .then_with(|| left.hypothesis_id.cmp(&right.hypothesis_id))
        });
        let next_test = best_next_test(&candidates, &pack.procedures, session);
        let trace_hash = hash_trace(session, pack, &traces)?;
        Ok(DiagnosticAssessment {
            assessments,
            next_test,
            trace: InferenceTrace {
                engine_version: DETERMINISTIC_ENGINE_VERSION.into(),
                session_id: session.id.to_string(),
                session_revision: session.revision,
                knowledge_pack_id: pack.manifest.id.clone(),
                knowledge_pack_version: pack.manifest.version.clone(),
                rules: traces,
                trace_hash,
            },
            warnings,
        })
    }
}

fn empty_assessment(hypothesis: &FaultHypothesis) -> HypothesisAssessment {
    HypothesisAssessment {
        hypothesis_id: hypothesis.id.clone(),
        title: hypothesis.title.clone(),
        severity: hypothesis.severity.clone(),
        excluded: false,
        priority_score: 0,
        supporting: vec![],
        contradicting: vec![],
    }
}

fn apply_evidence(target: &mut HypothesisAssessment, evidence: EvidenceAssessment) {
    match evidence.polarity {
        EvidencePolarity::Supports => {
            target.priority_score += evidence.strength.ordinal_weight();
            target.supporting.push(evidence);
        }
        EvidencePolarity::Contradicts => {
            target.priority_score -= evidence.strength.ordinal_weight();
            target.contradicting.push(evidence);
        }
        EvidencePolarity::Excludes => {
            target.excluded = true;
            target.contradicting.push(evidence);
        }
        EvidencePolarity::Neutral => {}
    }
}

pub fn evaluate_condition(condition: &ConditionExpr, session: &DiagnosticSession) -> TruthValue {
    match condition {
        ConditionExpr::All { conditions } => {
            let values: Vec<_> = conditions
                .iter()
                .map(|condition| evaluate_condition(condition, session))
                .collect();
            if values.contains(&TruthValue::False) {
                TruthValue::False
            } else if values.contains(&TruthValue::Unknown) {
                TruthValue::Unknown
            } else {
                TruthValue::True
            }
        }
        ConditionExpr::Any { conditions } => {
            let values: Vec<_> = conditions
                .iter()
                .map(|condition| evaluate_condition(condition, session))
                .collect();
            if values.contains(&TruthValue::True) {
                TruthValue::True
            } else if values.contains(&TruthValue::Unknown) {
                TruthValue::Unknown
            } else {
                TruthValue::False
            }
        }
        ConditionExpr::Not { condition } => evaluate_condition(condition, session).not(),
        ConditionExpr::ObservationMatches {
            kind,
            value,
            component_key,
        } => {
            let matches: Vec<_> = session
                .observations
                .iter()
                .filter(|observation| {
                    observation.kind == *kind
                        && component_matches(&observation.component_key, component_key)
                })
                .collect();
            if matches.is_empty() {
                TruthValue::Unknown
            } else if matches
                .iter()
                .rev()
                .any(|observation| observation.value == *value)
            {
                TruthValue::True
            } else {
                TruthValue::False
            }
        }
        ConditionExpr::MeasurementCompares {
            quantity,
            operator,
            threshold,
            unit,
            component_key,
        } => session
            .measurements
            .iter()
            .rev()
            .find(|measurement| {
                eq(&measurement.quantity, quantity)
                    && component_matches(&measurement.component_key, component_key)
            })
            .map_or(TruthValue::Unknown, |measurement| {
                if !eq(&measurement.value.unit, unit) {
                    TruthValue::Unknown
                } else if compare(measurement.value.value, *operator, *threshold) {
                    TruthValue::True
                } else {
                    TruthValue::False
                }
            }),
        ConditionExpr::ConfigurationMatches { predicate } => {
            if predicate.matches(&session.vehicle.configuration) {
                TruthValue::True
            } else {
                TruthValue::False
            }
        }
        ConditionExpr::ProcedureCompleted { procedure_id } => {
            if session.procedure_runs.iter().any(|run| {
                eq(&run.procedure_id, procedure_id)
                    && run.state == crate::ProcedureRunState::Completed
            }) {
                TruthValue::True
            } else {
                TruthValue::False
            }
        }
        ConditionExpr::MissingObservation {
            kind,
            component_key,
        } => {
            if session.observations.iter().any(|observation| {
                observation.kind == *kind
                    && component_matches(&observation.component_key, component_key)
            }) {
                TruthValue::False
            } else {
                TruthValue::True
            }
        }
        ConditionExpr::MissingMeasurement {
            quantity,
            component_key,
        } => {
            if session.measurements.iter().any(|measurement| {
                eq(&measurement.quantity, quantity)
                    && component_matches(&measurement.component_key, component_key)
            }) {
                TruthValue::False
            } else {
                TruthValue::True
            }
        }
    }
}

fn best_next_test(
    candidates: &[(String, EvidenceStrength, String)],
    procedures: &[Procedure],
    session: &DiagnosticSession,
) -> Option<NextTestRecommendation> {
    let mut ranked: Vec<_> = candidates
        .iter()
        .filter_map(|(id, discrimination, rationale)| {
            let procedure = procedures.iter().find(|procedure| {
                procedure.id == *id
                    && procedure.status == KnowledgeStatus::Published
                    && procedure
                        .applicability
                        .evaluate(&session.vehicle.configuration)
                        == ApplicabilityMatch::Applies
                    && !session.procedure_runs.iter().any(|run| {
                        run.procedure_id == *id && run.state == crate::ProcedureRunState::Completed
                    })
            })?;
            let hazards: Vec<_> = procedure
                .hazards
                .iter()
                .chain(procedure.steps.iter().flat_map(|step| step.hazards.iter()))
                .collect();
            let score = discrimination.ordinal_weight() * 10
                - i32::try_from(hazards.len()).unwrap_or(i32::MAX) * 2
                - i32::try_from(procedure.required_tools.len()).unwrap_or(i32::MAX);
            Some(NextTestRecommendation {
                procedure_id: procedure.id.clone(),
                procedure_version: procedure.version.clone(),
                title: procedure.title.clone(),
                rationale: rationale.clone(),
                discrimination: *discrimination,
                priority_score: score,
                prerequisites: procedure.prerequisites.clone(),
                hazard_summaries: hazards
                    .into_iter()
                    .map(|hazard| hazard.summary.clone())
                    .collect(),
                citation_ids: procedure.citation_ids.clone(),
            })
        })
        .collect();
    ranked.sort_by(|left, right| {
        right
            .priority_score
            .cmp(&left.priority_score)
            .then_with(|| left.procedure_id.cmp(&right.procedure_id))
    });
    ranked.into_iter().next()
}

fn hash_trace(
    session: &DiagnosticSession,
    pack: &KnowledgePack,
    rules: &[RuleTrace],
) -> Result<String, crate::DomainError> {
    let bytes = serde_json::to_vec(&(
        DETERMINISTIC_ENGINE_VERSION,
        &session.id,
        session.revision,
        &pack.manifest.id,
        &pack.manifest.version,
        rules,
    ))
    .map_err(|error| crate::DomainError::Serialization(error.to_string()))?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

fn component_matches(actual: &Option<String>, expected: &Option<String>) -> bool {
    expected
        .as_ref()
        .is_none_or(|expected| actual.as_ref().is_some_and(|actual| eq(actual, expected)))
}

fn eq(left: &str, right: &str) -> bool {
    left.trim().eq_ignore_ascii_case(right.trim())
}

fn compare(value: f64, operator: ComparisonOperator, threshold: f64) -> bool {
    match operator {
        ComparisonOperator::LessThan => value < threshold,
        ComparisonOperator::LessOrEqual => value <= threshold,
        ComparisonOperator::Equal => (value - threshold).abs() <= f64::EPSILON,
        ComparisonOperator::GreaterOrEqual => value >= threshold,
        ComparisonOperator::GreaterThan => value > threshold,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::tests::{fixture_pack, fixture_session};

    #[test]
    fn missing_measurement_recommends_a_test() {
        let session = fixture_session();
        let pack = fixture_pack();
        let result = DeterministicEngine.evaluate(&session, &pack).unwrap();
        assert_eq!(
            result
                .next_test
                .as_ref()
                .map(|next| next.procedure_id.as_str()),
            Some("fixture.measure-voltage")
        );
        assert_eq!(result.assessments[0].priority_score, 0);
    }

    #[test]
    fn measured_condition_supports_hypothesis_deterministically() {
        let mut session = fixture_session();
        session.measurements.push(crate::Measurement {
            id: crate::MeasurementId::new(),
            quantity: "voltage".into(),
            value: crate::Quantity {
                value: 2.0,
                unit: "V".into(),
                uncertainty: None,
            },
            acquisition: crate::Acquisition::Instrument {
                kind: "fixture meter".into(),
                identifier: None,
            },
            measured_at: crate::now_timestamp(),
            component_key: Some("fixture-component".into()),
            terminals: None,
            conditions: vec![],
            source_step: None,
            notes: None,
        });
        let pack = fixture_pack();
        let first = DeterministicEngine.evaluate(&session, &pack).unwrap();
        let second = DeterministicEngine.evaluate(&session, &pack).unwrap();
        assert_eq!(first.trace.trace_hash, second.trace.trace_hash);
        assert_eq!(first.assessments[0].priority_score, 4);
        assert!(first.next_test.is_none());
    }
}
