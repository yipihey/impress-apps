//! Persona registry for managing available personas
//!
//! The registry provides:
//! - Loading and resolution of personas (project > user > builtin)
//! - Lookup by ID
//! - Listing and filtering

use std::collections::HashMap;
use std::path::Path;

use super::builtin::builtin_personas;
use super::toml_loader::{load_persona_from_toml, PersonaLoadError};
use super::{Persona, PersonaId};
use crate::agent::AgentType;

/// Source location of a persona
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PersonaSource {
    /// Compiled into impel-core
    Builtin,
    /// Loaded from ~/.impel/personas/
    User,
    /// Loaded from .impel/personas/ (project directory)
    Project,
}

impl PersonaSource {
    /// Resolution priority (higher = takes precedence)
    pub fn priority(&self) -> u8 {
        match self {
            PersonaSource::Builtin => 0,
            PersonaSource::User => 1,
            PersonaSource::Project => 2,
        }
    }
}

/// Registry for managing available personas
#[derive(Debug, Default)]
pub struct PersonaRegistry {
    personas: HashMap<PersonaId, Persona>,
    sources: HashMap<PersonaId, PersonaSource>,
}

impl PersonaRegistry {
    /// Create an empty registry
    pub fn new() -> Self {
        Self::default()
    }

    /// Create a registry with builtin personas loaded
    pub fn with_builtins() -> Self {
        let mut registry = Self::new();
        for persona in builtin_personas() {
            registry.register(persona, PersonaSource::Builtin);
        }
        registry
    }

    /// Load personas from standard locations
    ///
    /// Loads in order: builtin, user (~/.impel/personas/), project (.impel/personas/)
    /// Later sources override earlier ones for the same ID.
    pub fn load_standard(project_root: Option<&Path>) -> Result<Self, PersonaLoadError> {
        let mut registry = Self::with_builtins();

        // Load user personas from ~/.impel/personas/
        if let Some(home) = dirs::home_dir() {
            let user_dir = home.join(".impel").join("personas");
            if user_dir.exists() {
                registry.load_from_directory(&user_dir, PersonaSource::User)?;
            }
        }

        // Load project personas from .impel/personas/
        if let Some(root) = project_root {
            let project_dir = root.join(".impel").join("personas");
            if project_dir.exists() {
                registry.load_from_directory(&project_dir, PersonaSource::Project)?;
            }
        }

        Ok(registry)
    }

    /// Load personas from a directory
    ///
    /// Expects structure: {dir}/{persona_name}/identity.toml
    pub fn load_from_directory(
        &mut self,
        dir: &Path,
        source: PersonaSource,
    ) -> Result<(), PersonaLoadError> {
        if !dir.is_dir() {
            return Ok(()); // Silently skip non-existent directories
        }

        for entry in std::fs::read_dir(dir).map_err(|e| PersonaLoadError::Io(e.to_string()))? {
            let entry = entry.map_err(|e| PersonaLoadError::Io(e.to_string()))?;
            let path = entry.path();

            if path.is_dir() {
                let identity_path = path.join("identity.toml");
                if identity_path.exists() {
                    let persona = load_persona_from_toml(&identity_path)?;
                    self.register(persona, source.clone());
                }
            }
        }

        Ok(())
    }

    /// Register a persona with its source
    ///
    /// If a persona with the same ID already exists, it will be replaced
    /// only if the new source has equal or higher priority.
    pub fn register(&mut self, persona: Persona, source: PersonaSource) {
        let id = persona.id.clone();

        // Check if we should replace
        if let Some(existing_source) = self.sources.get(&id) {
            if source.priority() < existing_source.priority() {
                return; // Don't replace with lower priority
            }
        }

        self.personas.insert(id.clone(), persona);
        self.sources.insert(id, source);
    }

    /// Get a persona by ID
    pub fn get(&self, id: &PersonaId) -> Option<&Persona> {
        self.personas.get(id)
    }

    /// Get a persona by string ID
    pub fn get_by_str(&self, id: &str) -> Option<&Persona> {
        self.personas.get(&PersonaId::new(id))
    }

    /// Get the source of a persona
    pub fn source(&self, id: &PersonaId) -> Option<&PersonaSource> {
        self.sources.get(id)
    }

    /// List all personas
    pub fn all(&self) -> impl Iterator<Item = &Persona> {
        self.personas.values()
    }

    /// List personas by archetype
    pub fn by_archetype(&self, archetype: AgentType) -> impl Iterator<Item = &Persona> {
        self.personas
            .values()
            .filter(move |p| p.archetype == archetype)
    }

    /// List builtin personas
    pub fn builtins(&self) -> impl Iterator<Item = &Persona> {
        let builtin_ids: Vec<_> = self
            .sources
            .iter()
            .filter(|(_, s)| **s == PersonaSource::Builtin)
            .map(|(id, _)| id.clone())
            .collect();

        self.personas
            .values()
            .filter(move |p| builtin_ids.contains(&p.id))
    }

    /// List user-defined personas
    pub fn user_defined(&self) -> impl Iterator<Item = &Persona> {
        let user_ids: Vec<_> = self
            .sources
            .iter()
            .filter(|(_, s)| **s == PersonaSource::User)
            .map(|(id, _)| id.clone())
            .collect();

        self.personas
            .values()
            .filter(move |p| user_ids.contains(&p.id))
    }

    /// List project-specific personas
    pub fn project_specific(&self) -> impl Iterator<Item = &Persona> {
        let project_ids: Vec<_> = self
            .sources
            .iter()
            .filter(|(_, s)| **s == PersonaSource::Project)
            .map(|(id, _)| id.clone())
            .collect();

        self.personas
            .values()
            .filter(move |p| project_ids.contains(&p.id))
    }

    /// Get the number of registered personas
    pub fn count(&self) -> usize {
        self.personas.len()
    }

    /// Check if a persona exists
    pub fn contains(&self, id: &PersonaId) -> bool {
        self.personas.contains_key(id)
    }

    /// Remove a persona (mainly for testing)
    pub fn remove(&mut self, id: &PersonaId) -> Option<Persona> {
        self.sources.remove(id);
        self.personas.remove(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty_registry() {
        let registry = PersonaRegistry::new();
        assert_eq!(registry.count(), 0);
    }

    #[test]
    fn test_with_builtins() {
        let registry = PersonaRegistry::with_builtins();
        assert!(registry.count() >= 3); // At least scout, archivist, steward
        assert!(registry.get_by_str("scout").is_some());
        assert!(registry.get_by_str("archivist").is_some());
        assert!(registry.get_by_str("steward").is_some());
    }

    #[test]
    fn test_source_priority() {
        assert!(PersonaSource::Project.priority() > PersonaSource::User.priority());
        assert!(PersonaSource::User.priority() > PersonaSource::Builtin.priority());
    }

    #[test]
    fn test_override_by_priority() {
        let mut registry = PersonaRegistry::new();

        // Register builtin
        let builtin = Persona::new("test", "Test", AgentType::Research, "Builtin version");
        registry.register(builtin, PersonaSource::Builtin);

        assert_eq!(
            registry.get_by_str("test").unwrap().role_description,
            "Builtin version"
        );

        // Override with user (higher priority)
        let user = Persona::new("test", "Test", AgentType::Research, "User version");
        registry.register(user, PersonaSource::User);

        assert_eq!(
            registry.get_by_str("test").unwrap().role_description,
            "User version"
        );

        // Try to override with builtin (lower priority) - should fail
        let builtin2 = Persona::new("test", "Test", AgentType::Research, "Another builtin");
        registry.register(builtin2, PersonaSource::Builtin);

        assert_eq!(
            registry.get_by_str("test").unwrap().role_description,
            "User version"
        );
    }

    #[test]
    fn test_by_archetype() {
        let registry = PersonaRegistry::with_builtins();

        let research: Vec<_> = registry.by_archetype(AgentType::Research).collect();
        assert!(!research.is_empty());
        assert!(research.iter().all(|p| p.archetype == AgentType::Research));
    }
}
