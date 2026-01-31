//! SMTP client for sending messages.

use crate::{ImpartError, Result};
use crate::types::AccountConfig;
use lettre::{
    message::{header::ContentType, Mailbox as LettreMailbox, Message as LettreMessage},
    transport::smtp::authentication::Credentials,
    SmtpTransport, Transport,
};

// MARK: - Draft Message

/// Message to be sent.
#[derive(Debug, Clone)]
pub struct DraftMessage {
    pub from_email: String,
    pub to_emails: Vec<String>,
    pub cc_emails: Vec<String>,
    pub subject: String,
    pub text_body: String,
    pub html_body: Option<String>,
}

// MARK: - SMTP Client

/// SMTP client for sending messages.
pub struct SmtpClient {
    transport: SmtpTransport,
    #[allow(dead_code)]
    from_email: String,
}

impl SmtpClient {
    /// Create a new SMTP client.
    pub fn new(config: &AccountConfig, password: &str) -> Result<Self> {
        let creds = Credentials::new(config.email.clone(), password.to_string());

        let transport = if config.smtp_starttls {
            SmtpTransport::starttls_relay(&config.smtp_host)
                .map_err(|e| ImpartError::Smtp(e.to_string()))?
                .credentials(creds)
                .port(config.smtp_port)
                .build()
        } else {
            SmtpTransport::relay(&config.smtp_host)
                .map_err(|e| ImpartError::Smtp(e.to_string()))?
                .credentials(creds)
                .port(config.smtp_port)
                .build()
        };

        Ok(Self {
            transport,
            from_email: config.email.clone(),
        })
    }

    /// Send a message.
    pub fn send(&self, draft: &DraftMessage) -> Result<()> {
        let from: LettreMailbox = draft.from_email.parse()
            .map_err(|e: lettre::address::AddressError| ImpartError::Smtp(e.to_string()))?;

        let mut builder = LettreMessage::builder()
            .from(from)
            .subject(&draft.subject);

        // Add To recipients
        for to in &draft.to_emails {
            let mailbox: LettreMailbox = to.parse()
                .map_err(|e: lettre::address::AddressError| ImpartError::Smtp(e.to_string()))?;
            builder = builder.to(mailbox);
        }

        // Add CC recipients
        for cc in &draft.cc_emails {
            let mailbox: LettreMailbox = cc.parse()
                .map_err(|e: lettre::address::AddressError| ImpartError::Smtp(e.to_string()))?;
            builder = builder.cc(mailbox);
        }

        // Build message with body
        let message = if let Some(html) = &draft.html_body {
            builder
                .header(ContentType::TEXT_HTML)
                .body(html.clone())
                .map_err(|e| ImpartError::Smtp(e.to_string()))?
        } else {
            builder
                .header(ContentType::TEXT_PLAIN)
                .body(draft.text_body.clone())
                .map_err(|e| ImpartError::Smtp(e.to_string()))?
        };

        self.transport
            .send(&message)
            .map_err(|e| ImpartError::Smtp(e.to_string()))?;

        Ok(())
    }

    /// Disconnect (cleanup).
    pub fn disconnect(&self) {
        // SmtpTransport handles cleanup on drop
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_draft_message_creation() {
        let draft = DraftMessage {
            from_email: "test@example.com".to_string(),
            to_emails: vec!["recipient@example.com".to_string()],
            cc_emails: vec![],
            subject: "Test".to_string(),
            text_body: "Hello".to_string(),
            html_body: None,
        };
        assert_eq!(draft.to_emails.len(), 1);
    }
}
