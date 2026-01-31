//! FFI bindings for Swift/Kotlin via UniFFI.
//!
//! This module provides the bridge between Rust types and the UniFFI-generated bindings.
//! The UDL file defines the interface; this module provides the implementations.

use crate::{threading, ImpartError, Result};
use std::sync::Mutex;

// MARK: - FFI Function Implementations

/// Thread messages using JWZ algorithm (matches UDL function signature).
/// Takes FFI envelopes, threads them, returns FFI threads.
pub fn thread_messages(envelopes: Vec<crate::ffi_types::Envelope>) -> Vec<crate::ffi_types::Thread> {
    let internal_envelopes: Vec<crate::types::Envelope> =
        envelopes.into_iter().map(Into::into).collect();
    let threads = threading::thread_messages(&internal_envelopes);
    threads.into_iter().map(Into::into).collect()
}

/// Parse a raw MIME message (matches UDL function signature).
pub fn parse_message(raw: Vec<u8>) -> Result<crate::ffi_types::ParsedMessage> {
    let parsed = crate::mime::parse_message(&raw)?;
    Ok(parsed.into())
}

// MARK: - IMAP Client

/// Thread-safe IMAP client wrapper for FFI.
pub struct FfiImapClient {
    inner: Mutex<crate::imap::ImapClient>,
}

impl FfiImapClient {
    pub fn new(config: crate::ffi_types::AccountConfig, password: String) -> Result<Self> {
        let internal_config = config.to_internal();
        let client = crate::imap::ImapClient::new(&internal_config, &password)?;
        Ok(Self {
            inner: Mutex::new(client),
        })
    }

    pub fn list_mailboxes(&self) -> Result<Vec<crate::ffi_types::Mailbox>> {
        let mut guard = self.inner.lock().map_err(|_| ImpartError::Imap("Lock poisoned".to_string()))?;
        let mailboxes = guard.list_mailboxes()?;
        Ok(mailboxes.into_iter().map(Into::into).collect())
    }

    pub fn fetch_envelopes(&self, mailbox_name: String, start: u32, count: u32) -> Result<Vec<crate::ffi_types::Envelope>> {
        let mut guard = self.inner.lock().map_err(|_| ImpartError::Imap("Lock poisoned".to_string()))?;
        let envelopes = guard.fetch_envelopes(&mailbox_name, start, count)?;
        Ok(envelopes.into_iter().map(Into::into).collect())
    }

    pub fn fetch_message(&self, mailbox_name: String, uid: u32) -> Result<crate::ffi_types::ParsedMessage> {
        let mut guard = self.inner.lock().map_err(|_| ImpartError::Imap("Lock poisoned".to_string()))?;
        let parsed = guard.fetch_message(&mailbox_name, uid)?;
        Ok(parsed.into())
    }

    pub fn set_flags(&self, mailbox_name: String, uids: Vec<u32>, flags: Vec<String>, add: bool) -> Result<()> {
        let mut guard = self.inner.lock().map_err(|_| ImpartError::Imap("Lock poisoned".to_string()))?;
        guard.set_flags(&mailbox_name, &uids, &flags, add)
    }

    pub fn move_messages(&self, from_mailbox: String, to_mailbox: String, uids: Vec<u32>) -> Result<()> {
        let mut guard = self.inner.lock().map_err(|_| ImpartError::Imap("Lock poisoned".to_string()))?;
        guard.move_messages(&from_mailbox, &to_mailbox, &uids)
    }

    pub fn disconnect(&self) {
        if let Ok(mut guard) = self.inner.lock() {
            guard.disconnect();
        }
    }
}

// MARK: - SMTP Client

/// Thread-safe SMTP client wrapper for FFI.
pub struct FfiSmtpClient {
    inner: crate::smtp::SmtpClient,
}

impl FfiSmtpClient {
    pub fn new(config: crate::ffi_types::AccountConfig, password: String) -> Result<Self> {
        let internal_config = config.to_internal();
        let client = crate::smtp::SmtpClient::new(&internal_config, &password)?;
        Ok(Self { inner: client })
    }

    pub fn send(&self, draft: crate::ffi_types::DraftMessage) -> Result<()> {
        let internal_draft = crate::smtp::DraftMessage {
            from_email: draft.from_email,
            to_emails: draft.to_emails,
            cc_emails: draft.cc_emails,
            subject: draft.subject,
            text_body: draft.text_body,
            html_body: draft.html_body,
        };
        self.inner.send(&internal_draft)
    }

    pub fn disconnect(&self) {
        self.inner.disconnect();
    }
}
