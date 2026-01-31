//! MIME parsing module.
//!
//! Provides parsing of RFC 2045 MIME messages.

use crate::{ImpartError, Result};
use crate::types::{Address, Envelope};
use mailparse::{parse_mail, MailHeaderMap, ParsedMail};

// MARK: - Parsed Message

/// Parsed email message.
#[derive(Debug)]
pub struct ParsedMessage {
    /// Message envelope (headers).
    pub envelope: Envelope,

    /// Plain text body.
    pub text_body: Option<String>,

    /// HTML body.
    pub html_body: Option<String>,

    /// Attachments.
    pub attachments: Vec<Attachment>,
}

/// Email attachment.
#[derive(Debug)]
pub struct Attachment {
    /// Filename.
    pub filename: String,

    /// MIME type.
    pub mime_type: String,

    /// Content size in bytes.
    pub size: usize,

    /// Content ID for inline attachments.
    pub content_id: Option<String>,

    /// Raw data.
    pub data: Vec<u8>,
}

// MARK: - Parsing

/// Parse a raw email message.
pub fn parse_message(raw: &[u8]) -> Result<ParsedMessage> {
    let parsed = parse_mail(raw).map_err(|e| ImpartError::Mime(e.to_string()))?;

    let envelope = extract_envelope(&parsed)?;
    let (text_body, html_body, attachments) = extract_body_parts(&parsed)?;

    Ok(ParsedMessage {
        envelope,
        text_body,
        html_body,
        attachments,
    })
}

/// Extract envelope from parsed mail.
fn extract_envelope(mail: &ParsedMail) -> Result<Envelope> {
    let headers = &mail.headers;

    let mut envelope = Envelope::new(0);

    // Message-ID
    envelope.message_id = headers.get_first_value("Message-ID");

    // In-Reply-To
    envelope.in_reply_to = headers.get_first_value("In-Reply-To");

    // References
    if let Some(refs) = headers.get_first_value("References") {
        envelope.references = refs
            .split_whitespace()
            .map(|s| s.trim_matches(|c| c == '<' || c == '>').to_string())
            .collect();
    }

    // Subject
    envelope.subject = headers.get_first_value("Subject");

    // From
    if let Some(from) = headers.get_first_value("From") {
        envelope.from = parse_address_list(&from);
    }

    // To
    if let Some(to) = headers.get_first_value("To") {
        envelope.to = parse_address_list(&to);
    }

    // CC
    if let Some(cc) = headers.get_first_value("Cc") {
        envelope.cc = parse_address_list(&cc);
    }

    // Date
    if let Some(date_str) = headers.get_first_value("Date") {
        if let Ok(date) = mailparse::dateparse(&date_str) {
            envelope.date = chrono::DateTime::from_timestamp(date, 0);
        }
    }

    Ok(envelope)
}

/// Parse an address list string.
fn parse_address_list(s: &str) -> Vec<Address> {
    // Simple parsing - full RFC 5322 parsing is complex
    s.split(',')
        .filter_map(|addr| {
            let addr = addr.trim();
            if addr.is_empty() {
                return None;
            }

            // Try to extract "Name <email>"
            if let Some(start) = addr.find('<') {
                if let Some(end) = addr.find('>') {
                    let email = addr[start + 1..end].trim().to_string();
                    let name = addr[..start].trim().trim_matches('"').to_string();
                    return Some(Address {
                        name: if name.is_empty() { None } else { Some(name) },
                        email,
                    });
                }
            }

            // Just an email address
            Some(Address::new(addr.to_string()))
        })
        .collect()
}

/// Extract body parts (text, HTML, attachments) from parsed mail.
fn extract_body_parts(
    mail: &ParsedMail,
) -> Result<(Option<String>, Option<String>, Vec<Attachment>)> {
    let mut text_body = None;
    let mut html_body = None;
    let mut attachments = Vec::new();

    extract_parts_recursive(mail, &mut text_body, &mut html_body, &mut attachments)?;

    Ok((text_body, html_body, attachments))
}

/// Recursively extract parts from a MIME message.
fn extract_parts_recursive(
    mail: &ParsedMail,
    text_body: &mut Option<String>,
    html_body: &mut Option<String>,
    attachments: &mut Vec<Attachment>,
) -> Result<()> {
    let content_type = mail.ctype.mimetype.to_lowercase();

    if mail.subparts.is_empty() {
        // Leaf part
        if content_type == "text/plain" && text_body.is_none() {
            text_body.replace(mail.get_body().unwrap_or_default());
        } else if content_type == "text/html" && html_body.is_none() {
            html_body.replace(mail.get_body().unwrap_or_default());
        } else if !content_type.starts_with("text/") {
            // Attachment
            let filename = mail
                .get_content_disposition()
                .params
                .get("filename")
                .cloned()
                .or_else(|| mail.ctype.params.get("name").cloned())
                .unwrap_or_else(|| "attachment".to_string());

            let content_id = mail
                .headers
                .get_first_value("Content-ID")
                .map(|s| s.trim_matches(|c| c == '<' || c == '>').to_string());

            let data = mail.get_body_raw().unwrap_or_default();

            attachments.push(Attachment {
                filename,
                mime_type: content_type,
                size: data.len(),
                content_id,
                data,
            });
        }
    } else {
        // Multipart - recurse into subparts
        for part in &mail.subparts {
            extract_parts_recursive(part, text_body, html_body, attachments)?;
        }
    }

    Ok(())
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_message() {
        let raw = b"From: sender@example.com\r\n\
            To: recipient@example.com\r\n\
            Subject: Test\r\n\
            \r\n\
            Hello, World!";

        let msg = parse_message(raw).unwrap();
        assert_eq!(msg.envelope.subject, Some("Test".to_string()));
        assert_eq!(msg.envelope.from.len(), 1);
        assert_eq!(msg.envelope.from[0].email, "sender@example.com");
        assert!(msg.text_body.is_some());
    }

    #[test]
    fn test_parse_address_list() {
        let addrs = parse_address_list("John Doe <john@example.com>, jane@example.com");
        assert_eq!(addrs.len(), 2);
        assert_eq!(addrs[0].name, Some("John Doe".to_string()));
        assert_eq!(addrs[0].email, "john@example.com");
        assert_eq!(addrs[1].name, None);
        assert_eq!(addrs[1].email, "jane@example.com");
    }
}
