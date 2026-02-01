//! Mbox file format support for conversation storage.
//!
//! Implements RFC 4155 compliant mbox format for storing research conversations.
//! Each conversation is stored as a separate mbox file containing all messages
//! in the conversation thread.
//!
//! # Format
//!
//! Each message is delimited by a "From " line:
//! ```text
//! From sender@example.com Sat Jan 31 12:00:00 2026
//! From: sender@example.com
//! To: recipient@example.com
//! Subject: Message subject
//! Date: Sat, 31 Jan 2026 12:00:00 +0000
//! Message-ID: <unique-id@impart>
//! Content-Type: text/plain; charset=utf-8
//!
//! Message body here...
//!
//! ```

use crate::{Address, ImpartError, Result};
use chrono::{DateTime, Utc};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use uuid::Uuid;

// MARK: - Mbox Message

/// A single message in mbox format.
#[derive(Debug, Clone)]
pub struct MboxMessage {
    /// Unique message ID.
    pub id: Uuid,
    /// Message-ID header value.
    pub message_id: String,
    /// In-Reply-To header (for threading).
    pub in_reply_to: Option<String>,
    /// References header (for threading).
    pub references: Vec<String>,
    /// From address.
    pub from: Address,
    /// To addresses.
    pub to: Vec<Address>,
    /// CC addresses.
    pub cc: Vec<Address>,
    /// Subject line.
    pub subject: String,
    /// Message date.
    pub date: DateTime<Utc>,
    /// Plain text body.
    pub text_body: String,
    /// HTML body (optional).
    pub html_body: Option<String>,
    /// Custom headers for impart-specific data.
    pub custom_headers: Vec<(String, String)>,
}

impl MboxMessage {
    /// Create a new message with generated ID.
    pub fn new(from: Address, to: Vec<Address>, subject: String, body: String) -> Self {
        let id = Uuid::new_v4();
        let message_id = format!("<{}@impart.local>", id);

        Self {
            id,
            message_id,
            in_reply_to: None,
            references: Vec::new(),
            from,
            to,
            cc: Vec::new(),
            subject,
            date: Utc::now(),
            text_body: body,
            html_body: None,
            custom_headers: Vec::new(),
        }
    }

    /// Create a reply to another message.
    pub fn reply_to(parent: &MboxMessage, from: Address, body: String) -> Self {
        let id = Uuid::new_v4();
        let message_id = format!("<{}@impart.local>", id);

        // Build references chain
        let mut references = parent.references.clone();
        references.push(parent.message_id.clone());

        Self {
            id,
            message_id,
            in_reply_to: Some(parent.message_id.clone()),
            references,
            from,
            to: vec![parent.from.clone()],
            cc: Vec::new(),
            subject: format!("Re: {}", parent.subject.trim_start_matches("Re: ")),
            date: Utc::now(),
            text_body: body,
            html_body: None,
            custom_headers: Vec::new(),
        }
    }

    /// Add a custom header (X-Impart-*).
    pub fn add_header(&mut self, name: &str, value: &str) {
        self.custom_headers.push((name.to_string(), value.to_string()));
    }

    /// Format as mbox entry.
    pub fn to_mbox_string(&self) -> String {
        let mut output = String::new();

        // From_ line (envelope)
        let from_line = format!(
            "From {} {}\n",
            self.from.email,
            self.date.format("%a %b %d %H:%M:%S %Y")
        );
        output.push_str(&from_line);

        // Standard headers
        output.push_str(&format!("From: {}\n", self.from.to_rfc5322()));
        output.push_str(&format!(
            "To: {}\n",
            self.to.iter().map(|a| a.to_rfc5322()).collect::<Vec<_>>().join(", ")
        ));

        if !self.cc.is_empty() {
            output.push_str(&format!(
                "Cc: {}\n",
                self.cc.iter().map(|a| a.to_rfc5322()).collect::<Vec<_>>().join(", ")
            ));
        }

        output.push_str(&format!("Subject: {}\n", self.subject));
        output.push_str(&format!(
            "Date: {}\n",
            self.date.format("%a, %d %b %Y %H:%M:%S %z")
        ));
        output.push_str(&format!("Message-ID: {}\n", self.message_id));

        if let Some(ref reply_to) = self.in_reply_to {
            output.push_str(&format!("In-Reply-To: {}\n", reply_to));
        }

        if !self.references.is_empty() {
            output.push_str(&format!("References: {}\n", self.references.join(" ")));
        }

        // Custom headers
        for (name, value) in &self.custom_headers {
            output.push_str(&format!("{}: {}\n", name, value));
        }

        // Content-Type
        output.push_str("Content-Type: text/plain; charset=utf-8\n");
        output.push_str("MIME-Version: 1.0\n");

        // Blank line before body
        output.push('\n');

        // Body with From_ escaping (MBOXRD style)
        for line in self.text_body.lines() {
            if line.starts_with("From ") || line.starts_with(">From ") {
                output.push('>');
            }
            output.push_str(line);
            output.push('\n');
        }

        // Ensure trailing newline
        if !output.ends_with("\n\n") {
            output.push('\n');
        }

        output
    }
}

// MARK: - Mbox File

/// An mbox file containing multiple messages.
#[derive(Debug, Default)]
pub struct MboxFile {
    /// Messages in the mbox.
    pub messages: Vec<MboxMessage>,
}

impl MboxFile {
    /// Create a new empty mbox.
    pub fn new() -> Self {
        Self { messages: Vec::new() }
    }

    /// Add a message to the mbox.
    pub fn add_message(&mut self, message: MboxMessage) {
        self.messages.push(message);
    }

    /// Write mbox to a file.
    pub fn write_to_file(&self, path: &Path) -> Result<()> {
        let mut file = std::fs::File::create(path)
            .map_err(|e| ImpartError::Io(e))?;

        for message in &self.messages {
            file.write_all(message.to_mbox_string().as_bytes())
                .map_err(|e| ImpartError::Io(e))?;
        }

        Ok(())
    }

    /// Read mbox from a file.
    pub fn read_from_file(path: &Path) -> Result<Self> {
        let file = std::fs::File::open(path)
            .map_err(|e| ImpartError::Io(e))?;
        let reader = BufReader::new(file);

        let mut mbox = MboxFile::new();
        let mut current_message: Option<String> = None;

        for line in reader.lines() {
            let line = line.map_err(|e| ImpartError::Io(e))?;

            if line.starts_with("From ") && !line.starts_with("From:") {
                // Start of new message
                if let Some(msg_text) = current_message.take() {
                    if let Ok(msg) = parse_mbox_message(&msg_text) {
                        mbox.add_message(msg);
                    }
                }
                current_message = Some(String::new());
            }

            if let Some(ref mut msg) = current_message {
                msg.push_str(&line);
                msg.push('\n');
            }
        }

        // Handle last message
        if let Some(msg_text) = current_message {
            if let Ok(msg) = parse_mbox_message(&msg_text) {
                mbox.add_message(msg);
            }
        }

        Ok(mbox)
    }

    /// Append a message to an existing mbox file.
    pub fn append_message(path: &Path, message: &MboxMessage) -> Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|e| ImpartError::Io(e))?;

        file.write_all(message.to_mbox_string().as_bytes())
            .map_err(|e| ImpartError::Io(e))?;

        Ok(())
    }
}

// MARK: - Parsing

/// Parse a single mbox message from text.
fn parse_mbox_message(text: &str) -> Result<MboxMessage> {
    let raw = text.as_bytes();
    let parsed = crate::mime::parse_message(raw)?;

    let from = parsed.envelope.from.first()
        .cloned()
        .unwrap_or_else(|| Address::new("unknown@unknown"));

    let to = parsed.envelope.to.clone();
    let cc = parsed.envelope.cc.clone();

    let id = Uuid::new_v4(); // Generate new ID for parsed messages

    Ok(MboxMessage {
        id,
        message_id: parsed.envelope.message_id.unwrap_or_else(|| format!("<{}@parsed>", id)),
        in_reply_to: parsed.envelope.in_reply_to,
        references: parsed.envelope.references,
        from,
        to,
        cc,
        subject: parsed.envelope.subject.unwrap_or_default(),
        date: parsed.envelope.date.unwrap_or_else(Utc::now),
        text_body: parsed.text_body.unwrap_or_default(),
        html_body: parsed.html_body,
        custom_headers: Vec::new(),
    })
}

// MARK: - Conversation Mbox

/// A research conversation stored as an mbox file.
#[derive(Debug)]
pub struct ConversationMbox {
    /// Unique conversation ID.
    pub id: Uuid,
    /// Conversation title.
    pub title: String,
    /// Path to the mbox file.
    pub path: std::path::PathBuf,
    /// Messages in the conversation.
    pub messages: Vec<MboxMessage>,
}

impl ConversationMbox {
    /// Create a new conversation.
    pub fn new(title: String, base_dir: &Path) -> Self {
        let id = Uuid::new_v4();
        let filename = format!("{}.mbox", id);
        let path = base_dir.join(filename);

        Self {
            id,
            title,
            path,
            messages: Vec::new(),
        }
    }

    /// Load a conversation from an mbox file.
    pub fn load(path: &Path) -> Result<Self> {
        let mbox = MboxFile::read_from_file(path)?;

        // Extract conversation metadata from first message headers
        let title = mbox.messages.first()
            .and_then(|m| {
                m.custom_headers.iter()
                    .find(|(k, _)| k == "X-Impart-Conversation-Title")
                    .map(|(_, v)| v.clone())
            })
            .unwrap_or_else(|| "Untitled Conversation".to_string());

        let id = mbox.messages.first()
            .and_then(|m| {
                m.custom_headers.iter()
                    .find(|(k, _)| k == "X-Impart-Conversation-ID")
                    .and_then(|(_, v)| Uuid::parse_str(v).ok())
            })
            .unwrap_or_else(Uuid::new_v4);

        Ok(Self {
            id,
            title,
            path: path.to_path_buf(),
            messages: mbox.messages,
        })
    }

    /// Add a message to the conversation.
    pub fn add_message(&mut self, mut message: MboxMessage) -> Result<()> {
        // Add conversation metadata headers
        message.add_header("X-Impart-Conversation-ID", &self.id.to_string());
        message.add_header("X-Impart-Conversation-Title", &self.title);

        // Append to file
        MboxFile::append_message(&self.path, &message)?;

        self.messages.push(message);
        Ok(())
    }

    /// Add a user message.
    pub fn add_user_message(&mut self, user_email: &str, content: &str) -> Result<Uuid> {
        let from = Address::new(user_email);
        let to = vec![Address::new("counsel@impart.local")];

        let mut message = if let Some(last) = self.messages.last() {
            MboxMessage::reply_to(last, from, content.to_string())
        } else {
            MboxMessage::new(from, to, self.title.clone(), content.to_string())
        };

        message.add_header("X-Impart-Role", "human");

        let id = message.id;
        self.add_message(message)?;
        Ok(id)
    }

    /// Add an AI counsel message.
    pub fn add_counsel_message(&mut self, model: &str, content: &str) -> Result<Uuid> {
        let from = Address::with_name(format!("AI Counsel ({})", model), "counsel@impart.local");
        let to: Vec<Address> = self.messages.first()
            .map(|m| vec![m.from.clone()])
            .unwrap_or_default();

        let mut message = if let Some(last) = self.messages.last() {
            MboxMessage::reply_to(last, from, content.to_string())
        } else {
            MboxMessage::new(from, to, self.title.clone(), content.to_string())
        };

        message.add_header("X-Impart-Role", "counsel");
        message.add_header("X-Impart-Model", model);

        let id = message.id;
        self.add_message(message)?;
        Ok(id)
    }

    /// Add an artifact reference message.
    pub fn add_artifact_message(
        &mut self,
        from_email: &str,
        artifact_uri: &str,
        artifact_type: &str,
        description: &str,
    ) -> Result<Uuid> {
        let from = Address::new(from_email);
        let to = vec![Address::new("artifacts@impart.local")];

        let body = format!(
            "Artifact: {}\nType: {}\n\n{}",
            artifact_uri, artifact_type, description
        );

        let mut message = if let Some(last) = self.messages.last() {
            MboxMessage::reply_to(last, from, body)
        } else {
            MboxMessage::new(from, to, format!("Artifact: {}", artifact_type), body)
        };

        message.add_header("X-Impart-Role", "artifact");
        message.add_header("X-Impart-Artifact-URI", artifact_uri);
        message.add_header("X-Impart-Artifact-Type", artifact_type);

        let id = message.id;
        self.add_message(message)?;
        Ok(id)
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_mbox_message_creation() {
        let from = Address::with_name("Test User", "test@example.com");
        let to = vec![Address::new("recipient@example.com")];
        let msg = MboxMessage::new(from, to, "Test Subject".into(), "Hello World".into());

        assert!(msg.message_id.contains("@impart.local"));
        assert_eq!(msg.subject, "Test Subject");
        assert_eq!(msg.text_body, "Hello World");
    }

    #[test]
    fn test_mbox_format() {
        let from = Address::with_name("Test User", "test@example.com");
        let to = vec![Address::new("recipient@example.com")];
        let msg = MboxMessage::new(from, to, "Test Subject".into(), "Hello World".into());

        let formatted = msg.to_mbox_string();

        assert!(formatted.starts_with("From test@example.com"));
        assert!(formatted.contains("From: Test User <test@example.com>"));
        assert!(formatted.contains("Subject: Test Subject"));
        assert!(formatted.contains("Hello World"));
    }

    #[test]
    fn test_from_escaping() {
        let from = Address::new("test@example.com");
        let to = vec![Address::new("recipient@example.com")];
        let msg = MboxMessage::new(from, to, "Test".into(), "From the beginning\nFrom here too".into());

        let formatted = msg.to_mbox_string();

        // Body lines starting with "From " should be escaped
        assert!(formatted.contains(">From the beginning"));
        assert!(formatted.contains(">From here too"));
    }

    #[test]
    fn test_mbox_file_write_read() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().join("test.mbox");

        let mut mbox = MboxFile::new();

        let msg1 = MboxMessage::new(
            Address::new("sender@example.com"),
            vec![Address::new("recipient@example.com")],
            "First Message".into(),
            "Hello".into(),
        );
        mbox.add_message(msg1);

        let msg2 = MboxMessage::new(
            Address::new("sender@example.com"),
            vec![Address::new("recipient@example.com")],
            "Second Message".into(),
            "World".into(),
        );
        mbox.add_message(msg2);

        mbox.write_to_file(&path).unwrap();

        let read_mbox = MboxFile::read_from_file(&path).unwrap();
        assert_eq!(read_mbox.messages.len(), 2);
    }

    #[test]
    fn test_conversation_mbox() {
        let temp_dir = TempDir::new().unwrap();

        let mut conv = ConversationMbox::new("Test Conversation".into(), temp_dir.path());

        conv.add_user_message("user@example.com", "Hello, AI!").unwrap();
        conv.add_counsel_message("opus-4.5", "Hello! How can I help you today?").unwrap();

        assert_eq!(conv.messages.len(), 2);

        // Check threading
        assert!(conv.messages[1].in_reply_to.is_some());
        assert!(!conv.messages[1].references.is_empty());
    }
}
