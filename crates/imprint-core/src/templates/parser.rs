//! Template package parsing and export
//!
//! This module handles reading and writing template packages (.imprintTemplate bundles).

use super::{Template, TemplateError, TemplateMetadata, TemplateResult, TemplateSource};
use std::path::Path;

/// Parse a template from a directory (unpacked template)
pub fn parse_template_directory(path: &Path) -> TemplateResult<Template> {
    // Read manifest.json
    let manifest_path = path.join("manifest.json");
    if !manifest_path.exists() {
        return Err(TemplateError::InvalidManifest(format!(
            "manifest.json not found in {:?}",
            path
        )));
    }

    let manifest_content = std::fs::read_to_string(&manifest_path)?;
    let metadata: TemplateMetadata = serde_json::from_str(&manifest_content).map_err(|e| {
        TemplateError::InvalidManifest(format!("Failed to parse manifest.json: {}", e))
    })?;

    // Read template.typ
    let template_path = path.join("template.typ");
    let typst_source = if template_path.exists() {
        std::fs::read_to_string(&template_path)?
    } else {
        // Fall back to looking for any .typ file
        find_typ_file(path)?
    };

    // Read optional LaTeX preamble
    let latex_preamble_path = path.join("latex").join("preamble.tex");
    let latex_preamble = if latex_preamble_path.exists() {
        Some(std::fs::read_to_string(&latex_preamble_path)?)
    } else {
        None
    };

    // Read optional CSL style
    let csl_path = path.join("bibliography.csl");
    let csl_style = if csl_path.exists() {
        Some(std::fs::read_to_string(&csl_path)?)
    } else {
        None
    };

    Ok(Template {
        metadata,
        typst_source,
        latex_preamble,
        csl_style,
        source: TemplateSource::User(path.to_path_buf()),
    })
}

/// Parse a template from a .imprintTemplate package (zip or directory)
pub fn parse_template_package(path: &Path) -> TemplateResult<Template> {
    if path.is_dir() {
        parse_template_directory(path)
    } else if path
        .extension()
        .map(|e| e == "imprintTemplate")
        .unwrap_or(false)
    {
        // For now, we treat .imprintTemplate as a directory
        // In the future, this could support zip archives
        parse_template_directory(path)
    } else {
        Err(TemplateError::Invalid(format!(
            "Unsupported template format: {:?}",
            path
        )))
    }
}

/// Export a template to a directory
pub fn export_template(template: &Template, dest_path: &Path) -> TemplateResult<()> {
    // Create destination directory
    std::fs::create_dir_all(dest_path)?;

    // Write manifest.json
    let manifest_path = dest_path.join("manifest.json");
    let manifest_json = serde_json::to_string_pretty(&template.metadata)?;
    std::fs::write(&manifest_path, manifest_json)?;

    // Write template.typ
    let template_path = dest_path.join("template.typ");
    std::fs::write(&template_path, &template.typst_source)?;

    // Write LaTeX preamble if present
    if let Some(latex_preamble) = &template.latex_preamble {
        let latex_dir = dest_path.join("latex");
        std::fs::create_dir_all(&latex_dir)?;
        std::fs::write(latex_dir.join("preamble.tex"), latex_preamble)?;
    }

    // Write CSL style if present
    if let Some(csl_style) = &template.csl_style {
        std::fs::write(dest_path.join("bibliography.csl"), csl_style)?;
    }

    Ok(())
}

/// Find the first .typ file in a directory
fn find_typ_file(dir: &Path) -> TemplateResult<String> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().map(|e| e == "typ").unwrap_or(false) {
            return Ok(std::fs::read_to_string(&path)?);
        }
    }

    Err(TemplateError::InvalidManifest(
        "No .typ file found in template directory".to_string(),
    ))
}

/// Validate a template's Typst source for basic correctness
pub fn validate_template(template: &Template) -> TemplateResult<()> {
    // Basic validation checks
    if template.metadata.id.is_empty() {
        return Err(TemplateError::Invalid(
            "Template ID cannot be empty".to_string(),
        ));
    }

    if template.metadata.name.is_empty() {
        return Err(TemplateError::Invalid(
            "Template name cannot be empty".to_string(),
        ));
    }

    if template.typst_source.is_empty() {
        return Err(TemplateError::Invalid(
            "Template source cannot be empty".to_string(),
        ));
    }

    // Validate ID format (alphanumeric with hyphens)
    if !template
        .metadata
        .id
        .chars()
        .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
    {
        return Err(TemplateError::Invalid(
            "Template ID must contain only alphanumeric characters, hyphens, and underscores"
                .to_string(),
        ));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::templates::{PageDefaults, TemplateCategory, TypstRequirements};
    use tempfile::TempDir;

    #[test]
    fn test_export_and_reimport_template() {
        let metadata = TemplateMetadata {
            id: "test-export".to_string(),
            name: "Test Export Template".to_string(),
            version: "1.0.0".to_string(),
            description: "A test template for export".to_string(),
            author: "Test Author".to_string(),
            license: "MIT".to_string(),
            category: TemplateCategory::Custom,
            tags: vec!["test".to_string()],
            journal: None,
            typst: TypstRequirements::default(),
            page_defaults: PageDefaults::default(),
            exports: vec!["pdf".to_string()],
            created_at: None,
            modified_at: None,
        };

        let template = Template {
            metadata,
            typst_source: "= Test Document\n\nHello world.".to_string(),
            latex_preamble: Some("\\documentclass{article}".to_string()),
            csl_style: None,
            source: TemplateSource::Builtin,
        };

        // Export to temp directory
        let temp_dir = TempDir::new().unwrap();
        let export_path = temp_dir.path().join("test-export");

        export_template(&template, &export_path).unwrap();

        // Verify files were created
        assert!(export_path.join("manifest.json").exists());
        assert!(export_path.join("template.typ").exists());
        assert!(export_path.join("latex").join("preamble.tex").exists());

        // Re-import and verify
        let reimported = parse_template_directory(&export_path).unwrap();
        assert_eq!(reimported.metadata.id, "test-export");
        assert_eq!(reimported.metadata.name, "Test Export Template");
        assert_eq!(reimported.typst_source, "= Test Document\n\nHello world.");
        assert!(reimported.latex_preamble.is_some());
    }

    #[test]
    fn test_validate_template() {
        use crate::templates::Template;

        let mut metadata = TemplateMetadata {
            id: "valid-id".to_string(),
            name: "Valid Name".to_string(),
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

        let template = Template::new(metadata.clone(), "= Hello".to_string());
        assert!(validate_template(&template).is_ok());

        // Empty ID should fail
        metadata.id = String::new();
        let template = Template::new(metadata.clone(), "= Hello".to_string());
        assert!(validate_template(&template).is_err());

        // Invalid ID characters should fail
        metadata.id = "invalid id!".to_string();
        let template = Template::new(metadata.clone(), "= Hello".to_string());
        assert!(validate_template(&template).is_err());
    }
}
