//! Core types for impart-core.

use serde::{Deserialize, Serialize};
use uuid::Uuid;
use chrono::{DateTime, Utc};

// MARK: - Address

/// Email address with optional display name.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Address {
    /// Display name (e.g., "John Doe").
    pub name: Option<String>,

    /// Email address (e.g., "john@example.com").
    pub email: String,
}

impl Address {
    /// Create a new address.
    pub fn new(email: impl Into<String>) -> Self {
        Self {
            name: None,
            email: email.into(),
        }
    }

    /// Create a new address with display name.
    pub fn with_name(name: impl Into<String>, email: impl Into<String>) -> Self {
        Self {
            name: Some(name.into()),
            email: email.into(),
        }
    }

    /// Format as RFC 5322 address.
    pub fn to_rfc5322(&self) -> String {
        match &self.name {
            Some(name) => format!("{} <{}>", name, self.email),
            None => self.email.clone(),
        }
    }
}

// MARK: - Envelope

/// Message envelope (headers without body).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope {
    /// Unique identifier for this message.
    pub uid: u32,

    /// Message-ID header.
    pub message_id: Option<String>,

    /// In-Reply-To header.
    pub in_reply_to: Option<String>,

    /// References header (list of message IDs).
    pub references: Vec<String>,

    /// Subject line.
    pub subject: Option<String>,

    /// From addresses.
    pub from: Vec<Address>,

    /// To addresses.
    pub to: Vec<Address>,

    /// CC addresses.
    pub cc: Vec<Address>,

    /// BCC addresses.
    pub bcc: Vec<Address>,

    /// Date header.
    pub date: Option<DateTime<Utc>>,

    /// IMAP flags (e.g., \Seen, \Flagged).
    pub flags: Vec<String>,
}

impl Envelope {
    /// Create a new empty envelope.
    pub fn new(uid: u32) -> Self {
        Self {
            uid,
            message_id: None,
            in_reply_to: None,
            references: Vec::new(),
            subject: None,
            from: Vec::new(),
            to: Vec::new(),
            cc: Vec::new(),
            bcc: Vec::new(),
            date: None,
            flags: Vec::new(),
        }
    }

    /// Check if the message has been read.
    pub fn is_read(&self) -> bool {
        self.flags.iter().any(|f| f.eq_ignore_ascii_case("\\Seen"))
    }

    /// Check if the message is flagged/starred.
    pub fn is_flagged(&self) -> bool {
        self.flags.iter().any(|f| f.eq_ignore_ascii_case("\\Flagged"))
    }

    /// Check if the message is a draft.
    pub fn is_draft(&self) -> bool {
        self.flags.iter().any(|f| f.eq_ignore_ascii_case("\\Draft"))
    }
}

// MARK: - Mailbox

/// IMAP mailbox (folder).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Mailbox {
    /// Full path (e.g., "INBOX", "[Gmail]/Sent Mail").
    pub name: String,

    /// Hierarchy delimiter (e.g., "/", ".").
    pub delimiter: String,

    /// IMAP flags (e.g., \Noselect, \HasChildren).
    pub flags: Vec<String>,

    /// Total message count.
    pub message_count: u32,

    /// Unseen message count.
    pub unseen_count: u32,
}

impl Mailbox {
    /// Create a new mailbox.
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            delimiter: "/".to_string(),
            flags: Vec::new(),
            message_count: 0,
            unseen_count: 0,
        }
    }

    /// Check if this mailbox can be selected.
    pub fn is_selectable(&self) -> bool {
        !self.flags.iter().any(|f| f.eq_ignore_ascii_case("\\Noselect"))
    }

    /// Get the short name (last component).
    pub fn short_name(&self) -> &str {
        self.name
            .rsplit(&self.delimiter)
            .next()
            .unwrap_or(&self.name)
    }
}

// MARK: - Thread

/// Conversation thread (JWZ algorithm output).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Thread {
    /// Root message ID.
    pub root_message_id: String,

    /// All message IDs in thread order.
    pub message_ids: Vec<String>,

    /// Thread subject (from root message).
    pub subject: Option<String>,
}

impl Thread {
    /// Create a new thread with a single message.
    pub fn new(root_message_id: impl Into<String>) -> Self {
        let root = root_message_id.into();
        Self {
            root_message_id: root.clone(),
            message_ids: vec![root],
            subject: None,
        }
    }

    /// Number of messages in thread.
    pub fn len(&self) -> usize {
        self.message_ids.len()
    }

    /// Check if thread is empty.
    pub fn is_empty(&self) -> bool {
        self.message_ids.is_empty()
    }
}

// MARK: - Account Configuration

/// Email account configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountConfig {
    /// Unique account ID.
    pub id: Uuid,

    /// Email address.
    pub email: String,

    /// Display name.
    pub display_name: String,

    /// IMAP server hostname.
    pub imap_host: String,

    /// IMAP server port.
    pub imap_port: u16,

    /// SMTP server hostname.
    pub smtp_host: String,

    /// SMTP server port.
    pub smtp_port: u16,

    /// Use TLS for IMAP.
    pub imap_tls: bool,

    /// Use STARTTLS for SMTP.
    pub smtp_starttls: bool,
}

impl AccountConfig {
    /// Create a new account configuration.
    pub fn new(email: impl Into<String>) -> Self {
        let email = email.into();
        Self {
            id: Uuid::new_v4(),
            email: email.clone(),
            display_name: email,
            imap_host: String::new(),
            imap_port: 993,
            smtp_host: String::new(),
            smtp_port: 587,
            imap_tls: true,
            smtp_starttls: true,
        }
    }

    /// Create Gmail configuration.
    pub fn gmail(email: impl Into<String>) -> Self {
        let email = email.into();
        Self {
            id: Uuid::new_v4(),
            email: email.clone(),
            display_name: email,
            imap_host: "imap.gmail.com".to_string(),
            imap_port: 993,
            smtp_host: "smtp.gmail.com".to_string(),
            smtp_port: 587,
            imap_tls: true,
            smtp_starttls: true,
        }
    }
}
