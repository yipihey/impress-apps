//! Validation for publications

use super::Publication;
use serde::{Deserialize, Serialize};

/// Severity of a validation error
#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize)]
pub enum ValidationSeverity {
    Error,
    Warning,
    Info,
}

/// A validation error or warning
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct ValidationError {
    pub field: String,
    pub message: String,
    pub severity: ValidationSeverity,
}

/// Validate a publication and return errors/warnings
#[cfg(feature = "native")]
#[uniffi::export]
pub fn validate_publication(publication: &Publication) -> Vec<ValidationError> {
    let mut errors = Vec::new();

    // Required fields
    if publication.cite_key.is_empty() {
        errors.push(ValidationError {
            field: "cite_key".to_string(),
            message: "Citation key is required".to_string(),
            severity: ValidationSeverity::Error,
        });
    }

    if publication.title.is_empty() {
        errors.push(ValidationError {
            field: "title".to_string(),
            message: "Title is required".to_string(),
            severity: ValidationSeverity::Error,
        });
    }

    if publication.entry_type.is_empty() {
        errors.push(ValidationError {
            field: "entry_type".to_string(),
            message: "Entry type is required".to_string(),
            severity: ValidationSeverity::Error,
        });
    }

    // Warnings for recommended fields
    if publication.authors.is_empty() {
        errors.push(ValidationError {
            field: "authors".to_string(),
            message: "Authors are recommended".to_string(),
            severity: ValidationSeverity::Warning,
        });
    }

    if publication.year.is_none() {
        errors.push(ValidationError {
            field: "year".to_string(),
            message: "Year is recommended".to_string(),
            severity: ValidationSeverity::Warning,
        });
    }

    // Entry-type specific validation
    let entry_type = publication.entry_type.to_lowercase();
    match entry_type.as_str() {
        "article" => {
            if publication.journal.is_none() {
                errors.push(ValidationError {
                    field: "journal".to_string(),
                    message: "Journal is required for article entries".to_string(),
                    severity: ValidationSeverity::Warning,
                });
            }
        }
        "inproceedings" | "conference" => {
            if publication.booktitle.is_none() {
                errors.push(ValidationError {
                    field: "booktitle".to_string(),
                    message: "Booktitle is required for conference entries".to_string(),
                    severity: ValidationSeverity::Warning,
                });
            }
        }
        "book" | "inbook" => {
            if publication.publisher.is_none() {
                errors.push(ValidationError {
                    field: "publisher".to_string(),
                    message: "Publisher is recommended for book entries".to_string(),
                    severity: ValidationSeverity::Warning,
                });
            }
        }
        "phdthesis" | "mastersthesis" => {
            if publication.school.is_none() {
                errors.push(ValidationError {
                    field: "school".to_string(),
                    message: "School is required for thesis entries".to_string(),
                    severity: ValidationSeverity::Warning,
                });
            }
        }
        _ => {}
    }

    // Identifier validation
    if let Some(ref doi) = publication.identifiers.doi {
        if !doi.starts_with("10.") {
            errors.push(ValidationError {
                field: "doi".to_string(),
                message: "DOI should start with '10.'".to_string(),
                severity: ValidationSeverity::Warning,
            });
        }
    }

    errors
}

/// Check if a publication is valid (no errors)
#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_valid(publication: &Publication) -> bool {
    validate_publication(publication)
        .iter()
        .all(|e| !matches!(e.severity, ValidationSeverity::Error))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_empty_publication() {
        let pub_ = Publication::new(String::new(), String::new(), String::new());
        let errors = validate_publication(&pub_);
        assert!(errors.iter().any(|e| e.field == "cite_key"));
        assert!(errors.iter().any(|e| e.field == "title"));
        assert!(errors.iter().any(|e| e.field == "entry_type"));
    }

    #[test]
    fn test_validate_valid_publication() {
        let mut pub_ = Publication::new(
            "smith2024".to_string(),
            "article".to_string(),
            "A Great Paper".to_string(),
        );
        pub_.year = Some(2024);
        pub_.authors
            .push(crate::domain::Author::new("Smith".to_string()));
        pub_.journal = Some("Nature".to_string());

        let errors = validate_publication(&pub_);
        assert!(is_valid(&pub_));
        // Should have no errors, only possible info/warnings
        assert!(errors
            .iter()
            .all(|e| !matches!(e.severity, ValidationSeverity::Error)));
    }

    #[test]
    fn test_is_valid() {
        let valid = Publication::new(
            "test2024".to_string(),
            "article".to_string(),
            "Test".to_string(),
        );
        assert!(is_valid(&valid));

        let invalid = Publication::new(String::new(), String::new(), String::new());
        assert!(!is_valid(&invalid));
    }
}
