//! BibDesk file reference encoding/decoding
//!
//! BibDesk stores file references in `Bdsk-File-*` fields as base64-encoded
//! binary plists. This module provides functions to encode and decode these
//! references for round-trip BibTeX compatibility.

use plist::{Dictionary, Value};
use std::io::Cursor;

/// Decode a Bdsk-File-* field value to extract the relative path
///
/// # Arguments
/// * `value` - The base64-encoded binary plist string
///
/// # Returns
/// The decoded relative path, or None if decoding fails
///
/// # Example
/// ```
/// use imbib_core::bibtex::bdsk_file_decode;
///
/// // Decode a Bdsk-File value (the actual value would be longer)
/// let result = bdsk_file_decode("YnBsaXN0MDDRAQJfEBByZWxhdGl2ZVBhdGhYdGVzdC5wZGYICw4fAAAAAAAA".to_string());
/// ```
pub(crate) fn bdsk_file_decode_internal(value: String) -> Option<String> {
    // Decode base64
    use base64::{engine::general_purpose::STANDARD, Engine};
    let data = STANDARD.decode(&value).ok()?;

    // Parse as plist
    let plist: Value = plist::from_reader(Cursor::new(data)).ok()?;

    // Extract relativePath from dictionary
    if let Value::Dictionary(dict) = plist {
        if let Some(Value::String(path)) = dict.get("relativePath") {
            return Some(path.clone());
        }
    }

    None
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bdsk_file_decode(value: String) -> Option<String> {
    bdsk_file_decode_internal(value)
}

pub(crate) fn bdsk_file_encode_internal(relative_path: String) -> Option<String> {
    // Create plist dictionary
    let mut dict = Dictionary::new();
    dict.insert("relativePath".to_string(), Value::String(relative_path));

    // Serialize to binary plist
    let mut buffer = Vec::new();
    plist::to_writer_binary(&mut buffer, &Value::Dictionary(dict)).ok()?;

    // Encode as base64
    use base64::{engine::general_purpose::STANDARD, Engine};
    Some(STANDARD.encode(&buffer))
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bdsk_file_encode(relative_path: String) -> Option<String> {
    bdsk_file_encode_internal(relative_path)
}

pub(crate) fn bdsk_file_extract_all_internal(
    fields: std::collections::HashMap<String, String>,
) -> Vec<String> {
    let mut paths = Vec::new();

    for (key, value) in fields {
        if key.to_lowercase().starts_with("bdsk-file-") {
            if let Some(path) = bdsk_file_decode_internal(value) {
                paths.push(path);
            }
        }
    }

    paths.sort();
    paths
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bdsk_file_extract_all(fields: std::collections::HashMap<String, String>) -> Vec<String> {
    bdsk_file_extract_all_internal(fields)
}

pub(crate) fn bdsk_file_create_fields_internal(
    paths: Vec<String>,
) -> std::collections::HashMap<String, String> {
    let mut fields = std::collections::HashMap::new();

    for (index, path) in paths.into_iter().enumerate() {
        if let Some(encoded) = bdsk_file_encode_internal(path) {
            fields.insert(format!("Bdsk-File-{}", index + 1), encoded);
        }
    }

    fields
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bdsk_file_create_fields(paths: Vec<String>) -> std::collections::HashMap<String, String> {
    bdsk_file_create_fields_internal(paths)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_decode_roundtrip() {
        let original_path = "Papers/Smith2024.pdf";
        let encoded = bdsk_file_encode(original_path.to_string()).expect("encoding should succeed");
        let decoded = bdsk_file_decode(encoded).expect("decoding should succeed");
        assert_eq!(decoded, original_path);
    }

    #[test]
    fn test_encode_decode_with_spaces() {
        let original_path = "My Papers/John Smith - Paper Title.pdf";
        let encoded = bdsk_file_encode(original_path.to_string()).expect("encoding should succeed");
        let decoded = bdsk_file_decode(encoded).expect("decoding should succeed");
        assert_eq!(decoded, original_path);
    }

    #[test]
    fn test_encode_decode_with_unicode() {
        let original_path = "Papers/Müller2024_Übersicht.pdf";
        let encoded = bdsk_file_encode(original_path.to_string()).expect("encoding should succeed");
        let decoded = bdsk_file_decode(encoded).expect("decoding should succeed");
        assert_eq!(decoded, original_path);
    }

    #[test]
    fn test_decode_invalid_base64() {
        assert!(bdsk_file_decode("not valid base64!!!".to_string()).is_none());
    }

    #[test]
    fn test_decode_invalid_plist() {
        use base64::{engine::general_purpose::STANDARD, Engine};
        let invalid_plist = STANDARD.encode(b"not a plist");
        assert!(bdsk_file_decode(invalid_plist).is_none());
    }

    #[test]
    fn test_extract_all() {
        let path1 = "Papers/A.pdf";
        let path2 = "Papers/B.pdf";

        let mut fields = std::collections::HashMap::new();
        fields.insert(
            "Bdsk-File-1".to_string(),
            bdsk_file_encode(path1.to_string()).unwrap(),
        );
        fields.insert(
            "Bdsk-File-2".to_string(),
            bdsk_file_encode(path2.to_string()).unwrap(),
        );
        fields.insert("title".to_string(), "Some Title".to_string());
        fields.insert("author".to_string(), "John Smith".to_string());

        let paths = bdsk_file_extract_all(fields);
        assert_eq!(paths, vec!["Papers/A.pdf", "Papers/B.pdf"]);
    }

    #[test]
    fn test_extract_all_case_insensitive() {
        let path = "Papers/Test.pdf";

        let mut fields = std::collections::HashMap::new();
        fields.insert(
            "bdsk-file-1".to_string(),
            bdsk_file_encode(path.to_string()).unwrap(),
        );

        let paths = bdsk_file_extract_all(fields);
        assert_eq!(paths, vec!["Papers/Test.pdf"]);
    }

    #[test]
    fn test_create_fields() {
        let paths = vec!["Papers/A.pdf".to_string(), "Papers/B.pdf".to_string()];
        let fields = bdsk_file_create_fields(paths);

        assert!(fields.contains_key("Bdsk-File-1"));
        assert!(fields.contains_key("Bdsk-File-2"));

        // Verify roundtrip
        let decoded1 = bdsk_file_decode(fields.get("Bdsk-File-1").unwrap().clone());
        let decoded2 = bdsk_file_decode(fields.get("Bdsk-File-2").unwrap().clone());

        assert_eq!(decoded1, Some("Papers/A.pdf".to_string()));
        assert_eq!(decoded2, Some("Papers/B.pdf".to_string()));
    }
}
