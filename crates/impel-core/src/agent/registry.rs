//! Agent registry for tracking registered agents

use std::collections::HashMap;

use super::{Agent, AgentStatus, AgentType};
use crate::error::{AgentError, Result};
use crate::thread::ThreadId;

/// Registry for managing agents
#[derive(Debug, Default)]
pub struct AgentRegistry {
    agents: HashMap<String, Agent>,
    type_counters: HashMap<AgentType, u32>,
}

impl AgentRegistry {
    /// Create a new empty registry
    pub fn new() -> Self {
        Self {
            agents: HashMap::new(),
            type_counters: HashMap::new(),
        }
    }

    /// Register a new agent
    pub fn register(&mut self, agent: Agent) -> Result<()> {
        if self.agents.contains_key(&agent.id) {
            return Err(AgentError::AlreadyRegistered(agent.id.clone()).into());
        }

        // Update type counter
        let count = self.type_counters.entry(agent.agent_type).or_insert(0);
        *count = (*count).max(
            agent
                .id
                .split('-')
                .last()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0),
        );

        self.agents.insert(agent.id.clone(), agent);
        Ok(())
    }

    /// Create and register a new agent of the given type
    pub fn create_agent(&mut self, agent_type: AgentType) -> Result<&Agent> {
        let counter = self.type_counters.entry(agent_type).or_insert(0);
        *counter += 1;
        let agent = Agent::new_with_type(agent_type, *counter);
        let id = agent.id.clone();
        self.register(agent)?;
        Ok(self.agents.get(&id).unwrap())
    }

    /// Get an agent by ID
    pub fn get(&self, id: &str) -> Option<&Agent> {
        self.agents.get(id)
    }

    /// Get a mutable reference to an agent by ID
    pub fn get_mut(&mut self, id: &str) -> Option<&mut Agent> {
        self.agents.get_mut(id)
    }

    /// Remove an agent from the registry
    pub fn unregister(&mut self, id: &str) -> Option<Agent> {
        self.agents.remove(id)
    }

    /// Get all agents
    pub fn all(&self) -> impl Iterator<Item = &Agent> {
        self.agents.values()
    }

    /// Get all agents of a specific type
    pub fn by_type(&self, agent_type: AgentType) -> impl Iterator<Item = &Agent> {
        self.agents
            .values()
            .filter(move |a| a.agent_type == agent_type)
    }

    /// Get all idle agents
    pub fn idle(&self) -> impl Iterator<Item = &Agent> {
        self.agents
            .values()
            .filter(|a| a.status == AgentStatus::Idle)
    }

    /// Get all working agents
    pub fn working(&self) -> impl Iterator<Item = &Agent> {
        self.agents
            .values()
            .filter(|a| a.status == AgentStatus::Working)
    }

    /// Get all active agents (not terminated)
    pub fn active(&self) -> impl Iterator<Item = &Agent> {
        self.agents.values().filter(|a| a.status.is_active())
    }

    /// Find an idle agent of the given type
    pub fn find_idle(&self, agent_type: AgentType) -> Option<&Agent> {
        self.agents
            .values()
            .find(|a| a.agent_type == agent_type && a.status == AgentStatus::Idle)
    }

    /// Find the agent working on a specific thread
    pub fn find_by_thread(&self, thread_id: &ThreadId) -> Option<&Agent> {
        self.agents
            .values()
            .find(|a| a.current_thread.as_ref() == Some(thread_id))
    }

    /// Get the number of registered agents
    pub fn count(&self) -> usize {
        self.agents.len()
    }

    /// Get the number of agents by status
    pub fn count_by_status(&self, status: AgentStatus) -> usize {
        self.agents.values().filter(|a| a.status == status).count()
    }

    /// Get the number of agents by type
    pub fn count_by_type(&self, agent_type: AgentType) -> usize {
        self.agents
            .values()
            .filter(|a| a.agent_type == agent_type)
            .count()
    }

    /// Authenticate an agent by token
    pub fn authenticate(&self, token: &str) -> Option<&Agent> {
        self.agents
            .values()
            .find(|a| a.auth_token.as_deref() == Some(token))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_register_agent() {
        let mut registry = AgentRegistry::new();
        let agent = Agent::new("test-1".to_string(), AgentType::Research);
        assert!(registry.register(agent).is_ok());
        assert!(registry.get("test-1").is_some());
    }

    #[test]
    fn test_duplicate_registration() {
        let mut registry = AgentRegistry::new();
        let agent1 = Agent::new("test-1".to_string(), AgentType::Research);
        let agent2 = Agent::new("test-1".to_string(), AgentType::Code);
        assert!(registry.register(agent1).is_ok());
        assert!(registry.register(agent2).is_err());
    }

    #[test]
    fn test_create_agent() {
        let mut registry = AgentRegistry::new();
        let agent1 = registry.create_agent(AgentType::Research).unwrap();
        assert_eq!(agent1.id, "research-1");
        let agent2 = registry.create_agent(AgentType::Research).unwrap();
        assert_eq!(agent2.id, "research-2");
    }

    #[test]
    fn test_find_idle() {
        let mut registry = AgentRegistry::new();
        registry.create_agent(AgentType::Research).unwrap();

        let idle = registry.find_idle(AgentType::Research);
        assert!(idle.is_some());

        // Mark as working
        registry
            .get_mut("research-1")
            .unwrap()
            .assign_thread(ThreadId::new());
        let idle = registry.find_idle(AgentType::Research);
        assert!(idle.is_none());
    }

    #[test]
    fn test_count_by_status() {
        let mut registry = AgentRegistry::new();
        registry.create_agent(AgentType::Research).unwrap();
        registry.create_agent(AgentType::Code).unwrap();

        assert_eq!(registry.count_by_status(AgentStatus::Idle), 2);
        assert_eq!(registry.count_by_status(AgentStatus::Working), 0);
    }
}
