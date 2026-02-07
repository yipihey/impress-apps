//! TOML loader for user-defined personas
//!
//! Loads personas from identity.toml files with the following structure:
//!
//! ```toml
//! [identity]
//! id = "custom-scout"
//! name = "Custom Scout"
//! archetype = "research"
//! role_description = "A customized research explorer"
//! system_prompt = """
//! You are a customized Scout...
//! """
//!
//! [behavior]
//! verbosity = 0.5
//! risk_tolerance = 0.8
//! citation_density = 0.3
//! escalation_tendency = 0.6
//! working_style = "rapid"
//! notes = ["Note 1", "Note 2"]
//!
//! [domain]
//! primary_domains = ["machine learning", "NLP"]
//! methodologies = ["literature survey"]
//! data_sources = ["arxiv", "semantic scholar"]
//!
//! [model]
//! provider = "anthropic"
//! model = "claude-sonnet-4-20250514"
//! temperature = 0.7
//! max_tokens = 4096
//!
//! [[tools.policies]]
//! tool = "imbib"
//! access = "read_write"
//!
//! [[tools.policies]]
//! tool = "bash"
//! access = "none"
//!
//! [tools]
//! default_access = "read"
//! ```

use std::collections::HashMap;
use std::path::Path;

use serde::Deserialize;

use crate::agent::AgentType;

use super::{
    Persona, PersonaBehavior, PersonaDomain, PersonaId, PersonaModelConfig, ToolAccess, ToolPolicy,
    ToolPolicySet, WorkingStyle,
};

/// Errors that can occur when loading a persona from TOML
#[derive(Debug, thiserror::Error)]
pub enum PersonaLoadError {
    #[error("IO error: {0}")]
    Io(String),

    #[error("TOML parse error: {0}")]
    Parse(String),

    #[error("Missing required field: {0}")]
    MissingField(String),

    #[error("Invalid archetype: {0}")]
    InvalidArchetype(String),

    #[error("Invalid working style: {0}")]
    InvalidWorkingStyle(String),

    #[error("Invalid access level: {0}")]
    InvalidAccess(String),
}

/// TOML representation of a persona identity
#[derive(Debug, Deserialize)]
struct TomlIdentity {
    id: String,
    name: String,
    archetype: String,
    role_description: String,
    #[serde(default)]
    system_prompt: String,
}

/// TOML representation of behavior
#[derive(Debug, Deserialize, Default)]
struct TomlBehavior {
    #[serde(default = "default_verbosity")]
    verbosity: f64,
    #[serde(default = "default_risk")]
    risk_tolerance: f64,
    #[serde(default = "default_citation")]
    citation_density: f64,
    #[serde(default = "default_escalation")]
    escalation_tendency: f64,
    #[serde(default)]
    working_style: Option<String>,
    #[serde(default)]
    notes: Vec<String>,
}

fn default_verbosity() -> f64 {
    0.5
}
fn default_risk() -> f64 {
    0.3
}
fn default_citation() -> f64 {
    0.5
}
fn default_escalation() -> f64 {
    0.5
}

/// TOML representation of domain
#[derive(Debug, Deserialize, Default)]
struct TomlDomain {
    #[serde(default)]
    primary_domains: Vec<String>,
    #[serde(default)]
    methodologies: Vec<String>,
    #[serde(default)]
    data_sources: Vec<String>,
    #[serde(default)]
    terminology: HashMap<String, String>,
}

/// TOML representation of model config
#[derive(Debug, Deserialize)]
struct TomlModel {
    #[serde(default = "default_provider")]
    provider: String,
    #[serde(default = "default_model")]
    model: String,
    #[serde(default = "default_temperature")]
    temperature: f64,
    max_tokens: Option<u32>,
    top_p: Option<f64>,
}

fn default_provider() -> String {
    "anthropic".to_string()
}
fn default_model() -> String {
    "claude-sonnet-4-20250514".to_string()
}
fn default_temperature() -> f64 {
    0.7
}

impl Default for TomlModel {
    fn default() -> Self {
        Self {
            provider: default_provider(),
            model: default_model(),
            temperature: default_temperature(),
            max_tokens: None,
            top_p: None,
        }
    }
}

/// TOML representation of a tool policy
#[derive(Debug, Deserialize)]
struct TomlToolPolicy {
    tool: String,
    access: String,
    #[serde(default)]
    scope: Vec<String>,
    notes: Option<String>,
}

/// TOML representation of tools config
#[derive(Debug, Deserialize, Default)]
struct TomlTools {
    #[serde(default)]
    policies: Vec<TomlToolPolicy>,
    #[serde(default)]
    default_access: Option<String>,
}

/// Full TOML persona document
#[derive(Debug, Deserialize)]
struct TomlPersona {
    identity: TomlIdentity,
    #[serde(default)]
    behavior: TomlBehavior,
    #[serde(default)]
    domain: TomlDomain,
    #[serde(default)]
    model: TomlModel,
    #[serde(default)]
    tools: TomlTools,
}

/// Load a persona from a TOML file
pub fn load_persona_from_toml(path: &Path) -> Result<Persona, PersonaLoadError> {
    let content = std::fs::read_to_string(path).map_err(|e| PersonaLoadError::Io(e.to_string()))?;

    let toml: TomlPersona =
        toml::from_str(&content).map_err(|e| PersonaLoadError::Parse(e.to_string()))?;

    let archetype = parse_archetype(&toml.identity.archetype)?;
    let behavior = parse_behavior(toml.behavior)?;
    let domain = parse_domain(toml.domain);
    let model = parse_model(toml.model);
    let tools = parse_tools(toml.tools)?;

    let persona = Persona {
        id: PersonaId::new(toml.identity.id),
        name: toml.identity.name,
        archetype,
        role_description: toml.identity.role_description,
        system_prompt: toml.identity.system_prompt,
        behavior,
        domain,
        model,
        tools,
        builtin: false,
        source_path: Some(path.to_string_lossy().to_string()),
    };

    Ok(persona)
}

fn parse_archetype(s: &str) -> Result<AgentType, PersonaLoadError> {
    match s.to_lowercase().as_str() {
        "research" => Ok(AgentType::Research),
        "code" => Ok(AgentType::Code),
        "verification" => Ok(AgentType::Verification),
        "adversarial" => Ok(AgentType::Adversarial),
        "review" => Ok(AgentType::Review),
        "librarian" => Ok(AgentType::Librarian),
        _ => Err(PersonaLoadError::InvalidArchetype(s.to_string())),
    }
}

fn parse_working_style(s: &str) -> Result<WorkingStyle, PersonaLoadError> {
    match s.to_lowercase().as_str() {
        "rapid" => Ok(WorkingStyle::Rapid),
        "balanced" => Ok(WorkingStyle::Balanced),
        "methodical" => Ok(WorkingStyle::Methodical),
        "analytical" => Ok(WorkingStyle::Analytical),
        _ => Err(PersonaLoadError::InvalidWorkingStyle(s.to_string())),
    }
}

fn parse_access(s: &str) -> Result<ToolAccess, PersonaLoadError> {
    match s.to_lowercase().replace('_', "").as_str() {
        "none" => Ok(ToolAccess::None),
        "read" => Ok(ToolAccess::Read),
        "readwrite" => Ok(ToolAccess::ReadWrite),
        "full" => Ok(ToolAccess::Full),
        _ => Err(PersonaLoadError::InvalidAccess(s.to_string())),
    }
}

fn parse_behavior(toml: TomlBehavior) -> Result<PersonaBehavior, PersonaLoadError> {
    let working_style = match toml.working_style {
        Some(s) => parse_working_style(&s)?,
        None => WorkingStyle::default(),
    };

    Ok(PersonaBehavior {
        verbosity: toml.verbosity,
        risk_tolerance: toml.risk_tolerance,
        citation_density: toml.citation_density,
        escalation_tendency: toml.escalation_tendency,
        working_style,
        notes: toml.notes,
    })
}

fn parse_domain(toml: TomlDomain) -> PersonaDomain {
    PersonaDomain {
        primary_domains: toml.primary_domains,
        methodologies: toml.methodologies,
        data_sources: toml.data_sources,
        terminology: toml.terminology,
    }
}

fn parse_model(toml: TomlModel) -> PersonaModelConfig {
    PersonaModelConfig {
        provider: toml.provider,
        model: toml.model,
        temperature: toml.temperature,
        max_tokens: toml.max_tokens,
        top_p: toml.top_p,
    }
}

fn parse_tools(toml: TomlTools) -> Result<ToolPolicySet, PersonaLoadError> {
    let mut policies = Vec::new();

    for p in toml.policies {
        let access = parse_access(&p.access)?;
        let mut policy = ToolPolicy::new(p.tool, access);
        policy.scope = p.scope;
        policy.notes = p.notes;
        policies.push(policy);
    }

    let default_access = match toml.default_access {
        Some(s) => parse_access(&s)?,
        None => ToolAccess::None,
    };

    Ok(ToolPolicySet {
        policies,
        default_access,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn write_temp_toml(content: &str) -> NamedTempFile {
        let mut file = NamedTempFile::new().unwrap();
        file.write_all(content.as_bytes()).unwrap();
        file.flush().unwrap();
        file
    }

    #[test]
    fn test_minimal_persona() {
        let toml = r#"
[identity]
id = "test-persona"
name = "Test Persona"
archetype = "research"
role_description = "A test persona"
"#;

        let file = write_temp_toml(toml);
        let persona = load_persona_from_toml(file.path()).unwrap();

        assert_eq!(persona.id.as_str(), "test-persona");
        assert_eq!(persona.name, "Test Persona");
        assert_eq!(persona.archetype, AgentType::Research);
        assert!(!persona.builtin);
    }

    #[test]
    fn test_full_persona() {
        let toml = r#"
[identity]
id = "custom-scout"
name = "Custom Scout"
archetype = "research"
role_description = "A customized research explorer"
system_prompt = "You are a customized Scout..."

[behavior]
verbosity = 0.4
risk_tolerance = 0.9
citation_density = 0.2
escalation_tendency = 0.5
working_style = "rapid"
notes = ["Fast and loose", "Prototype-oriented"]

[domain]
primary_domains = ["machine learning", "NLP"]
methodologies = ["literature survey"]
data_sources = ["arxiv"]

[model]
provider = "anthropic"
model = "claude-sonnet-4-20250514"
temperature = 0.8
max_tokens = 8192

[[tools.policies]]
tool = "imbib"
access = "read_write"

[[tools.policies]]
tool = "bash"
access = "none"

[tools]
default_access = "read"
"#;

        let file = write_temp_toml(toml);
        let persona = load_persona_from_toml(file.path()).unwrap();

        assert_eq!(persona.id.as_str(), "custom-scout");
        assert!((persona.behavior.risk_tolerance - 0.9).abs() < f64::EPSILON);
        assert_eq!(persona.behavior.working_style, WorkingStyle::Rapid);
        assert_eq!(persona.behavior.notes.len(), 2);
        assert_eq!(persona.domain.primary_domains.len(), 2);
        assert!((persona.model.temperature - 0.8).abs() < f64::EPSILON);
        assert_eq!(persona.model.max_tokens, Some(8192));
        assert!(persona.tools.can_access("imbib"));
        assert!(persona.tools.can_write("imbib"));
        assert!(!persona.tools.can_access("bash"));
    }

    #[test]
    fn test_invalid_archetype() {
        let toml = r#"
[identity]
id = "test"
name = "Test"
archetype = "invalid"
role_description = "Test"
"#;

        let file = write_temp_toml(toml);
        let result = load_persona_from_toml(file.path());
        assert!(matches!(result, Err(PersonaLoadError::InvalidArchetype(_))));
    }

    #[test]
    fn test_parse_access_variants() {
        assert_eq!(parse_access("none").unwrap(), ToolAccess::None);
        assert_eq!(parse_access("read").unwrap(), ToolAccess::Read);
        assert_eq!(parse_access("read_write").unwrap(), ToolAccess::ReadWrite);
        assert_eq!(parse_access("readwrite").unwrap(), ToolAccess::ReadWrite);
        assert_eq!(parse_access("ReadWrite").unwrap(), ToolAccess::ReadWrite);
        assert_eq!(parse_access("full").unwrap(), ToolAccess::Full);
    }
}
