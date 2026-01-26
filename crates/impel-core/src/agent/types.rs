//! Agent type definitions

use serde::{Deserialize, Serialize};

/// The type of agent
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum AgentType {
    /// Research agent - performs literature review, data gathering
    Research,
    /// Code agent - writes and maintains code
    Code,
    /// Verification agent - tests, validates, reproduces results
    Verification,
    /// Adversarial agent - challenges assumptions, finds weaknesses
    Adversarial,
    /// Review agent - reviews work, ensures quality
    Review,
    /// Librarian agent - manages references, citations, bibliography
    Librarian,
}

impl AgentType {
    /// Get a human-readable name for the agent type
    pub fn name(&self) -> &'static str {
        match self {
            AgentType::Research => "Research",
            AgentType::Code => "Code",
            AgentType::Verification => "Verification",
            AgentType::Adversarial => "Adversarial",
            AgentType::Review => "Review",
            AgentType::Librarian => "Librarian",
        }
    }

    /// Get a description of the agent type's role
    pub fn description(&self) -> &'static str {
        match self {
            AgentType::Research => "Performs literature review and data gathering",
            AgentType::Code => "Writes and maintains code",
            AgentType::Verification => "Tests, validates, and reproduces results",
            AgentType::Adversarial => "Challenges assumptions and finds weaknesses",
            AgentType::Review => "Reviews work and ensures quality standards",
            AgentType::Librarian => "Manages references, citations, and bibliography",
        }
    }

    /// Get the capabilities of this agent type
    pub fn capabilities(&self) -> Vec<AgentCapability> {
        match self {
            AgentType::Research => vec![
                AgentCapability::LiteratureSearch,
                AgentCapability::DataCollection,
                AgentCapability::Summarization,
            ],
            AgentType::Code => vec![
                AgentCapability::CodeGeneration,
                AgentCapability::CodeReview,
                AgentCapability::Testing,
            ],
            AgentType::Verification => vec![
                AgentCapability::Testing,
                AgentCapability::Validation,
                AgentCapability::Reproduction,
            ],
            AgentType::Adversarial => vec![
                AgentCapability::CritiqueGeneration,
                AgentCapability::WeaknessIdentification,
            ],
            AgentType::Review => vec![
                AgentCapability::QualityAssessment,
                AgentCapability::CodeReview,
                AgentCapability::DocumentReview,
            ],
            AgentType::Librarian => vec![
                AgentCapability::ReferenceManagement,
                AgentCapability::CitationFormatting,
                AgentCapability::BibliographyGeneration,
            ],
        }
    }

    /// Check if this agent type can perform a specific capability
    pub fn can_perform(&self, capability: AgentCapability) -> bool {
        self.capabilities().contains(&capability)
    }
}

impl std::fmt::Display for AgentType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.name())
    }
}

/// Capabilities that agents can have
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum AgentCapability {
    /// Search and retrieve literature
    LiteratureSearch,
    /// Collect and organize data
    DataCollection,
    /// Summarize content
    Summarization,
    /// Generate code
    CodeGeneration,
    /// Review code
    CodeReview,
    /// Run tests
    Testing,
    /// Validate results
    Validation,
    /// Reproduce experiments
    Reproduction,
    /// Generate critiques
    CritiqueGeneration,
    /// Identify weaknesses
    WeaknessIdentification,
    /// Assess quality
    QualityAssessment,
    /// Review documents
    DocumentReview,
    /// Manage references
    ReferenceManagement,
    /// Format citations
    CitationFormatting,
    /// Generate bibliography
    BibliographyGeneration,
}

impl AgentCapability {
    /// Get a human-readable name for the capability
    pub fn name(&self) -> &'static str {
        match self {
            AgentCapability::LiteratureSearch => "Literature Search",
            AgentCapability::DataCollection => "Data Collection",
            AgentCapability::Summarization => "Summarization",
            AgentCapability::CodeGeneration => "Code Generation",
            AgentCapability::CodeReview => "Code Review",
            AgentCapability::Testing => "Testing",
            AgentCapability::Validation => "Validation",
            AgentCapability::Reproduction => "Reproduction",
            AgentCapability::CritiqueGeneration => "Critique Generation",
            AgentCapability::WeaknessIdentification => "Weakness Identification",
            AgentCapability::QualityAssessment => "Quality Assessment",
            AgentCapability::DocumentReview => "Document Review",
            AgentCapability::ReferenceManagement => "Reference Management",
            AgentCapability::CitationFormatting => "Citation Formatting",
            AgentCapability::BibliographyGeneration => "Bibliography Generation",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_agent_capabilities() {
        let research = AgentType::Research;
        assert!(research.can_perform(AgentCapability::LiteratureSearch));
        assert!(!research.can_perform(AgentCapability::CodeGeneration));

        let code = AgentType::Code;
        assert!(code.can_perform(AgentCapability::CodeGeneration));
        assert!(!code.can_perform(AgentCapability::LiteratureSearch));
    }

    #[test]
    fn test_librarian_capabilities() {
        let librarian = AgentType::Librarian;
        assert!(librarian.can_perform(AgentCapability::ReferenceManagement));
        assert!(librarian.can_perform(AgentCapability::CitationFormatting));
        assert!(librarian.can_perform(AgentCapability::BibliographyGeneration));
    }
}
