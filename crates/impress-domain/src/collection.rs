//! Collection representation for grouping publications

use serde::{Deserialize, Serialize};

/// A collection (folder) for organizing publications
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Collection {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
    pub is_smart: bool,
    pub smart_query: Option<String>,
    pub created_at: Option<String>,
}

impl Collection {
    /// Create a new regular collection
    pub fn new(name: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            parent_id: None,
            is_smart: false,
            smart_query: None,
            created_at: None,
        }
    }

    /// Create a new smart collection with a query
    pub fn new_smart(name: String, query: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            parent_id: None,
            is_smart: true,
            smart_query: Some(query),
            created_at: None,
        }
    }

    /// Create a subcollection under a parent
    pub fn with_parent(mut self, parent_id: String) -> Self {
        self.parent_id = Some(parent_id);
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_collection_new() {
        let col = Collection::new("Research Papers".to_string());
        assert_eq!(col.name, "Research Papers");
        assert!(!col.is_smart);
        assert!(col.parent_id.is_none());
    }

    #[test]
    fn test_collection_smart() {
        let smart = Collection::new_smart("Recent".to_string(), "year:>2020".to_string());
        assert_eq!(smart.name, "Recent");
        assert!(smart.is_smart);
        assert_eq!(smart.smart_query, Some("year:>2020".to_string()));
    }

    #[test]
    fn test_collection_with_parent() {
        let parent = Collection::new("Work".to_string());
        let child = Collection::new("Project A".to_string()).with_parent(parent.id.clone());
        assert_eq!(child.parent_id, Some(parent.id));
    }
}
