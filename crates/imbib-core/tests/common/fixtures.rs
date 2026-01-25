//! Test fixture loading utilities

use std::path::PathBuf;

/// Get the path to a fixture file
pub fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("test_fixtures")
        .join(name)
}

/// Load a fixture file as a string
#[allow(dead_code)]
pub fn load_fixture(name: &str) -> String {
    std::fs::read_to_string(fixture_path(name))
        .unwrap_or_else(|_| panic!("Failed to load fixture: {}", name))
}

/// Load a BibTeX fixture
pub fn load_bibtex_fixture(name: &str) -> String {
    load_fixture(&format!("bibtex/{}", name))
}

/// Load a RIS fixture
pub fn load_ris_fixture(name: &str) -> String {
    load_fixture(&format!("ris/{}", name))
}

/// Load a mock API response fixture
#[allow(dead_code)]
pub fn load_response_fixture(name: &str) -> String {
    load_fixture(&format!("responses/{}", name))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fixture_path() {
        let path = fixture_path("bibtex/simple.bib");
        assert!(path.to_string_lossy().contains("test_fixtures"));
    }

    #[test]
    fn test_load_bibtex_fixture() {
        let content = load_bibtex_fixture("simple.bib");
        assert!(content.contains("@article"));
    }

    #[test]
    fn test_load_ris_fixture() {
        let content = load_ris_fixture("sample.ris");
        assert!(content.contains("TY  -"));
    }
}
