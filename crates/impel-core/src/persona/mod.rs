//! Persona system for agent behavioral configuration
//!
//! Personas provide rich behavioral configuration for agents, superseding
//! the simpler AgentType with:
//! - Role descriptions and behavioral traits
//! - Model configuration (provider, temperature, token limits)
//! - Tool access policies (which tools, read/write permissions)
//! - Domain-specific prompting
//!
//! Personas can be:
//! - Builtin (compiled into impel-core)
//! - User-defined (~/.impel/personas/{name}/identity.toml)
//! - Project-specific (.impel/personas/{name}/identity.toml)
//!
//! Resolution order: project > user > builtin

mod builtin;
mod persona;
mod registry;
mod toml_loader;

pub use builtin::builtin_personas;
pub use persona::{
    Persona, PersonaBehavior, PersonaDomain, PersonaId, PersonaModelConfig, ToolAccess, ToolPolicy,
    ToolPolicySet, WorkingStyle,
};
pub use registry::PersonaRegistry;
pub use toml_loader::{load_persona_from_toml, PersonaLoadError};
