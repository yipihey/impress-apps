//! BibDesk file reference encoding/decoding — delegates to the canonical
//! `impress_bibtex` (→ `im-bibtex`) crate.

pub(crate) fn bdsk_file_decode_internal(value: String) -> Option<String> {
    impress_bibtex::bdsk_file_decode(value)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bdsk_file_decode(value: String) -> Option<String> {
    bdsk_file_decode_internal(value)
}

pub(crate) fn bdsk_file_encode_internal(relative_path: String) -> Option<String> {
    impress_bibtex::bdsk_file_encode(relative_path)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bdsk_file_encode(relative_path: String) -> Option<String> {
    bdsk_file_encode_internal(relative_path)
}

pub(crate) fn bdsk_file_extract_all_internal(
    fields: std::collections::HashMap<String, String>,
) -> Vec<String> {
    impress_bibtex::bdsk_file_extract_all(fields)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn bdsk_file_extract_all(fields: std::collections::HashMap<String, String>) -> Vec<String> {
    bdsk_file_extract_all_internal(fields)
}

pub(crate) fn bdsk_file_create_fields_internal(
    paths: Vec<String>,
) -> std::collections::HashMap<String, String> {
    impress_bibtex::bdsk_file_create_fields(paths)
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
