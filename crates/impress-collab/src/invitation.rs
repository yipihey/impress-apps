//! Invitation and secure link sharing for collaborative resources.
//!
//! Provides structures for managing invitations to shared resources and
//! generating secure, time-limited sharing links.

use crate::permissions::Permissions;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Errors that can occur during invitation operations.
#[derive(Debug, Error)]
pub enum InvitationError {
    /// The invitation has expired
    #[error("invitation has expired")]
    Expired,

    /// The invitation has already been used
    #[error("invitation has already been accepted")]
    AlreadyAccepted,

    /// The invitation was revoked
    #[error("invitation has been revoked")]
    Revoked,

    /// The secure link has expired
    #[error("secure link has expired")]
    LinkExpired,

    /// The secure link has reached its usage limit
    #[error("secure link usage limit exceeded")]
    UsageLimitExceeded,

    /// Invalid token format
    #[error("invalid token format")]
    InvalidToken,
}

/// Status of an invitation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InvitationStatus {
    /// Invitation is pending acceptance
    #[default]
    Pending,
    /// Invitation has been accepted
    Accepted,
    /// Invitation has been declined
    Declined,
    /// Invitation has expired
    Expired,
    /// Invitation has been revoked by the sender
    Revoked,
}

/// An invitation to access a shared resource.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Invitation {
    /// Unique identifier for this invitation
    pub id: String,

    /// ID of the resource being shared
    pub resource_id: String,

    /// Type of the resource (e.g., "library", "collection", "publication")
    pub resource_type: String,

    /// User ID of the person who created the invitation
    pub inviter_id: String,

    /// Email address of the invited person
    pub invitee_email: String,

    /// Permissions granted to the invitee upon acceptance
    pub permissions: Permissions,

    /// Optional personal message from the inviter
    pub message: Option<String>,

    /// Current status of the invitation
    pub status: InvitationStatus,

    /// When the invitation was created
    pub created_at: DateTime<Utc>,

    /// When the invitation expires (if applicable)
    pub expires_at: Option<DateTime<Utc>>,

    /// When the invitation was accepted (if applicable)
    pub accepted_at: Option<DateTime<Utc>>,
}

impl Invitation {
    /// Create a new pending invitation.
    pub fn new(
        id: String,
        resource_id: String,
        resource_type: String,
        inviter_id: String,
        invitee_email: String,
        permissions: Permissions,
    ) -> Self {
        Self {
            id,
            resource_id,
            resource_type,
            inviter_id,
            invitee_email,
            permissions,
            message: None,
            status: InvitationStatus::Pending,
            created_at: Utc::now(),
            expires_at: None,
            accepted_at: None,
        }
    }

    /// Set an optional message for the invitation.
    pub fn with_message(mut self, message: impl Into<String>) -> Self {
        self.message = Some(message.into());
        self
    }

    /// Set an expiration time for the invitation.
    pub fn with_expiration(mut self, expires_at: DateTime<Utc>) -> Self {
        self.expires_at = Some(expires_at);
        self
    }

    /// Check if the invitation has expired.
    pub fn is_expired(&self) -> bool {
        if let Some(expires_at) = self.expires_at {
            Utc::now() > expires_at
        } else {
            false
        }
    }

    /// Check if the invitation can still be accepted.
    pub fn can_accept(&self) -> bool {
        self.status == InvitationStatus::Pending && !self.is_expired()
    }

    /// Accept the invitation.
    pub fn accept(&mut self) -> Result<(), InvitationError> {
        if self.is_expired() {
            self.status = InvitationStatus::Expired;
            return Err(InvitationError::Expired);
        }

        match self.status {
            InvitationStatus::Pending => {
                self.status = InvitationStatus::Accepted;
                self.accepted_at = Some(Utc::now());
                Ok(())
            }
            InvitationStatus::Accepted => Err(InvitationError::AlreadyAccepted),
            InvitationStatus::Revoked => Err(InvitationError::Revoked),
            InvitationStatus::Expired => Err(InvitationError::Expired),
            InvitationStatus::Declined => Err(InvitationError::Revoked),
        }
    }

    /// Decline the invitation.
    pub fn decline(&mut self) {
        if self.status == InvitationStatus::Pending {
            self.status = InvitationStatus::Declined;
        }
    }

    /// Revoke the invitation.
    pub fn revoke(&mut self) {
        if self.status == InvitationStatus::Pending {
            self.status = InvitationStatus::Revoked;
        }
    }
}

/// A secure, shareable link for resource access.
///
/// Secure links allow sharing resources without requiring user accounts,
/// with configurable permissions, expiration, and usage limits.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecureLink {
    /// Unique identifier for this link
    pub id: String,

    /// The secure token used in the URL
    pub token: String,

    /// ID of the resource being shared
    pub resource_id: String,

    /// Type of the resource
    pub resource_type: String,

    /// User ID of the person who created the link
    pub creator_id: String,

    /// Permissions granted to anyone using this link
    pub permissions: Permissions,

    /// When the link was created
    pub created_at: DateTime<Utc>,

    /// When the link expires (if applicable)
    pub expires_at: Option<DateTime<Utc>>,

    /// Maximum number of times this link can be used
    pub max_uses: Option<u32>,

    /// Current number of times this link has been used
    pub use_count: u32,

    /// Whether the link is currently active
    pub is_active: bool,

    /// Optional label for the link
    pub label: Option<String>,
}

impl SecureLink {
    /// Create a new secure link.
    pub fn new(
        id: String,
        token: String,
        resource_id: String,
        resource_type: String,
        creator_id: String,
        permissions: Permissions,
    ) -> Self {
        Self {
            id,
            token,
            resource_id,
            resource_type,
            creator_id,
            permissions,
            created_at: Utc::now(),
            expires_at: None,
            max_uses: None,
            use_count: 0,
            is_active: true,
            label: None,
        }
    }

    /// Set an expiration time for the link.
    pub fn with_expiration(mut self, expires_at: DateTime<Utc>) -> Self {
        self.expires_at = Some(expires_at);
        self
    }

    /// Set a maximum number of uses for the link.
    pub fn with_max_uses(mut self, max_uses: u32) -> Self {
        self.max_uses = Some(max_uses);
        self
    }

    /// Set an optional label for the link.
    pub fn with_label(mut self, label: impl Into<String>) -> Self {
        self.label = Some(label.into());
        self
    }

    /// Check if the link has expired.
    pub fn is_expired(&self) -> bool {
        if let Some(expires_at) = self.expires_at {
            Utc::now() > expires_at
        } else {
            false
        }
    }

    /// Check if the link has reached its usage limit.
    pub fn is_usage_exceeded(&self) -> bool {
        if let Some(max_uses) = self.max_uses {
            self.use_count >= max_uses
        } else {
            false
        }
    }

    /// Check if the link is currently valid for use.
    pub fn is_valid(&self) -> bool {
        self.is_active && !self.is_expired() && !self.is_usage_exceeded()
    }

    /// Attempt to use the link, incrementing the use count if valid.
    pub fn use_link(&mut self) -> Result<Permissions, InvitationError> {
        if !self.is_active {
            return Err(InvitationError::Revoked);
        }

        if self.is_expired() {
            return Err(InvitationError::LinkExpired);
        }

        if self.is_usage_exceeded() {
            return Err(InvitationError::UsageLimitExceeded);
        }

        self.use_count += 1;
        Ok(self.permissions)
    }

    /// Deactivate the link.
    pub fn deactivate(&mut self) {
        self.is_active = false;
    }

    /// Reactivate a deactivated link.
    pub fn reactivate(&mut self) {
        self.is_active = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    #[test]
    fn test_invitation_creation() {
        let inv = Invitation::new(
            "inv-1".to_string(),
            "lib-1".to_string(),
            "library".to_string(),
            "user-1".to_string(),
            "invited@example.com".to_string(),
            Permissions::EDITOR,
        );

        assert_eq!(inv.status, InvitationStatus::Pending);
        assert!(inv.can_accept());
    }

    #[test]
    fn test_invitation_acceptance() {
        let mut inv = Invitation::new(
            "inv-1".to_string(),
            "lib-1".to_string(),
            "library".to_string(),
            "user-1".to_string(),
            "invited@example.com".to_string(),
            Permissions::EDITOR,
        );

        assert!(inv.accept().is_ok());
        assert_eq!(inv.status, InvitationStatus::Accepted);
        assert!(inv.accepted_at.is_some());

        // Cannot accept twice
        assert!(inv.accept().is_err());
    }

    #[test]
    fn test_invitation_expiration() {
        let mut inv = Invitation::new(
            "inv-1".to_string(),
            "lib-1".to_string(),
            "library".to_string(),
            "user-1".to_string(),
            "invited@example.com".to_string(),
            Permissions::VIEWER,
        )
        .with_expiration(Utc::now() - Duration::hours(1));

        assert!(inv.is_expired());
        assert!(!inv.can_accept());
        assert!(inv.accept().is_err());
    }

    #[test]
    fn test_secure_link_creation() {
        let link = SecureLink::new(
            "link-1".to_string(),
            "abc123xyz".to_string(),
            "lib-1".to_string(),
            "library".to_string(),
            "user-1".to_string(),
            Permissions::VIEWER,
        );

        assert!(link.is_valid());
        assert_eq!(link.use_count, 0);
    }

    #[test]
    fn test_secure_link_usage_limit() {
        let mut link = SecureLink::new(
            "link-1".to_string(),
            "abc123xyz".to_string(),
            "lib-1".to_string(),
            "library".to_string(),
            "user-1".to_string(),
            Permissions::VIEWER,
        )
        .with_max_uses(2);

        assert!(link.use_link().is_ok());
        assert!(link.use_link().is_ok());
        assert!(link.use_link().is_err());
        assert!(link.is_usage_exceeded());
    }

    #[test]
    fn test_secure_link_expiration() {
        let mut link = SecureLink::new(
            "link-1".to_string(),
            "abc123xyz".to_string(),
            "lib-1".to_string(),
            "library".to_string(),
            "user-1".to_string(),
            Permissions::VIEWER,
        )
        .with_expiration(Utc::now() - Duration::hours(1));

        assert!(link.is_expired());
        assert!(!link.is_valid());
        assert!(link.use_link().is_err());
    }
}
