//! Error types for impel-core

use thiserror::Error;

/// Result type alias for impel operations
pub type Result<T> = std::result::Result<T, ImpelError>;

/// Main error type for impel operations
#[derive(Error, Debug)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Error), uniffi(flat_error))]
pub enum ImpelError {
    /// Thread-related errors
    #[error("Thread error: {0}")]
    Thread(#[from] ThreadError),

    /// Agent-related errors
    #[error("Agent error: {0}")]
    Agent(#[from] AgentError),

    /// Event-related errors
    #[error("Event error: {0}")]
    Event(#[from] EventError),

    /// Message-related errors
    #[error("Message error: {0}")]
    Message(#[from] MessageError),

    /// Persistence-related errors
    #[error("Persistence error: {0}")]
    Persistence(#[from] PersistenceError),

    /// Escalation-related errors
    #[error("Escalation error: {0}")]
    Escalation(#[from] EscalationError),

    /// Integration-related errors
    #[error("Integration error: {0}")]
    Integration(#[from] IntegrationError),

    /// Invalid operation
    #[error("Invalid operation: {0}")]
    InvalidOperation(String),

    /// Not found
    #[error("Not found: {0}")]
    NotFound(String),
}

/// Thread-specific errors
#[derive(Error, Debug)]
pub enum ThreadError {
    /// Invalid state transition
    #[error("Invalid state transition from {from:?} to {to:?}")]
    InvalidStateTransition { from: String, to: String },

    /// Thread not found
    #[error("Thread not found: {0}")]
    NotFound(String),

    /// Thread already claimed
    #[error("Thread {0} already claimed by agent {1}")]
    AlreadyClaimed(String, String),

    /// Thread not claimable (wrong state)
    #[error("Thread {0} is not claimable in state {1}")]
    NotClaimable(String, String),

    /// Constitution violation
    #[error("Constitution violation: {0}")]
    ConstitutionViolation(String),
}

/// Agent-specific errors
#[derive(Error, Debug)]
pub enum AgentError {
    /// Agent not found
    #[error("Agent not found: {0}")]
    NotFound(String),

    /// Agent already registered
    #[error("Agent already registered: {0}")]
    AlreadyRegistered(String),

    /// Agent not authorized
    #[error("Agent {0} not authorized for operation: {1}")]
    NotAuthorized(String, String),

    /// Agent busy
    #[error("Agent {0} is busy with thread {1}")]
    Busy(String, String),
}

/// Event-specific errors
#[derive(Error, Debug)]
pub enum EventError {
    /// Event not found
    #[error("Event not found: {0}")]
    NotFound(String),

    /// Invalid event sequence
    #[error("Invalid event sequence: expected {expected}, got {actual}")]
    InvalidSequence { expected: u64, actual: u64 },

    /// Event already processed
    #[error("Event already processed: {0}")]
    AlreadyProcessed(String),

    /// Projection error
    #[error("Projection error: {0}")]
    ProjectionError(String),
}

/// Message-specific errors
#[derive(Error, Debug)]
pub enum MessageError {
    /// Message not found
    #[error("Message not found: {0}")]
    NotFound(String),

    /// Invalid message format
    #[error("Invalid message format: {0}")]
    InvalidFormat(String),

    /// Message parse error
    #[error("Message parse error: {0}")]
    ParseError(String),

    /// Missing required header
    #[error("Missing required header: {0}")]
    MissingHeader(String),

    /// Invalid recipient
    #[error("Invalid recipient: {0}")]
    InvalidRecipient(String),
}

/// Persistence-specific errors
#[derive(Error, Debug)]
pub enum PersistenceError {
    /// Database error
    #[error("Database error: {0}")]
    Database(String),

    /// Migration error
    #[error("Migration error: {0}")]
    Migration(String),

    /// Serialization error
    #[error("Serialization error: {0}")]
    Serialization(String),

    /// IO error
    #[error("IO error: {0}")]
    Io(String),

    /// Schema version mismatch
    #[error("Schema version mismatch: expected {expected}, got {actual}")]
    SchemaVersionMismatch { expected: u32, actual: u32 },
}

/// Escalation-specific errors
#[derive(Error, Debug)]
pub enum EscalationError {
    /// Escalation not found
    #[error("Escalation not found: {0}")]
    NotFound(String),

    /// Escalation already resolved
    #[error("Escalation already resolved: {0}")]
    AlreadyResolved(String),

    /// Invalid resolution
    #[error("Invalid resolution for escalation {0}: {1}")]
    InvalidResolution(String, String),
}

/// Integration-specific errors
#[derive(Error, Debug)]
pub enum IntegrationError {
    /// Imbib integration error
    #[error("Imbib error: {0}")]
    Imbib(String),

    /// Imprint integration error
    #[error("Imprint error: {0}")]
    Imprint(String),

    /// Implore integration error
    #[error("Implore error: {0}")]
    Implore(String),

    /// Integration not available
    #[error("Integration not available: {0}")]
    NotAvailable(String),
}

#[cfg(feature = "sqlite")]
impl From<rusqlite::Error> for PersistenceError {
    fn from(err: rusqlite::Error) -> Self {
        PersistenceError::Database(err.to_string())
    }
}

impl From<std::io::Error> for PersistenceError {
    fn from(err: std::io::Error) -> Self {
        PersistenceError::Io(err.to_string())
    }
}

impl From<serde_json::Error> for PersistenceError {
    fn from(err: serde_json::Error) -> Self {
        PersistenceError::Serialization(err.to_string())
    }
}

#[cfg(feature = "sqlite")]
impl From<rusqlite::Error> for ImpelError {
    fn from(err: rusqlite::Error) -> Self {
        ImpelError::Persistence(PersistenceError::Database(err.to_string()))
    }
}

impl From<serde_json::Error> for ImpelError {
    fn from(err: serde_json::Error) -> Self {
        ImpelError::Persistence(PersistenceError::Serialization(err.to_string()))
    }
}
