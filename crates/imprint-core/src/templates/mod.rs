//! Template system for journal and conference document styles
//!
//! This module provides a plugin system for managing document templates that define
//! journal-specific styling, page layouts, and export configurations.
//!
//! # Features
//!
//! - **Template Registry**: Manages built-in and user-installed templates
//! - **Template Metadata**: Rich metadata including journal info, page defaults, export options
//! - **Template Packages**: Self-contained bundles with Typst source, CSL styles, and assets
//! - **Import/Export**: Share templates as `.imprintTemplate` packages
//!
//! # Template Package Structure
//!
//! ```text
//! template.imprintTemplate/
//! ├── manifest.json           # Metadata, version, dependencies
//! ├── template.typ            # Main Typst template (preamble + macros)
//! ├── bibliography.csl        # Optional citation style
//! ├── assets/                 # Logos, fonts, etc.
//! ├── examples/               # Example documents
//! ├── latex/                  # LaTeX export support
//! │   ├── preamble.tex
//! │   └── mappings.json
//! └── README.md
//! ```
//!
//! # Example
//!
//! ```ignore
//! use imprint_core::templates::{TemplateRegistry, TemplateMetadata};
//!
//! let registry = TemplateRegistry::new();
//! let mnras = registry.get("mnras").expect("MNRAS template should exist");
//! println!("Template: {} v{}", mnras.metadata().name, mnras.metadata().version);
//! ```

mod builtin;
mod parser;

pub use builtin::*;
pub use parser::*;

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use thiserror::Error;

/// Errors that can occur when working with templates
#[derive(Debug, Error)]
pub enum TemplateError {
    #[error("Template not found: {0}")]
    NotFound(String),

    #[error("Invalid manifest: {0}")]
    InvalidManifest(String),

    #[error("Invalid template: {0}")]
    Invalid(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON parsing error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("Template already exists: {0}")]
    AlreadyExists(String),

    #[error("Unsupported template version: {0}")]
    UnsupportedVersion(String),
}

/// Result type for template operations
pub type TemplateResult<T> = Result<T, TemplateError>;

/// Category of template
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TemplateCategory {
    /// Academic journal template
    Journal,
    /// Conference proceedings template
    Conference,
    /// Thesis or dissertation template
    Thesis,
    /// Technical report template
    Report,
    /// User-created custom template
    Custom,
}

impl Default for TemplateCategory {
    fn default() -> Self {
        Self::Custom
    }
}

/// Journal-specific information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JournalInfo {
    /// Publisher name (e.g., "Oxford University Press")
    pub publisher: String,
    /// Journal website URL
    #[serde(default)]
    pub url: Option<String>,
    /// Corresponding LaTeX document class
    #[serde(default, rename = "latexClass")]
    pub latex_class: Option<String>,
    /// ISSN if available
    #[serde(default)]
    pub issn: Option<String>,
}

/// Page layout defaults for a template
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PageDefaults {
    /// Paper size ("a4", "letter", "a5")
    #[serde(default = "default_page_size")]
    pub size: String,
    /// Margins in mm
    #[serde(default)]
    pub margins: PageMargins,
    /// Number of columns (1 or 2)
    #[serde(default = "default_columns")]
    pub columns: u8,
    /// Base font size in pt
    #[serde(default = "default_font_size", rename = "fontSize")]
    pub font_size: f64,
}

fn default_page_size() -> String {
    "a4".to_string()
}

fn default_columns() -> u8 {
    1
}

fn default_font_size() -> f64 {
    11.0
}

impl Default for PageDefaults {
    fn default() -> Self {
        Self {
            size: default_page_size(),
            margins: PageMargins::default(),
            columns: default_columns(),
            font_size: default_font_size(),
        }
    }
}

/// Page margins in millimeters
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PageMargins {
    pub top: f64,
    pub right: f64,
    pub bottom: f64,
    pub left: f64,
}

impl Default for PageMargins {
    fn default() -> Self {
        Self {
            top: 25.0,
            right: 25.0,
            bottom: 25.0,
            left: 25.0,
        }
    }
}

/// Typst version requirements
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TypstRequirements {
    /// Minimum required Typst version
    #[serde(default, rename = "minVersion")]
    pub min_version: Option<String>,
}

/// Template metadata from manifest.json
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TemplateMetadata {
    /// Unique template identifier (e.g., "mnras", "neurips")
    pub id: String,
    /// Human-readable template name
    pub name: String,
    /// Template version (semver)
    #[serde(default = "default_version")]
    pub version: String,
    /// Description of the template
    #[serde(default)]
    pub description: String,
    /// Template author
    #[serde(default = "default_author")]
    pub author: String,
    /// License (e.g., "MIT", "CC-BY-4.0")
    #[serde(default = "default_license")]
    pub license: String,
    /// Template category
    #[serde(default)]
    pub category: TemplateCategory,
    /// Searchable tags
    #[serde(default)]
    pub tags: Vec<String>,
    /// Journal-specific information (for journal templates)
    #[serde(default)]
    pub journal: Option<JournalInfo>,
    /// Typst version requirements
    #[serde(default)]
    pub typst: TypstRequirements,
    /// Page layout defaults
    #[serde(default, rename = "pageDefaults")]
    pub page_defaults: PageDefaults,
    /// Supported export formats
    #[serde(default)]
    pub exports: Vec<String>,
    /// Creation date (ISO 8601)
    #[serde(default, rename = "createdAt")]
    pub created_at: Option<String>,
    /// Last modification date (ISO 8601)
    #[serde(default, rename = "modifiedAt")]
    pub modified_at: Option<String>,
}

fn default_version() -> String {
    "1.0.0".to_string()
}

fn default_author() -> String {
    "imprint community".to_string()
}

fn default_license() -> String {
    "MIT".to_string()
}

/// Source of a template (built-in or user)
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TemplateSource {
    /// Template bundled with the application
    Builtin,
    /// User-installed template with path to directory
    User(PathBuf),
}

/// A complete template with metadata and content
#[derive(Debug, Clone)]
pub struct Template {
    /// Template metadata from manifest
    pub metadata: TemplateMetadata,
    /// Main Typst template source
    pub typst_source: String,
    /// Optional LaTeX preamble for export
    pub latex_preamble: Option<String>,
    /// Optional CSL citation style
    pub csl_style: Option<String>,
    /// Source of this template
    pub source: TemplateSource,
}

impl Template {
    /// Create a new template from metadata and source
    pub fn new(metadata: TemplateMetadata, typst_source: String) -> Self {
        Self {
            metadata,
            typst_source,
            latex_preamble: None,
            csl_style: None,
            source: TemplateSource::Builtin,
        }
    }

    /// Get the template ID
    pub fn id(&self) -> &str {
        &self.metadata.id
    }

    /// Get the template name
    pub fn name(&self) -> &str {
        &self.metadata.name
    }

    /// Check if this is a built-in template
    pub fn is_builtin(&self) -> bool {
        matches!(self.source, TemplateSource::Builtin)
    }

    /// Generate Typst document preamble with variables filled in
    pub fn render_preamble(&self, variables: &HashMap<String, String>) -> String {
        let mut result = self.typst_source.clone();
        for (key, value) in variables {
            result = result.replace(&format!("${{{}}}", key), value);
        }
        result
    }
}

/// Registry of available templates
pub struct TemplateRegistry {
    /// All loaded templates indexed by ID
    templates: HashMap<String, Template>,
    /// User templates directory
    user_templates_dir: PathBuf,
}

impl TemplateRegistry {
    /// Create a new template registry with built-in templates
    pub fn new() -> Self {
        let mut registry = Self {
            templates: HashMap::new(),
            user_templates_dir: Self::default_user_templates_dir(),
        };
        registry.load_builtin_templates();
        registry
    }

    /// Create registry with custom user templates directory
    pub fn with_user_dir(user_templates_dir: PathBuf) -> Self {
        let mut registry = Self {
            templates: HashMap::new(),
            user_templates_dir,
        };
        registry.load_builtin_templates();
        registry
    }

    /// Get the default user templates directory
    pub fn default_user_templates_dir() -> PathBuf {
        dirs::data_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("imprint")
            .join("templates")
    }

    /// Load all built-in templates
    fn load_builtin_templates(&mut self) {
        for template in builtin::builtin_templates() {
            self.templates.insert(template.id().to_string(), template);
        }
    }

    /// Load user templates from the user templates directory
    pub fn load_user_templates(&mut self) -> TemplateResult<usize> {
        if !self.user_templates_dir.exists() {
            return Ok(0);
        }

        let mut loaded = 0;
        let entries = std::fs::read_dir(&self.user_templates_dir)?;

        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                match self.load_template_from_dir(&path) {
                    Ok(template) => {
                        self.templates.insert(template.id().to_string(), template);
                        loaded += 1;
                    }
                    Err(e) => {
                        // Log error but continue loading other templates
                        eprintln!("Failed to load template from {:?}: {}", path, e);
                    }
                }
            }
        }

        Ok(loaded)
    }

    /// Load a template from a directory
    pub fn load_template_from_dir(&self, path: &Path) -> TemplateResult<Template> {
        parser::parse_template_directory(path)
    }

    /// Get a template by ID
    pub fn get(&self, id: &str) -> Option<&Template> {
        self.templates.get(id)
    }

    /// List all available templates
    pub fn list(&self) -> Vec<&Template> {
        self.templates.values().collect()
    }

    /// List all template metadata (lighter weight than full templates)
    pub fn list_metadata(&self) -> Vec<&TemplateMetadata> {
        self.templates.values().map(|t| &t.metadata).collect()
    }

    /// List built-in templates only
    pub fn builtin_templates(&self) -> Vec<&Template> {
        self.templates.values().filter(|t| t.is_builtin()).collect()
    }

    /// List user templates only
    pub fn user_templates(&self) -> Vec<&Template> {
        self.templates
            .values()
            .filter(|t| !t.is_builtin())
            .collect()
    }

    /// Filter templates by category
    pub fn by_category(&self, category: &TemplateCategory) -> Vec<&Template> {
        self.templates
            .values()
            .filter(|t| &t.metadata.category == category)
            .collect()
    }

    /// Search templates by query string (matches name, description, tags)
    pub fn search(&self, query: &str) -> Vec<&Template> {
        let query_lower = query.to_lowercase();
        self.templates
            .values()
            .filter(|t| {
                t.metadata.name.to_lowercase().contains(&query_lower)
                    || t.metadata.description.to_lowercase().contains(&query_lower)
                    || t.metadata
                        .tags
                        .iter()
                        .any(|tag| tag.to_lowercase().contains(&query_lower))
            })
            .collect()
    }

    /// Register a user template
    pub fn register_user(&mut self, template: Template) -> TemplateResult<()> {
        let id = template.id().to_string();
        if self.templates.contains_key(&id) {
            return Err(TemplateError::AlreadyExists(id));
        }
        self.templates.insert(id, template);
        Ok(())
    }

    /// Import a template from a .imprintTemplate package
    pub fn import(&mut self, path: &Path) -> TemplateResult<String> {
        let template = parser::parse_template_package(path)?;
        let id = template.id().to_string();

        // Copy to user templates directory
        let dest_dir = self.user_templates_dir.join(&id);
        if dest_dir.exists() {
            return Err(TemplateError::AlreadyExists(id));
        }

        std::fs::create_dir_all(&dest_dir)?;
        copy_dir_contents(path, &dest_dir)?;

        self.templates.insert(id.clone(), template);
        Ok(id)
    }

    /// Export a template to a .imprintTemplate package
    pub fn export(&self, id: &str, dest_path: &Path) -> TemplateResult<()> {
        let template = self
            .templates
            .get(id)
            .ok_or_else(|| TemplateError::NotFound(id.to_string()))?;

        parser::export_template(template, dest_path)
    }

    /// Delete a user template (cannot delete built-in templates)
    pub fn delete_user(&mut self, id: &str) -> TemplateResult<()> {
        let template = self
            .templates
            .get(id)
            .ok_or_else(|| TemplateError::NotFound(id.to_string()))?;

        if template.is_builtin() {
            return Err(TemplateError::Invalid(
                "Cannot delete built-in templates".to_string(),
            ));
        }

        if let TemplateSource::User(path) = &template.source {
            if path.exists() {
                std::fs::remove_dir_all(path)?;
            }
        }

        self.templates.remove(id);
        Ok(())
    }

    /// Get the number of templates
    pub fn len(&self) -> usize {
        self.templates.len()
    }

    /// Check if registry is empty
    pub fn is_empty(&self) -> bool {
        self.templates.is_empty()
    }
}

impl Default for TemplateRegistry {
    fn default() -> Self {
        Self::new()
    }
}

/// Helper function to copy directory contents recursively
fn copy_dir_contents(src: &Path, dest: &Path) -> std::io::Result<()> {
    if !dest.exists() {
        std::fs::create_dir_all(dest)?;
    }

    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let path = entry.path();
        let dest_path = dest.join(entry.file_name());

        if path.is_dir() {
            copy_dir_contents(&path, &dest_path)?;
        } else {
            std::fs::copy(&path, &dest_path)?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_template_registry_new() {
        let registry = TemplateRegistry::new();
        assert!(
            !registry.is_empty(),
            "Registry should have built-in templates"
        );
    }

    #[test]
    fn test_builtin_templates_exist() {
        let registry = TemplateRegistry::new();

        // Check for some expected built-in templates
        assert!(
            registry.get("generic").is_some(),
            "generic template should exist"
        );
        assert!(
            registry.get("mnras").is_some(),
            "mnras template should exist"
        );
        assert!(
            registry.get("nature").is_some(),
            "nature template should exist"
        );
    }

    #[test]
    fn test_template_category_filter() {
        let registry = TemplateRegistry::new();
        let journal_templates = registry.by_category(&TemplateCategory::Journal);

        assert!(
            !journal_templates.is_empty(),
            "Should have journal templates"
        );
        for template in journal_templates {
            assert_eq!(template.metadata.category, TemplateCategory::Journal);
        }
    }

    #[test]
    fn test_template_search() {
        let registry = TemplateRegistry::new();

        let results = registry.search("astronomy");
        assert!(
            !results.is_empty(),
            "Should find templates with astronomy tag"
        );
    }

    #[test]
    fn test_template_metadata_parse() {
        let json = r#"{
            "id": "test",
            "name": "Test Template",
            "version": "1.0.0",
            "description": "A test template",
            "category": "journal",
            "tags": ["test", "example"],
            "pageDefaults": {
                "size": "a4",
                "columns": 2,
                "fontSize": 10
            }
        }"#;

        let metadata: TemplateMetadata = serde_json::from_str(json).unwrap();
        assert_eq!(metadata.id, "test");
        assert_eq!(metadata.name, "Test Template");
        assert_eq!(metadata.category, TemplateCategory::Journal);
        assert_eq!(metadata.page_defaults.columns, 2);
        assert_eq!(metadata.page_defaults.font_size, 10.0);
    }

    #[test]
    fn test_template_render_preamble() {
        let metadata = TemplateMetadata {
            id: "test".to_string(),
            name: "Test".to_string(),
            version: "1.0.0".to_string(),
            description: String::new(),
            author: String::new(),
            license: String::new(),
            category: TemplateCategory::Custom,
            tags: vec![],
            journal: None,
            typst: TypstRequirements::default(),
            page_defaults: PageDefaults::default(),
            exports: vec![],
            created_at: None,
            modified_at: None,
        };

        let template = Template::new(metadata, "Title: ${title}\nAuthor: ${author}".to_string());

        let mut vars = HashMap::new();
        vars.insert("title".to_string(), "My Paper".to_string());
        vars.insert("author".to_string(), "Jane Doe".to_string());

        let result = template.render_preamble(&vars);
        assert!(result.contains("Title: My Paper"));
        assert!(result.contains("Author: Jane Doe"));
    }
}
