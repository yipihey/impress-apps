//! Automation module for URL scheme and command handling
//!
//! Parses imbib:// URLs and executes automation commands.
//! URL format: imbib://command/subcommand?param1=value1&param2=value2

use std::collections::HashMap;
use url::Url;

/// Bibliography synchronization action for cross-app communication
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum BibSyncAction {
    /// Export bibliography from imprint to imbib
    Export,
    /// Import from imbib library to imprint
    Import,
    /// Check for missing citations
    Verify,
}

/// Supported automation commands
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum AutomationCommand {
    /// Search across all configured sources
    Search(SearchCommand),
    /// Import publications from URL or content
    Import(ImportCommand),
    /// Open a publication by identifier
    Open(OpenCommand),
    /// Lookup and enrich a publication
    Lookup(LookupCommand),
    /// Export publications
    Export(ExportCommand),
    /// Library management
    Library(LibraryCommand),
    // Cross-app commands (imbib <-> imprint)
    /// Insert a citation into an imprint document
    InsertCitation(InsertCitationCommand),
    /// Open a manuscript in imprint
    OpenManuscript(OpenManuscriptCommand),
    /// Synchronize bibliography between apps
    SyncBibliography(SyncBibliographyCommand),
    /// Unknown command
    Unknown(String),
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SearchCommand {
    pub query: String,
    pub source: Option<String>,
    pub max_results: Option<i32>,
    pub auto_import: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImportCommand {
    pub url: Option<String>,
    pub content: Option<String>,
    pub format: Option<String>,
    pub library: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct OpenCommand {
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub bibcode: Option<String>,
    pub cite_key: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct LookupCommand {
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub bibcode: Option<String>,
    pub title: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ExportCommand {
    pub format: String,
    pub cite_keys: Vec<String>,
    pub library: Option<String>,
    pub destination: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct LibraryCommand {
    pub action: String,
    pub name: Option<String>,
    pub path: Option<String>,
}

// Cross-app command structs

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct InsertCitationCommand {
    pub cite_key: String,
    pub imprint_document_id: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct OpenManuscriptCommand {
    pub manuscript_id: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SyncBibliographyCommand {
    pub imprint_document_id: String,
    pub action: BibSyncAction,
}

/// Parse result with command and any errors
#[derive(uniffi::Record, Clone, Debug)]
pub struct ParseResult {
    pub command: Option<AutomationCommand>,
    pub error: Option<String>,
}

pub fn parse_url_command_internal(url_string: String) -> ParseResult {
    let url = match Url::parse(&url_string) {
        Ok(u) => u,
        Err(e) => {
            return ParseResult {
                command: None,
                error: Some(format!("Invalid URL: {}", e)),
            }
        }
    };

    // Check scheme
    if url.scheme() != "imbib" {
        return ParseResult {
            command: None,
            error: Some(format!("Unexpected scheme: {}", url.scheme())),
        };
    }

    // Get command from host
    let command_name = match url.host_str() {
        Some(h) => h.to_lowercase(),
        None => {
            return ParseResult {
                command: None,
                error: Some("Missing command".to_string()),
            }
        }
    };

    // Parse query parameters
    let params: HashMap<String, String> = url
        .query_pairs()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();

    let command = match command_name.as_str() {
        "search" => parse_search_command(&params),
        "import" => parse_import_command(&params),
        "open" => parse_open_command(&params),
        "lookup" => parse_lookup_command(&params),
        "export" => parse_export_command(&params),
        "library" => parse_library_command(&params),
        // Cross-app commands
        "insert-citation" => parse_insert_citation_command(&params),
        "open-manuscript" => parse_open_manuscript_command(&params),
        "sync-bibliography" => parse_sync_bibliography_command(&params),
        _ => AutomationCommand::Unknown(command_name),
    };

    ParseResult {
        command: Some(command),
        error: None,
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn parse_url_command(url_string: String) -> ParseResult {
    parse_url_command_internal(url_string)
}

fn parse_search_command(params: &HashMap<String, String>) -> AutomationCommand {
    AutomationCommand::Search(SearchCommand {
        query: params
            .get("query")
            .or_else(|| params.get("q"))
            .cloned()
            .unwrap_or_default(),
        source: params.get("source").or_else(|| params.get("src")).cloned(),
        max_results: params
            .get("max")
            .or_else(|| params.get("limit"))
            .and_then(|s| s.parse().ok()),
        auto_import: params
            .get("autoimport")
            .or_else(|| params.get("import"))
            .map(|v| v == "true" || v == "1")
            .unwrap_or(false),
    })
}

fn parse_import_command(params: &HashMap<String, String>) -> AutomationCommand {
    AutomationCommand::Import(ImportCommand {
        url: params.get("url").cloned(),
        content: params
            .get("content")
            .or_else(|| params.get("data"))
            .cloned(),
        format: params.get("format").or_else(|| params.get("fmt")).cloned(),
        library: params.get("library").or_else(|| params.get("lib")).cloned(),
    })
}

fn parse_open_command(params: &HashMap<String, String>) -> AutomationCommand {
    AutomationCommand::Open(OpenCommand {
        doi: params.get("doi").cloned(),
        arxiv_id: params
            .get("arxiv")
            .or_else(|| params.get("arxiv_id"))
            .cloned(),
        bibcode: params.get("bibcode").cloned(),
        cite_key: params.get("key").or_else(|| params.get("citekey")).cloned(),
    })
}

fn parse_lookup_command(params: &HashMap<String, String>) -> AutomationCommand {
    AutomationCommand::Lookup(LookupCommand {
        doi: params.get("doi").cloned(),
        arxiv_id: params
            .get("arxiv")
            .or_else(|| params.get("arxiv_id"))
            .cloned(),
        bibcode: params.get("bibcode").cloned(),
        title: params.get("title").cloned(),
    })
}

fn parse_export_command(params: &HashMap<String, String>) -> AutomationCommand {
    let keys_str = params
        .get("keys")
        .or_else(|| params.get("citekeys"))
        .cloned()
        .unwrap_or_default();
    let cite_keys: Vec<String> = keys_str
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    AutomationCommand::Export(ExportCommand {
        format: params
            .get("format")
            .or_else(|| params.get("fmt"))
            .cloned()
            .unwrap_or_else(|| "bibtex".to_string()),
        cite_keys,
        library: params.get("library").or_else(|| params.get("lib")).cloned(),
        destination: params.get("dest").or_else(|| params.get("output")).cloned(),
    })
}

fn parse_library_command(params: &HashMap<String, String>) -> AutomationCommand {
    AutomationCommand::Library(LibraryCommand {
        action: params
            .get("action")
            .cloned()
            .unwrap_or_else(|| "list".to_string()),
        name: params.get("name").cloned(),
        path: params.get("path").cloned(),
    })
}

// Cross-app command parsers

fn parse_insert_citation_command(params: &HashMap<String, String>) -> AutomationCommand {
    AutomationCommand::InsertCitation(InsertCitationCommand {
        cite_key: params
            .get("cite_key")
            .or_else(|| params.get("key"))
            .cloned()
            .unwrap_or_default(),
        imprint_document_id: params
            .get("document")
            .or_else(|| params.get("doc_id"))
            .cloned(),
    })
}

fn parse_open_manuscript_command(params: &HashMap<String, String>) -> AutomationCommand {
    AutomationCommand::OpenManuscript(OpenManuscriptCommand {
        manuscript_id: params
            .get("id")
            .or_else(|| params.get("manuscript_id"))
            .cloned()
            .unwrap_or_default(),
    })
}

fn parse_sync_bibliography_command(params: &HashMap<String, String>) -> AutomationCommand {
    let action = params
        .get("action")
        .map(|s| s.to_lowercase())
        .map(|s| match s.as_str() {
            "export" => BibSyncAction::Export,
            "import" => BibSyncAction::Import,
            "verify" | "check" => BibSyncAction::Verify,
            _ => BibSyncAction::Verify, // Default to verify for unknown actions
        })
        .unwrap_or(BibSyncAction::Verify);

    AutomationCommand::SyncBibliography(SyncBibliographyCommand {
        imprint_document_id: params
            .get("document")
            .or_else(|| params.get("doc_id"))
            .cloned()
            .unwrap_or_default(),
        action,
    })
}

pub fn build_search_url_internal(
    query: String,
    source: Option<String>,
    max_results: Option<i32>,
) -> String {
    let mut url = format!("imbib://search?query={}", urlencoding::encode(&query));
    if let Some(src) = source {
        url.push_str(&format!("&source={}", urlencoding::encode(&src)));
    }
    if let Some(max) = max_results {
        url.push_str(&format!("&max={}", max));
    }
    url
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn build_search_url(query: String, source: Option<String>, max_results: Option<i32>) -> String {
    build_search_url_internal(query, source, max_results)
}

pub fn build_open_url_internal(
    doi: Option<String>,
    arxiv_id: Option<String>,
    cite_key: Option<String>,
) -> String {
    let mut params = Vec::new();
    if let Some(d) = doi {
        params.push(format!("doi={}", urlencoding::encode(&d)));
    }
    if let Some(a) = arxiv_id {
        params.push(format!("arxiv={}", urlencoding::encode(&a)));
    }
    if let Some(k) = cite_key {
        params.push(format!("key={}", urlencoding::encode(&k)));
    }
    format!("imbib://open?{}", params.join("&"))
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn build_open_url(
    doi: Option<String>,
    arxiv_id: Option<String>,
    cite_key: Option<String>,
) -> String {
    build_open_url_internal(doi, arxiv_id, cite_key)
}

pub fn build_lookup_url_internal(
    doi: Option<String>,
    arxiv_id: Option<String>,
    title: Option<String>,
) -> String {
    let mut params = Vec::new();
    if let Some(d) = doi {
        params.push(format!("doi={}", urlencoding::encode(&d)));
    }
    if let Some(a) = arxiv_id {
        params.push(format!("arxiv={}", urlencoding::encode(&a)));
    }
    if let Some(t) = title {
        params.push(format!("title={}", urlencoding::encode(&t)));
    }
    format!("imbib://lookup?{}", params.join("&"))
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn build_lookup_url(
    doi: Option<String>,
    arxiv_id: Option<String>,
    title: Option<String>,
) -> String {
    build_lookup_url_internal(doi, arxiv_id, title)
}

// Cross-app URL builders

pub fn build_insert_citation_url_internal(
    cite_key: String,
    document_id: Option<String>,
) -> String {
    let mut url = format!(
        "imbib://insert-citation?cite_key={}",
        urlencoding::encode(&cite_key)
    );
    if let Some(doc_id) = document_id {
        url.push_str(&format!("&document={}", urlencoding::encode(&doc_id)));
    }
    url
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn build_insert_citation_url(cite_key: String, document_id: Option<String>) -> String {
    build_insert_citation_url_internal(cite_key, document_id)
}

pub fn build_open_manuscript_url_internal(manuscript_id: String) -> String {
    format!(
        "imbib://open-manuscript?id={}",
        urlencoding::encode(&manuscript_id)
    )
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn build_open_manuscript_url(manuscript_id: String) -> String {
    build_open_manuscript_url_internal(manuscript_id)
}

pub fn build_sync_bibliography_url_internal(document_id: String, action: BibSyncAction) -> String {
    let action_str = match action {
        BibSyncAction::Export => "export",
        BibSyncAction::Import => "import",
        BibSyncAction::Verify => "verify",
    };
    format!(
        "imbib://sync-bibliography?document={}&action={}",
        urlencoding::encode(&document_id),
        action_str
    )
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn build_sync_bibliography_url(document_id: String, action: BibSyncAction) -> String {
    build_sync_bibliography_url_internal(document_id, action)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_search_url() {
        let result =
            parse_url_command("imbib://search?query=einstein&source=ads&max=50".to_string());
        assert!(result.error.is_none());
        match result.command {
            Some(AutomationCommand::Search(cmd)) => {
                assert_eq!(cmd.query, "einstein");
                assert_eq!(cmd.source, Some("ads".to_string()));
                assert_eq!(cmd.max_results, Some(50));
            }
            _ => panic!("Expected search command"),
        }
    }

    #[test]
    fn test_parse_open_url() {
        let result = parse_url_command("imbib://open?doi=10.1234/test".to_string());
        assert!(result.error.is_none());
        match result.command {
            Some(AutomationCommand::Open(cmd)) => {
                assert_eq!(cmd.doi, Some("10.1234/test".to_string()));
            }
            _ => panic!("Expected open command"),
        }
    }

    #[test]
    fn test_parse_lookup_url() {
        let result = parse_url_command("imbib://lookup?arxiv=2301.12345".to_string());
        assert!(result.error.is_none());
        match result.command {
            Some(AutomationCommand::Lookup(cmd)) => {
                assert_eq!(cmd.arxiv_id, Some("2301.12345".to_string()));
            }
            _ => panic!("Expected lookup command"),
        }
    }

    #[test]
    fn test_parse_export_url() {
        let result = parse_url_command("imbib://export?format=ris&keys=key1,key2,key3".to_string());
        assert!(result.error.is_none());
        match result.command {
            Some(AutomationCommand::Export(cmd)) => {
                assert_eq!(cmd.format, "ris");
                assert_eq!(cmd.cite_keys.len(), 3);
            }
            _ => panic!("Expected export command"),
        }
    }

    #[test]
    fn test_build_search_url() {
        let url = build_search_url(
            "test query".to_string(),
            Some("arxiv".to_string()),
            Some(20),
        );
        assert!(url.contains("query=test%20query"));
        assert!(url.contains("source=arxiv"));
        assert!(url.contains("max=20"));
    }

    #[test]
    fn test_parse_invalid_scheme() {
        let result = parse_url_command("https://example.com".to_string());
        assert!(result.error.is_some());
    }

    #[test]
    fn test_parse_unknown_command() {
        let result = parse_url_command("imbib://unknown?param=value".to_string());
        assert!(result.error.is_none());
        match result.command {
            Some(AutomationCommand::Unknown(cmd)) => {
                assert_eq!(cmd, "unknown");
            }
            _ => panic!("Expected unknown command"),
        }
    }

    // Cross-app command tests

    #[test]
    fn test_parse_insert_citation_url() {
        let result = parse_url_command(
            "imbib://insert-citation?cite_key=Smith2024&document=abc123".to_string(),
        );
        assert!(result.error.is_none());
        match result.command {
            Some(AutomationCommand::InsertCitation(cmd)) => {
                assert_eq!(cmd.cite_key, "Smith2024");
                assert_eq!(cmd.imprint_document_id, Some("abc123".to_string()));
            }
            _ => panic!("Expected insert-citation command"),
        }
    }

    #[test]
    fn test_parse_insert_citation_url_no_document() {
        let result = parse_url_command("imbib://insert-citation?cite_key=Smith2024".to_string());
        assert!(result.error.is_none());
        match result.command {
            Some(AutomationCommand::InsertCitation(cmd)) => {
                assert_eq!(cmd.cite_key, "Smith2024");
                assert_eq!(cmd.imprint_document_id, None);
            }
            _ => panic!("Expected insert-citation command"),
        }
    }

    #[test]
    fn test_parse_open_manuscript_url() {
        let result = parse_url_command("imbib://open-manuscript?id=xyz789".to_string());
        assert!(result.error.is_none());
        match result.command {
            Some(AutomationCommand::OpenManuscript(cmd)) => {
                assert_eq!(cmd.manuscript_id, "xyz789");
            }
            _ => panic!("Expected open-manuscript command"),
        }
    }

    #[test]
    fn test_parse_sync_bibliography_url_export() {
        let result =
            parse_url_command("imbib://sync-bibliography?document=abc123&action=export".to_string());
        assert!(result.error.is_none());
        match result.command {
            Some(AutomationCommand::SyncBibliography(cmd)) => {
                assert_eq!(cmd.imprint_document_id, "abc123");
                assert_eq!(cmd.action, BibSyncAction::Export);
            }
            _ => panic!("Expected sync-bibliography command"),
        }
    }

    #[test]
    fn test_parse_sync_bibliography_url_import() {
        let result =
            parse_url_command("imbib://sync-bibliography?document=abc123&action=import".to_string());
        assert!(result.error.is_none());
        match result.command {
            Some(AutomationCommand::SyncBibliography(cmd)) => {
                assert_eq!(cmd.imprint_document_id, "abc123");
                assert_eq!(cmd.action, BibSyncAction::Import);
            }
            _ => panic!("Expected sync-bibliography command"),
        }
    }

    #[test]
    fn test_parse_sync_bibliography_url_verify() {
        let result =
            parse_url_command("imbib://sync-bibliography?document=abc123&action=verify".to_string());
        assert!(result.error.is_none());
        match result.command {
            Some(AutomationCommand::SyncBibliography(cmd)) => {
                assert_eq!(cmd.imprint_document_id, "abc123");
                assert_eq!(cmd.action, BibSyncAction::Verify);
            }
            _ => panic!("Expected sync-bibliography command"),
        }
    }

    #[test]
    fn test_build_insert_citation_url() {
        let url = build_insert_citation_url_internal(
            "Smith2024".to_string(),
            Some("doc123".to_string()),
        );
        assert!(url.contains("insert-citation"));
        assert!(url.contains("cite_key=Smith2024"));
        assert!(url.contains("document=doc123"));
    }

    #[test]
    fn test_build_insert_citation_url_no_document() {
        let url = build_insert_citation_url_internal("Smith2024".to_string(), None);
        assert!(url.contains("insert-citation"));
        assert!(url.contains("cite_key=Smith2024"));
        assert!(!url.contains("document="));
    }

    #[test]
    fn test_build_open_manuscript_url() {
        let url = build_open_manuscript_url_internal("manuscript123".to_string());
        assert!(url.contains("open-manuscript"));
        assert!(url.contains("id=manuscript123"));
    }

    #[test]
    fn test_build_sync_bibliography_url_export() {
        let url =
            build_sync_bibliography_url_internal("doc456".to_string(), BibSyncAction::Export);
        assert!(url.contains("sync-bibliography"));
        assert!(url.contains("document=doc456"));
        assert!(url.contains("action=export"));
    }

    #[test]
    fn test_build_sync_bibliography_url_import() {
        let url =
            build_sync_bibliography_url_internal("doc456".to_string(), BibSyncAction::Import);
        assert!(url.contains("action=import"));
    }

    #[test]
    fn test_build_sync_bibliography_url_verify() {
        let url =
            build_sync_bibliography_url_internal("doc456".to_string(), BibSyncAction::Verify);
        assert!(url.contains("action=verify"));
    }

    #[test]
    fn test_roundtrip_insert_citation() {
        let original_key = "Einstein1905";
        let original_doc = Some("doc-uuid-123".to_string());
        let url = build_insert_citation_url_internal(original_key.to_string(), original_doc.clone());
        let result = parse_url_command_internal(url);
        match result.command {
            Some(AutomationCommand::InsertCitation(cmd)) => {
                assert_eq!(cmd.cite_key, original_key);
                assert_eq!(cmd.imprint_document_id, original_doc);
            }
            _ => panic!("Roundtrip failed for insert-citation"),
        }
    }

    #[test]
    fn test_roundtrip_sync_bibliography() {
        let original_doc = "doc-uuid-456";
        let original_action = BibSyncAction::Export;
        let url = build_sync_bibliography_url_internal(
            original_doc.to_string(),
            original_action.clone(),
        );
        let result = parse_url_command_internal(url);
        match result.command {
            Some(AutomationCommand::SyncBibliography(cmd)) => {
                assert_eq!(cmd.imprint_document_id, original_doc);
                assert_eq!(cmd.action, original_action);
            }
            _ => panic!("Roundtrip failed for sync-bibliography"),
        }
    }
}
