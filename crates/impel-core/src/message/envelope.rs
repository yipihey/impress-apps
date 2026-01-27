//! RFC 5322 message envelope

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::MessageBody;
use crate::error::{MessageError, Result};
use crate::thread::ThreadId;

/// Unique identifier for a message (RFC 5322 Message-ID format)
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct MessageId(pub String);

impl MessageId {
    /// Create a new message ID
    pub fn new() -> Self {
        let uuid = Uuid::new_v4();
        let timestamp = Utc::now().timestamp();
        Self(format!("<{}.{}@impel.local>", uuid, timestamp))
    }

    /// Parse a message ID from a string
    pub fn parse(s: &str) -> Result<Self> {
        let s = s.trim();
        if s.starts_with('<') && s.ends_with('>') {
            Ok(Self(s.to_string()))
        } else if !s.contains('<') {
            Ok(Self(format!("<{}>", s)))
        } else {
            Err(MessageError::InvalidFormat(format!("Invalid message ID: {}", s)).into())
        }
    }

    /// Get the raw ID without angle brackets
    pub fn raw(&self) -> &str {
        self.0.trim_start_matches('<').trim_end_matches('>')
    }
}

impl Default for MessageId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for MessageId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Address in email format (local@domain)
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Address {
    /// Display name (optional)
    pub name: Option<String>,
    /// Local part (before @)
    pub local: String,
    /// Domain part (after @)
    pub domain: String,
}

impl Address {
    /// Create an address for an agent
    pub fn agent(agent_id: &str) -> Self {
        Self {
            name: Some(agent_id.to_string()),
            local: agent_id.to_string(),
            domain: "impel.local".to_string(),
        }
    }

    /// Create an address for a human
    pub fn human(name: &str) -> Self {
        Self {
            name: Some(name.to_string()),
            local: "human".to_string(),
            domain: "impel.local".to_string(),
        }
    }

    /// Create an address for the system
    pub fn system() -> Self {
        Self {
            name: Some("Impel System".to_string()),
            local: "system".to_string(),
            domain: "impel.local".to_string(),
        }
    }

    /// Format as email string
    pub fn email(&self) -> String {
        format!("{}@{}", self.local, self.domain)
    }

    /// Format with display name if present
    pub fn formatted(&self) -> String {
        if let Some(ref name) = self.name {
            format!("{} <{}@{}>", name, self.local, self.domain)
        } else {
            self.email()
        }
    }
}

impl std::fmt::Display for Address {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.formatted())
    }
}

/// RFC 5322 message envelope with headers
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct MessageEnvelope {
    /// Unique message ID
    pub message_id: MessageId,
    /// Sender address
    pub from: Address,
    /// Recipient addresses
    pub to: Vec<Address>,
    /// CC addresses
    pub cc: Vec<Address>,
    /// Subject line
    pub subject: String,
    /// Date/time of message
    pub date: DateTime<Utc>,
    /// In-Reply-To header (parent message ID)
    pub in_reply_to: Option<MessageId>,
    /// References header (thread chain of message IDs)
    pub references: Vec<MessageId>,
    /// Custom X-Impel-Thread header
    pub thread_id: Option<ThreadId>,
    /// Custom X-Impel-Temperature header
    pub temperature: Option<f64>,
    /// Custom X-Impel-Priority header
    pub priority: Option<String>,
    /// Message body
    pub body: MessageBody,
}

impl MessageEnvelope {
    /// Create a new message
    pub fn new(from: Address, to: Vec<Address>, subject: String, body: MessageBody) -> Self {
        Self {
            message_id: MessageId::new(),
            from,
            to,
            cc: Vec::new(),
            subject,
            date: Utc::now(),
            in_reply_to: None,
            references: Vec::new(),
            thread_id: None,
            temperature: None,
            priority: None,
            body,
        }
    }

    /// Create a reply to this message
    pub fn reply(&self, from: Address, body: MessageBody) -> Self {
        let subject = if self.subject.starts_with("Re: ") {
            self.subject.clone()
        } else {
            format!("Re: {}", self.subject)
        };

        let mut references = self.references.clone();
        references.push(self.message_id.clone());

        Self {
            message_id: MessageId::new(),
            from,
            to: vec![self.from.clone()],
            cc: Vec::new(),
            subject,
            date: Utc::now(),
            in_reply_to: Some(self.message_id.clone()),
            references,
            thread_id: self.thread_id.clone(),
            temperature: self.temperature,
            priority: self.priority.clone(),
            body,
        }
    }

    /// Set the thread ID
    pub fn with_thread(mut self, thread_id: ThreadId) -> Self {
        self.thread_id = Some(thread_id);
        self
    }

    /// Set the temperature
    pub fn with_temperature(mut self, temperature: f64) -> Self {
        self.temperature = Some(temperature);
        self
    }

    /// Set the priority
    pub fn with_priority(mut self, priority: String) -> Self {
        self.priority = Some(priority);
        self
    }

    /// Add CC recipients
    pub fn with_cc(mut self, cc: Vec<Address>) -> Self {
        self.cc = cc;
        self
    }

    /// Format as RFC 5322 .eml file content
    pub fn to_eml(&self) -> String {
        let mut headers = Vec::new();

        headers.push(format!("Message-ID: {}", self.message_id));
        headers.push(format!("From: {}", self.from.formatted()));
        headers.push(format!(
            "To: {}",
            self.to
                .iter()
                .map(|a| a.formatted())
                .collect::<Vec<_>>()
                .join(", ")
        ));

        if !self.cc.is_empty() {
            headers.push(format!(
                "Cc: {}",
                self.cc
                    .iter()
                    .map(|a| a.formatted())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }

        headers.push(format!("Subject: {}", self.subject));
        headers.push(format!(
            "Date: {}",
            self.date.format("%a, %d %b %Y %H:%M:%S %z")
        ));

        if let Some(ref reply_to) = self.in_reply_to {
            headers.push(format!("In-Reply-To: {}", reply_to));
        }

        if !self.references.is_empty() {
            headers.push(format!(
                "References: {}",
                self.references
                    .iter()
                    .map(|r| r.to_string())
                    .collect::<Vec<_>>()
                    .join(" ")
            ));
        }

        if let Some(ref thread_id) = self.thread_id {
            headers.push(format!("X-Impel-Thread: {}", thread_id));
        }

        if let Some(temp) = self.temperature {
            headers.push(format!("X-Impel-Temperature: {:.2}", temp));
        }

        if let Some(ref priority) = self.priority {
            headers.push(format!("X-Impel-Priority: {}", priority));
        }

        headers.push("MIME-Version: 1.0".to_string());
        headers.push("Content-Type: text/plain; charset=utf-8".to_string());

        format!("{}\n\n{}", headers.join("\n"), self.body.text)
    }

    /// Parse from .eml content (basic parser)
    pub fn from_eml(content: &str) -> Result<Self> {
        let parts: Vec<&str> = content.splitn(2, "\n\n").collect();
        if parts.len() != 2 {
            return Err(MessageError::ParseError("Missing body separator".to_string()).into());
        }

        let header_section = parts[0];
        let body_text = parts[1];

        let mut message_id = None;
        let mut from = None;
        let mut to = Vec::new();
        let mut subject = String::new();
        let mut date = Utc::now();
        let mut in_reply_to = None;
        let mut references = Vec::new();
        let mut thread_id = None;
        let mut temperature = None;

        for line in header_section.lines() {
            let line = line.trim();
            if let Some((key, value)) = line.split_once(':') {
                let key = key.trim().to_lowercase();
                let value = value.trim();

                match key.as_str() {
                    "message-id" => message_id = Some(MessageId::parse(value)?),
                    "from" => from = Some(parse_address(value)),
                    "to" => to = parse_address_list(value),
                    "subject" => subject = value.to_string(),
                    "in-reply-to" => in_reply_to = Some(MessageId::parse(value)?),
                    "references" => {
                        references = value
                            .split_whitespace()
                            .filter_map(|s| MessageId::parse(s).ok())
                            .collect();
                    }
                    "x-impel-thread" => thread_id = ThreadId::parse(value).ok(),
                    "x-impel-temperature" => temperature = value.parse().ok(),
                    _ => {}
                }
            }
        }

        let from = from.ok_or_else(|| MessageError::MissingHeader("From".to_string()))?;

        Ok(Self {
            message_id: message_id.unwrap_or_else(MessageId::new),
            from,
            to,
            cc: Vec::new(),
            subject,
            date,
            in_reply_to,
            references,
            thread_id,
            temperature,
            priority: None,
            body: MessageBody::new(body_text.to_string()),
        })
    }
}

/// Parse a single address from a string (simplified)
fn parse_address(s: &str) -> Address {
    let s = s.trim();

    // Try to parse "Name <email@domain>" format
    if let Some(start) = s.find('<') {
        if let Some(end) = s.find('>') {
            let name = s[..start].trim().to_string();
            let email = &s[start + 1..end];
            if let Some((local, domain)) = email.split_once('@') {
                return Address {
                    name: if name.is_empty() { None } else { Some(name) },
                    local: local.to_string(),
                    domain: domain.to_string(),
                };
            }
        }
    }

    // Try plain email format
    if let Some((local, domain)) = s.split_once('@') {
        return Address {
            name: None,
            local: local.to_string(),
            domain: domain.to_string(),
        };
    }

    // Fallback
    Address {
        name: None,
        local: s.to_string(),
        domain: "impel.local".to_string(),
    }
}

/// Parse a comma-separated list of addresses
fn parse_address_list(s: &str) -> Vec<Address> {
    s.split(',')
        .map(|addr| parse_address(addr.trim()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_message_id() {
        let id = MessageId::new();
        assert!(id.0.starts_with('<'));
        assert!(id.0.ends_with('>'));
        assert!(id.0.contains("@impel.local"));
    }

    #[test]
    fn test_address_formatting() {
        let addr = Address::agent("research-1");
        assert_eq!(addr.email(), "research-1@impel.local");
        assert!(addr.formatted().contains("research-1"));
    }

    #[test]
    fn test_message_creation() {
        let from = Address::agent("research-1");
        let to = vec![Address::agent("writer-1")];
        let body = MessageBody::new("Hello, World!".to_string());

        let msg = MessageEnvelope::new(from, to, "Test Subject".to_string(), body);

        assert_eq!(msg.subject, "Test Subject");
        assert_eq!(msg.body.text, "Hello, World!");
    }

    #[test]
    fn test_reply() {
        let from = Address::agent("research-1");
        let to = vec![Address::agent("writer-1")];
        let body = MessageBody::new("Original message".to_string());

        let original = MessageEnvelope::new(from.clone(), to, "Topic".to_string(), body);

        let reply_body = MessageBody::new("Reply text".to_string());
        let reply = original.reply(Address::agent("writer-1"), reply_body);

        assert_eq!(reply.subject, "Re: Topic");
        assert_eq!(reply.in_reply_to, Some(original.message_id.clone()));
        assert!(reply.references.contains(&original.message_id));
    }

    #[test]
    fn test_eml_roundtrip() {
        let from = Address::agent("research-1");
        let to = vec![Address::agent("writer-1")];
        let body = MessageBody::new("Test body content".to_string());

        let msg = MessageEnvelope::new(from, to, "Test Subject".to_string(), body)
            .with_thread(ThreadId::new());

        let eml = msg.to_eml();
        let parsed = MessageEnvelope::from_eml(&eml).unwrap();

        assert_eq!(parsed.subject, msg.subject);
        assert_eq!(parsed.body.text, msg.body.text);
    }
}
