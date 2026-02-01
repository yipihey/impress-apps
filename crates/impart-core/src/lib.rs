//! impart-core: Cross-platform email/messaging library
//!
//! This crate provides the core functionality for the impart communication tool,
//! including IMAP/SMTP protocols, MIME parsing, message threading, and provenance tracking.
//!
//! # Architecture
//!
//! ```text
//! ┌─────────────────────────────────────────────────────────────┐
//! │                        impart-core                          │
//! ├─────────────────────────────────────────────────────────────┤
//! │  imap          │ IMAP client for fetching messages          │
//! │  smtp          │ SMTP client for sending messages           │
//! │  mime          │ MIME parsing and encoding                  │
//! │  threading     │ JWZ algorithm for conversation threading   │
//! │  provenance    │ Event sourcing for research conversations  │
//! │  search        │ Full-text search over messages             │
//! │  ffi           │ UniFFI bindings for Swift/Kotlin           │
//! └─────────────────────────────────────────────────────────────┘
//! ```
//!
//! # Features
//!
//! - `native`: Enable IMAP/SMTP clients and UniFFI bindings (default off)
//!
//! # Example
//!
//! ```rust,ignore
//! use impart_core::mime::parse_message;
//!
//! let raw = b"From: sender@example.com\r\nTo: recipient@example.com\r\nSubject: Hello\r\n\r\nHello, World!";
//! let message = parse_message(raw)?;
//! println!("Subject: {}", message.subject.unwrap_or_default());
//! ```

use thiserror::Error;

// Modules - types contains internal types, not re-exported to avoid collision with FFI types
pub mod types;
pub mod mime;
pub mod threading;
pub mod mbox;

// Provenance event sourcing for research conversations
pub mod provenance;

// Re-export core types for convenience
pub use types::Address;

#[cfg(feature = "native")]
mod imap;

#[cfg(feature = "native")]
mod smtp;

#[cfg(feature = "native")]
mod ffi;

#[cfg(feature = "native")]
pub mod ffi_types;

// Re-export all FFI types at crate root for UniFFI scaffolding
#[cfg(feature = "native")]
pub use ffi_types::*;

// Re-export FFI functions and clients
#[cfg(feature = "native")]
pub use ffi::{thread_messages, parse_message, FfiImapClient, FfiSmtpClient};

// UniFFI scaffolding
#[cfg(feature = "native")]
uniffi::include_scaffolding!("uniffi");

// MARK: - Errors

/// Errors from impart-core operations.
#[derive(Error, Debug)]
pub enum ImpartError {
    /// IMAP connection or protocol error.
    #[error("IMAP error: {0}")]
    Imap(String),

    /// SMTP connection or protocol error.
    #[error("SMTP error: {0}")]
    Smtp(String),

    /// MIME parsing error.
    #[error("MIME parsing error: {0}")]
    Mime(String),

    /// Authentication failed.
    #[error("Authentication failed: {0}")]
    Auth(String),

    /// Network error.
    #[error("Network error: {0}")]
    Network(String),

    /// I/O error.
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
}

/// Result type for impart operations.
pub type Result<T> = std::result::Result<T, ImpartError>;

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_display() {
        let err = ImpartError::Imap("connection refused".to_string());
        assert!(err.to_string().contains("IMAP"));
    }
}
