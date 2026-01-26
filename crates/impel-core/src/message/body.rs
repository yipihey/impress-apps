//! Message body and attachments

use serde::{Deserialize, Serialize};

/// Message body content
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct MessageBody {
    /// Plain text content
    pub text: String,
    /// HTML content (optional)
    pub html: Option<String>,
    /// Attachments
    pub attachments: Vec<Attachment>,
}

impl MessageBody {
    /// Create a plain text body
    pub fn new(text: String) -> Self {
        Self {
            text,
            html: None,
            attachments: Vec::new(),
        }
    }

    /// Create a body with HTML
    pub fn with_html(text: String, html: String) -> Self {
        Self {
            text,
            html: Some(html),
            attachments: Vec::new(),
        }
    }

    /// Add an attachment
    pub fn attach(mut self, attachment: Attachment) -> Self {
        self.attachments.push(attachment);
        self
    }

    /// Check if the body has attachments
    pub fn has_attachments(&self) -> bool {
        !self.attachments.is_empty()
    }

    /// Get the body length in characters
    pub fn len(&self) -> usize {
        self.text.len()
    }

    /// Check if the body is empty
    pub fn is_empty(&self) -> bool {
        self.text.is_empty()
    }

    /// Get a preview of the body (first N characters)
    pub fn preview(&self, max_len: usize) -> String {
        if self.text.len() <= max_len {
            self.text.clone()
        } else {
            format!("{}...", &self.text[..max_len])
        }
    }
}

/// An attachment to a message
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Attachment {
    /// Filename
    pub filename: String,
    /// MIME type
    pub content_type: String,
    /// Content (base64 encoded for binary, plain for text)
    pub content: String,
    /// Content disposition (inline or attachment)
    pub disposition: AttachmentDisposition,
    /// Size in bytes
    pub size: usize,
}

impl Attachment {
    /// Create a text attachment
    pub fn text(filename: String, content: String) -> Self {
        let size = content.len();
        Self {
            filename,
            content_type: "text/plain".to_string(),
            content,
            disposition: AttachmentDisposition::Attachment,
            size,
        }
    }

    /// Create an attachment from bytes
    pub fn binary(filename: String, content_type: String, data: &[u8]) -> Self {
        use std::io::Write;
        let size = data.len();

        // Base64 encode
        let mut encoded = Vec::new();
        {
            let mut encoder = base64_encoder(&mut encoded);
            encoder.write_all(data).unwrap();
        }

        Self {
            filename,
            content_type,
            content: String::from_utf8(encoded).unwrap(),
            disposition: AttachmentDisposition::Attachment,
            size,
        }
    }

    /// Create an inline attachment
    pub fn inline(filename: String, content_type: String, content: String) -> Self {
        let size = content.len();
        Self {
            filename,
            content_type,
            content,
            disposition: AttachmentDisposition::Inline,
            size,
        }
    }

    /// Get the content as bytes (decoding base64 if necessary)
    pub fn as_bytes(&self) -> Vec<u8> {
        if self.content_type.starts_with("text/") {
            self.content.as_bytes().to_vec()
        } else {
            // Decode base64
            base64_decode(&self.content).unwrap_or_default()
        }
    }
}

/// Content disposition for attachments
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum AttachmentDisposition {
    /// Display inline in the message
    Inline,
    /// Separate attachment
    Attachment,
}

impl std::fmt::Display for AttachmentDisposition {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AttachmentDisposition::Inline => write!(f, "inline"),
            AttachmentDisposition::Attachment => write!(f, "attachment"),
        }
    }
}

// Simple base64 helpers (avoiding external dependency for this simple case)
fn base64_encoder(output: &mut Vec<u8>) -> impl std::io::Write + '_ {
    struct Base64Encoder<'a>(&'a mut Vec<u8>);

    impl std::io::Write for Base64Encoder<'_> {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

            for chunk in buf.chunks(3) {
                let b0 = chunk[0] as usize;
                let b1 = chunk.get(1).copied().unwrap_or(0) as usize;
                let b2 = chunk.get(2).copied().unwrap_or(0) as usize;

                self.0.push(ALPHABET[b0 >> 2]);
                self.0.push(ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)]);

                if chunk.len() > 1 {
                    self.0.push(ALPHABET[((b1 & 0x0f) << 2) | (b2 >> 6)]);
                } else {
                    self.0.push(b'=');
                }

                if chunk.len() > 2 {
                    self.0.push(ALPHABET[b2 & 0x3f]);
                } else {
                    self.0.push(b'=');
                }
            }

            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    Base64Encoder(output)
}

fn base64_decode(input: &str) -> Option<Vec<u8>> {
    const DECODE_TABLE: [i8; 256] = {
        let mut table = [-1i8; 256];
        let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut i = 0;
        while i < 64 {
            table[alphabet[i] as usize] = i as i8;
            i += 1;
        }
        table
    };

    let input: Vec<u8> = input.bytes().filter(|&b| b != b'\n' && b != b'\r').collect();
    if input.len() % 4 != 0 {
        return None;
    }

    let mut output = Vec::with_capacity(input.len() * 3 / 4);

    for chunk in input.chunks(4) {
        let a = DECODE_TABLE[chunk[0] as usize];
        let b = DECODE_TABLE[chunk[1] as usize];
        let c = if chunk[2] == b'=' { 0 } else { DECODE_TABLE[chunk[2] as usize] };
        let d = if chunk[3] == b'=' { 0 } else { DECODE_TABLE[chunk[3] as usize] };

        if a < 0 || b < 0 || (chunk[2] != b'=' && c < 0) || (chunk[3] != b'=' && d < 0) {
            return None;
        }

        output.push(((a as u8) << 2) | ((b as u8) >> 4));
        if chunk[2] != b'=' {
            output.push(((b as u8) << 4) | ((c as u8) >> 2));
        }
        if chunk[3] != b'=' {
            output.push(((c as u8) << 6) | (d as u8));
        }
    }

    Some(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_message_body() {
        let body = MessageBody::new("Hello, World!".to_string());
        assert_eq!(body.text, "Hello, World!");
        assert!(!body.has_attachments());
    }

    #[test]
    fn test_body_preview() {
        let body = MessageBody::new("This is a long message that should be truncated".to_string());
        let preview = body.preview(20);
        assert!(preview.ends_with("..."));
        assert!(preview.len() <= 23); // 20 chars + "..."
    }

    #[test]
    fn test_attachment() {
        let attachment = Attachment::text("readme.txt".to_string(), "Hello!".to_string());
        assert_eq!(attachment.filename, "readme.txt");
        assert_eq!(attachment.content_type, "text/plain");
    }

    #[test]
    fn test_base64_roundtrip() {
        let original = b"Hello, World!";
        let attachment = Attachment::binary(
            "test.bin".to_string(),
            "application/octet-stream".to_string(),
            original,
        );

        let decoded = attachment.as_bytes();
        assert_eq!(decoded, original);
    }
}
