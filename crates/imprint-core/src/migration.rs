//! Document migration module for schema version upgrades
//!
//! This module handles migration of imprint documents between schema versions,
//! ensuring data safety during format changes.
//!
//! # Schema Versions
//!
//! - 100 (v1.0): Initial release - main.typ, metadata.json
//! - 110 (v1.1): Added linked imbib manuscript ID
//! - 120 (v1.2): Added CRDT state file (document.crdt)
//!
//! # Safety
//!
//! All migrations:
//! - Preserve existing data
//! - Create backups before destructive changes
//! - Validate results before committing

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Schema version for imprint documents
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[repr(u32)]
pub enum SchemaVersion {
    /// Initial release (1.0)
    V1_0 = 100,
    /// Added linked imbib manuscript ID (1.1)
    V1_1 = 110,
    /// Added CRDT state file (1.2)
    V1_2 = 120,
}

impl SchemaVersion {
    /// Current schema version
    pub const CURRENT: SchemaVersion = SchemaVersion::V1_2;

    /// Minimum version that can be read by this app
    pub const MINIMUM_READABLE: SchemaVersion = SchemaVersion::V1_0;

    /// Create from raw integer value
    pub fn from_raw(value: u32) -> Option<SchemaVersion> {
        match value {
            100 => Some(SchemaVersion::V1_0),
            110 => Some(SchemaVersion::V1_1),
            120 => Some(SchemaVersion::V1_2),
            _ => None,
        }
    }

    /// Get raw integer value
    pub fn as_raw(&self) -> u32 {
        *self as u32
    }

    /// Get display string (e.g., "1.2")
    pub fn display(&self) -> String {
        let raw = self.as_raw();
        let major = raw / 100;
        let minor = (raw % 100) / 10;
        format!("{}.{}", major, minor)
    }

    /// Check if this version is compatible with the current app
    pub fn is_compatible(&self) -> bool {
        *self >= Self::MINIMUM_READABLE && *self <= Self::CURRENT
    }

    /// Check if migration is needed to reach current version
    pub fn needs_migration(&self) -> bool {
        *self < Self::CURRENT && *self >= Self::MINIMUM_READABLE
    }

    /// Get the next version in the migration path
    pub fn next(&self) -> Option<SchemaVersion> {
        match self {
            SchemaVersion::V1_0 => Some(SchemaVersion::V1_1),
            SchemaVersion::V1_1 => Some(SchemaVersion::V1_2),
            SchemaVersion::V1_2 => None,
        }
    }
}

impl Default for SchemaVersion {
    fn default() -> Self {
        Self::CURRENT
    }
}

/// Errors that can occur during migration
#[derive(Debug, Error)]
pub enum MigrationError {
    /// Version is newer than what this app supports
    #[error("Document version {0} is newer than supported version {}", SchemaVersion::CURRENT.as_raw())]
    VersionTooNew(u32),

    /// Version is too old to migrate
    #[error("Document version {0} is too old to migrate (minimum: {})", SchemaVersion::MINIMUM_READABLE.as_raw())]
    VersionTooOld(u32),

    /// Unknown version number
    #[error("Unknown schema version: {0}")]
    UnknownVersion(u32),

    /// Migration step failed
    #[error("Migration from v{0} to v{1} failed: {2}")]
    StepFailed(String, String, String),

    /// Document data is corrupted
    #[error("Document data is corrupted: {0}")]
    CorruptedData(String),

    /// IO error during migration
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

/// Result of version compatibility check
#[derive(Debug, Clone)]
pub enum VersionCheckResult {
    /// Document is at current version
    Current,
    /// Document needs migration
    NeedsMigration {
        from: SchemaVersion,
        to: SchemaVersion,
    },
    /// Document is from a newer app
    NewerThanApp { version: u32 },
    /// Document is too old to read
    TooOld { version: u32 },
    /// Unknown version format
    Unknown { version: u32 },
    /// Legacy document without version info
    Legacy,
}

/// Check compatibility of a document version
pub fn check_version(raw_version: Option<u32>) -> VersionCheckResult {
    match raw_version {
        None => VersionCheckResult::Legacy,
        Some(raw) => {
            if let Some(version) = SchemaVersion::from_raw(raw) {
                if version == SchemaVersion::CURRENT {
                    VersionCheckResult::Current
                } else if version.needs_migration() {
                    VersionCheckResult::NeedsMigration {
                        from: version,
                        to: SchemaVersion::CURRENT,
                    }
                } else if version < SchemaVersion::MINIMUM_READABLE {
                    VersionCheckResult::TooOld { version: raw }
                } else {
                    // version > CURRENT
                    VersionCheckResult::NewerThanApp { version: raw }
                }
            } else if raw > SchemaVersion::CURRENT.as_raw() {
                VersionCheckResult::NewerThanApp { version: raw }
            } else {
                VersionCheckResult::Unknown { version: raw }
            }
        }
    }
}

/// Document metadata with versioning information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VersionedMetadata {
    /// Schema version number
    pub schema_version: u32,
    /// Document ID
    pub id: String,
    /// Document title
    pub title: String,
    /// Author names
    pub authors: Vec<String>,
    /// Created timestamp (Unix millis)
    pub created_at: i64,
    /// Modified timestamp (Unix millis)
    pub modified_at: i64,
    /// Linked imbib manuscript ID (v1.1+)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub linked_imbib_manuscript_id: Option<String>,
    /// App version that last saved this document
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_saved_by_app_version: Option<String>,
}

impl VersionedMetadata {
    /// Create new metadata with current schema version
    pub fn new(id: String, title: String) -> Self {
        let now = chrono::Utc::now().timestamp_millis();
        Self {
            schema_version: SchemaVersion::CURRENT.as_raw(),
            id,
            title,
            authors: Vec::new(),
            created_at: now,
            modified_at: now,
            linked_imbib_manuscript_id: None,
            last_saved_by_app_version: None,
        }
    }

    /// Get the schema version as enum
    pub fn version(&self) -> Option<SchemaVersion> {
        SchemaVersion::from_raw(self.schema_version)
    }

    /// Update to current version
    pub fn update_to_current(&mut self) {
        self.schema_version = SchemaVersion::CURRENT.as_raw();
        self.modified_at = chrono::Utc::now().timestamp_millis();
    }
}

/// Migration context for tracking migration state
pub struct MigrationContext {
    /// Source document data
    pub source: Vec<u8>,
    /// Current version being migrated from
    pub current_version: SchemaVersion,
    /// Target version to migrate to
    pub target_version: SchemaVersion,
    /// Migration steps performed
    pub steps_performed: Vec<String>,
}

impl MigrationContext {
    /// Create a new migration context
    pub fn new(source: Vec<u8>, from: SchemaVersion, to: SchemaVersion) -> Self {
        Self {
            source,
            current_version: from,
            target_version: to,
            steps_performed: Vec::new(),
        }
    }

    /// Record a migration step
    pub fn record_step(&mut self, description: &str) {
        self.steps_performed.push(description.to_string());
    }
}

/// Migrate CRDT document from one version to another
///
/// This function handles migration of the Automerge CRDT state between versions.
/// Most migrations are additive and don't require CRDT changes, but some
/// structural changes may need CRDT reconstruction.
pub fn migrate_crdt(
    crdt_data: &[u8],
    from: SchemaVersion,
    to: SchemaVersion,
) -> Result<Vec<u8>, MigrationError> {
    if from >= to {
        // Already at target version or newer
        return Ok(crdt_data.to_vec());
    }

    let mut current = from;
    let mut data = crdt_data.to_vec();

    while current < to {
        let next = current.next().ok_or_else(|| {
            MigrationError::StepFailed(
                current.display(),
                to.display(),
                "No migration path available".to_string(),
            )
        })?;

        data = migrate_crdt_step(&data, current, next)?;
        current = next;
    }

    Ok(data)
}

/// Migrate CRDT data one version step
fn migrate_crdt_step(
    crdt_data: &[u8],
    from: SchemaVersion,
    to: SchemaVersion,
) -> Result<Vec<u8>, MigrationError> {
    match (from, to) {
        (SchemaVersion::V1_0, SchemaVersion::V1_1) => {
            // v1.0 -> v1.1: No CRDT changes needed
            // Just adding linked_imbib_manuscript_id to metadata (not in CRDT)
            Ok(crdt_data.to_vec())
        }
        (SchemaVersion::V1_1, SchemaVersion::V1_2) => {
            // v1.1 -> v1.2: CRDT file is now required
            // If CRDT data is empty, that's fine - it will be created on first edit
            Ok(crdt_data.to_vec())
        }
        _ => Err(MigrationError::StepFailed(
            from.display(),
            to.display(),
            "Unknown migration step".to_string(),
        )),
    }
}

/// Validate CRDT data integrity
pub fn validate_crdt(crdt_data: &[u8]) -> Result<CrdtValidation, MigrationError> {
    if crdt_data.is_empty() {
        return Ok(CrdtValidation {
            is_valid: true,
            has_content: false,
            estimated_text_length: 0,
            issues: Vec::new(),
        });
    }

    // Check Automerge magic bytes
    const AUTOMERGE_MAGIC: [u8; 4] = [0x85, 0x6f, 0x4a, 0x83];
    if crdt_data.len() >= 4 && crdt_data[0..4] != AUTOMERGE_MAGIC {
        return Ok(CrdtValidation {
            is_valid: false,
            has_content: false,
            estimated_text_length: 0,
            issues: vec!["Invalid Automerge header".to_string()],
        });
    }

    // Basic validation passed
    // Note: Full validation would require loading the document with Automerge
    Ok(CrdtValidation {
        is_valid: true,
        has_content: crdt_data.len() > 4,
        estimated_text_length: crdt_data.len() / 4, // Rough estimate
        issues: Vec::new(),
    })
}

/// Result of CRDT validation
#[derive(Debug, Clone)]
pub struct CrdtValidation {
    /// Whether the CRDT data is valid
    pub is_valid: bool,
    /// Whether the CRDT contains content
    pub has_content: bool,
    /// Estimated text length (rough approximation)
    pub estimated_text_length: usize,
    /// Any issues found
    pub issues: Vec<String>,
}

// ============================================================================
// UniFFI Exports for Migration
// ============================================================================

/// Schema version for FFI
#[cfg(feature = "uniffi")]
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq)]
pub enum FFISchemaVersion {
    V1_0,
    V1_1,
    V1_2,
    Unknown,
}

#[cfg(feature = "uniffi")]
impl From<SchemaVersion> for FFISchemaVersion {
    fn from(version: SchemaVersion) -> Self {
        match version {
            SchemaVersion::V1_0 => FFISchemaVersion::V1_0,
            SchemaVersion::V1_1 => FFISchemaVersion::V1_1,
            SchemaVersion::V1_2 => FFISchemaVersion::V1_2,
        }
    }
}

/// Version check result for FFI
#[cfg(feature = "uniffi")]
#[derive(uniffi::Enum, Debug, Clone)]
pub enum FFIVersionCheckResult {
    Current,
    NeedsMigration { from_version: u32, to_version: u32 },
    NewerThanApp { version: u32 },
    TooOld { version: u32 },
    Unknown { version: u32 },
    Legacy,
}

#[cfg(feature = "uniffi")]
impl From<VersionCheckResult> for FFIVersionCheckResult {
    fn from(result: VersionCheckResult) -> Self {
        match result {
            VersionCheckResult::Current => FFIVersionCheckResult::Current,
            VersionCheckResult::NeedsMigration { from, to } => {
                FFIVersionCheckResult::NeedsMigration {
                    from_version: from.as_raw(),
                    to_version: to.as_raw(),
                }
            }
            VersionCheckResult::NewerThanApp { version } => {
                FFIVersionCheckResult::NewerThanApp { version }
            }
            VersionCheckResult::TooOld { version } => FFIVersionCheckResult::TooOld { version },
            VersionCheckResult::Unknown { version } => FFIVersionCheckResult::Unknown { version },
            VersionCheckResult::Legacy => FFIVersionCheckResult::Legacy,
        }
    }
}

/// Check document version compatibility
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn check_document_version(raw_version: Option<u32>) -> FFIVersionCheckResult {
    FFIVersionCheckResult::from(check_version(raw_version))
}

/// Get current schema version
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn get_current_schema_version() -> u32 {
    SchemaVersion::CURRENT.as_raw()
}

/// Get minimum readable schema version
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn get_minimum_schema_version() -> u32 {
    SchemaVersion::MINIMUM_READABLE.as_raw()
}

/// Validate CRDT data
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn validate_crdt_data(data: Vec<u8>) -> FFICrdtValidation {
    match validate_crdt(&data) {
        Ok(validation) => FFICrdtValidation {
            is_valid: validation.is_valid,
            has_content: validation.has_content,
            estimated_text_length: validation.estimated_text_length as u64,
            issues: validation.issues,
        },
        Err(e) => FFICrdtValidation {
            is_valid: false,
            has_content: false,
            estimated_text_length: 0,
            issues: vec![e.to_string()],
        },
    }
}

/// CRDT validation result for FFI
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FFICrdtValidation {
    pub is_valid: bool,
    pub has_content: bool,
    pub estimated_text_length: u64,
    pub issues: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_schema_version_ordering() {
        assert!(SchemaVersion::V1_0 < SchemaVersion::V1_1);
        assert!(SchemaVersion::V1_1 < SchemaVersion::V1_2);
        assert!(SchemaVersion::V1_2 == SchemaVersion::CURRENT);
    }

    #[test]
    fn test_schema_version_display() {
        assert_eq!(SchemaVersion::V1_0.display(), "1.0");
        assert_eq!(SchemaVersion::V1_1.display(), "1.1");
        assert_eq!(SchemaVersion::V1_2.display(), "1.2");
    }

    #[test]
    fn test_version_check() {
        assert!(matches!(check_version(Some(120)), VersionCheckResult::Current));
        assert!(matches!(
            check_version(Some(100)),
            VersionCheckResult::NeedsMigration { .. }
        ));
        assert!(matches!(
            check_version(Some(200)),
            VersionCheckResult::NewerThanApp { .. }
        ));
        assert!(matches!(check_version(None), VersionCheckResult::Legacy));
    }

    #[test]
    fn test_crdt_validation_empty() {
        let result = validate_crdt(&[]).unwrap();
        assert!(result.is_valid);
        assert!(!result.has_content);
    }

    #[test]
    fn test_crdt_validation_invalid_header() {
        let result = validate_crdt(&[0x00, 0x00, 0x00, 0x00]).unwrap();
        assert!(!result.is_valid);
        assert!(!result.issues.is_empty());
    }

    #[test]
    fn test_crdt_validation_valid_header() {
        let data = vec![0x85, 0x6f, 0x4a, 0x83, 0x01, 0x02, 0x03];
        let result = validate_crdt(&data).unwrap();
        assert!(result.is_valid);
        assert!(result.has_content);
    }
}
