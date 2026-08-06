use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::{Market, VehicleConfiguration};

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
pub struct Applicability {
    #[serde(default)]
    pub all: Vec<ApplicabilityPredicate>,
    #[serde(default)]
    pub any: Vec<ApplicabilityPredicate>,
    #[serde(default)]
    pub none: Vec<ApplicabilityPredicate>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "snake_case")]
pub enum ApplicabilityPredicate {
    ModelFamily(String),
    ModelYear { min: u16, max: u16 },
    Market(Market),
    EmissionsSpec(String),
    EngineCode(String),
    FuelSystem(String),
    Transmission(String),
    HasOption(String),
    HasComponent(String),
    NoDeviation(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ApplicabilityMatch {
    Applies,
    Inapplicable,
}

impl ApplicabilityPredicate {
    pub fn matches(&self, config: &VehicleConfiguration) -> bool {
        match self {
            Self::ModelFamily(value) => eq(&config.model_family, value),
            Self::ModelYear { min, max } => (*min..=*max).contains(&config.model_year),
            Self::Market(value) => &config.market == value,
            Self::EmissionsSpec(value) => eq(&config.emissions_spec, value),
            Self::EngineCode(value) => eq(&config.engine_code, value),
            Self::FuelSystem(value) => eq(&config.fuel_system, value),
            Self::Transmission(value) => config.transmission.as_ref().is_some_and(|v| eq(v, value)),
            Self::HasOption(value) => contains(&config.installed_options, value),
            Self::HasComponent(value) => contains(&config.installed_components, value),
            Self::NoDeviation(field) => !config
                .deviations
                .iter()
                .any(|deviation| eq(&deviation.field, field)),
        }
    }
}

impl Applicability {
    pub fn evaluate(&self, config: &VehicleConfiguration) -> ApplicabilityMatch {
        let all = self.all.iter().all(|predicate| predicate.matches(config));
        let any = self.any.is_empty() || self.any.iter().any(|predicate| predicate.matches(config));
        let none = self.none.iter().all(|predicate| !predicate.matches(config));
        if all && any && none {
            ApplicabilityMatch::Applies
        } else {
            ApplicabilityMatch::Inapplicable
        }
    }
}

fn eq(left: &str, right: &str) -> bool {
    left.trim().eq_ignore_ascii_case(right.trim())
}

fn contains(values: &std::collections::BTreeSet<String>, needle: &str) -> bool {
    values.iter().any(|value| eq(value, needle))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ConfigurationId, VerificationState};
    use std::collections::BTreeSet;

    fn config() -> VehicleConfiguration {
        VehicleConfiguration {
            id: ConfigurationId::new(),
            model_family: "Type 2".into(),
            model_year: 1978,
            market: Market::California,
            emissions_spec: "California".into(),
            engine_code: "GE".into(),
            fuel_system: "L-Jetronic".into(),
            transmission: Some("manual".into()),
            installed_options: BTreeSet::new(),
            installed_components: BTreeSet::from(["double-relay".into()]),
            deviations: vec![],
            verification: VerificationState::Verified,
        }
    }

    #[test]
    fn combines_all_any_and_none() {
        let applicability = Applicability {
            all: vec![
                ApplicabilityPredicate::ModelYear {
                    min: 1978,
                    max: 1978,
                },
                ApplicabilityPredicate::Market(Market::California),
            ],
            any: vec![
                ApplicabilityPredicate::EngineCode("GE".into()),
                ApplicabilityPredicate::EngineCode("GD".into()),
            ],
            none: vec![ApplicabilityPredicate::HasOption("carburetor".into())],
        };
        assert_eq!(
            applicability.evaluate(&config()),
            ApplicabilityMatch::Applies
        );
    }
}
