//! Automation module for URL scheme and command handling
//!
//! Parses imprint:// URLs and executes automation commands.
//! URL format: imprint://command/subcommand?param1=value1&param2=value2
//!
//! # Supported Commands
//!
//! - `imprint://open` - Open a document by ID or path
//! - `imprint://new` - Create a new document
//! - `imprint://insert-citation` - Insert a citation from imbib
//! - `imprint://export` - Export document to various formats
//! - `imprint://share` - Share a document with collaborators
//! - `imprint://import-notes` - Import annotations from imbib
//! - `imprint://sync` - Trigger sync with collaboration peers
//! - `imprint://compile` - Compile document to PDF
//!
//! # Cross-App Integration
//!
//! These commands enable integration with imbib for citation management:
//!
//! ```text
//! imbib → imprint://insert-citation?cite_key=Smith2024&position=123
//! imbib → imprint://import-notes?publication_id=abc&document_id=xyz
//! ```

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use thiserror::Error;

/// Errors that can occur during URL parsing
#[derive(Debug, Error)]
pub enum AutomationError {
    /// Invalid URL format
    #[error("Invalid URL: {0}")]
    InvalidUrl(String),

    /// Missing required parameter
    #[error("Missing required parameter: {0}")]
    MissingParameter(String),

    /// Unknown command
    #[error("Unknown command: {0}")]
    UnknownCommand(String),

    /// Invalid scheme (expected imprint://)
    #[error("Invalid scheme: expected 'imprint', got '{0}'")]
    InvalidScheme(String),
}

/// Supported automation commands for imprint
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ImprintCommand {
    /// Open a document
    Open(OpenDocumentCommand),
    /// Create a new document
    New(NewDocumentCommand),
    /// Insert a citation
    InsertCitation(InsertCitationCommand),
    /// Export document
    Export(ExportCommand),
    /// Share document
    Share(ShareCommand),
    /// Import notes from imbib
    ImportNotes(ImportNotesCommand),
    /// Sync with collaborators
    Sync(SyncCommand),
    /// Compile document to output format
    Compile(CompileCommand),
    /// Set edit mode
    SetEditMode(SetEditModeCommand),
    /// Navigate to position
    Navigate(NavigateCommand),
    /// Unknown command
    Unknown(String),
}

/// Open a document by ID or path
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct OpenDocumentCommand {
    /// Document ID (UUID)
    pub document_id: Option<String>,
    /// File path
    pub path: Option<String>,
    /// Open in specific edit mode
    pub edit_mode: Option<String>,
    /// Navigate to position after opening
    pub position: Option<u64>,
}

/// Create a new document
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct NewDocumentCommand {
    /// Document title
    pub title: Option<String>,
    /// Template to use
    pub template: Option<String>,
    /// Initial content
    pub content: Option<String>,
    /// Associated manuscript ID (in imbib)
    pub manuscript_id: Option<String>,
}

/// Insert a citation into the document
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct InsertCitationCommand {
    /// Citation key to insert
    pub cite_key: String,
    /// Target document ID
    pub document_id: Option<String>,
    /// Position to insert at (character offset)
    pub position: Option<u64>,
    /// BibTeX entry to add to bibliography
    pub bibtex: Option<String>,
    /// Publication ID in imbib
    pub publication_id: Option<String>,
}

/// Export document to a format
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ExportCommand {
    /// Document ID to export
    pub document_id: String,
    /// Output format (pdf, latex, docx, html, typst)
    pub format: String,
    /// Destination path
    pub destination: Option<String>,
    /// Include bibliography file
    pub include_bibliography: bool,
}

/// Share document with collaborators
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ShareCommand {
    /// Document ID to share
    pub document_id: String,
    /// Share action (invite, revoke, list)
    pub action: ShareAction,
    /// Email of collaborator (for invite/revoke)
    pub email: Option<String>,
    /// Permission level (view, comment, edit)
    pub permission: Option<String>,
}

/// Share actions
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ShareAction {
    /// Invite a collaborator
    Invite,
    /// Revoke access
    Revoke,
    /// List current collaborators
    List,
    /// Generate a shareable link
    CreateLink,
}

/// Import notes from imbib PDF annotations
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ImportNotesCommand {
    /// Target document ID
    pub document_id: String,
    /// Publication ID in imbib to import from
    pub publication_id: String,
    /// Import format (quote, margin_note, inline)
    pub format: Option<String>,
    /// Position to insert at
    pub position: Option<u64>,
    /// Filter by annotation type (highlight, note, all)
    pub annotation_type: Option<String>,
}

/// Sync with collaborators
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct SyncCommand {
    /// Document ID to sync
    pub document_id: Option<String>,
    /// Sync all documents
    pub all: bool,
    /// Force full sync (ignore cache)
    pub force: bool,
}

/// Compile document to output
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CompileCommand {
    /// Document ID to compile
    pub document_id: String,
    /// Output format (pdf, svg, png)
    pub format: Option<String>,
    /// Destination path
    pub destination: Option<String>,
    /// Draft mode (faster, lower quality)
    pub draft: bool,
}

/// Set the edit mode
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct SetEditModeCommand {
    /// Document ID
    pub document_id: Option<String>,
    /// Mode (direct_pdf, split_view, text_only)
    pub mode: String,
}

/// Navigate to a position in the document
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct NavigateCommand {
    /// Document ID
    pub document_id: Option<String>,
    /// Position type
    pub position_type: NavigationTarget,
    /// Position value (line number, character offset, page number, or search term)
    pub value: String,
}

/// Navigation target types
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum NavigationTarget {
    /// Go to line number
    Line,
    /// Go to character offset
    Offset,
    /// Go to page (in PDF preview)
    Page,
    /// Search for text
    Search,
    /// Go to citation
    Citation,
}

/// Parse result with command and any errors
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ParseResult {
    /// Parsed command (if successful)
    pub command: Option<ImprintCommand>,
    /// Error message (if failed)
    pub error: Option<String>,
}

/// Parse an imprint:// URL into a command
pub fn parse_url_command(url_string: &str) -> ParseResult {
    // Parse the URL
    let url = match url::Url::parse(url_string) {
        Ok(u) => u,
        Err(e) => {
            return ParseResult {
                command: None,
                error: Some(format!("Invalid URL: {}", e)),
            }
        }
    };

    // Verify scheme
    if url.scheme() != "imprint" {
        return ParseResult {
            command: None,
            error: Some(format!(
                "Invalid scheme: expected 'imprint', got '{}'",
                url.scheme()
            )),
        };
    }

    // Get command name from host
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

    // Parse command based on name
    let command = match command_name.as_str() {
        "open" => parse_open_command(&params),
        "new" => parse_new_command(&params),
        "insert-citation" | "cite" => parse_insert_citation_command(&params),
        "export" => parse_export_command(&params),
        "share" => parse_share_command(&params),
        "import-notes" | "import" => parse_import_notes_command(&params),
        "sync" => parse_sync_command(&params),
        "compile" | "render" => parse_compile_command(&params),
        "mode" | "set-mode" => parse_set_edit_mode_command(&params),
        "navigate" | "goto" => parse_navigate_command(&params),
        _ => ImprintCommand::Unknown(command_name),
    };

    ParseResult {
        command: Some(command),
        error: None,
    }
}

// FFI wrapper
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn parse_imprint_url(url_string: String) -> ParseResult {
    parse_url_command(&url_string)
}

fn parse_open_command(params: &HashMap<String, String>) -> ImprintCommand {
    ImprintCommand::Open(OpenDocumentCommand {
        document_id: params
            .get("id")
            .or_else(|| params.get("document_id"))
            .cloned(),
        path: params.get("path").or_else(|| params.get("file")).cloned(),
        edit_mode: params
            .get("mode")
            .or_else(|| params.get("edit_mode"))
            .cloned(),
        position: params
            .get("position")
            .or_else(|| params.get("pos"))
            .and_then(|s| s.parse().ok()),
    })
}

fn parse_new_command(params: &HashMap<String, String>) -> ImprintCommand {
    ImprintCommand::New(NewDocumentCommand {
        title: params.get("title").cloned(),
        template: params.get("template").cloned(),
        content: params.get("content").cloned(),
        manuscript_id: params
            .get("manuscript_id")
            .or_else(|| params.get("manuscript"))
            .cloned(),
    })
}

fn parse_insert_citation_command(params: &HashMap<String, String>) -> ImprintCommand {
    ImprintCommand::InsertCitation(InsertCitationCommand {
        cite_key: params
            .get("cite_key")
            .or_else(|| params.get("key"))
            .cloned()
            .unwrap_or_default(),
        document_id: params
            .get("document_id")
            .or_else(|| params.get("document"))
            .or_else(|| params.get("doc"))
            .cloned(),
        position: params
            .get("position")
            .or_else(|| params.get("pos"))
            .and_then(|s| s.parse().ok()),
        bibtex: params.get("bibtex").cloned(),
        publication_id: params
            .get("publication_id")
            .or_else(|| params.get("pub_id"))
            .cloned(),
    })
}

fn parse_export_command(params: &HashMap<String, String>) -> ImprintCommand {
    ImprintCommand::Export(ExportCommand {
        document_id: params
            .get("document_id")
            .or_else(|| params.get("document"))
            .or_else(|| params.get("id"))
            .cloned()
            .unwrap_or_default(),
        format: params
            .get("format")
            .or_else(|| params.get("fmt"))
            .cloned()
            .unwrap_or_else(|| "pdf".to_string()),
        destination: params
            .get("destination")
            .or_else(|| params.get("dest"))
            .or_else(|| params.get("output"))
            .cloned(),
        include_bibliography: params
            .get("include_bib")
            .or_else(|| params.get("bib"))
            .map(|v| v == "true" || v == "1")
            .unwrap_or(true),
    })
}

fn parse_share_command(params: &HashMap<String, String>) -> ImprintCommand {
    let action = params
        .get("action")
        .map(|s| match s.to_lowercase().as_str() {
            "invite" | "add" => ShareAction::Invite,
            "revoke" | "remove" => ShareAction::Revoke,
            "list" => ShareAction::List,
            "link" | "create_link" => ShareAction::CreateLink,
            _ => ShareAction::List,
        })
        .unwrap_or(ShareAction::List);

    ImprintCommand::Share(ShareCommand {
        document_id: params
            .get("document_id")
            .or_else(|| params.get("document"))
            .or_else(|| params.get("id"))
            .cloned()
            .unwrap_or_default(),
        action,
        email: params.get("email").cloned(),
        permission: params
            .get("permission")
            .or_else(|| params.get("perm"))
            .cloned(),
    })
}

fn parse_import_notes_command(params: &HashMap<String, String>) -> ImprintCommand {
    ImprintCommand::ImportNotes(ImportNotesCommand {
        document_id: params
            .get("document_id")
            .or_else(|| params.get("document"))
            .cloned()
            .unwrap_or_default(),
        publication_id: params
            .get("publication_id")
            .or_else(|| params.get("pub_id"))
            .or_else(|| params.get("publication"))
            .cloned()
            .unwrap_or_default(),
        format: params.get("format").cloned(),
        position: params
            .get("position")
            .or_else(|| params.get("pos"))
            .and_then(|s| s.parse().ok()),
        annotation_type: params
            .get("type")
            .or_else(|| params.get("annotation_type"))
            .cloned(),
    })
}

fn parse_sync_command(params: &HashMap<String, String>) -> ImprintCommand {
    ImprintCommand::Sync(SyncCommand {
        document_id: params
            .get("document_id")
            .or_else(|| params.get("document"))
            .or_else(|| params.get("id"))
            .cloned(),
        all: params
            .get("all")
            .map(|v| v == "true" || v == "1")
            .unwrap_or(false),
        force: params
            .get("force")
            .map(|v| v == "true" || v == "1")
            .unwrap_or(false),
    })
}

fn parse_compile_command(params: &HashMap<String, String>) -> ImprintCommand {
    ImprintCommand::Compile(CompileCommand {
        document_id: params
            .get("document_id")
            .or_else(|| params.get("document"))
            .or_else(|| params.get("id"))
            .cloned()
            .unwrap_or_default(),
        format: params.get("format").or_else(|| params.get("fmt")).cloned(),
        destination: params
            .get("destination")
            .or_else(|| params.get("dest"))
            .cloned(),
        draft: params
            .get("draft")
            .map(|v| v == "true" || v == "1")
            .unwrap_or(false),
    })
}

fn parse_set_edit_mode_command(params: &HashMap<String, String>) -> ImprintCommand {
    ImprintCommand::SetEditMode(SetEditModeCommand {
        document_id: params
            .get("document_id")
            .or_else(|| params.get("document"))
            .cloned(),
        mode: params
            .get("mode")
            .cloned()
            .unwrap_or_else(|| "split_view".to_string()),
    })
}

fn parse_navigate_command(params: &HashMap<String, String>) -> ImprintCommand {
    let position_type = params
        .get("type")
        .map(|s| match s.to_lowercase().as_str() {
            "line" => NavigationTarget::Line,
            "offset" | "pos" => NavigationTarget::Offset,
            "page" => NavigationTarget::Page,
            "search" | "find" => NavigationTarget::Search,
            "citation" | "cite" => NavigationTarget::Citation,
            _ => NavigationTarget::Line,
        })
        .unwrap_or(NavigationTarget::Line);

    ImprintCommand::Navigate(NavigateCommand {
        document_id: params
            .get("document_id")
            .or_else(|| params.get("document"))
            .cloned(),
        position_type,
        value: params
            .get("value")
            .or_else(|| params.get("v"))
            .or_else(|| params.get("line"))
            .or_else(|| params.get("page"))
            .cloned()
            .unwrap_or_default(),
    })
}

// ===== URL Builders =====

/// Build an open document URL
pub fn build_open_url(document_id: Option<&str>, path: Option<&str>) -> String {
    let mut params = Vec::new();
    if let Some(id) = document_id {
        params.push(format!("id={}", urlencoding::encode(id)));
    }
    if let Some(p) = path {
        params.push(format!("path={}", urlencoding::encode(p)));
    }
    if params.is_empty() {
        "imprint://open".to_string()
    } else {
        format!("imprint://open?{}", params.join("&"))
    }
}

/// Build a new document URL
pub fn build_new_url(title: Option<&str>, template: Option<&str>) -> String {
    let mut params = Vec::new();
    if let Some(t) = title {
        params.push(format!("title={}", urlencoding::encode(t)));
    }
    if let Some(tpl) = template {
        params.push(format!("template={}", urlencoding::encode(tpl)));
    }
    if params.is_empty() {
        "imprint://new".to_string()
    } else {
        format!("imprint://new?{}", params.join("&"))
    }
}

/// Build an insert citation URL
pub fn build_insert_citation_url(
    cite_key: &str,
    document_id: Option<&str>,
    position: Option<u64>,
) -> String {
    let mut url = format!(
        "imprint://insert-citation?cite_key={}",
        urlencoding::encode(cite_key)
    );
    if let Some(doc_id) = document_id {
        url.push_str(&format!("&document={}", urlencoding::encode(doc_id)));
    }
    if let Some(pos) = position {
        url.push_str(&format!("&position={}", pos));
    }
    url
}

/// Build an export URL
pub fn build_export_url(document_id: &str, format: &str, destination: Option<&str>) -> String {
    let mut url = format!(
        "imprint://export?document={}&format={}",
        urlencoding::encode(document_id),
        urlencoding::encode(format)
    );
    if let Some(dest) = destination {
        url.push_str(&format!("&dest={}", urlencoding::encode(dest)));
    }
    url
}

/// Build an import notes URL
pub fn build_import_notes_url(
    document_id: &str,
    publication_id: &str,
    format: Option<&str>,
) -> String {
    let mut url = format!(
        "imprint://import-notes?document={}&publication_id={}",
        urlencoding::encode(document_id),
        urlencoding::encode(publication_id)
    );
    if let Some(fmt) = format {
        url.push_str(&format!("&format={}", urlencoding::encode(fmt)));
    }
    url
}

/// Build a compile URL
pub fn build_compile_url(document_id: &str, format: Option<&str>, draft: bool) -> String {
    let mut url = format!(
        "imprint://compile?document={}",
        urlencoding::encode(document_id)
    );
    if let Some(fmt) = format {
        url.push_str(&format!("&format={}", urlencoding::encode(fmt)));
    }
    if draft {
        url.push_str("&draft=true");
    }
    url
}

/// Build a share URL
pub fn build_share_url(document_id: &str, action: ShareAction, email: Option<&str>) -> String {
    let action_str = match action {
        ShareAction::Invite => "invite",
        ShareAction::Revoke => "revoke",
        ShareAction::List => "list",
        ShareAction::CreateLink => "link",
    };
    let mut url = format!(
        "imprint://share?document={}&action={}",
        urlencoding::encode(document_id),
        action_str
    );
    if let Some(e) = email {
        url.push_str(&format!("&email={}", urlencoding::encode(e)));
    }
    url
}

// FFI wrappers for URL builders
#[cfg(feature = "uniffi")]
mod ffi {
    use super::*;

    #[uniffi::export]
    pub fn build_imprint_open_url(document_id: Option<String>, path: Option<String>) -> String {
        build_open_url(document_id.as_deref(), path.as_deref())
    }

    #[uniffi::export]
    pub fn build_imprint_new_url(title: Option<String>, template: Option<String>) -> String {
        build_new_url(title.as_deref(), template.as_deref())
    }

    #[uniffi::export]
    pub fn build_imprint_insert_citation_url(
        cite_key: String,
        document_id: Option<String>,
        position: Option<u64>,
    ) -> String {
        build_insert_citation_url(&cite_key, document_id.as_deref(), position)
    }

    #[uniffi::export]
    pub fn build_imprint_export_url(
        document_id: String,
        format: String,
        destination: Option<String>,
    ) -> String {
        build_export_url(&document_id, &format, destination.as_deref())
    }

    #[uniffi::export]
    pub fn build_imprint_import_notes_url(
        document_id: String,
        publication_id: String,
        format: Option<String>,
    ) -> String {
        build_import_notes_url(&document_id, &publication_id, format.as_deref())
    }

    #[uniffi::export]
    pub fn build_imprint_compile_url(
        document_id: String,
        format: Option<String>,
        draft: bool,
    ) -> String {
        build_compile_url(&document_id, format.as_deref(), draft)
    }

    #[uniffi::export]
    pub fn build_imprint_share_url(
        document_id: String,
        action: ShareAction,
        email: Option<String>,
    ) -> String {
        build_share_url(&document_id, action, email.as_deref())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_open_url() {
        let result = parse_url_command("imprint://open?id=doc123&mode=split_view");
        assert!(result.error.is_none());
        match result.command {
            Some(ImprintCommand::Open(cmd)) => {
                assert_eq!(cmd.document_id, Some("doc123".to_string()));
                assert_eq!(cmd.edit_mode, Some("split_view".to_string()));
            }
            _ => panic!("Expected Open command"),
        }
    }

    #[test]
    fn test_parse_new_url() {
        let result = parse_url_command("imprint://new?title=My%20Paper&template=article");
        assert!(result.error.is_none());
        match result.command {
            Some(ImprintCommand::New(cmd)) => {
                assert_eq!(cmd.title, Some("My Paper".to_string()));
                assert_eq!(cmd.template, Some("article".to_string()));
            }
            _ => panic!("Expected New command"),
        }
    }

    #[test]
    fn test_parse_insert_citation_url() {
        let result = parse_url_command(
            "imprint://insert-citation?cite_key=Smith2024&document=abc&position=100",
        );
        assert!(result.error.is_none());
        match result.command {
            Some(ImprintCommand::InsertCitation(cmd)) => {
                assert_eq!(cmd.cite_key, "Smith2024");
                assert_eq!(cmd.document_id, Some("abc".to_string()));
                assert_eq!(cmd.position, Some(100));
            }
            _ => panic!("Expected InsertCitation command"),
        }
    }

    #[test]
    fn test_parse_export_url() {
        let result =
            parse_url_command("imprint://export?document=doc1&format=latex&dest=/tmp/out.tex");
        assert!(result.error.is_none());
        match result.command {
            Some(ImprintCommand::Export(cmd)) => {
                assert_eq!(cmd.document_id, "doc1");
                assert_eq!(cmd.format, "latex");
                assert_eq!(cmd.destination, Some("/tmp/out.tex".to_string()));
            }
            _ => panic!("Expected Export command"),
        }
    }

    #[test]
    fn test_parse_share_url() {
        let result = parse_url_command(
            "imprint://share?document=doc1&action=invite&email=test@example.com&permission=edit",
        );
        assert!(result.error.is_none());
        match result.command {
            Some(ImprintCommand::Share(cmd)) => {
                assert_eq!(cmd.document_id, "doc1");
                assert_eq!(cmd.action, ShareAction::Invite);
                assert_eq!(cmd.email, Some("test@example.com".to_string()));
                assert_eq!(cmd.permission, Some("edit".to_string()));
            }
            _ => panic!("Expected Share command"),
        }
    }

    #[test]
    fn test_parse_import_notes_url() {
        let result = parse_url_command(
            "imprint://import-notes?document=doc1&publication_id=pub1&format=quote&type=highlight",
        );
        assert!(result.error.is_none());
        match result.command {
            Some(ImprintCommand::ImportNotes(cmd)) => {
                assert_eq!(cmd.document_id, "doc1");
                assert_eq!(cmd.publication_id, "pub1");
                assert_eq!(cmd.format, Some("quote".to_string()));
                assert_eq!(cmd.annotation_type, Some("highlight".to_string()));
            }
            _ => panic!("Expected ImportNotes command"),
        }
    }

    #[test]
    fn test_parse_sync_url() {
        let result = parse_url_command("imprint://sync?document=doc1&force=true");
        assert!(result.error.is_none());
        match result.command {
            Some(ImprintCommand::Sync(cmd)) => {
                assert_eq!(cmd.document_id, Some("doc1".to_string()));
                assert!(cmd.force);
                assert!(!cmd.all);
            }
            _ => panic!("Expected Sync command"),
        }
    }

    #[test]
    fn test_parse_compile_url() {
        let result = parse_url_command("imprint://compile?document=doc1&format=pdf&draft=true");
        assert!(result.error.is_none());
        match result.command {
            Some(ImprintCommand::Compile(cmd)) => {
                assert_eq!(cmd.document_id, "doc1");
                assert_eq!(cmd.format, Some("pdf".to_string()));
                assert!(cmd.draft);
            }
            _ => panic!("Expected Compile command"),
        }
    }

    #[test]
    fn test_parse_navigate_url() {
        let result = parse_url_command("imprint://navigate?type=line&value=42");
        assert!(result.error.is_none());
        match result.command {
            Some(ImprintCommand::Navigate(cmd)) => {
                assert_eq!(cmd.position_type, NavigationTarget::Line);
                assert_eq!(cmd.value, "42");
            }
            _ => panic!("Expected Navigate command"),
        }
    }

    #[test]
    fn test_parse_unknown_command() {
        let result = parse_url_command("imprint://unknown?param=value");
        assert!(result.error.is_none());
        match result.command {
            Some(ImprintCommand::Unknown(cmd)) => {
                assert_eq!(cmd, "unknown");
            }
            _ => panic!("Expected Unknown command"),
        }
    }

    #[test]
    fn test_parse_invalid_scheme() {
        let result = parse_url_command("https://example.com");
        assert!(result.error.is_some());
        assert!(result.error.unwrap().contains("Invalid scheme"));
    }

    #[test]
    fn test_parse_invalid_url() {
        let result = parse_url_command("not a url");
        assert!(result.error.is_some());
    }

    // URL builder tests

    #[test]
    fn test_build_open_url() {
        let url = build_open_url(Some("doc123"), None);
        assert!(url.contains("imprint://open"));
        assert!(url.contains("id=doc123"));
    }

    #[test]
    fn test_build_insert_citation_url() {
        let url = build_insert_citation_url("Smith2024", Some("doc1"), Some(100));
        assert!(url.contains("insert-citation"));
        assert!(url.contains("cite_key=Smith2024"));
        assert!(url.contains("document=doc1"));
        assert!(url.contains("position=100"));
    }

    #[test]
    fn test_build_export_url() {
        let url = build_export_url("doc1", "latex", Some("/tmp/out.tex"));
        assert!(url.contains("export"));
        assert!(url.contains("document=doc1"));
        assert!(url.contains("format=latex"));
    }

    #[test]
    fn test_build_import_notes_url() {
        let url = build_import_notes_url("doc1", "pub1", Some("quote"));
        assert!(url.contains("import-notes"));
        assert!(url.contains("document=doc1"));
        assert!(url.contains("publication_id=pub1"));
        assert!(url.contains("format=quote"));
    }

    #[test]
    fn test_roundtrip_insert_citation() {
        let original_key = "Einstein1905";
        let original_doc = Some("doc-uuid");
        let original_pos = Some(42u64);

        let url = build_insert_citation_url(original_key, original_doc, original_pos);
        let result = parse_url_command(&url);

        match result.command {
            Some(ImprintCommand::InsertCitation(cmd)) => {
                assert_eq!(cmd.cite_key, original_key);
                assert_eq!(cmd.document_id.as_deref(), original_doc);
                assert_eq!(cmd.position, original_pos);
            }
            _ => panic!("Roundtrip failed"),
        }
    }

    #[test]
    fn test_command_alias_cite() {
        let result = parse_url_command("imprint://cite?key=Smith2024");
        match result.command {
            Some(ImprintCommand::InsertCitation(cmd)) => {
                assert_eq!(cmd.cite_key, "Smith2024");
            }
            _ => panic!("Expected InsertCitation via 'cite' alias"),
        }
    }

    #[test]
    fn test_roundtrip_new_document() {
        let original_title = Some("My Research Paper");
        let original_template = Some("article");

        let url = build_new_url(original_title, original_template);
        let result = parse_url_command(&url);

        match result.command {
            Some(ImprintCommand::New(cmd)) => {
                assert_eq!(cmd.title.as_deref(), original_title);
                assert_eq!(cmd.template.as_deref(), original_template);
            }
            _ => panic!("Roundtrip failed for new document"),
        }
    }

    #[test]
    fn test_roundtrip_export() {
        let original_doc = "doc-123";
        let original_format = "latex";
        let original_dest = Some("/tmp/output.tex");

        let url = build_export_url(original_doc, original_format, original_dest);
        let result = parse_url_command(&url);

        match result.command {
            Some(ImprintCommand::Export(cmd)) => {
                assert_eq!(cmd.document_id, original_doc);
                assert_eq!(cmd.format, original_format);
                assert_eq!(cmd.destination.as_deref(), original_dest);
            }
            _ => panic!("Roundtrip failed for export"),
        }
    }

    #[test]
    fn test_roundtrip_share() {
        let original_doc = "doc-456";
        let original_action = ShareAction::Invite;
        let original_email = Some("user@example.com");

        let url = build_share_url(original_doc, original_action.clone(), original_email);
        let result = parse_url_command(&url);

        match result.command {
            Some(ImprintCommand::Share(cmd)) => {
                assert_eq!(cmd.document_id, original_doc);
                assert_eq!(cmd.action, original_action);
                assert_eq!(cmd.email.as_deref(), original_email);
            }
            _ => panic!("Roundtrip failed for share"),
        }
    }

    #[test]
    fn test_roundtrip_compile() {
        let original_doc = "doc-789";
        let original_format = Some("pdf");
        let original_draft = true;

        let url = build_compile_url(original_doc, original_format, original_draft);
        let result = parse_url_command(&url);

        match result.command {
            Some(ImprintCommand::Compile(cmd)) => {
                assert_eq!(cmd.document_id, original_doc);
                assert_eq!(cmd.format.as_deref(), original_format);
                assert_eq!(cmd.draft, original_draft);
            }
            _ => panic!("Roundtrip failed for compile"),
        }
    }

    #[test]
    fn test_roundtrip_import_notes() {
        let original_doc = "doc-abc";
        let original_pub = "pub-xyz";
        let original_format = Some("quote");

        let url = build_import_notes_url(original_doc, original_pub, original_format);
        let result = parse_url_command(&url);

        match result.command {
            Some(ImprintCommand::ImportNotes(cmd)) => {
                assert_eq!(cmd.document_id, original_doc);
                assert_eq!(cmd.publication_id, original_pub);
                assert_eq!(cmd.format.as_deref(), original_format);
            }
            _ => panic!("Roundtrip failed for import notes"),
        }
    }

    #[test]
    fn test_url_encoding_special_characters() {
        // Test that special characters are properly encoded/decoded
        let title_with_special = "Paper: A & B (2024)";
        let url = build_new_url(Some(title_with_special), None);
        let result = parse_url_command(&url);

        match result.command {
            Some(ImprintCommand::New(cmd)) => {
                assert_eq!(cmd.title.as_deref(), Some(title_with_special));
            }
            _ => panic!("Special characters roundtrip failed"),
        }
    }
}
