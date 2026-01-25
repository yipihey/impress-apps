//! Permission management with fine-grained access control using bitflags.
//!
//! Provides a flexible permission system that can represent individual permissions
//! or combinations of permissions for different user roles.

use bitflags::bitflags;
use serde::{Deserialize, Serialize};

bitflags! {
    /// Bitflag-based permissions for fine-grained access control.
    ///
    /// Permissions can be combined using bitwise operations to create
    /// custom permission sets or use predefined role-based permissions.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
    pub struct Permissions: u32 {
        /// Permission to view the resource
        const VIEW = 0b00000001;
        /// Permission to add comments to the resource
        const COMMENT = 0b00000010;
        /// Permission to edit the resource content
        const EDIT = 0b00000100;
        /// Permission to share the resource with others
        const SHARE = 0b00001000;
        /// Full administrative access to the resource
        const ADMIN = 0b00010000;
    }
}

impl Serialize for Permissions {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.bits().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Permissions {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let bits = u32::deserialize(deserializer)?;
        Permissions::from_bits(bits).ok_or_else(|| {
            serde::de::Error::custom(format!("invalid permission bits: {}", bits))
        })
    }
}

impl Permissions {
    /// Viewer role: can only view the resource
    pub const VIEWER: Permissions = Permissions::VIEW;

    /// Reviewer role: can view and comment on the resource
    pub const REVIEWER: Permissions = Permissions::VIEW.union(Permissions::COMMENT);

    /// Editor role: can view, comment, and edit the resource
    pub const EDITOR: Permissions = Permissions::REVIEWER.union(Permissions::EDIT);

    /// Owner role: full access including sharing and administration
    pub const OWNER: Permissions = Permissions::EDITOR
        .union(Permissions::SHARE)
        .union(Permissions::ADMIN);

    /// Check if this permission set allows viewing
    #[inline]
    pub fn can_view(&self) -> bool {
        self.contains(Permissions::VIEW)
    }

    /// Check if this permission set allows commenting
    #[inline]
    pub fn can_comment(&self) -> bool {
        self.contains(Permissions::COMMENT)
    }

    /// Check if this permission set allows editing
    #[inline]
    pub fn can_edit(&self) -> bool {
        self.contains(Permissions::EDIT)
    }

    /// Check if this permission set allows sharing
    #[inline]
    pub fn can_share(&self) -> bool {
        self.contains(Permissions::SHARE)
    }

    /// Check if this permission set has admin access
    #[inline]
    pub fn is_admin(&self) -> bool {
        self.contains(Permissions::ADMIN)
    }
}

impl Default for Permissions {
    fn default() -> Self {
        Permissions::VIEWER
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_viewer_permissions() {
        let perms = Permissions::VIEWER;
        assert!(perms.can_view());
        assert!(!perms.can_comment());
        assert!(!perms.can_edit());
        assert!(!perms.can_share());
        assert!(!perms.is_admin());
    }

    #[test]
    fn test_reviewer_permissions() {
        let perms = Permissions::REVIEWER;
        assert!(perms.can_view());
        assert!(perms.can_comment());
        assert!(!perms.can_edit());
        assert!(!perms.can_share());
        assert!(!perms.is_admin());
    }

    #[test]
    fn test_editor_permissions() {
        let perms = Permissions::EDITOR;
        assert!(perms.can_view());
        assert!(perms.can_comment());
        assert!(perms.can_edit());
        assert!(!perms.can_share());
        assert!(!perms.is_admin());
    }

    #[test]
    fn test_owner_permissions() {
        let perms = Permissions::OWNER;
        assert!(perms.can_view());
        assert!(perms.can_comment());
        assert!(perms.can_edit());
        assert!(perms.can_share());
        assert!(perms.is_admin());
    }

    #[test]
    fn test_custom_permissions() {
        let perms = Permissions::VIEW | Permissions::EDIT;
        assert!(perms.can_view());
        assert!(!perms.can_comment());
        assert!(perms.can_edit());
    }

    #[test]
    fn test_permission_serialization() {
        let perms = Permissions::EDITOR;
        let json = serde_json::to_string(&perms).unwrap();
        let deserialized: Permissions = serde_json::from_str(&json).unwrap();
        assert_eq!(perms, deserialized);
    }
}
