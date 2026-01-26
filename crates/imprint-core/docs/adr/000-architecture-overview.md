# ADR-002: imprint Application Architecture

**Status:** Proposed
**Date:** 2026-01-25
**Authors:** Tom Abel
**Supersedes:** ADR-001 (incorporated and expanded)

## Executive Summary

imprint is a collaborative academic writing application and companion to imbib. This ADR establishes the complete technical architecture with three guiding principles:

1. **Rust-first core**: All business logic, document handling, synchronization, and rendering in Rust
2. **Swift-thin UI**: Native Apple UI layer using SwiftUI, minimal logic
3. **macOS-primary**: Desktop-first development with iOS/iPad as companion apps

## Context

Academic writing applications face unique challenges:

- **Long documents** with complex structure (sections, equations, figures, citations)
- **Collaboration** across institutions with varying technical infrastructure
- **Offline capability** essential (conferences, fieldwork, travel)
- **Version control** for tracking changes over months/years of revision
- **Multi-format output** (journal-specific LaTeX, PDF, HTML)

Existing solutions fall short:

| Solution | Limitation |
|----------|------------|
| Overleaf | Online-only, LaTeX complexity exposed |
| Google Docs | Poor equation/citation support, no LaTeX export |
| Word | Collaboration conflicts, poor version control |
| Plain LaTeX + Git | Not accessible to all collaborators |

imprint aims to provide the writing experience of modern editors with the output quality of LaTeX and the collaboration features of Google Docs—while working offline.

## Decision Summary

### Core Technology Choices

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Authoring format | **Typst** | Fast incremental compilation (<100ms), clean syntax |
| Submission format | **LaTeX** | Journal requirement; Typst→LaTeX converter |
| Document model | **Automerge CRDT** | Conflict-free sync, full history |
| Core language | **Rust** | Memory safety, WASM target, excellent Swift interop |
| UI framework | **SwiftUI** | Native Apple experience, minimal platform code |
| Personal sync | **iCloud Drive** | Zero infrastructure, Apple ecosystem |
| Collaboration sync | **CloudKit Shared Zones** | Apple-native, built-in permissions |

### Access Tiers (Prioritized)

| Tier | Target Users | Identity | Status |
|------|--------------|----------|--------|
| **Tier 1** | Primary authors | Apple ID | **Priority** |
| **Tier 3** | Reviewers, advisors | None (secure link) | **Priority** |
| Tier 2 | Non-Apple collaborators | ORCID/Google/etc | **Deferred** |

Tier 2 (web application) is deferred to post-launch. The Rust/WASM architecture ensures this remains viable without rewriting core logic.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              imprint Architecture                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                         Swift UI Layer                                │ │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐     │ │
│  │  │   Editor    │ │ PDF Preview │ │  Outline    │ │  Comments   │     │ │
│  │  │   View      │ │    View     │ │   View      │ │   Panel     │     │ │
│  │  └──────┬──────┘ └──────┬──────┘ └──────┬──────┘ └──────┬──────┘     │ │
│  │         │               │               │               │            │ │
│  │  ┌──────┴───────────────┴───────────────┴───────────────┴──────┐     │ │
│  │  │                    ImprintDocument                          │     │ │
│  │  │                  (ObservableObject)                         │     │ │
│  │  └─────────────────────────┬───────────────────────────────────┘     │ │
│  │                            │                                         │ │
│  │  ┌─────────────────────────┴───────────────────────────────────┐     │ │
│  │  │              Swift ↔ Rust Bridge (UniFFI)                   │     │ │
│  │  └─────────────────────────┬───────────────────────────────────┘     │ │
│  └────────────────────────────┼─────────────────────────────────────────┘ │
│                               │                                           │
│  ┌────────────────────────────┼─────────────────────────────────────────┐ │
│  │                            ▼           Rust Core                     │ │
│  │  ┌─────────────────────────────────────────────────────────────────┐ │ │
│  │  │                      ImprintCore                                │ │ │
│  │  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐               │ │ │
│  │  │  │  Document   │ │    Sync     │ │  Render     │               │ │ │
│  │  │  │  Module     │ │   Module    │ │  Module     │               │ │ │
│  │  │  ├─────────────┤ ├─────────────┤ ├─────────────┤               │ │ │
│  │  │  │ • Automerge │ │ • Personal  │ │ • Typst     │               │ │ │
│  │  │  │ • History   │ │ • Collab    │ │ • Export    │               │ │ │
│  │  │  │ • Comments  │ │ • Presence  │ │ • Templates │               │ │ │
│  │  │  └─────────────┘ └─────────────┘ └─────────────┘               │ │ │
│  │  │                                                                 │ │ │
│  │  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐               │ │ │
│  │  │  │ Invitation  │ │   imbib     │ │  LaTeX      │               │ │ │
│  │  │  │  Module     │ │ Integration │ │  Converter  │               │ │ │
│  │  │  ├─────────────┤ ├─────────────┤ ├─────────────┤               │ │ │
│  │  │  │ • Create    │ │ • Citations │ │ • MNRAS     │               │ │ │
│  │  │  │ • Validate  │ │ • BibTeX    │ │ • ApJ       │               │ │ │
│  │  │  │ • Redeem    │ │ • PDF refs  │ │ • A&A       │               │ │ │
│  │  │  └─────────────┘ └─────────────┘ └─────────────┘               │ │ │
│  │  └─────────────────────────────────────────────────────────────────┘ │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                        Platform Services                             │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │  │
│  │  │ iCloud Drive │  │   CloudKit   │  │   Keychain   │               │  │
│  │  │ (Personal)   │  │  (Collab)    │  │  (Secrets)   │               │  │
│  │  └──────────────┘  └──────────────┘  └──────────────┘               │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Rust Core Design

### Capability Traits (Single Responsibility)

The core architecture follows the trait-based capability pattern, ensuring each concern is isolated and testable:

```rust
// capabilities/content.rs
/// Core document content operations
pub trait DocumentContent: Send + Sync {
    fn source(&self) -> String;
    fn edit(&mut self, range: Range<usize>, text: &str) -> ChangeSet;
    fn metadata(&self) -> &DocumentMetadata;
}

// capabilities/syncable.rs
/// Synchronization capability
pub trait Syncable: Send + Sync {
    fn generate_sync_message(&self, peer: &PeerId) -> Option<SyncMessage>;
    fn receive_sync_message(&mut self, message: &SyncMessage) -> Result<MergeResult, SyncError>;
    fn merge(&mut self, other: &dyn Syncable) -> MergeResult;
}

// capabilities/versionable.rs
/// Version history capability
pub trait Versionable: Send + Sync {
    fn history(&self) -> VersionTimeline;
    fn content_at(&self, snapshot: &SnapshotId) -> Result<String, HistoryError>;
    fn diff(&self, from: &SnapshotId, to: &SnapshotId) -> Result<Vec<DiffHunk>, HistoryError>;
}

// capabilities/restorable.rs
/// Restoration capability (extends Versionable)
pub trait Restorable: Versionable {
    fn restore(&mut self, snapshot: &SnapshotId) -> Result<ChangeSet, HistoryError>;
    fn restore_section(&mut self, section: &str, snapshot: &SnapshotId) -> Result<ChangeSet, HistoryError>;
}

// capabilities/commentable.rs
/// Commenting capability
pub trait Commentable: Send + Sync {
    fn add_comment(&mut self, anchor: TextAnchor, text: &str, author: &UserId) -> CommentId;
    fn reply_to(&mut self, parent: CommentId, text: &str, author: &UserId) -> CommentId;
    fn resolve(&mut self, id: CommentId, resolver: &UserId);
    fn comments(&self) -> &[Comment];
}

// capabilities/renderable.rs
/// PDF rendering capability
pub trait Renderable: Send + Sync {
    fn render_pdf(&self, config: &RenderConfig) -> Result<Vec<u8>, RenderError>;
    fn render_incremental(&self, cache: Option<&RenderCache>, config: &RenderConfig) -> Result<RenderResult, RenderError>;
}

// capabilities/exportable.rs
/// Export capability
pub trait Exportable: Send + Sync {
    fn export_latex(&self, template: &JournalTemplate) -> Result<String, ExportError>;
    fn export_typst(&self) -> String;
}
```

### FFI Session Facade (Composition)

The FFI layer exposes `ImprintSession` which composes specialized managers:

```rust
// imprint-ffi/src/session.rs

/// Main entry point for Swift, composing all capabilities
pub struct ImprintSession {
    document: Arc<RwLock<ImprintDocument>>,  // Core CRDT doc (DocumentContent)
    sync: SyncManager,                        // Syncable operations
    history: HistoryManager,                  // Versionable/Restorable
    comments: CommentManager,                 // Commentable
    render: RenderService,                    // Renderable
    export: ExportService,                    // Exportable
}

impl ImprintSession {
    pub fn new(title: &str, user: UserIdentity) -> Self {
        let document = Arc::new(RwLock::new(ImprintDocument::new(title, user.clone())));
        Self {
            document: document.clone(),
            sync: SyncManager::new(document.clone()),
            history: HistoryManager::new(document.clone()),
            comments: CommentManager::new(document.clone()),
            render: RenderService::new(document.clone()),
            export: ExportService::new(document.clone()),
        }
    }

    pub fn load(path: &Path) -> Result<Self, ImprintError> {
        let document = Arc::new(RwLock::new(ImprintDocument::load(path)?));
        Ok(Self {
            document: document.clone(),
            sync: SyncManager::new(document.clone()),
            history: HistoryManager::new(document.clone()),
            comments: CommentManager::new(document.clone()),
            render: RenderService::new(document.clone()),
            export: ExportService::new(document.clone()),
        })
    }
}
```

### Structured Error Handling

Errors use `thiserror` with rich context for debugging:

```rust
// error.rs

use thiserror::Error;

#[derive(Error, Debug)]
pub enum ImprintError {
    #[error("Document error: {0}")]
    Document(#[from] DocumentError),

    #[error("Sync error: {0}")]
    Sync(#[from] SyncError),

    #[error("Render error: {0}")]
    Render(#[from] RenderError),

    #[error("History error: {0}")]
    History(#[from] HistoryError),

    #[error("Export error: {0}")]
    Export(#[from] ExportError),

    #[error("Invitation error: {0}")]
    Invitation(#[from] InvitationError),
}

#[derive(Error, Debug)]
pub enum DocumentError {
    #[error("Document not found at path: {path}")]
    NotFound { path: String },

    #[error("Failed to save document to {path}: {reason}")]
    SaveFailed {
        path: String,
        reason: String,
        #[source] source: Option<std::io::Error>,
    },

    #[error("Invalid document format: {details}")]
    InvalidFormat { details: String },

    #[error("Document is read-only")]
    ReadOnly,
}

#[derive(Error, Debug)]
pub enum SyncError {
    #[error("Failed to generate sync message: {reason}")]
    GenerationFailed { reason: String },

    #[error("Invalid sync message from peer {peer_id}: {reason}")]
    InvalidMessage { peer_id: String, reason: String },

    #[error("Merge conflict in document {document_id}")]
    MergeConflict { document_id: String },

    #[error("Peer {peer_id} not found")]
    PeerNotFound { peer_id: String },
}

#[derive(Error, Debug)]
pub enum RenderError {
    #[error("Typst compilation failed at line {line}, column {column}: {message}")]
    CompilationError {
        line: u32,
        column: u32,
        message: String,
        hint: Option<String>,
    },

    #[error("Missing resource: {resource_type} '{name}'")]
    MissingResource { resource_type: String, name: String },

    #[error("Render timeout after {duration_ms}ms")]
    Timeout { duration_ms: u64 },

    #[error("PDF generation failed: {reason}")]
    PdfGenerationFailed { reason: String },
}

#[derive(Error, Debug)]
pub enum HistoryError {
    #[error("Snapshot {snapshot_id} not found")]
    SnapshotNotFound { snapshot_id: String },

    #[error("Section '{section}' not found in snapshot {snapshot_id}")]
    SectionNotFound { section: String, snapshot_id: String },

    #[error("Cannot restore: {reason}")]
    RestoreFailed { reason: String },
}

#[derive(Error, Debug)]
pub enum ExportError {
    #[error("Template '{template}' not supported")]
    UnsupportedTemplate { template: String },

    #[error("Export failed: {reason}")]
    ExportFailed { reason: String },

    #[error("Missing citation key: {key}")]
    MissingCitation { key: String },
}

#[derive(Error, Debug)]
pub enum InvitationError {
    #[error("Invitation expired at {expired_at}")]
    Expired { expired_at: String },

    #[error("Invitation revoked by {revoked_by} at {revoked_at}")]
    Revoked { revoked_by: String, revoked_at: String },

    #[error("Wrong recipient: expected {expected}, got {actual}")]
    WrongRecipient { expected: String, actual: String },

    #[error("Invalid verification code")]
    InvalidVerificationCode,

    #[error("Rate limited: try again in {retry_after_seconds} seconds")]
    RateLimited { retry_after_seconds: u64 },

    #[error("Invalid password")]
    InvalidPassword,

    #[error("Max views ({max_views}) exceeded")]
    MaxViewsExceeded { max_views: u32 },
}
```

### Thread Safety at FFI Boundary

The FFI layer ensures thread safety with `Arc<RwLock>` and callback channels:

```rust
// imprint-ffi/src/thread_safe.rs

use std::sync::{Arc, RwLock, Mutex};
use tokio::sync::mpsc;

/// Thread-safe session wrapper for FFI
pub struct ThreadSafeSession {
    inner: Arc<SessionInner>,
    notification_tx: mpsc::UnboundedSender<Notification>,
}

struct SessionInner {
    document: RwLock<ImprintDocument>,       // Multiple readers, single writer
    sync: RwLock<SyncManager>,               // Own lock for sync state
    render_cache: RwLock<Option<RenderCache>>, // Read-heavy
    pending_ops: Mutex<Vec<PendingOperation>>, // Batching
}

impl ThreadSafeSession {
    pub fn new(session: ImprintSession, delegate: Arc<dyn ImprintDelegate>) -> Self {
        let (tx, mut rx) = mpsc::unbounded_channel();

        // Spawn notification dispatcher
        tokio::spawn(async move {
            while let Some(notification) = rx.recv().await {
                match notification {
                    Notification::DocumentChanged(ranges) => {
                        delegate.on_document_changed(ranges);
                    }
                    Notification::PresenceChanged(user_id, position) => {
                        delegate.on_presence_changed(user_id, position);
                    }
                    Notification::SyncStatusChanged(status) => {
                        delegate.on_sync_status_changed(status);
                    }
                }
            }
        });

        Self {
            inner: Arc::new(SessionInner {
                document: RwLock::new(session.document),
                sync: RwLock::new(session.sync),
                render_cache: RwLock::new(None),
                pending_ops: Mutex::new(Vec::new()),
            }),
            notification_tx: tx,
        }
    }

    /// Read operations use read lock (concurrent)
    pub fn source(&self) -> String {
        self.inner.document.read().unwrap().source()
    }

    /// Write operations use write lock (exclusive)
    pub fn edit(&self, range: Range<usize>, text: &str) -> Result<(), ImprintError> {
        let mut doc = self.inner.document.write().unwrap();
        let change_set = doc.edit(range.clone(), text);

        // Notify delegate
        let _ = self.notification_tx.send(Notification::DocumentChanged(
            vec![TextRange { start: range.start as u64, end: range.end as u64 }]
        ));

        Ok(())
    }
}

/// Callback interface for Swift
#[uniffi::export(callback_interface)]
pub trait ImprintDelegate: Send + Sync {
    fn on_document_changed(&self, changed_ranges: Vec<TextRange>);
    fn on_presence_changed(&self, user_id: String, cursor_position: Option<u64>);
    fn on_sync_status_changed(&self, status: SyncStatus);
}

enum Notification {
    DocumentChanged(Vec<TextRange>),
    PresenceChanged(String, Option<u64>),
    SyncStatusChanged(SyncStatus),
}
```

### Security: Password Hashing with Argon2id

```rust
// imprint-invitation/src/password.rs

use argon2::{
    password_hash::{
        rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString,
    },
    Argon2, Params,
};

/// OWASP-recommended Argon2id hasher for secure link passwords
pub struct SecureLinkPasswordHasher {
    argon2: Argon2<'static>,
}

impl SecureLinkPasswordHasher {
    pub fn new() -> Self {
        // OWASP recommended: 64 MiB memory, 3 iterations, 4 parallelism
        let params = Params::new(
            64 * 1024,  // 64 MiB memory
            3,          // 3 iterations
            4,          // 4 parallel lanes
            Some(32),   // 32-byte output
        ).expect("valid Argon2 params");

        Self {
            argon2: Argon2::new(
                argon2::Algorithm::Argon2id,
                argon2::Version::V0x13,
                params,
            ),
        }
    }

    pub fn hash(&self, password: &str) -> Result<String, InvitationError> {
        let salt = SaltString::generate(&mut OsRng);
        Ok(self.argon2
            .hash_password(password.as_bytes(), &salt)
            .map_err(|e| InvitationError::HashingFailed { reason: e.to_string() })?
            .to_string())
    }

    pub fn verify(&self, password: &str, hash: &str) -> Result<bool, InvitationError> {
        let parsed_hash = PasswordHash::new(hash)
            .map_err(|e| InvitationError::HashingFailed { reason: e.to_string() })?;

        Ok(self.argon2.verify_password(password.as_bytes(), &parsed_hash).is_ok())
    }
}

impl Default for SecureLinkPasswordHasher {
    fn default() -> Self {
        Self::new()
    }
}
```

### Security: Rate Limiting for Validation

```rust
// imprint-invitation/src/rate_limit.rs

use std::collections::HashMap;
use std::time::{Duration, Instant};

pub struct RateLimitConfig {
    pub max_attempts: u32,
    pub window: Duration,
    pub lockout_duration: Duration,
}

impl Default for RateLimitConfig {
    fn default() -> Self {
        Self {
            max_attempts: 5,
            window: Duration::from_secs(60),
            lockout_duration: Duration::from_secs(300), // 5 minutes
        }
    }
}

pub struct ValidationRateLimiter {
    attempts: HashMap<String, Vec<Instant>>,
    lockouts: HashMap<String, Instant>,
    config: RateLimitConfig,
}

impl ValidationRateLimiter {
    pub fn new(config: RateLimitConfig) -> Self {
        Self {
            attempts: HashMap::new(),
            lockouts: HashMap::new(),
            config,
        }
    }

    /// Check if validation attempt is allowed. Returns Ok(()) or error with retry time.
    pub fn check(&mut self, key: &str) -> Result<(), InvitationError> {
        let now = Instant::now();

        // Check lockout
        if let Some(lockout_until) = self.lockouts.get(key) {
            if now < *lockout_until {
                let retry_after = (*lockout_until - now).as_secs();
                return Err(InvitationError::RateLimited {
                    retry_after_seconds: retry_after,
                });
            }
            self.lockouts.remove(key);
        }

        // Clean old attempts and count recent ones
        let attempts = self.attempts.entry(key.to_string()).or_default();
        attempts.retain(|&t| now.duration_since(t) < self.config.window);

        if attempts.len() >= self.config.max_attempts as usize {
            // Lock out
            self.lockouts.insert(key.to_string(), now + self.config.lockout_duration);
            let retry_after = self.config.lockout_duration.as_secs();
            return Err(InvitationError::RateLimited {
                retry_after_seconds: retry_after,
            });
        }

        Ok(())
    }

    /// Record a validation attempt
    pub fn record_attempt(&mut self, key: &str) {
        self.attempts
            .entry(key.to_string())
            .or_default()
            .push(Instant::now());
    }

    /// Clear attempts on successful validation
    pub fn clear(&mut self, key: &str) {
        self.attempts.remove(key);
        self.lockouts.remove(key);
    }
}
```

### Security: Encrypted Invitation Storage

```rust
// imprint-invitation/src/storage.rs

use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM};
use ring::rand::{SecureRandom, SystemRandom};

/// Encrypted storage for invitation secrets at rest
pub struct InvitationSecretStore {
    encryption_key: LessSafeKey,
    rng: SystemRandom,
}

impl InvitationSecretStore {
    pub fn new(key_bytes: &[u8; 32]) -> Result<Self, InvitationError> {
        let unbound_key = UnboundKey::new(&AES_256_GCM, key_bytes)
            .map_err(|_| InvitationError::EncryptionFailed { reason: "invalid key".to_string() })?;

        Ok(Self {
            encryption_key: LessSafeKey::new(unbound_key),
            rng: SystemRandom::new(),
        })
    }

    /// Encrypt a secret for storage
    pub fn encrypt(&self, plaintext: &[u8]) -> Result<Vec<u8>, InvitationError> {
        let mut nonce_bytes = [0u8; 12];
        self.rng.fill(&mut nonce_bytes)
            .map_err(|_| InvitationError::EncryptionFailed { reason: "RNG failed".to_string() })?;

        let nonce = Nonce::assume_unique_for_key(nonce_bytes);
        let mut in_out = plaintext.to_vec();

        self.encryption_key
            .seal_in_place_append_tag(nonce, Aad::empty(), &mut in_out)
            .map_err(|_| InvitationError::EncryptionFailed { reason: "seal failed".to_string() })?;

        // Prepend nonce to ciphertext
        let mut result = nonce_bytes.to_vec();
        result.extend(in_out);
        Ok(result)
    }

    /// Decrypt a secret from storage
    pub fn decrypt(&self, ciphertext: &[u8]) -> Result<Vec<u8>, InvitationError> {
        if ciphertext.len() < 12 {
            return Err(InvitationError::DecryptionFailed { reason: "ciphertext too short".to_string() });
        }

        let (nonce_bytes, encrypted) = ciphertext.split_at(12);
        let nonce = Nonce::assume_unique_for_key(nonce_bytes.try_into().unwrap());
        let mut in_out = encrypted.to_vec();

        let plaintext = self.encryption_key
            .open_in_place(nonce, Aad::empty(), &mut in_out)
            .map_err(|_| InvitationError::DecryptionFailed { reason: "open failed".to_string() })?;

        Ok(plaintext.to_vec())
    }
}
```

### Large Document Handling (Chunking)

```rust
// imprint-document/src/chunking.rs

use std::collections::HashMap;
use lru::LruCache;
use std::num::NonZeroUsize;

pub struct ChunkingConfig {
    pub target_chunk_size: usize,        // 64 KB default
    pub max_cached_chunks: usize,        // 32 chunks (~2 MB)
    pub large_document_threshold: usize, // 1 MB
}

impl Default for ChunkingConfig {
    fn default() -> Self {
        Self {
            target_chunk_size: 64 * 1024,
            max_cached_chunks: 32,
            large_document_threshold: 1024 * 1024,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ChunkId(pub String);

#[derive(Debug)]
pub enum ChunkState {
    Loaded(DocumentChunk),
    Unloaded { byte_range: Range<usize> },
    Loading,
}

pub struct DocumentChunk {
    pub id: ChunkId,
    pub content: String,
    pub byte_range: Range<usize>,
    pub section_hint: Option<String>,
}

/// Handles large documents (>1MB) with lazy chunk loading
pub struct ChunkedDocument {
    header: DocumentHeader,
    chunks: HashMap<ChunkId, ChunkState>,
    chunk_cache: LruCache<ChunkId, DocumentChunk>,
    loader: Arc<dyn ChunkLoader>,
    config: ChunkingConfig,
}

pub trait ChunkLoader: Send + Sync {
    fn load_chunk(&self, chunk_id: &ChunkId) -> Result<DocumentChunk, DocumentError>;
}

impl ChunkedDocument {
    pub fn new(header: DocumentHeader, loader: Arc<dyn ChunkLoader>, config: ChunkingConfig) -> Self {
        let cache_size = NonZeroUsize::new(config.max_cached_chunks).unwrap();
        Self {
            header,
            chunks: HashMap::new(),
            chunk_cache: LruCache::new(cache_size),
            loader,
            config,
        }
    }

    /// Check if document should use chunking
    pub fn should_chunk(document_size: usize, config: &ChunkingConfig) -> bool {
        document_size > config.large_document_threshold
    }

    /// Get content for a byte range, loading chunks as needed
    pub fn get_range(&mut self, range: Range<usize>) -> Result<String, DocumentError> {
        let needed_chunks = self.chunks_for_range(&range);
        let mut result = String::new();

        for chunk_id in needed_chunks {
            let chunk = self.ensure_loaded(&chunk_id)?;

            // Calculate overlap with requested range
            let chunk_start = chunk.byte_range.start.max(range.start);
            let chunk_end = chunk.byte_range.end.min(range.end);

            if chunk_start < chunk_end {
                let local_start = chunk_start - chunk.byte_range.start;
                let local_end = chunk_end - chunk.byte_range.start;
                result.push_str(&chunk.content[local_start..local_end]);
            }
        }

        Ok(result)
    }

    fn chunks_for_range(&self, range: &Range<usize>) -> Vec<ChunkId> {
        self.chunks
            .iter()
            .filter_map(|(id, state)| {
                let byte_range = match state {
                    ChunkState::Loaded(c) => &c.byte_range,
                    ChunkState::Unloaded { byte_range } => byte_range,
                    ChunkState::Loading => return None,
                };

                // Check for overlap
                if byte_range.start < range.end && byte_range.end > range.start {
                    Some(id.clone())
                } else {
                    None
                }
            })
            .collect()
    }

    fn ensure_loaded(&mut self, chunk_id: &ChunkId) -> Result<&DocumentChunk, DocumentError> {
        // Check cache first
        if self.chunk_cache.contains(chunk_id) {
            return Ok(self.chunk_cache.get(chunk_id).unwrap());
        }

        // Load chunk
        let chunk = self.loader.load_chunk(chunk_id)?;
        self.chunk_cache.put(chunk_id.clone(), chunk);

        Ok(self.chunk_cache.get(chunk_id).unwrap())
    }
}
```

### Cache Manager

```rust
// cache.rs

use std::sync::RwLock;
use lru::LruCache;
use std::num::NonZeroUsize;
use std::time::{Duration, Instant};

pub struct CacheConfig {
    pub render_cache_max_bytes: usize,   // 100 MB
    pub parse_cache_max_entries: usize,  // 10 entries
    pub history_cache_ttl: Duration,     // 60 seconds
}

impl Default for CacheConfig {
    fn default() -> Self {
        Self {
            render_cache_max_bytes: 100 * 1024 * 1024,
            parse_cache_max_entries: 10,
            history_cache_ttl: Duration::from_secs(60),
        }
    }
}

pub struct CacheManager {
    render_cache: RwLock<RenderCache>,
    parse_cache: RwLock<LruCache<String, ParsedDocument>>,
    history_cache: RwLock<HistoryCache>,
    config: CacheConfig,
}

pub struct RenderCache {
    entries: LruCache<String, RenderCacheEntry>,
    total_bytes: usize,
    max_bytes: usize,
}

struct RenderCacheEntry {
    pdf_data: Vec<u8>,
    source_hash: String,
}

pub struct HistoryCache {
    snapshots: Option<(Vec<Snapshot>, Instant)>,
    ttl: Duration,
}

impl CacheManager {
    pub fn new(config: CacheConfig) -> Self {
        Self {
            render_cache: RwLock::new(RenderCache {
                entries: LruCache::new(NonZeroUsize::new(100).unwrap()),
                total_bytes: 0,
                max_bytes: config.render_cache_max_bytes,
            }),
            parse_cache: RwLock::new(LruCache::new(
                NonZeroUsize::new(config.parse_cache_max_entries).unwrap()
            )),
            history_cache: RwLock::new(HistoryCache {
                snapshots: None,
                ttl: config.history_cache_ttl,
            }),
            config,
        }
    }

    pub fn get_render(&self, source_hash: &str) -> Option<Vec<u8>> {
        let cache = self.render_cache.read().unwrap();
        cache.entries.peek(source_hash).map(|e| e.pdf_data.clone())
    }

    pub fn put_render(&self, source_hash: String, pdf_data: Vec<u8>) {
        let mut cache = self.render_cache.write().unwrap();

        // Evict if needed
        while cache.total_bytes + pdf_data.len() > cache.max_bytes {
            if let Some((_, evicted)) = cache.entries.pop_lru() {
                cache.total_bytes -= evicted.pdf_data.len();
            } else {
                break;
            }
        }

        cache.total_bytes += pdf_data.len();
        cache.entries.put(source_hash.clone(), RenderCacheEntry {
            pdf_data,
            source_hash,
        });
    }

    pub fn get_history(&self) -> Option<Vec<Snapshot>> {
        let cache = self.history_cache.read().unwrap();
        cache.snapshots.as_ref().and_then(|(snapshots, cached_at)| {
            if cached_at.elapsed() < cache.ttl {
                Some(snapshots.clone())
            } else {
                None
            }
        })
    }

    pub fn put_history(&self, snapshots: Vec<Snapshot>) {
        let mut cache = self.history_cache.write().unwrap();
        cache.snapshots = Some((snapshots, Instant::now()));
    }

    pub fn invalidate_history(&self) {
        let mut cache = self.history_cache.write().unwrap();
        cache.snapshots = None;
    }
}
```

### Crate Structure

```
imprint-core/
├── Cargo.toml
├── src/
│   ├── lib.rs
│   ├── capabilities/          # Trait definitions
│   │   ├── mod.rs
│   │   ├── content.rs         # DocumentContent trait
│   │   ├── syncable.rs        # Syncable trait
│   │   ├── versionable.rs     # Versionable trait
│   │   ├── restorable.rs      # Restorable trait
│   │   ├── commentable.rs     # Commentable trait
│   │   ├── renderable.rs      # Renderable trait
│   │   └── exportable.rs      # Exportable trait
│   ├── error.rs               # Structured errors (thiserror)
│   ├── cache.rs               # CacheManager
│   └── telemetry.rs           # Optional telemetry hooks
│
├── crates/
│   ├── imprint-document/
│   │   ├── src/
│   │   │   ├── lib.rs
│   │   │   ├── document.rs    # Core ImprintDocument (DocumentContent only)
│   │   │   ├── chunking.rs    # Large document handling
│   │   │   ├── automerge.rs   # CRDT operations
│   │   │   ├── history.rs     # Implements Versionable/Restorable
│   │   │   ├── comments.rs    # Implements Commentable
│   │   │   └── schema.rs      # Document schema
│   │   └── Cargo.toml
│   │
│   ├── imprint-sync/
│   │   ├── src/
│   │   │   ├── lib.rs
│   │   │   ├── manager.rs     # SyncManager implements Syncable
│   │   │   ├── personal.rs    # iCloud file sync handling
│   │   │   ├── collaboration.rs  # Multi-user sync protocol
│   │   │   ├── presence.rs    # Cursor/selection awareness
│   │   │   └── conflict.rs    # Conflict detection & merge
│   │   └── Cargo.toml
│   │
│   ├── imprint-render/
│   │   ├── src/
│   │   │   ├── lib.rs
│   │   │   ├── service.rs     # RenderService implements Renderable
│   │   │   ├── typst.rs       # Typst compiler wrapper
│   │   │   ├── incremental.rs # Incremental compilation
│   │   │   ├── templates/     # Journal templates
│   │   │   │   ├── mod.rs
│   │   │   │   ├── mnras.rs
│   │   │   │   ├── apj.rs
│   │   │   │   └── aanda.rs
│   │   │   └── export/        # Implements Exportable
│   │   │       ├── mod.rs
│   │   │       ├── pdf.rs
│   │   │       └── latex.rs   # Typst → LaTeX converter
│   │   └── Cargo.toml
│   │
│   ├── imprint-invitation/
│   │   ├── src/
│   │   │   ├── lib.rs
│   │   │   ├── create.rs      # Invitation generation
│   │   │   ├── validate.rs    # Identity verification
│   │   │   ├── redeem.rs      # Acceptance flow
│   │   │   ├── permissions.rs # Permission model
│   │   │   ├── password.rs    # Argon2id hashing
│   │   │   ├── rate_limit.rs  # Rate limiting
│   │   │   ├── storage.rs     # Encrypted storage
│   │   │   └── secure_link.rs # Tier 3 anonymous links
│   │   └── Cargo.toml
│   │
│   ├── imprint-imbib/
│   │   ├── src/
│   │   │   ├── lib.rs
│   │   │   ├── library.rs     # Access imbib library
│   │   │   ├── citations.rs   # Citation formatting
│   │   │   └── bibtex.rs      # BibTeX generation
│   │   └── Cargo.toml
│   │
│   └── imprint-ffi/
│       ├── src/
│       │   ├── lib.rs
│       │   ├── session.rs     # ImprintSession facade
│       │   └── thread_safe.rs # ThreadSafeSession wrapper
│       ├── imprint.udl        # UniFFI interface definition
│       └── Cargo.toml
│
└── tests/
    ├── integration/
    ├── property/              # Property-based tests (proptest)
    ├── chaos/                 # Chaos sync tests
    └── offline/               # Offline simulation tests
```

### Key Rust Interfaces

```rust
// imprint-document/src/document.rs

use automerge::{AutoCommit, ObjId, Value};
use crate::capabilities::DocumentContent;

/// Core document representation (implements DocumentContent only)
pub struct ImprintDocument {
    /// Automerge document (CRDT state)
    crdt: AutoCommit,

    /// Document metadata
    metadata: DocumentMetadata,

    /// Local user info
    local_user: UserIdentity,
}

impl DocumentContent for ImprintDocument {
    fn source(&self) -> String {
        // Extract source from CRDT
        self.crdt.get(ROOT, "source")
            .ok()
            .flatten()
            .map(|(v, _)| v.to_str().unwrap_or_default().to_string())
            .unwrap_or_default()
    }

    fn edit(&mut self, range: Range<usize>, text: &str) -> ChangeSet {
        // Apply edit to CRDT text object
        let source_id = self.crdt.get(ROOT, "source").unwrap().unwrap().1;
        self.crdt.splice_text(&source_id, range.start, range.len() as isize, text).unwrap();

        ChangeSet {
            ranges: vec![range],
            text: text.to_string(),
        }
    }

    fn metadata(&self) -> &DocumentMetadata {
        &self.metadata
    }
}

impl ImprintDocument {
    /// Create new empty document
    pub fn new(title: &str, user: UserIdentity) -> Self {
        let mut crdt = AutoCommit::new();
        crdt.put(ROOT, "source", "").unwrap();
        crdt.put(ROOT, "title", title).unwrap();

        Self {
            crdt,
            metadata: DocumentMetadata {
                id: DocumentId::new(),
                title: title.to_string(),
                created_at: Utc::now(),
                modified_at: Utc::now(),
                owner: user.clone(),
                collaborators: vec![],
                template: None,
            },
            local_user: user,
        }
    }

    /// Load from .imprint package
    pub fn load(path: &Path) -> Result<Self, DocumentError> {
        let automerge_path = path.join("document.automerge");
        let data = std::fs::read(&automerge_path)
            .map_err(|e| DocumentError::NotFound { path: path.display().to_string() })?;

        let crdt = AutoCommit::load(&data)
            .map_err(|e| DocumentError::InvalidFormat { details: e.to_string() })?;

        // Load metadata
        let metadata = Self::load_metadata(&crdt)?;
        let local_user = Self::load_local_user(path)?;

        Ok(Self { crdt, metadata, local_user })
    }

    /// Save to .imprint package
    pub fn save(&self, path: &Path) -> Result<(), DocumentError> {
        std::fs::create_dir_all(path)
            .map_err(|e| DocumentError::SaveFailed {
                path: path.display().to_string(),
                reason: "failed to create directory".to_string(),
                source: Some(e),
            })?;

        let automerge_path = path.join("document.automerge");
        let data = self.crdt.save();

        std::fs::write(&automerge_path, data)
            .map_err(|e| DocumentError::SaveFailed {
                path: automerge_path.display().to_string(),
                reason: "failed to write file".to_string(),
                source: Some(e),
            })?;

        Ok(())
    }

    /// Insert citation from imbib
    pub fn insert_citation(&mut self, position: usize, cite_key: &str) -> ChangeSet {
        let citation_text = format!("@{}", cite_key);
        self.edit(position..position, &citation_text)
    }

    /// Get raw CRDT for sync operations
    pub(crate) fn crdt(&self) -> &AutoCommit {
        &self.crdt
    }

    /// Get mutable CRDT for sync operations
    pub(crate) fn crdt_mut(&mut self) -> &mut AutoCommit {
        &mut self.crdt
    }
}

/// Document metadata
pub struct DocumentMetadata {
    pub id: DocumentId,
    pub title: String,
    pub created_at: DateTime<Utc>,
    pub modified_at: DateTime<Utc>,
    pub owner: UserIdentity,
    pub collaborators: Vec<Collaborator>,
    pub template: Option<JournalTemplate>,
}

/// Collaborator with permissions
pub struct Collaborator {
    pub identity: UserIdentity,
    pub permissions: Permissions,
    pub added_at: DateTime<Utc>,
    pub added_by: UserIdentity,
}

/// Permission flags
bitflags! {
    pub struct Permissions: u32 {
        const VIEW    = 0b00000001;
        const COMMENT = 0b00000010;
        const EDIT    = 0b00000100;
        const SHARE   = 0b00001000;
        const ADMIN   = 0b00010000;

        const REVIEWER = Self::VIEW.bits | Self::COMMENT.bits;
        const AUTHOR   = Self::VIEW.bits | Self::COMMENT.bits | Self::EDIT.bits;
        const COAUTHOR = Self::AUTHOR.bits | Self::SHARE.bits;
    }
}
```

### UniFFI Interface Definition

```
// imprint-ffi/imprint.udl

namespace imprint {
    // Initialization
    void init_logging(LogLevel level);
};

[Error]
enum ImprintError {
    "DocumentNotFound",
    "DocumentSaveFailed",
    "InvalidFormat",
    "ReadOnly",
    "SyncGenerationFailed",
    "SyncInvalidMessage",
    "SyncMergeConflict",
    "RenderCompilationError",
    "RenderTimeout",
    "RenderMissingResource",
    "HistorySnapshotNotFound",
    "HistorySectionNotFound",
    "HistoryRestoreFailed",
    "ExportUnsupportedTemplate",
    "ExportFailed",
    "InvitationExpired",
    "InvitationRevoked",
    "WrongRecipient",
    "InvalidVerificationCode",
    "RateLimited",
    "InvalidPassword",
    "MaxViewsExceeded",
};

// --- Session (Facade) ---

interface ImprintSession {
    [Throws=ImprintError]
    constructor(string title, UserIdentity user);

    [Throws=ImprintError, Name=load]
    constructor(string path);

    [Throws=ImprintError]
    void save(string path);

    // DocumentContent
    string source();
    void edit(u64 start, u64 end, string text);
    DocumentMetadata metadata();
    void set_title(string title);

    // Syncable
    SyncMessage? generate_sync_message(string peer_id);
    [Throws=ImprintError]
    void receive_sync_message(SyncMessage message);
    void merge(ImprintSession other);

    // Versionable
    VersionTimeline history();
    [Throws=ImprintError]
    string content_at(string snapshot_id);
    [Throws=ImprintError]
    sequence<DiffHunk> diff(string from_id, string to_id);

    // Restorable
    [Throws=ImprintError]
    void restore(string snapshot_id);
    [Throws=ImprintError]
    void restore_section(string section, string snapshot_id);

    // Commentable
    string add_comment(u64 start, u64 end, string text, string author_id);
    string reply_to_comment(string parent_id, string text, string author_id);
    void resolve_comment(string comment_id, string resolver_id);
    sequence<Comment> comments();

    // Renderable
    [Throws=ImprintError]
    bytes render_pdf();

    // Exportable
    [Throws=ImprintError]
    string export_latex(JournalTemplate template);
    string export_typst();
};

// --- Thread-Safe Session ---

interface ThreadSafeSession {
    [Throws=ImprintError]
    constructor(ImprintSession session, ImprintDelegate delegate);

    string source();
    [Throws=ImprintError]
    void edit(u64 start, u64 end, string text);

    // ... other methods mirror ImprintSession
};

callback interface ImprintDelegate {
    void on_document_changed(sequence<TextRange> changed_ranges);
    void on_presence_changed(string user_id, u64? cursor_position);
    void on_sync_status_changed(SyncStatus status);
};

// --- Invitation ---

interface InvitationManager {
    constructor();

    [Throws=ImprintError]
    Invitation create_invitation(
        string document_id,
        string recipient_email,
        Permissions permissions,
        u64? expires_in_seconds
    );

    [Throws=ImprintError]
    SecureLink create_secure_link(
        string document_id,
        SecureLinkType link_type,
        string? password,
        u64? expires_in_seconds,
        u32? max_views
    );

    [Throws=ImprintError]
    InvitationValidation validate_invitation(
        string key,
        string user_record_id,
        string user_email
    );

    [Throws=ImprintError]
    SecureLinkValidation validate_secure_link(
        string key,
        string? password
    );
};

// --- Types ---

dictionary UserIdentity {
    string id;
    string display_name;
    string email;
    string? apple_user_record_id;
};

dictionary TextRange {
    u64 start;
    u64 end;
};

dictionary SyncMessage {
    bytes payload;
    string sender_id;
    i64 timestamp;
};

dictionary VersionTimeline {
    sequence<Snapshot> snapshots;
    sequence<Snapshot> significant_moments;
};

dictionary Snapshot {
    string id;
    i64 timestamp;
    string author;
    string description;
    SnapshotType snapshot_type;
};

enum SnapshotType {
    "SessionStart",
    "SessionEnd",
    "LargeEdit",
    "SectionChange",
    "CollaboratorJoined",
    "ManualCheckpoint",
};

dictionary DiffHunk {
    u64 start;
    u64 end;
    string old_text;
    string new_text;
    string author;
};

dictionary Comment {
    string id;
    u64 range_start;
    u64 range_end;
    string author_id;
    string author_name;
    string text;
    i64 timestamp;
    boolean resolved;
    sequence<Comment> replies;
};

dictionary Invitation {
    string id;
    string key;
    string document_id;
    string url;
    string? verification_code;
    i64 expires_at;
};

enum SecureLinkType {
    "ViewOnly",
    "ViewAndComment",
};

dictionary SecureLink {
    string id;
    string key;
    string url;
    SecureLinkType link_type;
    i64? expires_at;
    u32? max_views;
};

[Enum]
interface InvitationValidation {
    Valid(string document_id, Permissions permissions);
    RequiresVerificationCode();
    Invalid(string reason);
};

[Enum]
interface SecureLinkValidation {
    Valid(string document_id, SecureLinkType access_type);
    RequiresPassword();
    Invalid(string reason);
};

enum SyncStatus {
    "Synced",
    "Syncing",
    "Offline",
    "Conflict",
};

enum JournalTemplate {
    "MNRAS",
    "ApJ",
    "AandA",
    "PhysRevD",
    "JCAP",
    "Generic",
};

enum Permissions {
    "View",
    "Comment",
    "Edit",
    "Share",
    "Admin",
    "Reviewer",
    "Author",
    "CoAuthor",
};

enum LogLevel {
    "Error",
    "Warn",
    "Info",
    "Debug",
    "Trace",
};
```

## Swift UI Layer

### Project Structure

```
imprint/
├── imprint.xcodeproj
├── Shared/                       # Shared code (macOS + iOS)
│   ├── ImprintApp.swift
│   ├── Models/
│   │   ├── ImprintDocument.swift     # ObservableObject wrapping Rust
│   │   ├── Collaborator.swift
│   │   └── Preferences.swift
│   ├── Services/
│   │   ├── SyncService.swift         # iCloud + CloudKit coordination
│   │   ├── InvitationService.swift   # Invitation handling
│   │   └── ImbibService.swift        # imbib library access
│   └── Utilities/
│       ├── RustBridge.swift          # UniFFI generated + extensions
│       └── KeychainManager.swift
│
├── macOS/                        # macOS-specific
│   ├── AppDelegate.swift
│   ├── MainWindow.swift
│   ├── Views/
│   │   ├── EditorView.swift          # Main editor (NSTextView-backed)
│   │   ├── PDFPreviewView.swift      # PDF preview (PDFKit)
│   │   ├── OutlineView.swift         # Document outline
│   │   ├── CommentsPanel.swift       # Comments sidebar
│   │   ├── TimeMachineView.swift     # Version history
│   │   ├── InvitationSheet.swift     # Create invitation
│   │   └── CollaboratorsPanel.swift  # Manage collaborators
│   ├── Editor/
│   │   ├── TypstTextView.swift       # Custom NSTextView subclass
│   │   ├── SyntaxHighlighter.swift   # Typst syntax highlighting
│   │   └── CompletionProvider.swift  # Autocomplete
│   └── Resources/
│       └── MainMenu.xib
│
├── iOS/                          # iOS/iPad-specific
│   ├── Views/
│   │   ├── DocumentBrowserView.swift # Document picker
│   │   ├── EditorView.swift          # iOS editor
│   │   ├── SplitEditorView.swift     # iPad split view
│   │   └── CompactCommentsView.swift # Comments for iPhone
│   └── Resources/
│
└── Packages/
    └── ImprintCore/              # Swift package wrapping Rust
        ├── Package.swift
        └── Sources/
            └── ImprintCore/
                ├── Generated/        # UniFFI generated
                └── Extensions/       # Swift conveniences
```

### Swift Document Wrapper (Full @MainActor Isolation)

```swift
// Shared/Models/ImprintDocument.swift

import Foundation
import Combine
import ImprintCore

@MainActor
final class ImprintDocumentModel: ObservableObject {
    // MARK: - Published State

    @Published private(set) var source: String = ""
    @Published private(set) var pdfData: Data?
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var collaborators: [Collaborator] = []
    @Published private(set) var versionHistory: VersionTimeline?
    @Published private(set) var syncStatus: SyncStatus = .synced
    @Published private(set) var renderStatus: RenderStatus = .idle

    // MARK: - Rust Core (Thread-Safe)

    private let rustSession: ThreadSafeSession
    private let syncService: SyncService
    private var renderTask: Task<Void, Never>?

    // MARK: - Initialization

    init(url: URL) throws {
        let session = try ImprintSession.load(path: url.path)
        self.rustSession = try ThreadSafeSession(session: session, delegate: SessionDelegate())
        self.syncService = SyncService(documentId: rustSession.metadata().id)

        loadInitialState()
        setupSyncObserver()
    }

    init(title: String, user: UserIdentity) throws {
        let session = try ImprintSession(title: title, user: user)
        self.rustSession = try ThreadSafeSession(session: session, delegate: SessionDelegate())
        self.syncService = SyncService(documentId: rustSession.metadata().id)

        loadInitialState()
        setupSyncObserver()
    }

    private func loadInitialState() {
        source = rustSession.source()
        comments = rustSession.comments()
        versionHistory = rustSession.history()

        Task { await render() }
    }

    // MARK: - Editing

    func edit(range: Range<Int>, replacement: String) {
        // Optimistic local update for responsiveness
        let oldSource = source
        source = oldSource.replacingSubrange(
            oldSource.index(oldSource.startIndex, offsetBy: range.lowerBound)..<oldSource.index(oldSource.startIndex, offsetBy: range.upperBound),
            with: replacement
        )

        // Background Rust call
        Task.detached { [rustSession] in
            try? rustSession.edit(
                UInt64(range.lowerBound),
                UInt64(range.upperBound),
                replacement
            )
        }

        // Broadcast to collaborators
        Task.detached { [rustSession, syncService] in
            if let syncMessage = rustSession.generateSyncMessage(peerId: "all") {
                await syncService.broadcast(syncMessage)
            }
        }

        // Trigger incremental render
        scheduleRender()
    }

    // MARK: - Rendering

    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task {
            // Debounce: wait for typing pause
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

            guard !Task.isCancelled else { return }
            await render()
        }
    }

    private func render() async {
        renderStatus = .rendering

        do {
            let pdf = try await Task.detached { [rustSession] in
                try rustSession.renderPdf()
            }.value
            pdfData = Data(pdf)
            renderStatus = .idle
        } catch {
            renderStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Comments

    func addComment(range: Range<Int>, text: String) {
        let userId = rustSession.metadata().owner.id
        _ = rustSession.addComment(
            UInt64(range.lowerBound),
            UInt64(range.upperBound),
            text,
            authorId: userId
        )
        comments = rustSession.comments()

        Task.detached { [rustSession, syncService] in
            if let syncMessage = rustSession.generateSyncMessage(peerId: "all") {
                await syncService.broadcast(syncMessage)
            }
        }
    }

    func replyToComment(_ parentId: String, text: String) {
        let userId = rustSession.metadata().owner.id
        _ = rustSession.replyToComment(parentId: parentId, text: text, authorId: userId)
        comments = rustSession.comments()

        Task.detached { [rustSession, syncService] in
            if let syncMessage = rustSession.generateSyncMessage(peerId: "all") {
                await syncService.broadcast(syncMessage)
            }
        }
    }

    func resolveComment(_ commentId: String) {
        let userId = rustSession.metadata().owner.id
        rustSession.resolveComment(commentId: commentId, resolverId: userId)
        comments = rustSession.comments()

        Task.detached { [rustSession, syncService] in
            if let syncMessage = rustSession.generateSyncMessage(peerId: "all") {
                await syncService.broadcast(syncMessage)
            }
        }
    }

    // MARK: - Version History (Paper Time Machine)

    func refreshHistory() {
        versionHistory = rustSession.history()
    }

    func contentAt(snapshot: Snapshot) throws -> String {
        try rustSession.contentAt(snapshotId: snapshot.id)
    }

    func diff(from: Snapshot, to: Snapshot) throws -> [DiffHunk] {
        try rustSession.diff(fromId: from.id, toId: to.id)
    }

    func restore(to snapshot: Snapshot) throws {
        try rustSession.restore(snapshotId: snapshot.id)
        source = rustSession.source()

        Task.detached { [rustSession, syncService] in
            if let syncMessage = rustSession.generateSyncMessage(peerId: "all") {
                await syncService.broadcast(syncMessage)
            }
        }
        Task { await render() }
    }

    func restoreSection(_ section: String, from snapshot: Snapshot) throws {
        try rustSession.restoreSection(section: section, snapshotId: snapshot.id)
        source = rustSession.source()

        Task.detached { [rustSession, syncService] in
            if let syncMessage = rustSession.generateSyncMessage(peerId: "all") {
                await syncService.broadcast(syncMessage)
            }
        }
        Task { await render() }
    }

    // MARK: - Export

    func exportLaTeX(template: JournalTemplate) throws -> String {
        try rustSession.exportLatex(template: template)
    }

    func exportTypst() -> String {
        rustSession.exportTypst()
    }

    func exportPDF() -> Data? {
        pdfData
    }

    // MARK: - Sync

    private func setupSyncObserver() {
        syncService.onRemoteChange = { [weak self] message in
            Task { @MainActor in
                self?.handleRemoteChange(message)
            }
        }
    }

    private func handleRemoteChange(_ message: SyncMessage) {
        do {
            try rustSession.receiveSyncMessage(message: message)
            source = rustSession.source()
            comments = rustSession.comments()
            versionHistory = rustSession.history()
            Task { await render() }
        } catch {
            print("Sync error: \(error)")
        }
    }

    // MARK: - Persistence

    func save(to url: URL) throws {
        try rustSession.save(path: url.path)
    }
}

// MARK: - Session Delegate

private class SessionDelegate: ImprintDelegate {
    func onDocumentChanged(changedRanges: [TextRange]) {
        // Handled via optimistic updates
    }

    func onPresenceChanged(userId: String, cursorPosition: UInt64?) {
        // Update collaborator cursors
    }

    func onSyncStatusChanged(status: SyncStatus) {
        // Update sync status
    }
}

// MARK: - Supporting Types

enum RenderStatus: Equatable {
    case idle
    case rendering
    case error(String)
}
```

### Platform-Specific Views

```swift
// macOS/Views/MainWindow.swift

import SwiftUI

struct MainWindowView: View {
    @StateObject private var document: ImprintDocumentModel
    @State private var showingOutline = true
    @State private var showingComments = true
    @State private var showingTimeMachine = false

    var body: some View {
        NavigationSplitView {
            // Outline sidebar
            if showingOutline {
                OutlineView(document: document)
                    .frame(minWidth: 200)
            }
        } detail: {
            HSplitView {
                // Editor
                EditorView(document: document)
                    .frame(minWidth: 400)

                // PDF Preview
                PDFPreviewView(data: document.pdfData)
                    .frame(minWidth: 300)

                // Comments panel
                if showingComments {
                    CommentsPanel(document: document)
                        .frame(width: 280)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: { showingOutline.toggle() }) {
                    Image(systemName: "sidebar.left")
                }

                Button(action: { showingComments.toggle() }) {
                    Image(systemName: "text.bubble")
                }

                Divider()

                Button(action: { showingTimeMachine = true }) {
                    Image(systemName: "clock.arrow.circlepath")
                }

                ShareButton(document: document)
            }
        }
        .sheet(isPresented: $showingTimeMachine) {
            TimeMachineView(document: document)
        }
    }
}
```

```swift
// iOS/Views/DocumentView.swift

import SwiftUI

struct DocumentView: View {
    @StateObject private var document: ImprintDocumentModel
    @State private var mode: ViewMode = .editor
    @Environment(\.horizontalSizeClass) var sizeClass

    enum ViewMode {
        case editor
        case preview
        case split
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: Split view
                iPadLayout
            } else {
                // iPhone: Tab-based
                iPhoneLayout
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Share...", systemImage: "square.and.arrow.up") {
                        // Show share sheet
                    }
                    Button("Export PDF", systemImage: "doc.fill") {
                        // Export
                    }
                    Button("Export LaTeX", systemImage: "doc.text") {
                        // Export LaTeX
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder
    var iPadLayout: some View {
        HStack(spacing: 0) {
            EditorView(document: document)

            Divider()

            PDFPreviewView(data: document.pdfData)
        }
    }

    @ViewBuilder
    var iPhoneLayout: some View {
        TabView(selection: $mode) {
            EditorView(document: document)
                .tabItem { Label("Edit", systemImage: "pencil") }
                .tag(ViewMode.editor)

            PDFPreviewView(data: document.pdfData)
                .tabItem { Label("Preview", systemImage: "doc.richtext") }
                .tag(ViewMode.preview)

            CompactCommentsView(document: document)
                .tabItem { Label("Comments", systemImage: "text.bubble") }
        }
    }
}
```

## Synchronization Architecture

### Personal Sync (iCloud Drive)

```swift
// Shared/Services/SyncService.swift

import Foundation
import CloudKit

actor SyncService {
    let documentId: String
    private var filePresenter: DocumentFilePresenter?
    private var cloudKitSubscription: CKSubscription?

    var onRemoteChange: ((SyncMessage) -> Void)?

    // MARK: - Personal Sync (iCloud Drive)

    func startFileMonitoring(url: URL) {
        filePresenter = DocumentFilePresenter(url: url) { [weak self] in
            Task { await self?.handleFileChange(at: url) }
        }
        NSFileCoordinator.addFilePresenter(filePresenter!)
    }

    private func handleFileChange(at url: URL) async {
        // iCloud updated the file - load and merge
        let coordinator = NSFileCoordinator(filePresenter: filePresenter)
        var error: NSError?

        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { newURL in
            do {
                let data = try Data(contentsOf: newURL.appendingPathComponent("document.automerge"))
                let message = SyncMessage(payload: [UInt8](data), senderId: "icloud", timestamp: Int64(Date().timeIntervalSince1970))
                onRemoteChange?(message)
            } catch {
                print("Failed to read iCloud update: \(error)")
            }
        }
    }

    // MARK: - Collaboration Sync (CloudKit)

    func startCollaborationSync() async throws {
        let container = CKContainer(identifier: "iCloud.com.imbib.imprint")

        // Subscribe to sync messages for this document
        let predicate = NSPredicate(format: "documentId == %@", documentId)
        let subscription = CKQuerySubscription(
            recordType: "SyncMessage",
            predicate: predicate,
            options: [.firesOnRecordCreation]
        )

        let notification = CKSubscription.NotificationInfo()
        notification.shouldSendContentAvailable = true
        subscription.notificationInfo = notification

        try await container.privateCloudDatabase.save(subscription)
        cloudKitSubscription = subscription
    }

    func broadcast(_ message: SyncMessage?) async {
        guard let message = message else { return }

        // Save to CloudKit for collaborators
        let container = CKContainer(identifier: "iCloud.com.imbib.imprint")
        let record = CKRecord(recordType: "SyncMessage")
        record["documentId"] = documentId
        record["payload"] = Data(message.payload)
        record["senderId"] = message.senderId
        record["timestamp"] = Date()

        try? await container.sharedCloudDatabase.save(record)
    }

    func handleCloudKitNotification(_ notification: CKQueryNotification) async {
        guard let recordId = notification.recordID else { return }

        let container = CKContainer(identifier: "iCloud.com.imbib.imprint")

        do {
            let record = try await container.sharedCloudDatabase.record(for: recordId)

            guard let payload = record["payload"] as? Data,
                  let senderId = record["senderId"] as? String else { return }

            let message = SyncMessage(
                payload: [UInt8](payload),
                senderId: senderId,
                timestamp: Int64(Date().timeIntervalSince1970)
            )

            onRemoteChange?(message)
        } catch {
            print("Failed to fetch CloudKit record: \(error)")
        }
    }
}
```

### Invitation Flow (Tier 1 & Tier 3)

```swift
// Shared/Services/InvitationService.swift

import Foundation
import CloudKit
import ImprintCore

@MainActor
class InvitationService: ObservableObject {
    private let manager = InvitationManager()
    private let container = CKContainer(identifier: "iCloud.com.imbib.imprint")

    // MARK: - Tier 1: Apple ID Invitation

    func createInvitation(
        documentId: String,
        recipientEmail: String,
        permissions: Permissions
    ) async throws -> InvitationResult {
        // Create in Rust core
        let invitation = try manager.createInvitation(
            documentId: documentId,
            recipientEmail: recipientEmail,
            permissions: permissions,
            expiresInSeconds: 7 * 24 * 3600
        )

        // Store in CloudKit for lookup
        let record = CKRecord(recordType: "Invitation")
        record["key"] = invitation.key
        record["documentId"] = documentId
        record["recipientEmailHash"] = recipientEmail.lowercased().sha256()
        record["permissions"] = permissions.rawValue
        record["expiresAt"] = Date(timeIntervalSince1970: TimeInterval(invitation.expiresAt))
        record["verificationCode"] = invitation.verificationCode

        try await container.publicCloudDatabase.save(record)

        return InvitationResult(
            url: URL(string: invitation.url)!,
            verificationCode: invitation.verificationCode
        )
    }

    // MARK: - Tier 3: Secure Link (No Account)

    func createSecureLink(
        documentId: String,
        type: SecureLinkType,
        password: String? = nil,
        expiresInDays: Int? = nil,
        maxViews: Int? = nil
    ) async throws -> SecureLinkResult {
        let expiresIn: UInt64? = expiresInDays.map { UInt64($0 * 24 * 3600) }

        let link = try manager.createSecureLink(
            documentId: documentId,
            linkType: type,
            password: password,
            expiresInSeconds: expiresIn,
            maxViews: maxViews.map { UInt32($0) }
        )

        // Store in CloudKit
        let record = CKRecord(recordType: "SecureLink")
        record["key"] = link.key
        record["documentId"] = documentId
        record["linkType"] = type.rawValue
        record["passwordHash"] = password?.sha256()
        record["expiresAt"] = link.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        record["maxViews"] = link.maxViews.map { Int($0) }
        record["viewCount"] = 0

        try await container.publicCloudDatabase.save(record)

        return SecureLinkResult(
            url: URL(string: link.url)!,
            type: type,
            hasPassword: password != nil
        )
    }

    // MARK: - Redeem Invitation (Tier 1)

    func redeemInvitation(
        key: String,
        verificationCode: String?
    ) async throws -> RedeemResult {
        // Get current user identity from CloudKit
        let userRecordId = try await container.fetchUserRecordID()
        let identity = try await container.discoverUserIdentity(withUserRecordID: userRecordId)

        guard let email = identity.lookupInfo?.emailAddress else {
            throw InvitationError.emailNotAvailable
        }

        // Validate in Rust core
        let validation = try manager.validateInvitation(
            key: key,
            userRecordId: userRecordId.recordName,
            userEmail: email
        )

        switch validation {
        case .valid(let documentId, let permissions):
            // Mark as redeemed in CloudKit
            try await markInvitationRedeemed(key: key, by: userRecordId.recordName)

            // Join the shared document
            let document = try await joinSharedDocument(documentId: documentId)

            return .success(document: document, permissions: permissions)

        case .requiresVerificationCode:
            guard let code = verificationCode else {
                return .needsVerificationCode
            }
            // Retry with code
            return try await redeemWithVerificationCode(key: key, code: code, userRecordId: userRecordId, email: email)

        case .invalid(let reason):
            return .failed(reason: reason)
        }
    }

    // MARK: - Validate Secure Link (Tier 3)

    func validateSecureLink(key: String, password: String?) async throws -> SecureLinkValidationResult {
        let validation = try manager.validateSecureLink(key: key, password: password)

        switch validation {
        case .valid(let documentId, let accessType):
            // Increment view count
            try await incrementViewCount(key: key)

            // Fetch read-only snapshot
            let snapshot = try await fetchDocumentSnapshot(documentId: documentId)

            return .valid(snapshot: snapshot, accessType: accessType)

        case .requiresPassword:
            return .needsPassword

        case .invalid(let reason):
            return .invalid(reason: reason)
        }
    }
}

// Supporting types
struct InvitationResult {
    let url: URL
    let verificationCode: String?
}

struct SecureLinkResult {
    let url: URL
    let type: SecureLinkType
    let hasPassword: Bool
}

enum RedeemResult {
    case success(document: ImprintDocumentModel, permissions: Permissions)
    case needsVerificationCode
    case failed(reason: String)
}

enum SecureLinkValidationResult {
    case valid(snapshot: DocumentSnapshot, accessType: SecureLinkType)
    case needsPassword
    case invalid(reason: String)
}
```

## Paper Time Machine UI

```swift
// macOS/Views/TimeMachineView.swift

import SwiftUI

struct TimeMachineView: View {
    @ObservedObject var document: ImprintDocumentModel
    @State private var selectedSnapshot: Snapshot?
    @State private var comparisonSnapshot: Snapshot?
    @State private var viewMode: ViewMode = .timeline
    @State private var sectionFilter: String?

    enum ViewMode {
        case timeline
        case sideBySide
        case inlineDiff
    }

    var body: some View {
        HSplitView {
            // Timeline sidebar
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("Version History")
                        .font(.headline)
                    Spacer()
                    Picker("Filter", selection: $sectionFilter) {
                        Text("All Sections").tag(nil as String?)
                        ForEach(document.sections, id: \.self) { section in
                            Text(section).tag(section as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                .padding()

                Divider()

                // Timeline
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredSnapshots) { snapshot in
                            TimelineRow(
                                snapshot: snapshot,
                                isSelected: snapshot.id == selectedSnapshot?.id,
                                isComparison: snapshot.id == comparisonSnapshot?.id
                            )
                            .onTapGesture {
                                selectSnapshot(snapshot)
                            }
                            .contextMenu {
                                Button("Compare from here") {
                                    comparisonSnapshot = snapshot
                                }
                                Button("Restore to this point...") {
                                    confirmRestore(to: snapshot)
                                }
                                if sectionFilter != nil {
                                    Button("Restore this section only...") {
                                        confirmRestoreSection(to: snapshot)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 280, maxWidth: 350)

            // Preview area
            VStack {
                // View mode picker
                Picker("View", selection: $viewMode) {
                    Image(systemName: "calendar").tag(ViewMode.timeline)
                    Image(systemName: "rectangle.split.2x1").tag(ViewMode.sideBySide)
                    Image(systemName: "text.badge.plus").tag(ViewMode.inlineDiff)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .padding()

                // Content
                switch viewMode {
                case .timeline:
                    if let snapshot = selectedSnapshot {
                        SnapshotPreview(
                            content: try? document.contentAt(snapshot: snapshot),
                            metadata: snapshot
                        )
                    } else {
                        ContentUnavailableView(
                            "Select a Version",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Click on a point in the timeline to preview that version")
                        )
                    }

                case .sideBySide:
                    SideBySideView(
                        left: comparisonSnapshot.flatMap { try? document.contentAt(snapshot: $0) } ?? document.source,
                        right: selectedSnapshot.flatMap { try? document.contentAt(snapshot: $0) } ?? document.source,
                        leftLabel: comparisonSnapshot?.description ?? "Current",
                        rightLabel: selectedSnapshot?.description ?? "Current"
                    )

                case .inlineDiff:
                    if let from = comparisonSnapshot, let to = selectedSnapshot,
                       let hunks = try? document.diff(from: from, to: to) {
                        InlineDiffView(hunks: hunks)
                    } else {
                        ContentUnavailableView(
                            "Select Two Versions",
                            systemImage: "arrow.left.arrow.right",
                            description: Text("Right-click a version and choose 'Compare from here', then select another version")
                        )
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    // Dismiss
                }
            }
        }
    }

    var filteredSnapshots: [Snapshot] {
        guard let timeline = document.versionHistory else { return [] }

        if sectionFilter != nil {
            // Filter to snapshots that affected this section
            return timeline.snapshots.filter { snapshot in
                // Check if this snapshot modified the filtered section
                true // TODO: Implement section filtering
            }
        }
        return timeline.snapshots
    }

    func selectSnapshot(_ snapshot: Snapshot) {
        withAnimation {
            selectedSnapshot = snapshot
        }
    }

    func confirmRestore(to snapshot: Snapshot) {
        // Show confirmation alert
    }

    func confirmRestoreSection(to snapshot: Snapshot) {
        guard let section = sectionFilter else { return }
        // Show confirmation alert
    }
}

struct TimelineRow: View {
    let snapshot: Snapshot
    let isSelected: Bool
    let isComparison: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Timeline dot
            ZStack {
                Circle()
                    .fill(dotColor)
                    .frame(width: dotSize, height: dotSize)

                if isSelected {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: dotSize + 6, height: dotSize + 6)
                }

                if isComparison {
                    Circle()
                        .stroke(Color.orange, lineWidth: 2)
                        .frame(width: dotSize + 6, height: dotSize + 6)
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.description)
                    .font(.subheadline)
                    .fontWeight(isSignificant ? .medium : .regular)

                HStack {
                    Text(snapshot.author)
                        .foregroundColor(.secondary)
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(snapshot.formattedDate)
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    var isSignificant: Bool {
        switch snapshot.snapshotType {
        case .sessionStart, .sessionEnd, .largeEdit, .sectionChange, .collaboratorJoined:
            return true
        default:
            return false
        }
    }

    var dotSize: CGFloat {
        isSignificant ? 12 : 8
    }

    var dotColor: Color {
        switch snapshot.snapshotType {
        case .sessionStart: return .green
        case .sessionEnd: return .gray
        case .largeEdit: return .blue
        case .sectionChange: return .purple
        case .collaboratorJoined: return .orange
        case .manualCheckpoint: return .red
        }
    }
}
```

## Build and Distribution

### Rust Build

```bash
# Build script: build-rust.sh

#!/bin/bash
set -e

RUST_DIR="imprint-core"
OUT_DIR="imprint/Packages/ImprintCore/Sources/ImprintCore"

cd "$RUST_DIR"

# Build for all Apple targets
cargo build --release --target aarch64-apple-darwin    # macOS Apple Silicon
cargo build --release --target x86_64-apple-darwin     # macOS Intel
cargo build --release --target aarch64-apple-ios       # iOS device
cargo build --release --target aarch64-apple-ios-sim   # iOS simulator

# Generate UniFFI bindings
cargo run --bin uniffi-bindgen generate \
    --library target/aarch64-apple-darwin/release/libimprint_core.dylib \
    --language swift \
    --out-dir "$OUT_DIR/Generated"

# Create XCFramework
xcodebuild -create-xcframework \
    -library target/aarch64-apple-darwin/release/libimprint_core.a -headers include/ \
    -library target/x86_64-apple-darwin/release/libimprint_core.a -headers include/ \
    -library target/aarch64-apple-ios/release/libimprint_core.a -headers include/ \
    -library target/aarch64-apple-ios-sim/release/libimprint_core.a -headers include/ \
    -output "$OUT_DIR/ImprintCore.xcframework"

echo "Build complete!"
```

### Swift Package

```swift
// Packages/ImprintCore/Package.swift

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ImprintCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "ImprintCore", targets: ["ImprintCore"]),
    ],
    targets: [
        .target(
            name: "ImprintCore",
            dependencies: ["ImprintCoreFFI"],
            path: "Sources/ImprintCore"
        ),
        .binaryTarget(
            name: "ImprintCoreFFI",
            path: "Sources/ImprintCore/ImprintCore.xcframework"
        ),
    ]
)
```

## Testing Strategy

```
┌─────────────────────────────────────────────────────────────────┐
│                        Testing Pyramid                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│                         ┌─────────┐                             │
│                         │   E2E   │  ← UI automation            │
│                        ─┴─────────┴─                            │
│                      ┌───────────────┐                          │
│                      │  Integration  │  ← Swift + Rust          │
│                     ─┴───────────────┴─                         │
│                   ┌───────────────────────┐                     │
│                   │     Rust Unit Tests   │  ← Core logic       │
│                  ─┴───────────────────────┴─                    │
│                                                                 │
│  Rust (cargo test):                                            │
│  • Document operations                                          │
│  • Automerge CRDT behavior                                      │
│  • Typst compilation                                            │
│  • LaTeX export                                                 │
│  • Invitation validation                                        │
│  • Password hashing (Argon2id)                                  │
│  • Rate limiting                                                │
│  • Encryption/decryption                                        │
│                                                                 │
│  Swift (XCTest):                                               │
│  • UniFFI bridge correctness                                    │
│  • CloudKit sync logic                                          │
│  • iCloud file coordination                                     │
│  • UI state management                                          │
│  • @MainActor isolation                                         │
│                                                                 │
│  E2E (XCUITest):                                               │
│  • Full editing flow                                            │
│  • Collaboration scenarios                                      │
│  • Export workflows                                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Property-Based Tests (proptest)

```rust
// tests/property/crdt_properties.rs

use proptest::prelude::*;

proptest! {
    /// CRDT edits are commutative: A then B = B then A
    #[test]
    fn edit_commutativity(
        initial in ".*",
        edit_a in (0usize..100, 0usize..100, ".*"),
        edit_b in (0usize..100, 0usize..100, ".*"),
    ) {
        let mut doc_ab = ImprintDocument::new("test", user());
        doc_ab.edit(0..0, &initial);

        let mut doc_ba = doc_ab.clone();

        // Apply A then B
        doc_ab.edit(edit_a.0..edit_a.1.min(doc_ab.source().len()), &edit_a.2);
        let sync_a = doc_ab.generate_sync_message(&PeerId::new());

        doc_ab.edit(edit_b.0..edit_b.1.min(doc_ab.source().len()), &edit_b.2);
        let sync_b = doc_ab.generate_sync_message(&PeerId::new());

        // Apply B then A to other doc
        doc_ba.edit(edit_b.0..edit_b.1.min(doc_ba.source().len()), &edit_b.2);
        doc_ba.edit(edit_a.0..edit_a.1.min(doc_ba.source().len()), &edit_a.2);

        // Sync should converge
        doc_ab.receive_sync_message(&sync_b).unwrap();
        doc_ba.receive_sync_message(&sync_a).unwrap();

        prop_assert_eq!(doc_ab.source(), doc_ba.source());
    }

    /// Merge is idempotent: merge(A, A) = A
    #[test]
    fn merge_idempotence(initial in ".*", edits in prop::collection::vec(".*", 1..10)) {
        let mut doc = ImprintDocument::new("test", user());
        doc.edit(0..0, &initial);

        for edit in edits {
            doc.edit(0..0, &edit);
        }

        let before = doc.source();
        doc.merge(&doc.clone());
        let after = doc.source();

        prop_assert_eq!(before, after);
    }

    /// History is preserved through merges
    #[test]
    fn history_preservation(edits in prop::collection::vec(".*", 1..20)) {
        let mut doc = ImprintDocument::new("test", user());

        for edit in &edits {
            doc.edit(0..0, edit);
        }

        let history_before = doc.history().snapshots.len();

        let mut other = doc.clone();
        other.edit(0..0, "extra");

        doc.merge(&other);

        // Original history should still be accessible
        let history_after = doc.history().snapshots.len();
        prop_assert!(history_after >= history_before);
    }
}
```

### Chaos Tests

```rust
// tests/chaos/sync_convergence.rs

/// Test sync convergence under adverse network conditions
#[tokio::test]
async fn sync_converges_with_message_drops() {
    let mut docs: Vec<ImprintDocument> = (0..5)
        .map(|i| ImprintDocument::new(&format!("doc_{}", i), user()))
        .collect();

    let mut rng = rand::thread_rng();

    // Simulate 100 rounds of edits with 30% message drop rate
    for round in 0..100 {
        // Random doc makes an edit
        let editor_idx = rng.gen_range(0..docs.len());
        let edit_pos = rng.gen_range(0..=docs[editor_idx].source().len());
        docs[editor_idx].edit(edit_pos..edit_pos, &format!("r{}", round));

        // Broadcast with drops
        let sync_msg = docs[editor_idx].generate_sync_message(&PeerId::new());

        for (i, doc) in docs.iter_mut().enumerate() {
            if i != editor_idx && rng.gen_bool(0.7) { // 70% delivery rate
                if let Some(ref msg) = sync_msg {
                    let _ = doc.receive_sync_message(msg);
                }
            }
        }
    }

    // Final sync round (reliable)
    for i in 0..docs.len() {
        let msg = docs[i].generate_sync_message(&PeerId::new());
        for j in 0..docs.len() {
            if i != j {
                if let Some(ref m) = msg {
                    let _ = docs[j].receive_sync_message(m);
                }
            }
        }
    }

    // All docs should converge
    let final_source = docs[0].source();
    for doc in &docs[1..] {
        assert_eq!(doc.source(), final_source, "Documents did not converge");
    }
}

/// Test with message reordering
#[tokio::test]
async fn sync_converges_with_reordering() {
    // Similar structure but with message queue that delivers out of order
}

/// Test with network partitions
#[tokio::test]
async fn sync_converges_after_partition() {
    // Two groups edit independently, then partition heals
}
```

### Offline Simulation Tests

```rust
// tests/offline/offline_edit_sync.rs

/// Simulate offline editing then sync on reconnect
#[tokio::test]
async fn offline_edits_sync_on_reconnect() {
    let mut doc_a = ImprintDocument::new("shared", user_a());
    let mut doc_b = doc_a.clone();

    // Both start with same content
    doc_a.edit(0..0, "Initial content\n");
    doc_b.receive_sync_message(&doc_a.generate_sync_message(&PeerId::new()).unwrap()).unwrap();

    assert_eq!(doc_a.source(), doc_b.source());

    // Simulate going offline - no sync messages exchanged

    // User A edits offline
    doc_a.edit(doc_a.source().len()..doc_a.source().len(), "A's offline edit 1\n");
    doc_a.edit(doc_a.source().len()..doc_a.source().len(), "A's offline edit 2\n");

    // User B edits offline (different section)
    doc_b.edit(0..0, "B's header\n");

    // Reconnect - exchange sync messages
    let sync_a = doc_a.generate_sync_message(&PeerId::new()).unwrap();
    let sync_b = doc_b.generate_sync_message(&PeerId::new()).unwrap();

    doc_a.receive_sync_message(&sync_b).unwrap();
    doc_b.receive_sync_message(&sync_a).unwrap();

    // Documents should converge with all edits preserved
    assert_eq!(doc_a.source(), doc_b.source());
    assert!(doc_a.source().contains("A's offline edit 1"));
    assert!(doc_a.source().contains("A's offline edit 2"));
    assert!(doc_a.source().contains("B's header"));
}
```

## Implementation Phases

### Phase 1: Foundation (Weeks 1-6)
- [ ] Rust workspace setup with crate structure
- [ ] Capability traits definition
- [ ] Automerge document model
- [ ] Typst rendering integration
- [ ] UniFFI bindings generation
- [ ] Basic macOS app with editor + preview
- [ ] Local save/load

### Phase 2: Personal Sync (Weeks 7-10)
- [ ] iCloud Drive integration
- [ ] File coordination for external changes
- [ ] Conflict detection and merge
- [ ] iOS companion app (basic)

### Phase 3: Collaboration (Weeks 11-16)
- [ ] CloudKit shared zones
- [ ] Sync message protocol
- [ ] Invitation system (Tier 1)
- [ ] Permission enforcement
- [ ] Presence awareness (cursors)
- [ ] Thread-safe FFI layer

### Phase 4: Paper Time Machine (Weeks 17-20)
- [ ] Snapshot detection algorithm
- [ ] Timeline UI
- [ ] Diff visualization
- [ ] Section-level history
- [ ] Restore functionality

### Phase 5: Tier 3 Access & Security (Weeks 21-24)
- [ ] Secure link generation
- [ ] Argon2id password hashing
- [ ] Rate limiting
- [ ] Encrypted secret storage
- [ ] Read-only document viewer
- [ ] Anonymous comments
- [ ] Password protection

### Phase 6: Polish & imbib Integration (Weeks 25-30)
- [ ] imbib library integration
- [ ] Citation insertion
- [ ] Journal templates (MNRAS, ApJ, A&A)
- [ ] LaTeX export refinement
- [ ] Large document chunking
- [ ] Cache management
- [ ] iPad split-view optimization
- [ ] Performance optimization
- [ ] Property-based tests
- [ ] Chaos tests
- [ ] Beta testing

## Consequences

### Positive

1. **Maximum code reuse**: Rust core works unchanged on macOS, iOS, and future WASM target
2. **Memory safety**: Rust prevents entire classes of bugs
3. **Performance**: Native code for compute-heavy operations (Typst, Automerge)
4. **Native feel**: SwiftUI provides platform-appropriate UX
5. **Offline-first**: CRDT + iCloud = seamless offline experience
6. **Future web ready**: Rust → WASM enables Tier 2 when needed
7. **Clear responsibilities**: Trait-based design ensures single responsibility
8. **Debuggable errors**: Structured errors with context aid troubleshooting
9. **Thread safety**: Explicit locking model prevents data races
10. **Security**: Industry-standard password hashing, rate limiting, encryption

### Negative

1. **Two-language complexity**: Developers need Rust + Swift expertise
2. **Build complexity**: XCFramework generation adds CI burden
3. **UniFFI limitations**: Some Rust patterns don't map cleanly to Swift
4. **Debugging across boundary**: Stack traces split between languages
5. **More traits to maintain**: Capability pattern adds indirection

### Risks

| Risk | Mitigation |
|------|------------|
| UniFFI breaking changes | Pin version, test on updates |
| Automerge-swift immaturity | Contribute fixes upstream, fallback to JSON bridge |
| Typst breaking changes | Pin version, maintain compatibility layer |
| Apple platform changes | Follow betas, maintain macOS-1 and iOS-1 support |
| Large document performance | Chunking strategy, profiling, lazy loading |

## References

- [UniFFI](https://mozilla.github.io/uniffi-rs/) - Rust ↔ Swift bindings
- [Automerge](https://automerge.org/) - CRDT library
- [Automerge-swift](https://github.com/automerge/automerge-swift)
- [Typst](https://typst.app/) - Modern typesetting
- [CloudKit Documentation](https://developer.apple.com/documentation/cloudkit)
- [NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter)
- [thiserror](https://docs.rs/thiserror/) - Rust error handling
- [Argon2](https://docs.rs/argon2/) - Password hashing
- [proptest](https://docs.rs/proptest/) - Property-based testing
- [OWASP Password Storage](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)
- ADR-001: Sync and Collaboration Architecture (superseded, content incorporated)
