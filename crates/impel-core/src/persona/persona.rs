//! Persona type definitions
//!
//! A Persona is a rich behavioral configuration for an agent, providing:
//! - Identity (name, role description, archetype)
//! - Behavioral traits (verbosity, risk tolerance, citation style)
//! - Model configuration (provider, model, temperature)
//! - Tool access policies (which tools, read/write/execute)
//! - Domain expertise specification

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::agent::AgentType;

/// Unique identifier for a persona
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct PersonaId(pub String);

impl PersonaId {
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for PersonaId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl From<&str> for PersonaId {
    fn from(s: &str) -> Self {
        Self(s.to_string())
    }
}

impl From<String> for PersonaId {
    fn from(s: String) -> Self {
        Self(s)
    }
}

/// A persona is a rich behavioral configuration for an agent
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Persona {
    /// Unique identifier (e.g., "scout", "archivist", "steward")
    pub id: PersonaId,

    /// Human-readable display name
    pub name: String,

    /// The underlying capability archetype (links to existing AgentType)
    pub archetype: AgentType,

    /// Short description of the persona's role
    pub role_description: String,

    /// Extended description for system prompts
    pub system_prompt: String,

    /// Behavioral configuration
    pub behavior: PersonaBehavior,

    /// Domain expertise
    pub domain: PersonaDomain,

    /// Model configuration
    pub model: PersonaModelConfig,

    /// Tool access policies
    pub tools: ToolPolicySet,

    /// Whether this persona is builtin (vs user-defined or project-specific)
    pub builtin: bool,

    /// Source path if loaded from file (None for builtin)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_path: Option<String>,
}

impl Persona {
    /// Create a new persona with minimal configuration
    pub fn new(
        id: impl Into<PersonaId>,
        name: impl Into<String>,
        archetype: AgentType,
        role_description: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            archetype,
            role_description: role_description.into(),
            system_prompt: String::new(),
            behavior: PersonaBehavior::default(),
            domain: PersonaDomain::default(),
            model: PersonaModelConfig::default(),
            tools: ToolPolicySet::default(),
            builtin: false,
            source_path: None,
        }
    }

    /// Builder: set system prompt
    pub fn with_system_prompt(mut self, prompt: impl Into<String>) -> Self {
        self.system_prompt = prompt.into();
        self
    }

    /// Builder: set behavior
    pub fn with_behavior(mut self, behavior: PersonaBehavior) -> Self {
        self.behavior = behavior;
        self
    }

    /// Builder: set domain
    pub fn with_domain(mut self, domain: PersonaDomain) -> Self {
        self.domain = domain;
        self
    }

    /// Builder: set model config
    pub fn with_model(mut self, model: PersonaModelConfig) -> Self {
        self.model = model;
        self
    }

    /// Builder: set tools
    pub fn with_tools(mut self, tools: ToolPolicySet) -> Self {
        self.tools = tools;
        self
    }

    /// Builder: mark as builtin
    pub fn as_builtin(mut self) -> Self {
        self.builtin = true;
        self
    }

    /// Check if persona can use a specific tool
    pub fn can_use_tool(&self, tool: &str) -> bool {
        self.tools.can_access(tool)
    }

    /// Check if persona can write with a specific tool
    pub fn can_write_with(&self, tool: &str) -> bool {
        self.tools.can_write(tool)
    }
}

/// Behavioral traits that shape how a persona approaches tasks
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct PersonaBehavior {
    /// How verbose should responses be (0.0 = terse, 1.0 = comprehensive)
    pub verbosity: f64,

    /// Risk tolerance for novel approaches (0.0 = conservative, 1.0 = experimental)
    pub risk_tolerance: f64,

    /// How heavily to cite sources (0.0 = minimal, 1.0 = every claim)
    pub citation_density: f64,

    /// Tendency to seek human input (0.0 = autonomous, 1.0 = frequent escalation)
    pub escalation_tendency: f64,

    /// Preferred working style
    pub working_style: WorkingStyle,

    /// Additional behavioral notes for system prompts
    #[serde(default)]
    pub notes: Vec<String>,
}

impl Default for PersonaBehavior {
    fn default() -> Self {
        Self {
            verbosity: 0.5,
            risk_tolerance: 0.3,
            citation_density: 0.5,
            escalation_tendency: 0.5,
            working_style: WorkingStyle::Balanced,
            notes: Vec::new(),
        }
    }
}

/// Working style preferences
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum WorkingStyle {
    /// Fast iterations, prototype-oriented
    Rapid,
    /// Balance between speed and thoroughness
    #[default]
    Balanced,
    /// Methodical, thorough, documentation-heavy
    Methodical,
    /// Deep analysis before action
    Analytical,
}

impl WorkingStyle {
    pub fn name(&self) -> &'static str {
        match self {
            WorkingStyle::Rapid => "Rapid",
            WorkingStyle::Balanced => "Balanced",
            WorkingStyle::Methodical => "Methodical",
            WorkingStyle::Analytical => "Analytical",
        }
    }
}

/// Domain expertise specification
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct PersonaDomain {
    /// Primary research domains (e.g., "machine learning", "cosmology")
    #[serde(default)]
    pub primary_domains: Vec<String>,

    /// Methodological expertise (e.g., "statistical analysis", "literature review")
    #[serde(default)]
    pub methodologies: Vec<String>,

    /// Preferred data sources (e.g., "arxiv", "semantic scholar")
    #[serde(default)]
    pub data_sources: Vec<String>,

    /// Domain-specific terminology to use
    #[serde(default)]
    pub terminology: HashMap<String, String>,
}

/// Model configuration for a persona
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct PersonaModelConfig {
    /// Provider (e.g., "anthropic", "openai", "ollama")
    pub provider: String,

    /// Model identifier (e.g., "claude-sonnet-4-20250514", "gpt-4o")
    pub model: String,

    /// Sampling temperature (0.0 = deterministic, 1.0 = creative)
    pub temperature: f64,

    /// Maximum tokens in response (None = provider default)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,

    /// Top-p sampling (None = provider default)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub top_p: Option<f64>,
}

impl Default for PersonaModelConfig {
    fn default() -> Self {
        Self {
            provider: "anthropic".to_string(),
            model: "claude-sonnet-4-20250514".to_string(),
            temperature: 0.7,
            max_tokens: None,
            top_p: None,
        }
    }
}

impl PersonaModelConfig {
    pub fn anthropic(model: &str) -> Self {
        Self {
            provider: "anthropic".to_string(),
            model: model.to_string(),
            ..Default::default()
        }
    }

    pub fn with_temperature(mut self, temp: f64) -> Self {
        self.temperature = temp;
        self
    }

    pub fn with_max_tokens(mut self, tokens: u32) -> Self {
        self.max_tokens = Some(tokens);
        self
    }
}

/// Access level for a tool
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ToolAccess {
    /// No access
    #[default]
    None,
    /// Read-only access
    Read,
    /// Read and write access
    ReadWrite,
    /// Full access including execute/delete
    Full,
}

impl ToolAccess {
    pub fn can_read(&self) -> bool {
        !matches!(self, ToolAccess::None)
    }

    pub fn can_write(&self) -> bool {
        matches!(self, ToolAccess::ReadWrite | ToolAccess::Full)
    }

    pub fn can_execute(&self) -> bool {
        matches!(self, ToolAccess::Full)
    }
}

/// Policy for a specific tool
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ToolPolicy {
    /// Tool name (e.g., "imbib", "imprint", "bash")
    pub tool: String,

    /// Access level
    pub access: ToolAccess,

    /// Optional scope restrictions (e.g., specific collections, paths)
    #[serde(default)]
    pub scope: Vec<String>,

    /// Additional notes about usage
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
}

impl ToolPolicy {
    pub fn new(tool: impl Into<String>, access: ToolAccess) -> Self {
        Self {
            tool: tool.into(),
            access,
            scope: Vec::new(),
            notes: None,
        }
    }

    pub fn with_scope(mut self, scope: Vec<String>) -> Self {
        self.scope = scope;
        self
    }
}

/// Collection of tool policies for a persona
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ToolPolicySet {
    /// Individual tool policies
    #[serde(default)]
    pub policies: Vec<ToolPolicy>,

    /// Default access for unlisted tools
    #[serde(default)]
    pub default_access: ToolAccess,
}

impl ToolPolicySet {
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a tool policy
    pub fn with_policy(mut self, policy: ToolPolicy) -> Self {
        self.policies.push(policy);
        self
    }

    /// Set default access
    pub fn with_default(mut self, access: ToolAccess) -> Self {
        self.default_access = access;
        self
    }

    /// Get policy for a specific tool
    pub fn get_policy(&self, tool: &str) -> Option<&ToolPolicy> {
        self.policies.iter().find(|p| p.tool == tool)
    }

    /// Check if tool can be accessed
    pub fn can_access(&self, tool: &str) -> bool {
        self.get_policy(tool)
            .map(|p| p.access.can_read())
            .unwrap_or(self.default_access.can_read())
    }

    /// Check if tool can be written to
    pub fn can_write(&self, tool: &str) -> bool {
        self.get_policy(tool)
            .map(|p| p.access.can_write())
            .unwrap_or(self.default_access.can_write())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_persona_creation() {
        let persona = Persona::new(
            "scout",
            "Scout",
            AgentType::Research,
            "Eager explorer of new research directions",
        )
        .with_behavior(PersonaBehavior {
            risk_tolerance: 0.8,
            ..Default::default()
        })
        .as_builtin();

        assert_eq!(persona.id.as_str(), "scout");
        assert_eq!(persona.archetype, AgentType::Research);
        assert!(persona.builtin);
        assert!((persona.behavior.risk_tolerance - 0.8).abs() < f64::EPSILON);
    }

    #[test]
    fn test_tool_policy() {
        let tools = ToolPolicySet::new()
            .with_policy(ToolPolicy::new("imbib", ToolAccess::Read))
            .with_policy(ToolPolicy::new("imprint", ToolAccess::ReadWrite))
            .with_default(ToolAccess::None);

        assert!(tools.can_access("imbib"));
        assert!(!tools.can_write("imbib"));
        assert!(tools.can_access("imprint"));
        assert!(tools.can_write("imprint"));
        assert!(!tools.can_access("bash"));
    }

    #[test]
    fn test_model_config() {
        let config = PersonaModelConfig::anthropic("claude-sonnet-4-20250514")
            .with_temperature(0.3)
            .with_max_tokens(4096);

        assert_eq!(config.provider, "anthropic");
        assert_eq!(config.model, "claude-sonnet-4-20250514");
        assert!((config.temperature - 0.3).abs() < f64::EPSILON);
        assert_eq!(config.max_tokens, Some(4096));
    }
}
