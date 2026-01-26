//! Agent management for research agents
//!
//! Agents are the workers in the impel system. They claim threads,
//! perform work, and produce artifacts.

mod agent;
mod registry;
mod types;

pub use agent::{Agent, AgentStatus};
pub use registry::AgentRegistry;
pub use types::AgentType;
