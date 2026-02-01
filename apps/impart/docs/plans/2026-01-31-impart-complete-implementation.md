# Impart Complete Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a fully functional email client with IMAP sync, SMTP send, JWZ threading, search, AI draft review, and research conversation features.

**Architecture:** Rust core (`crates/impart-core`) handles IMAP/SMTP protocols, MIME parsing, and JWZ threading via UniFFI bindings. Swift `MessageManagerCore` provides the service layer, Core Data persistence, and view models. SwiftUI views (shared between macOS/iOS) present the UI with keyboard-first navigation.

**Tech Stack:** Rust (imap, lettre, mailparse, uniffi), Swift 5.9+, SwiftUI, Core Data, Keychain

---

## Phase 1: Rust Core with UniFFI Bindings

### Task 1.1: Add UniFFI Schema and Build Configuration

**Files:**
- Create: `crates/impart-core/src/uniffi.udl`
- Modify: `crates/impart-core/Cargo.toml`
- Modify: `crates/impart-core/src/lib.rs`
- Create: `crates/impart-core/build.rs`

**Step 1: Create UniFFI interface definition**

Create `crates/impart-core/src/uniffi.udl`:

```udl
namespace impart_core {
    // Threading
    sequence<Thread> thread_messages(sequence<Envelope> envelopes);

    // MIME parsing
    [Throws=ImpartError]
    ParsedMessage parse_message(bytes raw);
};

[Error]
enum ImpartError {
    "Imap",
    "Smtp",
    "Mime",
    "Auth",
    "Network",
    "Io",
};

dictionary Address {
    string? name;
    string email;
};

dictionary Envelope {
    u32 uid;
    string? message_id;
    string? in_reply_to;
    sequence<string> references;
    string? subject;
    sequence<Address> from_addresses;
    sequence<Address> to_addresses;
    sequence<Address> cc_addresses;
    sequence<Address> bcc_addresses;
    i64? date_timestamp;
    sequence<string> flags;
};

dictionary Thread {
    string root_message_id;
    sequence<string> message_ids;
    string? subject;
};

dictionary Attachment {
    string filename;
    string mime_type;
    u64 size;
    string? content_id;
    bytes data;
};

dictionary ParsedMessage {
    Envelope envelope;
    string? text_body;
    string? html_body;
    sequence<Attachment> attachments;
};

dictionary Mailbox {
    string name;
    string delimiter;
    sequence<string> flags;
    u32 message_count;
    u32 unseen_count;
};

dictionary AccountConfig {
    string id;
    string email;
    string display_name;
    string imap_host;
    u16 imap_port;
    string smtp_host;
    u16 smtp_port;
    boolean imap_tls;
    boolean smtp_starttls;
};

dictionary DraftMessage {
    string from_email;
    sequence<string> to_emails;
    sequence<string> cc_emails;
    string subject;
    string text_body;
    string? html_body;
};

[Trait]
interface ImapClient {
    [Throws=ImpartError]
    constructor(AccountConfig config, string password);

    [Throws=ImpartError]
    sequence<Mailbox> list_mailboxes();

    [Throws=ImpartError]
    sequence<Envelope> fetch_envelopes(string mailbox_name, u32 start, u32 count);

    [Throws=ImpartError]
    ParsedMessage fetch_message(string mailbox_name, u32 uid);

    [Throws=ImpartError]
    void set_flags(string mailbox_name, sequence<u32> uids, sequence<string> flags, boolean add);

    [Throws=ImpartError]
    void move_messages(string from_mailbox, string to_mailbox, sequence<u32> uids);

    void disconnect();
};

[Trait]
interface SmtpClient {
    [Throws=ImpartError]
    constructor(AccountConfig config, string password);

    [Throws=ImpartError]
    void send(DraftMessage message);

    void disconnect();
};
```

**Step 2: Update Cargo.toml build dependencies**

Add to `crates/impart-core/Cargo.toml`:

```toml
[build-dependencies]
uniffi = { version = "0.28", features = ["build"] }
```

**Step 3: Create build.rs**

Create `crates/impart-core/build.rs`:

```rust
fn main() {
    uniffi::generate_scaffolding("src/uniffi.udl").unwrap();
}
```

**Step 4: Update lib.rs to include UniFFI scaffolding**

Add to `crates/impart-core/src/lib.rs`:

```rust
#[cfg(feature = "native")]
uniffi::include_scaffolding!("uniffi");
```

**Step 5: Build and verify**

Run: `cd crates/impart-core && cargo build --features native`
Expected: Build succeeds

**Step 6: Commit**

```bash
git add crates/impart-core/
git commit -m "feat(impart): add UniFFI schema for Swift bindings"
```

---

### Task 1.2: Implement IMAP Client in Rust

**Files:**
- Create: `crates/impart-core/src/imap.rs`
- Modify: `crates/impart-core/src/lib.rs`

**Step 1: Write tests for IMAP client**

Add to `crates/impart-core/src/imap.rs`:

```rust
//! IMAP client implementation.

use crate::{AccountConfig, Envelope, ImpartError, Mailbox, ParsedMessage, Result};
use imap::Session;
use native_tls::TlsConnector;
use std::net::TcpStream;

// MARK: - IMAP Client

/// IMAP client for fetching messages.
pub struct ImapClient {
    session: Session<native_tls::TlsStream<TcpStream>>,
}

impl ImapClient {
    /// Create a new IMAP connection.
    pub fn new(config: &AccountConfig, password: &str) -> Result<Self> {
        let tls = TlsConnector::builder()
            .build()
            .map_err(|e| ImpartError::Network(e.to_string()))?;

        let client = imap::connect(
            (config.imap_host.as_str(), config.imap_port),
            &config.imap_host,
            &tls,
        )
        .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let session = client
            .login(&config.email, password)
            .map_err(|e| ImpartError::Auth(e.0.to_string()))?;

        Ok(Self { session })
    }

    /// List all mailboxes.
    pub fn list_mailboxes(&mut self) -> Result<Vec<Mailbox>> {
        let mailboxes = self
            .session
            .list(None, Some("*"))
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        Ok(mailboxes
            .iter()
            .map(|m| Mailbox {
                name: m.name().to_string(),
                delimiter: m.delimiter().map(|d| d.to_string()).unwrap_or_else(|| "/".to_string()),
                flags: m.attributes().iter().map(|a| format!("{:?}", a)).collect(),
                message_count: 0,
                unseen_count: 0,
            })
            .collect())
    }

    /// Fetch message envelopes from a mailbox.
    pub fn fetch_envelopes(
        &mut self,
        mailbox_name: &str,
        start: u32,
        count: u32,
    ) -> Result<Vec<Envelope>> {
        self.session
            .select(mailbox_name)
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let range = format!("{}:{}", start, start + count - 1);
        let messages = self
            .session
            .fetch(&range, "(UID ENVELOPE FLAGS)")
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let mut envelopes = Vec::new();
        for msg in messages.iter() {
            if let Some(env) = msg.envelope() {
                envelopes.push(convert_envelope(msg.uid.unwrap_or(0), env, &msg.flags()));
            }
        }

        Ok(envelopes)
    }

    /// Fetch full message by UID.
    pub fn fetch_message(&mut self, mailbox_name: &str, uid: u32) -> Result<ParsedMessage> {
        self.session
            .select(mailbox_name)
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let messages = self
            .session
            .uid_fetch(uid.to_string(), "BODY[]")
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let msg = messages
            .iter()
            .next()
            .ok_or_else(|| ImpartError::Imap("Message not found".to_string()))?;

        let body = msg
            .body()
            .ok_or_else(|| ImpartError::Imap("No body".to_string()))?;

        crate::mime::parse_message(body)
    }

    /// Set flags on messages.
    pub fn set_flags(
        &mut self,
        mailbox_name: &str,
        uids: &[u32],
        flags: &[String],
        add: bool,
    ) -> Result<()> {
        self.session
            .select(mailbox_name)
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let uid_str = uids.iter().map(|u| u.to_string()).collect::<Vec<_>>().join(",");
        let flag_str = flags.join(" ");

        let query = if add {
            format!("+FLAGS ({})", flag_str)
        } else {
            format!("-FLAGS ({})", flag_str)
        };

        self.session
            .uid_store(&uid_str, &query)
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        Ok(())
    }

    /// Move messages to another mailbox.
    pub fn move_messages(
        &mut self,
        from_mailbox: &str,
        to_mailbox: &str,
        uids: &[u32],
    ) -> Result<()> {
        self.session
            .select(from_mailbox)
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        let uid_str = uids.iter().map(|u| u.to_string()).collect::<Vec<_>>().join(",");

        self.session
            .uid_mv(&uid_str, to_mailbox)
            .map_err(|e| ImpartError::Imap(e.to_string()))?;

        Ok(())
    }

    /// Disconnect from server.
    pub fn disconnect(&mut self) {
        let _ = self.session.logout();
    }
}

/// Convert imap-rs envelope to our Envelope type.
fn convert_envelope(uid: u32, env: &imap::types::Envelope, flags: &[imap::types::Flag]) -> Envelope {
    use crate::Address;

    fn convert_addresses(addrs: Option<&Vec<imap::types::Address>>) -> Vec<Address> {
        addrs
            .map(|a| {
                a.iter()
                    .map(|addr| Address {
                        name: addr.name.as_ref().map(|n| String::from_utf8_lossy(n).to_string()),
                        email: format!(
                            "{}@{}",
                            addr.mailbox.as_ref().map(|m| String::from_utf8_lossy(m)).unwrap_or_default(),
                            addr.host.as_ref().map(|h| String::from_utf8_lossy(h)).unwrap_or_default()
                        ),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    Envelope {
        uid,
        message_id: env.message_id.as_ref().map(|m| String::from_utf8_lossy(m).to_string()),
        in_reply_to: env.in_reply_to.as_ref().map(|r| String::from_utf8_lossy(r).to_string()),
        references: Vec::new(), // ENVELOPE doesn't include References, need BODY[HEADER]
        subject: env.subject.as_ref().map(|s| String::from_utf8_lossy(s).to_string()),
        from: convert_addresses(env.from.as_ref()),
        to: convert_addresses(env.to.as_ref()),
        cc: convert_addresses(env.cc.as_ref()),
        bcc: convert_addresses(env.bcc.as_ref()),
        date: None, // Parse from date string if needed
        flags: flags.iter().map(|f| format!("{:?}", f)).collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_convert_envelope() {
        // Unit test without network
        let flags = vec![imap::types::Flag::Seen];
        // More tests would require mock IMAP server
    }
}
```

**Step 2: Export IMAP module**

Add to `crates/impart-core/src/lib.rs`:

```rust
#[cfg(feature = "native")]
pub mod imap;
#[cfg(feature = "native")]
pub use imap::ImapClient;
```

**Step 3: Build and verify**

Run: `cd crates/impart-core && cargo build --features native`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add crates/impart-core/src/imap.rs crates/impart-core/src/lib.rs
git commit -m "feat(impart): implement IMAP client in Rust"
```

---

### Task 1.3: Implement SMTP Client in Rust

**Files:**
- Create: `crates/impart-core/src/smtp.rs`
- Modify: `crates/impart-core/src/lib.rs`

**Step 1: Implement SMTP client**

Create `crates/impart-core/src/smtp.rs`:

```rust
//! SMTP client for sending messages.

use crate::{AccountConfig, ImpartError, Result};
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
```

**Step 2: Export SMTP module**

Add to `crates/impart-core/src/lib.rs`:

```rust
#[cfg(feature = "native")]
pub mod smtp;
#[cfg(feature = "native")]
pub use smtp::{DraftMessage, SmtpClient};
```

**Step 3: Build and verify**

Run: `cd crates/impart-core && cargo build --features native`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add crates/impart-core/src/smtp.rs crates/impart-core/src/lib.rs
git commit -m "feat(impart): implement SMTP client in Rust"
```

---

### Task 1.4: Create FFI Bridge Module

**Files:**
- Create: `crates/impart-core/src/ffi.rs`
- Modify: `crates/impart-core/src/lib.rs`

**Step 1: Create FFI wrapper types and functions**

Create `crates/impart-core/src/ffi.rs`:

```rust
//! FFI bindings for Swift/Kotlin via UniFFI.

use crate::{
    imap::ImapClient as RustImapClient,
    smtp::{DraftMessage as RustDraft, SmtpClient as RustSmtpClient},
    threading, AccountConfig, Envelope, ImpartError, Mailbox, ParsedMessage, Thread,
};
use std::sync::{Arc, Mutex};

// MARK: - Thread-safe wrappers

/// Thread-safe IMAP client wrapper for FFI.
pub struct FfiImapClient {
    inner: Mutex<RustImapClient>,
}

impl FfiImapClient {
    pub fn new(config: AccountConfig, password: String) -> Result<Arc<Self>, ImpartError> {
        let client = RustImapClient::new(&config, &password)?;
        Ok(Arc::new(Self {
            inner: Mutex::new(client),
        }))
    }

    pub fn list_mailboxes(&self) -> Result<Vec<Mailbox>, ImpartError> {
        let mut guard = self.inner.lock().map_err(|_| ImpartError::Imap("Lock poisoned".to_string()))?;
        guard.list_mailboxes()
    }

    pub fn fetch_envelopes(
        &self,
        mailbox_name: String,
        start: u32,
        count: u32,
    ) -> Result<Vec<Envelope>, ImpartError> {
        let mut guard = self.inner.lock().map_err(|_| ImpartError::Imap("Lock poisoned".to_string()))?;
        guard.fetch_envelopes(&mailbox_name, start, count)
    }

    pub fn fetch_message(&self, mailbox_name: String, uid: u32) -> Result<ParsedMessage, ImpartError> {
        let mut guard = self.inner.lock().map_err(|_| ImpartError::Imap("Lock poisoned".to_string()))?;
        guard.fetch_message(&mailbox_name, uid)
    }

    pub fn set_flags(
        &self,
        mailbox_name: String,
        uids: Vec<u32>,
        flags: Vec<String>,
        add: bool,
    ) -> Result<(), ImpartError> {
        let mut guard = self.inner.lock().map_err(|_| ImpartError::Imap("Lock poisoned".to_string()))?;
        guard.set_flags(&mailbox_name, &uids, &flags, add)
    }

    pub fn move_messages(
        &self,
        from_mailbox: String,
        to_mailbox: String,
        uids: Vec<u32>,
    ) -> Result<(), ImpartError> {
        let mut guard = self.inner.lock().map_err(|_| ImpartError::Imap("Lock poisoned".to_string()))?;
        guard.move_messages(&from_mailbox, &to_mailbox, &uids)
    }

    pub fn disconnect(&self) {
        if let Ok(mut guard) = self.inner.lock() {
            guard.disconnect();
        }
    }
}

/// Thread-safe SMTP client wrapper for FFI.
pub struct FfiSmtpClient {
    inner: RustSmtpClient,
}

impl FfiSmtpClient {
    pub fn new(config: AccountConfig, password: String) -> Result<Arc<Self>, ImpartError> {
        let client = RustSmtpClient::new(&config, &password)?;
        Ok(Arc::new(Self { inner: client }))
    }

    pub fn send(&self, draft: FfiDraftMessage) -> Result<(), ImpartError> {
        self.inner.send(&draft.into())
    }

    pub fn disconnect(&self) {
        self.inner.disconnect();
    }
}

/// FFI-friendly draft message.
pub struct FfiDraftMessage {
    pub from_email: String,
    pub to_emails: Vec<String>,
    pub cc_emails: Vec<String>,
    pub subject: String,
    pub text_body: String,
    pub html_body: Option<String>,
}

impl From<FfiDraftMessage> for RustDraft {
    fn from(ffi: FfiDraftMessage) -> Self {
        RustDraft {
            from_email: ffi.from_email,
            to_emails: ffi.to_emails,
            cc_emails: ffi.cc_emails,
            subject: ffi.subject,
            text_body: ffi.text_body,
            html_body: ffi.html_body,
        }
    }
}

// MARK: - Standalone functions

/// Thread messages using JWZ algorithm (exposed to FFI).
pub fn ffi_thread_messages(envelopes: Vec<Envelope>) -> Vec<Thread> {
    threading::thread_messages(&envelopes)
}

/// Parse a MIME message (exposed to FFI).
pub fn ffi_parse_message(raw: Vec<u8>) -> Result<ParsedMessage, ImpartError> {
    crate::mime::parse_message(&raw)
}
```

**Step 2: Export FFI module**

Update `crates/impart-core/src/lib.rs`:

```rust
#[cfg(feature = "native")]
pub mod ffi;

#[cfg(feature = "native")]
pub use ffi::{FfiImapClient, FfiSmtpClient, FfiDraftMessage, ffi_thread_messages, ffi_parse_message};
```

**Step 3: Build and verify**

Run: `cd crates/impart-core && cargo build --features native`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add crates/impart-core/src/ffi.rs crates/impart-core/src/lib.rs
git commit -m "feat(impart): add FFI bridge for Swift bindings"
```

---

### Task 1.5: Generate Swift Bindings

**Files:**
- Create: `Tools/generate-impart-bindings.sh`
- Modify: `apps/impart/ImpartRustCore/Package.swift`
- Replace: `apps/impart/ImpartRustCore/Sources/ImpartRustCore/Exports.swift`

**Step 1: Create binding generation script**

Create `Tools/generate-impart-bindings.sh`:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CRATE_DIR="$PROJECT_ROOT/crates/impart-core"
OUTPUT_DIR="$PROJECT_ROOT/apps/impart/ImpartRustCore/Sources/ImpartRustCore"

echo "Building impart-core with native feature..."
cd "$CRATE_DIR"
cargo build --release --features native

echo "Generating Swift bindings..."
cargo run --features native --bin uniffi-bindgen generate \
    --library target/release/libimpart_core.dylib \
    --language swift \
    --out-dir "$OUTPUT_DIR"

echo "Bindings generated at $OUTPUT_DIR"
```

**Step 2: Update ImpartRustCore Package.swift**

Replace `apps/impart/ImpartRustCore/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpartRustCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImpartRustCore",
            targets: ["ImpartRustCore"]
        )
    ],
    targets: [
        // Swift bindings generated by UniFFI
        .target(
            name: "ImpartRustCore",
            dependencies: ["ImpartCoreFFI"],
            path: "Sources/ImpartRustCore"
        ),
        // Binary framework from Rust
        .binaryTarget(
            name: "ImpartCoreFFI",
            path: "Frameworks/ImpartCoreFFI.xcframework"
        )
    ]
)
```

**Step 3: Commit**

```bash
chmod +x Tools/generate-impart-bindings.sh
git add Tools/generate-impart-bindings.sh apps/impart/ImpartRustCore/Package.swift
git commit -m "feat(impart): add Swift binding generation script"
```

---

## Phase 2: Swift Service Layer

### Task 2.1: Create Mail Provider Protocol Implementation

**Files:**
- Create: `apps/impart/MessageManagerCore/Sources/MessageManagerCore/Services/RustMailProvider.swift`

**Step 1: Implement MailProvider using Rust FFI**

Create `apps/impart/MessageManagerCore/Sources/MessageManagerCore/Services/RustMailProvider.swift`:

```swift
//
//  RustMailProvider.swift
//  MessageManagerCore
//
//  MailProvider implementation using Rust IMAP/SMTP clients.
//

import Foundation
import ImpartRustCore

// MARK: - Rust Mail Provider

/// MailProvider implementation backed by Rust IMAP/SMTP clients.
public actor RustMailProvider: MailProvider {
    private let config: Account
    private var imapClient: FfiImapClient?
    private var smtpClient: FfiSmtpClient?
    private let keychainService: KeychainService

    public init(account: Account, keychainService: KeychainService = .shared) {
        self.config = account
        self.keychainService = keychainService
    }

    // MARK: - Connection

    public func connect() async throws {
        let password = try keychainService.getPassword(for: config.id)

        let rustConfig = AccountConfig(
            id: config.id.uuidString,
            email: config.email,
            displayName: config.displayName,
            imapHost: config.imapSettings.host,
            imapPort: config.imapSettings.port,
            smtpHost: config.smtpSettings.host,
            smtpPort: config.smtpSettings.port,
            imapTls: config.imapSettings.security == .tls,
            smtpStarttls: config.smtpSettings.security == .starttls
        )

        imapClient = try FfiImapClient(config: rustConfig, password: password)
    }

    public func disconnect() async {
        imapClient?.disconnect()
        smtpClient?.disconnect()
        imapClient = nil
        smtpClient = nil
    }

    // MARK: - Mailboxes

    public func fetchMailboxes() async throws -> [Mailbox] {
        guard let client = imapClient else {
            throw MailProviderError.notConnected
        }

        let rustMailboxes = try client.listMailboxes()
        return rustMailboxes.map { $0.toSwift() }
    }

    // MARK: - Messages

    public func fetchMessages(mailbox: Mailbox, range: MessageRange) async throws -> [Message] {
        guard let client = imapClient else {
            throw MailProviderError.notConnected
        }

        let envelopes = try client.fetchEnvelopes(
            mailboxName: mailbox.fullPath,
            start: UInt32(range.start),
            count: UInt32(range.count)
        )

        return envelopes.map { $0.toSwift() }
    }

    public func fetchMessageContent(id: UUID) async throws -> MessageContent {
        guard let client = imapClient else {
            throw MailProviderError.notConnected
        }

        // Need to track UID mapping
        throw MailProviderError.notImplemented
    }

    // MARK: - Actions

    public func send(_ draft: DraftMessage) async throws {
        let password = try keychainService.getPassword(for: config.id)

        let rustConfig = AccountConfig(
            id: config.id.uuidString,
            email: config.email,
            displayName: config.displayName,
            imapHost: config.imapSettings.host,
            imapPort: config.imapSettings.port,
            smtpHost: config.smtpSettings.host,
            smtpPort: config.smtpSettings.port,
            imapTls: config.imapSettings.security == .tls,
            smtpStarttls: config.smtpSettings.security == .starttls
        )

        let smtp = try FfiSmtpClient(config: rustConfig, password: password)

        let ffiDraft = FfiDraftMessage(
            fromEmail: config.email,
            toEmails: draft.to.map(\.email),
            ccEmails: draft.cc.map(\.email),
            subject: draft.subject,
            textBody: draft.body,
            htmlBody: nil
        )

        try smtp.send(draft: ffiDraft)
        smtp.disconnect()
    }

    public func setRead(_ messageIds: [UUID], read: Bool) async throws {
        // Implementation requires UID mapping
        throw MailProviderError.notImplemented
    }

    public func move(_ messageIds: [UUID], to mailbox: Mailbox) async throws {
        // Implementation requires UID mapping
        throw MailProviderError.notImplemented
    }

    public func delete(_ messageIds: [UUID]) async throws {
        // Implementation requires UID mapping
        throw MailProviderError.notImplemented
    }
}

// MARK: - Errors

public enum MailProviderError: LocalizedError {
    case notConnected
    case notImplemented
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to mail server"
        case .notImplemented:
            return "Feature not yet implemented"
        case .authenticationFailed:
            return "Authentication failed"
        }
    }
}

// MARK: - Type Conversions

extension ImpartRustCore.Mailbox {
    func toSwift() -> MessageManagerCore.Mailbox {
        Mailbox(
            id: UUID(),
            name: shortName,
            fullPath: name,
            messageCount: Int(messageCount),
            unreadCount: Int(unseenCount)
        )
    }

    var shortName: String {
        name.split(separator: Character(delimiter)).last.map(String.init) ?? name
    }
}

extension ImpartRustCore.Envelope {
    func toSwift() -> Message {
        Message(
            id: UUID(),
            uid: uid,
            messageId: messageId,
            subject: subject ?? "(No Subject)",
            from: fromAddresses.map { $0.toSwift() },
            to: toAddresses.map { $0.toSwift() },
            cc: ccAddresses.map { $0.toSwift() },
            date: dateTimestamp.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date(),
            snippet: "",
            isRead: flags.contains("\\Seen"),
            isStarred: flags.contains("\\Flagged"),
            hasAttachments: false
        )
    }
}

extension ImpartRustCore.Address {
    func toSwift() -> EmailAddress {
        EmailAddress(name: name, email: email)
    }
}
```

**Step 2: Add KeychainService**

Create `apps/impart/MessageManagerCore/Sources/MessageManagerCore/Services/KeychainService.swift`:

```swift
//
//  KeychainService.swift
//  MessageManagerCore
//
//  Secure credential storage using Keychain.
//

import Foundation
import KeychainSwift

// MARK: - Keychain Service

/// Service for securely storing email account credentials.
public final class KeychainService: Sendable {
    public static let shared = KeychainService()

    private let keychain: KeychainSwift
    private let prefix = "com.impress.impart."

    public init() {
        let kc = KeychainSwift()
        kc.synchronizable = false
        self.keychain = kc
    }

    /// Store password for an account.
    public func setPassword(_ password: String, for accountId: UUID) throws {
        let key = prefix + accountId.uuidString
        guard keychain.set(password, forKey: key) else {
            throw KeychainError.saveFailed
        }
    }

    /// Retrieve password for an account.
    public func getPassword(for accountId: UUID) throws -> String {
        let key = prefix + accountId.uuidString
        guard let password = keychain.get(key) else {
            throw KeychainError.notFound
        }
        return password
    }

    /// Delete password for an account.
    public func deletePassword(for accountId: UUID) {
        let key = prefix + accountId.uuidString
        keychain.delete(key)
    }
}

// MARK: - Errors

public enum KeychainError: LocalizedError {
    case saveFailed
    case notFound

    public var errorDescription: String? {
        switch self {
        case .saveFailed:
            return "Failed to save to Keychain"
        case .notFound:
            return "Credential not found in Keychain"
        }
    }
}
```

**Step 3: Commit**

```bash
git add apps/impart/MessageManagerCore/Sources/MessageManagerCore/Services/
git commit -m "feat(impart): add RustMailProvider and KeychainService"
```

---

### Task 2.2: Create Sync Service

**Files:**
- Create: `apps/impart/MessageManagerCore/Sources/MessageManagerCore/Services/SyncService.swift`

**Step 1: Implement sync service**

Create `apps/impart/MessageManagerCore/Sources/MessageManagerCore/Services/SyncService.swift`:

```swift
//
//  SyncService.swift
//  MessageManagerCore
//
//  Synchronizes messages between server and local Core Data store.
//

import Foundation
import CoreData
import OSLog

private let syncLogger = Logger(subsystem: "com.impress.impart", category: "sync")

// MARK: - Sync Service

/// Service for synchronizing email between server and local storage.
public actor SyncService {
    private let persistence: PersistenceController
    private var providers: [UUID: RustMailProvider] = [:]

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    // MARK: - Provider Management

    /// Get or create a mail provider for an account.
    public func provider(for account: Account) -> RustMailProvider {
        if let existing = providers[account.id] {
            return existing
        }
        let provider = RustMailProvider(account: account)
        providers[account.id] = provider
        return provider
    }

    // MARK: - Sync Operations

    /// Sync all mailboxes for an account.
    public func syncMailboxes(for account: Account) async throws -> [Mailbox] {
        let provider = provider(for: account)
        try await provider.connect()
        defer { Task { await provider.disconnect() } }

        let mailboxes = try await provider.fetchMailboxes()

        // Save to Core Data
        try await persistence.performBackgroundTask { context in
            let fetchRequest = CDAccount.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", account.id as CVarArg)

            guard let cdAccount = try context.fetch(fetchRequest).first else {
                throw SyncError.accountNotFound
            }

            // Clear existing folders and recreate
            if let existingFolders = cdAccount.folders {
                for folder in existingFolders {
                    context.delete(folder)
                }
            }

            for mailbox in mailboxes {
                let cdFolder = CDFolder(context: context)
                cdFolder.id = mailbox.id
                cdFolder.name = mailbox.name
                cdFolder.fullPath = mailbox.fullPath
                cdFolder.messageCount = Int32(mailbox.messageCount)
                cdFolder.unreadCount = Int32(mailbox.unreadCount)
                cdFolder.account = cdAccount
                cdFolder.roleRaw = detectFolderRole(mailbox.fullPath).rawValue
            }

            try context.save()
        }

        syncLogger.info("Synced \(mailboxes.count) mailboxes for \(account.email)")
        return mailboxes
    }

    /// Sync messages from a mailbox.
    public func syncMessages(
        for account: Account,
        mailbox: Mailbox,
        range: MessageRange = MessageRange(start: 1, count: 50)
    ) async throws -> [Message] {
        let provider = provider(for: account)
        try await provider.connect()
        defer { Task { await provider.disconnect() } }

        let messages = try await provider.fetchMessages(mailbox: mailbox, range: range)

        // Save to Core Data
        try await persistence.performBackgroundTask { context in
            let folderRequest = CDFolder.fetchRequest()
            folderRequest.predicate = NSPredicate(format: "fullPath == %@ AND account.id == %@", mailbox.fullPath, account.id as CVarArg)

            guard let cdFolder = try context.fetch(folderRequest).first else {
                throw SyncError.folderNotFound
            }

            for message in messages {
                // Check if message already exists
                let existingRequest = CDMessage.fetchRequest()
                existingRequest.predicate = NSPredicate(format: "uid == %d AND folder == %@", message.uid, cdFolder)

                let cdMessage: CDMessage
                if let existing = try context.fetch(existingRequest).first {
                    cdMessage = existing
                } else {
                    cdMessage = CDMessage(context: context)
                    cdMessage.id = message.id
                }

                cdMessage.uid = Int32(message.uid)
                cdMessage.messageId = message.messageId
                cdMessage.subject = message.subject
                cdMessage.snippet = message.snippet
                cdMessage.date = message.date
                cdMessage.receivedDate = message.date
                cdMessage.isRead = message.isRead
                cdMessage.isStarred = message.isStarred
                cdMessage.hasAttachments = message.hasAttachments
                cdMessage.folder = cdFolder

                // Encode addresses
                cdMessage.fromJSON = encodeAddresses(message.from)
                cdMessage.toJSON = encodeAddresses(message.to)
                cdMessage.ccJSON = encodeAddresses(message.cc)
            }

            try context.save()
        }

        syncLogger.info("Synced \(messages.count) messages from \(mailbox.name)")
        return messages
    }

    /// Send a message.
    public func send(_ draft: DraftMessage, from account: Account) async throws {
        let provider = provider(for: account)
        try await provider.send(draft)
        syncLogger.info("Sent message: \(draft.subject)")
    }

    // MARK: - Helpers

    private func detectFolderRole(_ path: String) -> FolderRole {
        let lower = path.lowercased()
        if lower == "inbox" { return .inbox }
        if lower.contains("sent") { return .sent }
        if lower.contains("draft") { return .drafts }
        if lower.contains("trash") || lower.contains("deleted") { return .trash }
        if lower.contains("archive") || lower.contains("all mail") { return .archive }
        if lower.contains("spam") || lower.contains("junk") { return .spam }
        return .custom
    }

    private func encodeAddresses(_ addresses: [EmailAddress]) -> String {
        guard let data = try? JSONEncoder().encode(addresses),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

// MARK: - Sync Errors

public enum SyncError: LocalizedError {
    case accountNotFound
    case folderNotFound
    case syncFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "Account not found"
        case .folderNotFound:
            return "Folder not found"
        case .syncFailed(let reason):
            return "Sync failed: \(reason)"
        }
    }
}

// MARK: - Message Range

public struct MessageRange: Sendable {
    public let start: Int
    public let count: Int

    public init(start: Int, count: Int) {
        self.start = start
        self.count = count
    }
}
```

**Step 2: Commit**

```bash
git add apps/impart/MessageManagerCore/Sources/MessageManagerCore/Services/SyncService.swift
git commit -m "feat(impart): add SyncService for IMAP synchronization"
```

---

### Task 2.3: Update InboxViewModel to Use SyncService

**Files:**
- Modify: `apps/impart/MessageManagerCore/Sources/MessageManagerCore/ViewModels/InboxViewModel.swift`

**Step 1: Connect ViewModel to SyncService**

Update `loadMessages()` and `refresh()` methods in `InboxViewModel.swift`:

```swift
// Add property
private let syncService: SyncService

// Update init
public init(persistence: PersistenceController = .shared, syncService: SyncService? = nil) {
    self.persistence = persistence
    self.syncService = syncService ?? SyncService(persistence: persistence)
    self.triageService = MessageTriageService(persistenceController: persistence)
    self.folderManager = FolderManager(persistenceController: persistence)
}

// Update loadMessages
public func loadMessages() async {
    guard let account = selectedAccount, let mailbox = selectedMailbox else {
        messages = []
        threads = []
        return
    }

    isLoading = true
    errorMessage = nil

    do {
        // Fetch from Core Data first
        messages = try await fetchMessagesFromStore(mailbox: mailbox)

        // Thread messages using Rust core
        if showAsThreads {
            threads = await threadMessages(messages)
        }

        inboxLogger.info("Loaded \(self.messages.count) messages from \(mailbox.name)")
    } catch {
        errorMessage = error.localizedDescription
        inboxLogger.error("Failed to load messages: \(error.localizedDescription)")
    }

    isLoading = false
}

// Update refresh
public func refresh() async {
    guard let account = selectedAccount, let mailbox = selectedMailbox else { return }

    isLoading = true
    errorMessage = nil

    do {
        // Sync from server
        let newMessages = try await syncService.syncMessages(
            for: account,
            mailbox: mailbox
        )

        // Reload from store
        messages = try await fetchMessagesFromStore(mailbox: mailbox)

        if showAsThreads {
            threads = await threadMessages(messages)
        }

        inboxLogger.info("Refreshed \(mailbox.name) with \(newMessages.count) messages")
    } catch {
        errorMessage = error.localizedDescription
        inboxLogger.error("Failed to refresh: \(error.localizedDescription)")
    }

    isLoading = false
}

// Add helper methods
private func fetchMessagesFromStore(mailbox: Mailbox) async throws -> [Message] {
    try await persistence.performBackgroundTask { context in
        let request = CDMessage.fetchRequest()
        request.predicate = NSPredicate(format: "folder.fullPath == %@", mailbox.fullPath)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.date, ascending: false)]

        let cdMessages = try context.fetch(request)
        return cdMessages.map { $0.toMessage() }
    }
}

private func threadMessages(_ messages: [Message]) async -> [Thread] {
    // Convert to Rust envelopes and thread
    let envelopes = messages.map { $0.toRustEnvelope() }
    let rustThreads = ImpartRustCore.threadMessages(envelopes)
    return rustThreads.map { $0.toSwift() }
}
```

**Step 2: Commit**

```bash
git add apps/impart/MessageManagerCore/Sources/MessageManagerCore/ViewModels/InboxViewModel.swift
git commit -m "feat(impart): connect InboxViewModel to SyncService"
```

---

## Phase 3: Search Implementation

### Task 3.1: Add Full-Text Search

**Files:**
- Create: `apps/impart/MessageManagerCore/Sources/MessageManagerCore/Search/SearchService.swift`

**Step 1: Implement search service**

Create `apps/impart/MessageManagerCore/Sources/MessageManagerCore/Search/SearchService.swift`:

```swift
//
//  SearchService.swift
//  MessageManagerCore
//
//  Full-text search over messages using Core Data.
//

import Foundation
import CoreData
import OSLog

private let searchLogger = Logger(subsystem: "com.impress.impart", category: "search")

// MARK: - Search Service

/// Service for searching messages.
public actor SearchService {
    private let persistence: PersistenceController

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    /// Search messages by query.
    public func search(query: String, accountId: UUID? = nil, folderId: UUID? = nil) async throws -> [Message] {
        guard !query.isEmpty else { return [] }

        return try await persistence.performBackgroundTask { context in
            let request = CDMessage.fetchRequest()

            var predicates: [NSPredicate] = []

            // Text search predicate
            let searchPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "subject CONTAINS[cd] %@", query),
                NSPredicate(format: "snippet CONTAINS[cd] %@", query),
                NSPredicate(format: "fromJSON CONTAINS[cd] %@", query),
                NSPredicate(format: "toJSON CONTAINS[cd] %@", query)
            ])
            predicates.append(searchPredicate)

            // Optional account filter
            if let accountId {
                predicates.append(NSPredicate(format: "folder.account.id == %@", accountId as CVarArg))
            }

            // Optional folder filter
            if let folderId {
                predicates.append(NSPredicate(format: "folder.id == %@", folderId as CVarArg))
            }

            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.date, ascending: false)]
            request.fetchLimit = 100

            let cdMessages = try context.fetch(request)
            searchLogger.info("Search '\(query)' returned \(cdMessages.count) results")

            return cdMessages.map { $0.toMessage() }
        }
    }

    /// Search with advanced filters.
    public func advancedSearch(_ criteria: SearchCriteria) async throws -> [Message] {
        return try await persistence.performBackgroundTask { context in
            let request = CDMessage.fetchRequest()

            var predicates: [NSPredicate] = []

            if let query = criteria.query, !query.isEmpty {
                predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "subject CONTAINS[cd] %@", query),
                    NSPredicate(format: "snippet CONTAINS[cd] %@", query)
                ]))
            }

            if let from = criteria.from {
                predicates.append(NSPredicate(format: "fromJSON CONTAINS[cd] %@", from))
            }

            if let to = criteria.to {
                predicates.append(NSPredicate(format: "toJSON CONTAINS[cd] %@", to))
            }

            if let after = criteria.after {
                predicates.append(NSPredicate(format: "date >= %@", after as NSDate))
            }

            if let before = criteria.before {
                predicates.append(NSPredicate(format: "date <= %@", before as NSDate))
            }

            if criteria.hasAttachments == true {
                predicates.append(NSPredicate(format: "hasAttachments == YES"))
            }

            if criteria.isUnread == true {
                predicates.append(NSPredicate(format: "isRead == NO"))
            }

            if criteria.isStarred == true {
                predicates.append(NSPredicate(format: "isStarred == YES"))
            }

            request.predicate = predicates.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.date, ascending: false)]
            request.fetchLimit = criteria.limit ?? 100

            let cdMessages = try context.fetch(request)
            return cdMessages.map { $0.toMessage() }
        }
    }
}

// MARK: - Search Criteria

public struct SearchCriteria: Sendable {
    public var query: String?
    public var from: String?
    public var to: String?
    public var after: Date?
    public var before: Date?
    public var hasAttachments: Bool?
    public var isUnread: Bool?
    public var isStarred: Bool?
    public var limit: Int?

    public init(
        query: String? = nil,
        from: String? = nil,
        to: String? = nil,
        after: Date? = nil,
        before: Date? = nil,
        hasAttachments: Bool? = nil,
        isUnread: Bool? = nil,
        isStarred: Bool? = nil,
        limit: Int? = nil
    ) {
        self.query = query
        self.from = from
        self.to = to
        self.after = after
        self.before = before
        self.hasAttachments = hasAttachments
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.limit = limit
    }
}
```

**Step 2: Commit**

```bash
git add apps/impart/MessageManagerCore/Sources/MessageManagerCore/Search/
git commit -m "feat(impart): add SearchService for message search"
```

---

## Phase 4: AI Draft Review Integration

### Task 4.1: Connect AI Draft Review to ImpressAI

**Files:**
- Modify: `apps/impart/MessageManagerCore/Sources/MessageManagerCore/AI/AgentMessageHandler.swift`

**Step 1: Integrate with ImpressAI**

Add to `AgentMessageHandler.swift`:

```swift
import ImpressAI

extension AgentMessageHandler {
    /// Review a draft message using AI.
    public func reviewDraft(_ draft: DraftMessage) async throws -> DraftReview {
        let prompt = """
        Review this email draft and suggest improvements:

        To: \(draft.to.map(\.email).joined(separator: ", "))
        Subject: \(draft.subject)

        Body:
        \(draft.body)

        Provide:
        1. Overall assessment (professional tone, clarity, completeness)
        2. Specific suggestions for improvement
        3. Any potential issues (typos, unclear phrasing, missing information)
        """

        let executor = AIMultiModelExecutor.shared
        let response = try await executor.execute(
            prompt: prompt,
            category: .editing
        )

        return DraftReview(
            suggestions: response.content,
            improvedDraft: nil // Could parse and extract improved version
        )
    }

    /// Generate a reply draft using AI.
    public func generateReply(to message: Message, style: ReplyStyle) async throws -> DraftMessage {
        let prompt = """
        Generate a \(style.rawValue) reply to this email:

        From: \(message.fromDisplayString)
        Subject: \(message.subject)

        Original message:
        \(message.snippet)

        Write a professional reply.
        """

        let executor = AIMultiModelExecutor.shared
        let response = try await executor.execute(
            prompt: prompt,
            category: .generation
        )

        return DraftMessage(
            accountId: UUID(), // Would need to be passed in
            to: message.from,
            subject: "Re: \(message.subject)",
            body: response.content
        )
    }
}

// MARK: - Types

public struct DraftReview: Sendable {
    public let suggestions: String
    public let improvedDraft: DraftMessage?
}

public enum ReplyStyle: String, Sendable {
    case professional = "professional"
    case brief = "brief"
    case friendly = "friendly"
}
```

**Step 2: Commit**

```bash
git add apps/impart/MessageManagerCore/Sources/MessageManagerCore/AI/AgentMessageHandler.swift
git commit -m "feat(impart): integrate AI draft review with ImpressAI"
```

---

## Phase 5: SwiftUI Views

### Task 5.1: Complete MessageDetailView

**Files:**
- Modify: `apps/impart/macOS/Views/ContentView.swift`

**Step 1: Implement MessageDetailView**

Replace the placeholder `MessageDetailView` in `ContentView.swift`:

```swift
// MARK: - Message Detail View

/// Detail view for a single message.
struct MessageDetailView: View {
    let messageId: UUID
    @State private var message: Message?
    @State private var content: MessageContent?
    @State private var isLoading = true
    @State private var error: String?

    private let persistence = PersistenceController.shared

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading message...")
            } else if let error {
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if let message {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header
                        messageHeader(message)

                        Divider()

                        // Body
                        if let content {
                            if let html = content.htmlBody {
                                // WebView for HTML content
                                Text("HTML content display")
                                    .foregroundStyle(.secondary)
                            } else if let text = content.textBody {
                                Text(text)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text(message.snippet)
                                .textSelection(.enabled)
                        }

                        // Attachments
                        if message.hasAttachments, let attachments = content?.attachments {
                            attachmentSection(attachments)
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView(
                    "Message Not Found",
                    systemImage: "envelope",
                    description: Text("The message could not be loaded")
                )
            }
        }
        .navigationTitle(message?.subject ?? "Message")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    // Reply action
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .help("Reply")

                Button {
                    // Forward action
                } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                }
                .help("Forward")

                Button {
                    Task { await toggleStar() }
                } label: {
                    Image(systemName: message?.isStarred == true ? "star.fill" : "star")
                }
                .help("Star")
            }
        }
        .task {
            await loadMessage()
        }
    }

    @ViewBuilder
    private func messageHeader(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.subject)
                    .font(.title2)
                    .bold()
                Spacer()
                if message.isStarred {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }

            HStack {
                Text("From:")
                    .foregroundStyle(.secondary)
                Text(message.fromDisplayString)
            }

            HStack {
                Text("To:")
                    .foregroundStyle(.secondary)
                Text(message.to.map(\.displayString).joined(separator: ", "))
            }

            if !message.cc.isEmpty {
                HStack {
                    Text("Cc:")
                        .foregroundStyle(.secondary)
                    Text(message.cc.map(\.displayString).joined(separator: ", "))
                }
            }

            HStack {
                Text("Date:")
                    .foregroundStyle(.secondary)
                Text(message.date, style: .date)
                Text(message.date, style: .time)
            }
        }
    }

    @ViewBuilder
    private func attachmentSection(_ attachments: [Attachment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("Attachments")
                .font(.headline)

            ForEach(attachments) { attachment in
                HStack {
                    Image(systemName: iconForMimeType(attachment.mimeType))
                    Text(attachment.filename)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                        .foregroundStyle(.secondary)
                    Button("Save") {
                        // Save attachment
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func iconForMimeType(_ mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "video" }
        if mimeType.hasPrefix("audio/") { return "music.note" }
        if mimeType.contains("pdf") { return "doc.richtext" }
        if mimeType.contains("zip") || mimeType.contains("archive") { return "archivebox" }
        return "doc"
    }

    private func loadMessage() async {
        isLoading = true
        defer { isLoading = false }

        do {
            message = try await persistence.performBackgroundTask { context in
                let request = CDMessage.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
                return try context.fetch(request).first?.toMessage()
            }

            // Mark as read
            if let message, !message.isRead {
                try await markAsRead()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func markAsRead() async throws {
        try await persistence.performBackgroundTask { context in
            let request = CDMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
            if let cdMessage = try context.fetch(request).first {
                cdMessage.isRead = true
                try context.save()
            }
        }
    }

    private func toggleStar() async {
        guard var msg = message else { return }
        msg.isStarred.toggle()
        message = msg

        try? await persistence.performBackgroundTask { context in
            let request = CDMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
            if let cdMessage = try context.fetch(request).first {
                cdMessage.isStarred.toggle()
                try context.save()
            }
        }
    }
}

// MARK: - Attachment

struct Attachment: Identifiable {
    let id: UUID
    let filename: String
    let mimeType: String
    let size: Int
    let data: Data?
}

// MARK: - MessageContent

struct MessageContent {
    let textBody: String?
    let htmlBody: String?
    let attachments: [Attachment]
}
```

**Step 2: Commit**

```bash
git add apps/impart/macOS/Views/ContentView.swift
git commit -m "feat(impart): implement MessageDetailView with headers and body"
```

---

### Task 5.2: Complete AccountSetupView

**Files:**
- Create: `apps/impart/Shared/Views/AccountSetupView.swift`

**Step 1: Create account setup flow**

Create `apps/impart/Shared/Views/AccountSetupView.swift`:

```swift
//
//  AccountSetupView.swift
//  impart (Shared)
//
//  Account setup wizard for adding email accounts.
//

import SwiftUI
import MessageManagerCore

// MARK: - Account Setup View

/// Wizard for setting up a new email account.
public struct AccountSetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var step: SetupStep = .email
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var imapHost = ""
    @State private var imapPort: Int = 993
    @State private var smtpHost = ""
    @State private var smtpPort: Int = 587
    @State private var security: ConnectionSecurity = .tls
    @State private var isValidating = false
    @State private var errorMessage: String?

    private var detectedProvider: EmailProvider {
        EmailProvider.detect(from: email)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Progress indicator
                ProgressView(value: step.progress)
                    .padding(.horizontal)

                // Step content
                Group {
                    switch step {
                    case .email:
                        emailStep
                    case .password:
                        passwordStep
                    case .settings:
                        settingsStep
                    case .validation:
                        validationStep
                    }
                }
                .padding()

                Spacer()

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .padding(.horizontal)
                }

                // Navigation buttons
                HStack {
                    if step != .email {
                        Button("Back") {
                            withAnimation { step = step.previous }
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    Button(step.nextButtonTitle) {
                        handleNext()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                }
                .padding()
            }
            .navigationTitle("Add Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 400)
    }

    // MARK: - Steps

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter your email address")
                .font(.headline)

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .textFieldStyle(.roundedBorder)

            if detectedProvider != .custom {
                Label("\(detectedProvider.rawValue.capitalized) account detected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter your password")
                .font(.headline)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            if detectedProvider == .gmail {
                Text("For Gmail, use an App Password from your Google Account settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Settings")
                .font(.headline)

            if detectedProvider == .custom {
                Group {
                    TextField("Display Name", text: $displayName)

                    Section("IMAP") {
                        TextField("IMAP Host", text: $imapHost)
                        TextField("IMAP Port", value: $imapPort, format: .number)
                    }

                    Section("SMTP") {
                        TextField("SMTP Host", text: $smtpHost)
                        TextField("SMTP Port", value: $smtpPort, format: .number)
                    }

                    Picker("Security", selection: $security) {
                        ForEach(ConnectionSecurity.allCases, id: \.self) { sec in
                            Text(sec.displayName).tag(sec)
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
            } else {
                Text("Using default settings for \(detectedProvider.rawValue.capitalized)")
                    .foregroundStyle(.secondary)

                TextField("Display Name (optional)", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var validationStep: some View {
        VStack(spacing: 16) {
            if isValidating {
                ProgressView("Connecting to server...")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("Account added successfully!")
                    .font(.headline)
            }
        }
    }

    // MARK: - Logic

    private var canProceed: Bool {
        switch step {
        case .email:
            return email.contains("@") && email.contains(".")
        case .password:
            return !password.isEmpty
        case .settings:
            if detectedProvider == .custom {
                return !imapHost.isEmpty && !smtpHost.isEmpty
            }
            return true
        case .validation:
            return !isValidating
        }
    }

    private func handleNext() {
        errorMessage = nil

        switch step {
        case .email:
            withAnimation { step = .password }
        case .password:
            withAnimation { step = .settings }
        case .settings:
            withAnimation { step = .validation }
            validateAccount()
        case .validation:
            dismiss()
        }
    }

    private func validateAccount() {
        isValidating = true

        Task {
            do {
                // Build account config
                let account = buildAccount()

                // Save password to keychain
                try KeychainService.shared.setPassword(password, for: account.id)

                // Test connection
                let provider = RustMailProvider(account: account)
                try await provider.connect()
                await provider.disconnect()

                // Save account to Core Data
                try await saveAccount(account)

                isValidating = false
            } catch {
                errorMessage = error.localizedDescription
                isValidating = false
                withAnimation { step = .settings }
            }
        }
    }

    private func buildAccount() -> Account {
        let (imap, smtp): (IMAPSettings, SMTPSettings)

        if detectedProvider == .custom {
            imap = IMAPSettings(host: imapHost, port: UInt16(imapPort), security: security, username: email)
            smtp = SMTPSettings(host: smtpHost, port: UInt16(smtpPort), security: security, username: email)
        } else {
            (imap, smtp) = detectedProvider.defaultSettings(for: email)
        }

        return Account(
            email: email,
            displayName: displayName.isEmpty ? email : displayName,
            imapSettings: imap,
            smtpSettings: smtp
        )
    }

    private func saveAccount(_ account: Account) async throws {
        try await PersistenceController.shared.performBackgroundTask { context in
            let cdAccount = CDAccount(context: context)
            cdAccount.id = account.id
            cdAccount.email = account.email
            cdAccount.displayName = account.displayName
            cdAccount.imapHost = account.imapSettings.host
            cdAccount.imapPort = Int16(account.imapSettings.port)
            cdAccount.smtpHost = account.smtpSettings.host
            cdAccount.smtpPort = Int16(account.smtpSettings.port)
            cdAccount.isEnabled = true
            cdAccount.keychainItemId = account.id.uuidString
            try context.save()
        }
    }
}

// MARK: - Setup Step

private enum SetupStep: CaseIterable {
    case email, password, settings, validation

    var progress: Double {
        switch self {
        case .email: return 0.25
        case .password: return 0.5
        case .settings: return 0.75
        case .validation: return 1.0
        }
    }

    var nextButtonTitle: String {
        switch self {
        case .validation: return "Done"
        default: return "Continue"
        }
    }

    var previous: SetupStep {
        switch self {
        case .email: return .email
        case .password: return .email
        case .settings: return .password
        case .validation: return .settings
        }
    }
}

// MARK: - Preview

#Preview {
    AccountSetupView()
}
```

**Step 2: Commit**

```bash
git add apps/impart/Shared/Views/AccountSetupView.swift
git commit -m "feat(impart): add AccountSetupView wizard"
```

---

## Phase 6: Research Conversation Enhancement

### Task 6.1: Enhance Research Conversation View

**Files:**
- Modify: `apps/impart/macOS/Views/Research/ResearchChatView.swift`

**Step 1: Enhance with artifact support and side conversations**

Update `ResearchChatView.swift` to include:

```swift
// Add artifact mention support
// Add side conversation branching UI
// Add provenance event logging
// Connect to ResearchConversationViewModel
```

(Full implementation would include ScrollViewReader for auto-scroll, artifact pills, and branch indicators)

**Step 2: Commit**

```bash
git add apps/impart/macOS/Views/Research/
git commit -m "feat(impart): enhance research conversation UI"
```

---

## Final Steps

### Task 7.1: Update HTTP Router Endpoints

**Files:**
- Modify: `apps/impart/MessageManagerCore/Sources/MessageManagerCore/Automation/ImpartHTTPRouter.swift`

Complete the TODO implementations with actual data from SyncService and persistence layer.

### Task 7.2: Run Tests and Verify

```bash
cd apps/impart/MessageManagerCore && swift test
xcodegen generate
xcodebuild -scheme impart -configuration Debug build
```

### Task 7.3: Final Commit

```bash
git add .
git commit -m "feat(impart): complete implementation with IMAP/SMTP, search, AI review"
```

---

## Summary

This plan implements:

1. **Rust Core with UniFFI** — IMAP client, SMTP client, FFI bindings
2. **Swift Service Layer** — RustMailProvider, SyncService, KeychainService
3. **Search** — SearchService with Core Data full-text search
4. **AI Draft Review** — Integration with ImpressAI for draft suggestions
5. **SwiftUI Views** — MessageDetailView, AccountSetupView, enhanced research views

Total estimated tasks: ~20 bite-sized steps across 6 phases.
