//! Real-time collaboration support with sync and presence tracking
//!
//! This module provides the infrastructure for multi-user collaborative editing:
//!
//! - **Sync**: Synchronization of document changes between peers
//! - **Presence**: Tracking of connected users and their cursor positions
//! - **Conflict resolution**: Automatic CRDT-based conflict resolution
//!
//! # Architecture
//!
//! The collaboration system uses a peer-to-peer model where each client maintains
//! a local copy of the document. Changes are propagated using Automerge sync
//! messages, which automatically handle conflicts.
//!
//! # Example
//!
//! ```ignore
//! use imprint_core::collaboration::{SyncSession, Presence};
//!
//! let mut session = SyncSession::new(document);
//! session.connect(peer_id);
//!
//! // Handle incoming sync message
//! session.receive_sync_message(peer_id, message);
//!
//! // Get outgoing messages for a peer
//! let messages = session.generate_sync_messages(peer_id);
//! ```

use crate::document::ImprintDocument;
use automerge::sync::{Message, State as SyncState, SyncDoc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use thiserror::Error;

/// Errors that can occur during collaboration
#[derive(Debug, Error)]
pub enum CollaborationError {
    /// Sync error
    #[error("Sync error: {0}")]
    SyncError(String),

    /// Unknown peer
    #[error("Unknown peer: {0}")]
    UnknownPeer(String),

    /// Connection error
    #[error("Connection error: {0}")]
    ConnectionError(String),

    /// Document error
    #[error("Document error: {0}")]
    DocumentError(#[from] crate::document::DocumentError),
}

/// Result type for collaboration operations
pub type CollaborationResult<T> = Result<T, CollaborationError>;

/// Unique identifier for a collaborator
pub type PeerId = String;

/// A user's presence information in a collaborative session
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Presence {
    /// The peer's unique identifier
    pub peer_id: PeerId,

    /// Display name for the user
    pub display_name: String,

    /// Cursor position in the document (character offset)
    pub cursor_position: Option<usize>,

    /// Selection range (start, end) if any
    pub selection: Option<(usize, usize)>,

    /// User's color for cursor/selection highlighting
    pub color: String,

    /// Last activity timestamp (Unix milliseconds)
    pub last_active: i64,

    /// Whether the user is currently online
    pub online: bool,
}

impl Presence {
    /// Create a new presence for a user
    pub fn new(peer_id: impl Into<String>, display_name: impl Into<String>) -> Self {
        Self {
            peer_id: peer_id.into(),
            display_name: display_name.into(),
            cursor_position: None,
            selection: None,
            color: Self::generate_color(),
            last_active: chrono::Utc::now().timestamp_millis(),
            online: true,
        }
    }

    /// Update the cursor position
    pub fn set_cursor(&mut self, position: usize) {
        self.cursor_position = Some(position);
        self.selection = None;
        self.last_active = chrono::Utc::now().timestamp_millis();
    }

    /// Update the selection range
    pub fn set_selection(&mut self, start: usize, end: usize) {
        self.cursor_position = Some(end);
        self.selection = Some((start, end));
        self.last_active = chrono::Utc::now().timestamp_millis();
    }

    /// Generate a random color for the user
    fn generate_color() -> String {
        // Predefined set of distinguishable colors
        let colors = [
            "#E57373", "#81C784", "#64B5F6", "#FFD54F", "#BA68C8", "#4DD0E1", "#FF8A65", "#A1887F",
        ];
        let idx = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as usize % colors.len())
            .unwrap_or(0);
        colors[idx].to_string()
    }
}

/// A collaborative editing session
///
/// Manages sync state with multiple peers and tracks presence information.
pub struct SyncSession {
    /// The local document
    document: ImprintDocument,

    /// Sync state for each connected peer
    peer_states: HashMap<PeerId, SyncState>,

    /// Presence information for all known peers
    presence: HashMap<PeerId, Presence>,

    /// Local peer ID
    local_peer_id: PeerId,
}

impl SyncSession {
    /// Create a new sync session with the given document
    pub fn new(document: ImprintDocument, local_peer_id: impl Into<String>) -> Self {
        Self {
            document,
            peer_states: HashMap::new(),
            presence: HashMap::new(),
            local_peer_id: local_peer_id.into(),
        }
    }

    /// Get the local peer ID
    pub fn local_peer_id(&self) -> &str {
        &self.local_peer_id
    }

    /// Get a reference to the document
    pub fn document(&self) -> &ImprintDocument {
        &self.document
    }

    /// Get a mutable reference to the document
    pub fn document_mut(&mut self) -> &mut ImprintDocument {
        &mut self.document
    }

    /// Connect to a new peer
    pub fn connect(&mut self, peer_id: impl Into<String>) {
        let peer_id = peer_id.into();
        self.peer_states.insert(peer_id.clone(), SyncState::new());
        self.presence
            .insert(peer_id.clone(), Presence::new(&peer_id, &peer_id));
    }

    /// Disconnect from a peer
    pub fn disconnect(&mut self, peer_id: &str) {
        self.peer_states.remove(peer_id);
        if let Some(presence) = self.presence.get_mut(peer_id) {
            presence.online = false;
        }
    }

    /// Check if a peer is connected
    pub fn is_connected(&self, peer_id: &str) -> bool {
        self.peer_states.contains_key(peer_id)
    }

    /// Get all connected peer IDs
    pub fn connected_peers(&self) -> Vec<&str> {
        self.peer_states.keys().map(String::as_str).collect()
    }

    /// Generate sync messages for a peer
    ///
    /// This implements the Automerge sync protocol. Call this method after
    /// making local changes to generate messages to send to a peer.
    ///
    /// Returns `Some(message)` if there are changes to send, or `None` if
    /// the peer is already up to date.
    pub fn generate_sync_message(&mut self, peer_id: &str) -> CollaborationResult<Option<Message>> {
        // Check peer exists first
        if !self.peer_states.contains_key(peer_id) {
            return Err(CollaborationError::UnknownPeer(peer_id.to_string()));
        }

        // Get mutable references to both fields separately to satisfy borrow checker
        let state = self.peer_states.get_mut(peer_id).unwrap();
        let doc = self.document.automerge_mut();

        // Generate a sync message using Automerge's sync protocol
        let message = doc.sync().generate_sync_message(state);

        Ok(message)
    }

    /// Receive and apply a sync message from a peer
    ///
    /// This implements the Automerge sync protocol. When a message is received
    /// from a peer, call this method to apply it to the local document.
    ///
    /// After receiving, call `generate_sync_message` separately to check if
    /// you need to send a response. Do NOT call generate_sync_message inline
    /// as part of receiving - the sync protocol expects all messages to be
    /// generated before any are received in each round.
    pub fn receive_sync_message(
        &mut self,
        peer_id: &str,
        message: Message,
    ) -> CollaborationResult<()> {
        // Check peer exists first
        if !self.peer_states.contains_key(peer_id) {
            return Err(CollaborationError::UnknownPeer(peer_id.to_string()));
        }

        // Get the state and document
        let state = self.peer_states.get_mut(peer_id).unwrap();
        let doc = self.document.automerge_mut();

        // Receive the sync message - this applies changes from the peer
        doc.sync()
            .receive_sync_message(state, message)
            .map_err(|e: automerge::AutomergeError| CollaborationError::SyncError(e.to_string()))?;

        Ok(())
    }

    /// Get all pending sync messages for a peer
    ///
    /// Generates messages until the peer is in sync. This is useful for
    /// initial sync when establishing a new connection.
    pub fn generate_all_sync_messages(&mut self, peer_id: &str) -> CollaborationResult<Vec<Message>> {
        let mut messages = Vec::new();

        while let Some(msg) = self.generate_sync_message(peer_id)? {
            messages.push(msg);
        }

        Ok(messages)
    }

    /// Check if a peer needs sync
    ///
    /// Returns true if there are changes to send to the peer or if we need
    /// changes from the peer.
    pub fn needs_sync(&self, peer_id: &str) -> bool {
        // A peer needs sync if we have sync state for them
        // (A more accurate implementation would check the actual sync state)
        self.peer_states.contains_key(peer_id)
    }

    /// Encode a sync message to bytes for transport
    pub fn encode_message(message: Message) -> Vec<u8> {
        message.encode()
    }

    /// Decode a sync message from bytes
    pub fn decode_message(bytes: &[u8]) -> CollaborationResult<Message> {
        Message::decode(bytes).map_err(|e| CollaborationError::SyncError(e.to_string()))
    }

    /// Update presence for a peer
    pub fn update_presence(&mut self, presence: Presence) {
        self.presence.insert(presence.peer_id.clone(), presence);
    }

    /// Get presence for a specific peer
    pub fn get_presence(&self, peer_id: &str) -> Option<&Presence> {
        self.presence.get(peer_id)
    }

    /// Get all presence information
    pub fn all_presence(&self) -> impl Iterator<Item = &Presence> {
        self.presence.values()
    }

    /// Get online peers' presence
    pub fn online_presence(&self) -> impl Iterator<Item = &Presence> {
        self.presence.values().filter(|p| p.online)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sync_session_creation() {
        let doc = ImprintDocument::new();
        let session = SyncSession::new(doc, "local");
        assert_eq!(session.local_peer_id(), "local");
    }

    #[test]
    fn test_peer_connection() {
        let doc = ImprintDocument::new();
        let mut session = SyncSession::new(doc, "local");

        session.connect("peer1");
        assert!(session.is_connected("peer1"));
        assert!(!session.is_connected("peer2"));

        session.disconnect("peer1");
        assert!(!session.is_connected("peer1"));
    }

    #[test]
    fn test_presence_tracking() {
        let doc = ImprintDocument::new();
        let mut session = SyncSession::new(doc, "local");

        session.connect("peer1");
        let presence = session.get_presence("peer1").unwrap();
        assert!(presence.online);
        assert_eq!(presence.peer_id, "peer1");
    }

    #[test]
    fn test_presence_set_cursor() {
        let mut presence = Presence::new("peer1", "User 1");
        assert_eq!(presence.cursor_position, None);

        presence.set_cursor(100);
        assert_eq!(presence.cursor_position, Some(100));
        assert_eq!(presence.selection, None);
    }

    #[test]
    fn test_presence_set_selection() {
        let mut presence = Presence::new("peer1", "User 1");

        presence.set_selection(50, 150);
        assert_eq!(presence.cursor_position, Some(150)); // Cursor at end
        assert_eq!(presence.selection, Some((50, 150)));
    }

    #[test]
    fn test_presence_color_generation() {
        let presence = Presence::new("peer1", "User 1");
        // Color should be a valid hex color starting with #
        assert!(presence.color.starts_with('#'));
        assert_eq!(presence.color.len(), 7); // #RRGGBB format
    }

    #[test]
    fn test_presence_last_active_updates() {
        let mut presence = Presence::new("peer1", "User 1");
        let initial_time = presence.last_active;

        // Small delay to ensure time difference
        std::thread::sleep(std::time::Duration::from_millis(10));

        presence.set_cursor(100);
        assert!(presence.last_active >= initial_time);
    }

    #[test]
    fn test_sync_session_multiple_peers() {
        let doc = ImprintDocument::new();
        let mut session = SyncSession::new(doc, "local");

        session.connect("peer1");
        session.connect("peer2");
        session.connect("peer3");

        let peers = session.connected_peers();
        assert_eq!(peers.len(), 3);
        assert!(peers.contains(&"peer1"));
        assert!(peers.contains(&"peer2"));
        assert!(peers.contains(&"peer3"));
    }

    #[test]
    fn test_sync_session_update_presence() {
        let doc = ImprintDocument::new();
        let mut session = SyncSession::new(doc, "local");

        let mut presence = Presence::new("peer1", "Alice");
        presence.set_cursor(500);

        session.update_presence(presence);

        let retrieved = session.get_presence("peer1").unwrap();
        assert_eq!(retrieved.display_name, "Alice");
        assert_eq!(retrieved.cursor_position, Some(500));
    }

    #[test]
    fn test_sync_session_online_presence() {
        let doc = ImprintDocument::new();
        let mut session = SyncSession::new(doc, "local");

        session.connect("peer1");
        session.connect("peer2");
        session.disconnect("peer1");

        let online: Vec<_> = session.online_presence().collect();
        assert_eq!(online.len(), 1);
        assert_eq!(online[0].peer_id, "peer2");
    }

    #[test]
    fn test_sync_protocol_two_peers() {
        // Create a document and fork it for the second peer
        // This is the proper way to set up collaboration - both documents share the same origin
        let mut doc1 = ImprintDocument::new();
        let bytes = doc1.to_bytes();
        let doc2 = ImprintDocument::from_bytes(&bytes).unwrap();

        // Now doc1 makes changes
        doc1.insert_text(0, "Hello from peer1!").unwrap();

        let mut session1 = SyncSession::new(doc1, "peer1");
        let mut session2 = SyncSession::new(doc2, "peer2");

        // Connect the peers to each other
        session1.connect("peer2");
        session2.connect("peer1");

        // Sync loop: generate all messages, then receive all messages
        let mut iterations = 0;
        loop {
            iterations += 1;
            if iterations > 20 {
                panic!("Sync did not complete in 20 iterations");
            }

            // Generate messages from both sides first
            let msg1to2 = session1.generate_sync_message("peer2").unwrap();
            let msg2to1 = session2.generate_sync_message("peer1").unwrap();

            if msg1to2.is_none() && msg2to1.is_none() {
                break;
            }

            // Then receive them
            if let Some(msg) = msg1to2 {
                session2.receive_sync_message("peer1", msg).unwrap();
            }
            if let Some(msg) = msg2to1 {
                session1.receive_sync_message("peer2", msg).unwrap();
            }
        }

        // Verify both documents have the same content
        let text1 = session1.document().text().unwrap();
        let text2 = session2.document().text().unwrap();
        assert_eq!(text1, text2, "Documents should be in sync");
        assert_eq!(text1, "Hello from peer1!");
    }

    #[test]
    fn test_sync_protocol_concurrent_edits() {
        // Fork from a common origin
        let mut origin = ImprintDocument::new();
        let bytes = origin.to_bytes();

        // Each peer starts from the same origin but makes different edits
        let mut doc1 = ImprintDocument::from_bytes(&bytes).unwrap();
        doc1.insert_text(0, "A").unwrap();
        let mut session1 = SyncSession::new(doc1, "peer1");

        let mut doc2 = ImprintDocument::from_bytes(&bytes).unwrap();
        doc2.insert_text(0, "B").unwrap();
        let mut session2 = SyncSession::new(doc2, "peer2");

        // Connect the peers
        session1.connect("peer2");
        session2.connect("peer1");

        // Sync loop: generate all messages, then receive all messages
        let mut iterations = 0;
        loop {
            iterations += 1;
            if iterations > 20 {
                panic!("Sync did not complete in 20 iterations");
            }

            // Generate messages from both sides first
            let msg1to2 = session1.generate_sync_message("peer2").unwrap();
            let msg2to1 = session2.generate_sync_message("peer1").unwrap();

            if msg1to2.is_none() && msg2to1.is_none() {
                break;
            }

            // Then receive them
            if let Some(msg) = msg1to2 {
                session2.receive_sync_message("peer1", msg).unwrap();
            }
            if let Some(msg) = msg2to1 {
                session1.receive_sync_message("peer2", msg).unwrap();
            }
        }

        // After sync, both documents should have the same merged content
        let text1 = session1.document().text().unwrap();
        let text2 = session2.document().text().unwrap();
        assert_eq!(text1, text2, "Documents should have identical content after sync");
        // Both A and B should be present (order depends on CRDT resolution)
        assert!(text1.contains('A') && text1.contains('B'),
            "Both edits should be present: got '{}'", text1);
    }

    #[test]
    fn test_raw_automerge_sync() {
        // Test the underlying Automerge sync protocol directly
        use automerge::{AutoCommit, ObjType, transaction::Transactable, ReadDoc};

        // Create two documents from a common origin
        let mut origin = AutoCommit::new();
        origin.put_object(automerge::ROOT, "content", ObjType::Text).unwrap();
        let bytes = origin.save();

        let mut doc1 = AutoCommit::load(&bytes).unwrap();
        let mut doc2 = AutoCommit::load(&bytes).unwrap();

        // Get the content object ID
        let (_, content_id) = doc1.get(automerge::ROOT, "content").unwrap().unwrap();

        // doc1 makes a change
        doc1.splice_text(&content_id, 0, 0, "Hello").unwrap();
        assert_eq!(doc1.text(&content_id).unwrap(), "Hello");
        assert_eq!(doc2.text(&content_id).unwrap(), ""); // doc2 doesn't have the change yet

        // Sync using Automerge's sync protocol
        let mut state1 = SyncState::new();
        let mut state2 = SyncState::new();

        // Exchange messages until sync is complete
        let mut iterations = 0;
        loop {
            iterations += 1;
            if iterations > 20 {
                panic!("Sync did not complete");
            }

            let msg1to2 = doc1.sync().generate_sync_message(&mut state1);
            let msg2to1 = doc2.sync().generate_sync_message(&mut state2);

            if msg1to2.is_none() && msg2to1.is_none() {
                break;
            }

            if let Some(msg) = msg1to2 {
                doc2.sync().receive_sync_message(&mut state2, msg).unwrap();
            }
            if let Some(msg) = msg2to1 {
                doc1.sync().receive_sync_message(&mut state1, msg).unwrap();
            }
        }

        // Both documents should now have the same content
        let text1 = doc1.text(&content_id).unwrap();
        let text2 = doc2.text(&content_id).unwrap();
        assert_eq!(text1, text2, "Raw Automerge sync should work");
        assert_eq!(text1, "Hello");
    }

    #[test]
    fn test_message_encode_decode() {
        let mut doc = ImprintDocument::new();
        doc.insert_text(0, "Test content").unwrap();
        let mut session = SyncSession::new(doc, "local");

        session.connect("remote");

        // Generate a sync message
        if let Some(msg) = session.generate_sync_message("remote").unwrap() {
            // Encode to bytes
            let bytes = SyncSession::encode_message(msg);
            assert!(!bytes.is_empty());

            // Decode back
            let decoded = SyncSession::decode_message(&bytes).unwrap();

            // Re-encode and verify bytes match
            let bytes2 = SyncSession::encode_message(decoded);
            assert_eq!(bytes, bytes2);
        }
    }
}
