//! Real-time presence awareness for collaborative editing.
//!
//! Provides structures for tracking user presence in shared resources,
//! including cursor positions and activity status.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Status indicating a user's current presence state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PresenceStatus {
    /// User is actively working on the resource
    Active,
    /// User has the resource open but is idle
    Idle,
    /// User is away from the application
    Away,
    /// User is offline
    Offline,
}

impl Default for PresenceStatus {
    fn default() -> Self {
        PresenceStatus::Offline
    }
}

impl PresenceStatus {
    /// Check if the user is considered online (active, idle, or away).
    pub fn is_online(&self) -> bool {
        !matches!(self, PresenceStatus::Offline)
    }

    /// Check if the user is actively working.
    pub fn is_active(&self) -> bool {
        matches!(self, PresenceStatus::Active)
    }
}

/// A user's cursor position within a document or resource.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CursorPosition {
    /// The section or component ID where the cursor is located
    pub section_id: Option<String>,

    /// Line number (0-indexed) if applicable
    pub line: Option<u32>,

    /// Column/character offset (0-indexed) if applicable
    pub column: Option<u32>,

    /// Selection start position (if text is selected)
    pub selection_start: Option<u32>,

    /// Selection end position (if text is selected)
    pub selection_end: Option<u32>,

    /// Additional context about the cursor location
    pub context: Option<String>,
}

impl CursorPosition {
    /// Create a new cursor position with just a section ID.
    pub fn in_section(section_id: impl Into<String>) -> Self {
        Self {
            section_id: Some(section_id.into()),
            line: None,
            column: None,
            selection_start: None,
            selection_end: None,
            context: None,
        }
    }

    /// Create a new cursor position at a specific line and column.
    pub fn at(line: u32, column: u32) -> Self {
        Self {
            section_id: None,
            line: Some(line),
            column: Some(column),
            selection_start: None,
            selection_end: None,
            context: None,
        }
    }

    /// Create a cursor position with a text selection.
    pub fn with_selection(mut self, start: u32, end: u32) -> Self {
        self.selection_start = Some(start);
        self.selection_end = Some(end);
        self
    }

    /// Set the section ID for this cursor position.
    pub fn with_section(mut self, section_id: impl Into<String>) -> Self {
        self.section_id = Some(section_id.into());
        self
    }

    /// Set additional context for this cursor position.
    pub fn with_context(mut self, context: impl Into<String>) -> Self {
        self.context = Some(context.into());
        self
    }

    /// Check if this cursor position has an active selection.
    pub fn has_selection(&self) -> bool {
        self.selection_start.is_some() && self.selection_end.is_some()
    }

    /// Get the selection length if there is an active selection.
    pub fn selection_length(&self) -> Option<u32> {
        match (self.selection_start, self.selection_end) {
            (Some(start), Some(end)) => Some(end.saturating_sub(start)),
            _ => None,
        }
    }
}

impl Default for CursorPosition {
    fn default() -> Self {
        Self {
            section_id: None,
            line: None,
            column: None,
            selection_start: None,
            selection_end: None,
            context: None,
        }
    }
}

/// Information about a user's presence in a shared resource.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PresenceInfo {
    /// Unique identifier for this presence session
    pub session_id: String,

    /// User ID of the present user
    pub user_id: String,

    /// Display name of the user
    pub display_name: String,

    /// ID of the resource the user is present in
    pub resource_id: String,

    /// Current presence status
    pub status: PresenceStatus,

    /// Current cursor position (if applicable)
    pub cursor: Option<CursorPosition>,

    /// Color assigned to this user for visual identification
    pub color: Option<String>,

    /// When this presence session started
    pub joined_at: DateTime<Utc>,

    /// Last time activity was detected
    pub last_active_at: DateTime<Utc>,

    /// Client/device information
    pub client_info: Option<String>,
}

impl PresenceInfo {
    /// Create a new presence info for a user joining a resource.
    pub fn new(
        session_id: String,
        user_id: String,
        display_name: String,
        resource_id: String,
    ) -> Self {
        let now = Utc::now();
        Self {
            session_id,
            user_id,
            display_name,
            resource_id,
            status: PresenceStatus::Active,
            cursor: None,
            color: None,
            joined_at: now,
            last_active_at: now,
            client_info: None,
        }
    }

    /// Set the color for this presence.
    pub fn with_color(mut self, color: impl Into<String>) -> Self {
        self.color = Some(color.into());
        self
    }

    /// Set client info for this presence.
    pub fn with_client_info(mut self, client_info: impl Into<String>) -> Self {
        self.client_info = Some(client_info.into());
        self
    }

    /// Update the cursor position.
    pub fn update_cursor(&mut self, cursor: CursorPosition) {
        self.cursor = Some(cursor);
        self.touch();
    }

    /// Clear the cursor position.
    pub fn clear_cursor(&mut self) {
        self.cursor = None;
    }

    /// Update the presence status.
    pub fn update_status(&mut self, status: PresenceStatus) {
        self.status = status;
        if status.is_active() {
            self.touch();
        }
    }

    /// Mark the presence as active and update last_active_at.
    pub fn touch(&mut self) {
        self.last_active_at = Utc::now();
        if self.status != PresenceStatus::Active {
            self.status = PresenceStatus::Active;
        }
    }

    /// Mark the presence as idle.
    pub fn mark_idle(&mut self) {
        self.status = PresenceStatus::Idle;
    }

    /// Mark the presence as away.
    pub fn mark_away(&mut self) {
        self.status = PresenceStatus::Away;
    }

    /// Mark the presence as offline.
    pub fn mark_offline(&mut self) {
        self.status = PresenceStatus::Offline;
        self.cursor = None;
    }

    /// Get the duration since the user joined.
    pub fn session_duration(&self) -> chrono::Duration {
        Utc::now() - self.joined_at
    }

    /// Get the duration since the last activity.
    pub fn idle_duration(&self) -> chrono::Duration {
        Utc::now() - self.last_active_at
    }

    /// Check if the user should be considered idle based on a threshold.
    pub fn should_be_idle(&self, idle_threshold: chrono::Duration) -> bool {
        self.status == PresenceStatus::Active && self.idle_duration() > idle_threshold
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_presence_status() {
        assert!(PresenceStatus::Active.is_online());
        assert!(PresenceStatus::Idle.is_online());
        assert!(PresenceStatus::Away.is_online());
        assert!(!PresenceStatus::Offline.is_online());

        assert!(PresenceStatus::Active.is_active());
        assert!(!PresenceStatus::Idle.is_active());
    }

    #[test]
    fn test_cursor_position() {
        let cursor = CursorPosition::at(10, 5)
            .with_section("abstract")
            .with_selection(100, 150);

        assert_eq!(cursor.line, Some(10));
        assert_eq!(cursor.column, Some(5));
        assert!(cursor.has_selection());
        assert_eq!(cursor.selection_length(), Some(50));
    }

    #[test]
    fn test_cursor_position_no_selection() {
        let cursor = CursorPosition::in_section("introduction");

        assert_eq!(cursor.section_id, Some("introduction".to_string()));
        assert!(!cursor.has_selection());
        assert_eq!(cursor.selection_length(), None);
    }

    #[test]
    fn test_presence_info_creation() {
        let presence = PresenceInfo::new(
            "session-1".to_string(),
            "user-1".to_string(),
            "Alice".to_string(),
            "doc-1".to_string(),
        )
        .with_color("#FF5733");

        assert_eq!(presence.status, PresenceStatus::Active);
        assert_eq!(presence.color, Some("#FF5733".to_string()));
        assert!(presence.cursor.is_none());
    }

    #[test]
    fn test_presence_status_updates() {
        let mut presence = PresenceInfo::new(
            "session-1".to_string(),
            "user-1".to_string(),
            "Alice".to_string(),
            "doc-1".to_string(),
        );

        presence.mark_idle();
        assert_eq!(presence.status, PresenceStatus::Idle);

        presence.touch();
        assert_eq!(presence.status, PresenceStatus::Active);

        presence.mark_offline();
        assert_eq!(presence.status, PresenceStatus::Offline);
        assert!(presence.cursor.is_none());
    }

    #[test]
    fn test_presence_cursor_updates() {
        let mut presence = PresenceInfo::new(
            "session-1".to_string(),
            "user-1".to_string(),
            "Alice".to_string(),
            "doc-1".to_string(),
        );

        presence.update_cursor(CursorPosition::at(5, 10));
        assert!(presence.cursor.is_some());

        let cursor = presence.cursor.as_ref().unwrap();
        assert_eq!(cursor.line, Some(5));
        assert_eq!(cursor.column, Some(10));
    }
}
