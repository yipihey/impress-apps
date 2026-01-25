//! Library representation

use serde::{Deserialize, Serialize};

/// A library (collection of publications, typically from a .bib file)
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Library {
    pub id: String,
    pub name: String,
    pub file_path: Option<String>,
    pub is_default: bool,
    pub created_at: Option<String>,
    pub modified_at: Option<String>,
}

impl Library {
    /// Create a new library
    pub fn new(name: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            file_path: None,
            is_default: false,
            created_at: None,
            modified_at: None,
        }
    }

    /// Create a new library from a file path
    pub fn from_file(name: String, file_path: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            file_path: Some(file_path),
            is_default: false,
            created_at: None,
            modified_at: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_library_new() {
        let lib = Library::new("My Papers".to_string());
        assert_eq!(lib.name, "My Papers");
        assert!(!lib.is_default);
        assert!(lib.file_path.is_none());
    }

    #[test]
    fn test_library_from_file() {
        let lib = Library::from_file("Work".to_string(), "/Users/me/work.bib".to_string());
        assert_eq!(lib.name, "Work");
        assert_eq!(lib.file_path, Some("/Users/me/work.bib".to_string()));
    }
}
