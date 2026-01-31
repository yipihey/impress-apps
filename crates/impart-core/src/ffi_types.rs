//! FFI-compatible types for UniFFI bindings.
//!
//! These types match the UDL schema and provide conversion to/from internal types.

use crate::types;
use crate::mime;

// MARK: - Address

/// Email address with optional display name (FFI-compatible).
#[derive(Debug, Clone)]
pub struct Address {
    pub name: Option<String>,
    pub email: String,
}

impl From<types::Address> for Address {
    fn from(addr: types::Address) -> Self {
        Self {
            name: addr.name,
            email: addr.email,
        }
    }
}

impl From<Address> for types::Address {
    fn from(addr: Address) -> Self {
        Self {
            name: addr.name,
            email: addr.email,
        }
    }
}

// MARK: - Envelope

/// Message envelope (FFI-compatible).
#[derive(Debug, Clone)]
pub struct Envelope {
    pub uid: u32,
    pub message_id: Option<String>,
    pub in_reply_to: Option<String>,
    pub references: Vec<String>,
    pub subject: Option<String>,
    pub from_addresses: Vec<Address>,
    pub to_addresses: Vec<Address>,
    pub cc_addresses: Vec<Address>,
    pub bcc_addresses: Vec<Address>,
    pub date_timestamp: Option<i64>,
    pub flags: Vec<String>,
}

impl From<types::Envelope> for Envelope {
    fn from(env: types::Envelope) -> Self {
        Self {
            uid: env.uid,
            message_id: env.message_id,
            in_reply_to: env.in_reply_to,
            references: env.references,
            subject: env.subject,
            from_addresses: env.from.into_iter().map(Into::into).collect(),
            to_addresses: env.to.into_iter().map(Into::into).collect(),
            cc_addresses: env.cc.into_iter().map(Into::into).collect(),
            bcc_addresses: env.bcc.into_iter().map(Into::into).collect(),
            date_timestamp: env.date.map(|d| d.timestamp()),
            flags: env.flags,
        }
    }
}

impl From<Envelope> for types::Envelope {
    fn from(env: Envelope) -> Self {
        Self {
            uid: env.uid,
            message_id: env.message_id,
            in_reply_to: env.in_reply_to,
            references: env.references,
            subject: env.subject,
            from: env.from_addresses.into_iter().map(Into::into).collect(),
            to: env.to_addresses.into_iter().map(Into::into).collect(),
            cc: env.cc_addresses.into_iter().map(Into::into).collect(),
            bcc: env.bcc_addresses.into_iter().map(Into::into).collect(),
            date: env.date_timestamp.and_then(|ts| chrono::DateTime::from_timestamp(ts, 0)),
            flags: env.flags,
        }
    }
}

// MARK: - Thread

/// Thread (FFI-compatible).
#[derive(Debug, Clone)]
pub struct Thread {
    pub root_message_id: String,
    pub message_ids: Vec<String>,
    pub subject: Option<String>,
}

impl From<types::Thread> for Thread {
    fn from(t: types::Thread) -> Self {
        Self {
            root_message_id: t.root_message_id,
            message_ids: t.message_ids,
            subject: t.subject,
        }
    }
}

// MARK: - Mailbox

/// Mailbox (FFI-compatible).
#[derive(Debug, Clone)]
pub struct Mailbox {
    pub name: String,
    pub delimiter: String,
    pub flags: Vec<String>,
    pub message_count: u32,
    pub unseen_count: u32,
}

impl From<types::Mailbox> for Mailbox {
    fn from(m: types::Mailbox) -> Self {
        Self {
            name: m.name,
            delimiter: m.delimiter,
            flags: m.flags,
            message_count: m.message_count,
            unseen_count: m.unseen_count,
        }
    }
}

// MARK: - AccountConfig

/// Account configuration (FFI-compatible).
#[derive(Debug, Clone)]
pub struct AccountConfig {
    pub id: String,
    pub email: String,
    pub display_name: String,
    pub imap_host: String,
    pub imap_port: u16,
    pub smtp_host: String,
    pub smtp_port: u16,
    pub imap_tls: bool,
    pub smtp_starttls: bool,
}

impl AccountConfig {
    /// Convert to internal config type.
    pub fn to_internal(&self) -> types::AccountConfig {
        types::AccountConfig {
            id: uuid::Uuid::parse_str(&self.id).unwrap_or_else(|_| uuid::Uuid::new_v4()),
            email: self.email.clone(),
            display_name: self.display_name.clone(),
            imap_host: self.imap_host.clone(),
            imap_port: self.imap_port,
            smtp_host: self.smtp_host.clone(),
            smtp_port: self.smtp_port,
            imap_tls: self.imap_tls,
            smtp_starttls: self.smtp_starttls,
        }
    }
}

// MARK: - Attachment

/// Attachment (FFI-compatible).
#[derive(Debug, Clone)]
pub struct Attachment {
    pub filename: String,
    pub mime_type: String,
    pub size: u64,
    pub content_id: Option<String>,
    pub data: Vec<u8>,
}

impl From<mime::Attachment> for Attachment {
    fn from(a: mime::Attachment) -> Self {
        Self {
            filename: a.filename,
            mime_type: a.mime_type,
            size: a.size as u64,
            content_id: a.content_id,
            data: a.data,
        }
    }
}

// MARK: - ParsedMessage

/// Parsed message (FFI-compatible).
#[derive(Debug, Clone)]
pub struct ParsedMessage {
    pub envelope: Envelope,
    pub text_body: Option<String>,
    pub html_body: Option<String>,
    pub attachments: Vec<Attachment>,
}

impl From<mime::ParsedMessage> for ParsedMessage {
    fn from(m: mime::ParsedMessage) -> Self {
        Self {
            envelope: m.envelope.into(),
            text_body: m.text_body,
            html_body: m.html_body,
            attachments: m.attachments.into_iter().map(Into::into).collect(),
        }
    }
}

// MARK: - DraftMessage

/// Draft message for sending (FFI-compatible).
#[derive(Debug, Clone)]
pub struct DraftMessage {
    pub from_email: String,
    pub to_emails: Vec<String>,
    pub cc_emails: Vec<String>,
    pub subject: String,
    pub text_body: String,
    pub html_body: Option<String>,
}
