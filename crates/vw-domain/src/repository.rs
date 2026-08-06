use crate::{DiagnosticSession, KnowledgePack, SessionId};

pub trait DiagnosticRepository: Send + Sync {
    fn create_session(&self, session: &DiagnosticSession) -> Result<(), RepositoryError>;
    fn get_session(&self, id: &SessionId) -> Result<Option<DiagnosticSession>, RepositoryError>;
    fn save_session(
        &self,
        session: &DiagnosticSession,
        expected_revision: u64,
    ) -> Result<(), RepositoryError>;
    fn list_sessions(&self, limit: usize) -> Result<Vec<DiagnosticSession>, RepositoryError>;
    fn active_knowledge_pack(&self) -> Result<KnowledgePack, RepositoryError>;
}

#[derive(Debug, thiserror::Error)]
pub enum RepositoryError {
    #[error("session not found: {0}")]
    NotFound(String),
    #[error("stale session revision: expected {expected}, actual {actual}")]
    StaleRevision { expected: u64, actual: u64 },
    #[error("repository serialization failed: {0}")]
    Serialization(String),
    #[error("repository storage failed: {0}")]
    Storage(String),
}
