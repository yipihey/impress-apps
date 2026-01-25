//! Tag representation for organizing publications

use serde::{Deserialize, Serialize};

/// A tag for organizing publications
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Tag {
    pub id: String,
    pub name: String,
    pub color: Option<String>, // Hex color code
}

impl Tag {
    /// Create a new tag
    pub fn new(name: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            color: None,
        }
    }

    /// Builder method to add color
    pub fn with_color(mut self, color: String) -> Self {
        self.color = Some(color);
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tag_new() {
        let tag = Tag::new("Important".to_string());
        assert_eq!(tag.name, "Important");
        assert!(tag.color.is_none());
    }

    #[test]
    fn test_tag_with_color() {
        let tag = Tag::new("Urgent".to_string()).with_color("#FF0000".to_string());
        assert_eq!(tag.name, "Urgent");
        assert_eq!(tag.color, Some("#FF0000".to_string()));
    }
}
