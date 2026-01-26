//! RFC 5322 email-style message system
//!
//! Messages are stored as .eml files with full RFC 5322 headers.
//! Supports threading via In-Reply-To and References headers.

mod body;
mod envelope;
mod threading;

pub use body::{Attachment, AttachmentDisposition, MessageBody};
pub use envelope::{Address, MessageEnvelope, MessageId};
pub use threading::MessageThread;
