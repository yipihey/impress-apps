//! Import annotations and notes from PDF readers
//!
//! This module provides functionality to import highlights, annotations, and notes
//! from PDF reading applications (particularly imbib) into imprint documents.
//!
//! # Features
//!
//! - **Annotation import**: Import PDF highlights and annotations
//! - **Note conversion**: Convert annotations to document content
//! - **Citation linking**: Automatically link imported notes to their source publications
//! - **Batch import**: Import annotations from multiple PDFs at once
//! - **Multiple output formats**: Markdown and Typst output
//!
//! # Supported Formats
//!
//! - imbib annotations (via `impress-domain::Annotation`)
//! - Standard PDF annotations (highlights, notes, underlines, freetext)
//! - Drawing annotations (exported as description)
//!
//! # Example
//!
//! ```ignore
//! use imprint_core::note_import::{NoteImporter, ImportOptions, NoteOutputFormat};
//! use impress_domain::Annotation;
//!
//! let importer = NoteImporter::new();
//! let annotations = vec![/* annotations from imbib */];
//! let options = ImportOptions::default().with_output_format(NoteOutputFormat::Typst);
//! let content = importer.import_as_section(&annotations, Some(&options))?;
//! ```

use impress_domain::{Annotation, AnnotationType, Publication};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Errors that can occur during note import
#[derive(Debug, Error)]
pub enum ImportError {
    /// Invalid annotation format
    #[error("Invalid annotation format: {0}")]
    InvalidFormat(String),

    /// Missing required field
    #[error("Missing required field: {0}")]
    MissingField(String),

    /// Publication not found for linking
    #[error("Publication not found: {0}")]
    PublicationNotFound(String),
}

/// Result type for import operations
pub type ImportResult<T> = Result<T, ImportError>;

/// Output format for imported notes
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum NoteOutputFormat {
    /// Markdown format (default)
    #[default]
    Markdown,
    /// Typst format for direct document insertion
    Typst,
}

/// Quote style for imported highlights
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum QuoteStyle {
    /// Block quote (> in Markdown, #quote[] in Typst)
    #[default]
    Block,
    /// Inline quote
    Inline,
    /// Margin note (Typst only, uses #margin-note[])
    MarginNote,
    /// Footnote
    Footnote,
}

/// Options for controlling the import process
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ImportOptions {
    /// Output format
    pub output_format: NoteOutputFormat,

    /// Whether to include the original text of highlights
    pub include_highlight_text: bool,

    /// Whether to include page numbers
    pub include_page_numbers: bool,

    /// Whether to group annotations by type
    pub group_by_type: bool,

    /// Whether to add citation references
    pub add_citations: bool,

    /// Custom header to add before imported content
    pub header: Option<String>,

    /// Format for date/time stamps
    pub date_format: String,

    /// Quote style for highlights
    pub quote_style: QuoteStyle,

    /// Whether to include annotation author
    pub include_author: bool,

    /// Whether to include creation date
    pub include_date: bool,

    /// Filter to specific annotation types (empty = all)
    pub filter_types: Vec<AnnotationType>,
}

impl Default for ImportOptions {
    fn default() -> Self {
        Self {
            output_format: NoteOutputFormat::default(),
            include_highlight_text: true,
            include_page_numbers: true,
            group_by_type: false,
            add_citations: true,
            header: None,
            date_format: "%Y-%m-%d".to_string(),
            quote_style: QuoteStyle::default(),
            include_author: false,
            include_date: false,
            filter_types: Vec::new(),
        }
    }
}

impl ImportOptions {
    /// Create options for Typst output
    pub fn typst() -> Self {
        Self {
            output_format: NoteOutputFormat::Typst,
            ..Default::default()
        }
    }

    /// Create options for Markdown output
    pub fn markdown() -> Self {
        Self {
            output_format: NoteOutputFormat::Markdown,
            ..Default::default()
        }
    }

    /// Builder: set output format
    pub fn with_output_format(mut self, format: NoteOutputFormat) -> Self {
        self.output_format = format;
        self
    }

    /// Builder: set quote style
    pub fn with_quote_style(mut self, style: QuoteStyle) -> Self {
        self.quote_style = style;
        self
    }

    /// Builder: set grouping
    pub fn with_grouping(mut self, group: bool) -> Self {
        self.group_by_type = group;
        self
    }

    /// Builder: set citation inclusion
    pub fn with_citations(mut self, include: bool) -> Self {
        self.add_citations = include;
        self
    }

    /// Builder: set type filter
    pub fn with_types(mut self, types: Vec<AnnotationType>) -> Self {
        self.filter_types = types;
        self
    }

    /// Builder: set header
    pub fn with_header(mut self, header: impl Into<String>) -> Self {
        self.header = Some(header.into());
        self
    }
}

/// An imported note ready for insertion into a document
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportedNote {
    /// The text content of the note
    pub content: String,

    /// Source annotation type
    pub annotation_type: AnnotationType,

    /// Page number in the source PDF
    pub page: Option<u32>,

    /// Source publication if known
    pub source_publication: Option<Publication>,

    /// Citation key if available
    pub citation_key: Option<String>,

    /// Original annotation ID for reference
    pub annotation_id: Option<String>,
}

impl ImportedNote {
    /// Create a new imported note from an annotation
    pub fn from_annotation(annotation: &Annotation) -> Self {
        // Use selected_text for highlights, content for notes
        let content = annotation
            .selected_text
            .clone()
            .or_else(|| annotation.content.clone())
            .unwrap_or_default();

        Self {
            content,
            annotation_type: annotation.annotation_type.clone(),
            page: Some(annotation.page_number),
            source_publication: None,
            citation_key: None,
            annotation_id: Some(annotation.id.clone()),
        }
    }

    /// Create an imported note with publication context
    pub fn from_annotation_with_publication(
        annotation: &Annotation,
        publication: &Publication,
    ) -> Self {
        let mut note = Self::from_annotation(annotation);
        note.citation_key = Some(publication.cite_key.clone());
        note.source_publication = Some(publication.clone());
        note
    }

    /// Format the note for document insertion
    pub fn format(&self, options: &ImportOptions) -> String {
        match options.output_format {
            NoteOutputFormat::Markdown => self.format_markdown(options),
            NoteOutputFormat::Typst => self.format_typst(options),
        }
    }

    /// Format as Markdown
    fn format_markdown(&self, options: &ImportOptions) -> String {
        let mut parts = Vec::new();

        // Add content
        if !self.content.is_empty() {
            match self.annotation_type {
                AnnotationType::Highlight => {
                    if options.include_highlight_text {
                        match options.quote_style {
                            QuoteStyle::Block => parts.push(format!("> {}", self.content)),
                            QuoteStyle::Inline => parts.push(format!("\"{}\"", self.content)),
                            QuoteStyle::Footnote => parts.push(format!("[^{}]", self.content)),
                            QuoteStyle::MarginNote => {
                                // Markdown doesn't have margin notes, use block quote
                                parts.push(format!("> {}", self.content))
                            }
                        }
                    }
                }
                AnnotationType::Note => {
                    parts.push(self.content.clone());
                }
                AnnotationType::Underline => {
                    if options.include_highlight_text {
                        parts.push(format!("_{}_", self.content));
                    }
                }
                AnnotationType::FreeText => {
                    parts.push(self.content.clone());
                }
                AnnotationType::StrikeOut => {
                    if options.include_highlight_text {
                        parts.push(format!("~~{}~~", self.content));
                    }
                }
                _ => {
                    parts.push(self.content.clone());
                }
            }
        }

        // Add page reference
        if options.include_page_numbers {
            if let Some(page) = self.page {
                parts.push(format!("(p. {})", page));
            }
        }

        // Add citation
        if options.add_citations {
            if let Some(ref key) = self.citation_key {
                parts.push(format!("[@{}]", key));
            }
        }

        parts.join(" ")
    }

    /// Format as Typst
    fn format_typst(&self, options: &ImportOptions) -> String {
        if self.content.is_empty() {
            return String::new();
        }

        let attribution = if options.add_citations {
            self.citation_key
                .as_ref()
                .map(|key| {
                    let page_part = if options.include_page_numbers {
                        self.page
                            .map(|p| format!(", p. {}", p))
                            .unwrap_or_default()
                    } else {
                        String::new()
                    };
                    format!("@{}{}", key, page_part)
                })
        } else {
            None
        };

        match self.annotation_type {
            AnnotationType::Highlight => {
                if !options.include_highlight_text {
                    return String::new();
                }
                match options.quote_style {
                    QuoteStyle::Block => {
                        if let Some(attr) = attribution {
                            format!("#quote(attribution: [{}])[\n  {}\n]", attr, self.escape_typst(&self.content))
                        } else {
                            format!("#quote[\n  {}\n]", self.escape_typst(&self.content))
                        }
                    }
                    QuoteStyle::Inline => {
                        let cite = attribution
                            .map(|a| format!(" {}", a))
                            .unwrap_or_default();
                        format!("\"{}\"{}",self.escape_typst(&self.content), cite)
                    }
                    QuoteStyle::MarginNote => {
                        format!("#margin-note[{}]", self.escape_typst(&self.content))
                    }
                    QuoteStyle::Footnote => {
                        let cite = attribution
                            .map(|a| format!(" {}", a))
                            .unwrap_or_default();
                        format!("#footnote[\"{}\"{}]", self.escape_typst(&self.content), cite)
                    }
                }
            }
            AnnotationType::Note => {
                // Notes become regular paragraphs with optional citation
                let cite = if options.add_citations {
                    self.citation_key
                        .as_ref()
                        .map(|k| format!(" @{}", k))
                        .unwrap_or_default()
                } else {
                    String::new()
                };
                format!("{}{}", self.escape_typst(&self.content), cite)
            }
            AnnotationType::Underline => {
                if !options.include_highlight_text {
                    return String::new();
                }
                format!("#underline[{}]", self.escape_typst(&self.content))
            }
            AnnotationType::StrikeOut => {
                if !options.include_highlight_text {
                    return String::new();
                }
                format!("#strike[{}]", self.escape_typst(&self.content))
            }
            AnnotationType::FreeText => {
                format!("{}", self.escape_typst(&self.content))
            }
            _ => {
                // For other types, just output as text
                self.escape_typst(&self.content)
            }
        }
    }

    /// Escape special Typst characters
    fn escape_typst(&self, text: &str) -> String {
        text.replace('\\', "\\\\")
            .replace('#', "\\#")
            .replace('$', "\\$")
            .replace('@', "\\@")
            .replace('[', "\\[")
            .replace(']', "\\]")
    }
}

/// Importer for converting annotations to document content
#[derive(Debug, Default)]
pub struct NoteImporter {
    /// Default options for imports
    default_options: ImportOptions,
}

impl NoteImporter {
    /// Create a new note importer with default options
    pub fn new() -> Self {
        Self::default()
    }

    /// Create a new note importer with custom options
    pub fn with_options(options: ImportOptions) -> Self {
        Self {
            default_options: options,
        }
    }

    /// Import a single annotation
    pub fn import_annotation(&self, annotation: &Annotation) -> ImportResult<ImportedNote> {
        Ok(ImportedNote::from_annotation(annotation))
    }

    /// Import a single annotation with publication context
    pub fn import_annotation_with_publication(
        &self,
        annotation: &Annotation,
        publication: &Publication,
    ) -> ImportResult<ImportedNote> {
        Ok(ImportedNote::from_annotation_with_publication(annotation, publication))
    }

    /// Import multiple annotations
    pub fn import_annotations(&self, annotations: &[Annotation]) -> ImportResult<Vec<ImportedNote>> {
        annotations.iter().map(|a| self.import_annotation(a)).collect()
    }

    /// Import multiple annotations with publication context
    pub fn import_annotations_with_publication(
        &self,
        annotations: &[Annotation],
        publication: &Publication,
    ) -> ImportResult<Vec<ImportedNote>> {
        annotations
            .iter()
            .map(|a| self.import_annotation_with_publication(a, publication))
            .collect()
    }

    /// Filter annotations based on options
    fn filter_annotations<'a>(
        &self,
        annotations: &'a [Annotation],
        options: &ImportOptions,
    ) -> Vec<&'a Annotation> {
        if options.filter_types.is_empty() {
            annotations.iter().collect()
        } else {
            annotations
                .iter()
                .filter(|a| options.filter_types.contains(&a.annotation_type))
                .collect()
        }
    }

    /// Import annotations and format as a single document section
    pub fn import_as_section(
        &self,
        annotations: &[Annotation],
        options: Option<&ImportOptions>,
    ) -> ImportResult<String> {
        let opts = options.unwrap_or(&self.default_options);
        let filtered = self.filter_annotations(annotations, opts);
        let notes: Vec<ImportedNote> = filtered
            .into_iter()
            .map(ImportedNote::from_annotation)
            .collect();

        self.format_notes_as_section(&notes, opts)
    }

    /// Import annotations with publication and format as a section
    pub fn import_as_section_with_publication(
        &self,
        annotations: &[Annotation],
        publication: &Publication,
        options: Option<&ImportOptions>,
    ) -> ImportResult<String> {
        let opts = options.unwrap_or(&self.default_options);
        let filtered = self.filter_annotations(annotations, opts);
        let notes: Vec<ImportedNote> = filtered
            .into_iter()
            .map(|a| ImportedNote::from_annotation_with_publication(a, publication))
            .collect();

        self.format_notes_as_section(&notes, opts)
    }

    /// Format notes as a section
    fn format_notes_as_section(
        &self,
        notes: &[ImportedNote],
        opts: &ImportOptions,
    ) -> ImportResult<String> {
        let mut output = String::new();

        // Add header if specified
        if let Some(ref header) = opts.header {
            match opts.output_format {
                NoteOutputFormat::Markdown => {
                    output.push_str(header);
                    output.push_str("\n\n");
                }
                NoteOutputFormat::Typst => {
                    // Assume header is a section title
                    output.push_str(&format!("== {}\n\n", header));
                }
            }
        }

        if opts.group_by_type {
            self.format_grouped(notes, opts, &mut output);
        } else {
            self.format_sequential(notes, opts, &mut output);
        }

        Ok(output.trim().to_string())
    }

    /// Format notes grouped by type
    fn format_grouped(&self, notes: &[ImportedNote], opts: &ImportOptions, output: &mut String) {
        let mut highlights = Vec::new();
        let mut notes_list = Vec::new();
        let mut underlines = Vec::new();
        let mut other = Vec::new();

        for note in notes {
            match note.annotation_type {
                AnnotationType::Highlight => highlights.push(note),
                AnnotationType::Note | AnnotationType::FreeText => notes_list.push(note),
                AnnotationType::Underline => underlines.push(note),
                _ => other.push(note),
            }
        }

        let heading = |title: &str| match opts.output_format {
            NoteOutputFormat::Markdown => format!("## {}\n\n", title),
            NoteOutputFormat::Typst => format!("=== {}\n\n", title),
        };

        if !highlights.is_empty() {
            output.push_str(&heading("Highlights"));
            for note in highlights {
                let formatted = note.format(opts);
                if !formatted.is_empty() {
                    output.push_str(&formatted);
                    output.push_str("\n\n");
                }
            }
        }

        if !underlines.is_empty() {
            output.push_str(&heading("Key Passages"));
            for note in underlines {
                let formatted = note.format(opts);
                if !formatted.is_empty() {
                    output.push_str(&formatted);
                    output.push_str("\n\n");
                }
            }
        }

        if !notes_list.is_empty() {
            output.push_str(&heading("Notes"));
            for note in notes_list {
                let formatted = note.format(opts);
                if !formatted.is_empty() {
                    output.push_str(&formatted);
                    output.push_str("\n\n");
                }
            }
        }

        if !other.is_empty() {
            output.push_str(&heading("Other"));
            for note in other {
                let formatted = note.format(opts);
                if !formatted.is_empty() {
                    output.push_str(&formatted);
                    output.push_str("\n\n");
                }
            }
        }
    }

    /// Format notes in sequential order (by page)
    fn format_sequential(&self, notes: &[ImportedNote], opts: &ImportOptions, output: &mut String) {
        // Sort by page number
        let mut sorted_notes: Vec<_> = notes.iter().collect();
        sorted_notes.sort_by_key(|n| n.page.unwrap_or(0));

        for note in sorted_notes {
            let formatted = note.format(opts);
            if !formatted.is_empty() {
                output.push_str(&formatted);
                output.push_str("\n\n");
            }
        }
    }

    /// Generate a quick citation quote in Typst format
    ///
    /// This is a convenience method for inserting a single highlight as a quote
    /// with attribution.
    pub fn format_as_typst_quote(
        text: &str,
        cite_key: &str,
        page: Option<u32>,
    ) -> String {
        let attribution = match page {
            Some(p) => format!("@{}, p. {}", cite_key, p),
            None => format!("@{}", cite_key),
        };
        format!(
            "#quote(attribution: [{}])[\n  {}\n]",
            attribution,
            text.replace('#', "\\#")
                .replace('@', "\\@")
                .replace('[', "\\[")
                .replace(']', "\\]")
        )
    }

    /// Generate a margin note in Typst format
    pub fn format_as_typst_margin_note(text: &str) -> String {
        format!(
            "#margin-note[{}]",
            text.replace('#', "\\#")
                .replace('[', "\\[")
                .replace(']', "\\]")
        )
    }
}

/// Batch import result for multiple publications
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct BatchImportResult {
    /// Successfully imported content
    pub content: String,
    /// Number of annotations imported
    pub annotation_count: u32,
    /// Number of publications processed
    pub publication_count: u32,
    /// Any warnings during import
    pub warnings: Vec<String>,
}

/// Import annotations from multiple publications at once
pub fn batch_import(
    items: &[(Publication, Vec<Annotation>)],
    options: &ImportOptions,
) -> BatchImportResult {
    let importer = NoteImporter::with_options(options.clone());
    let mut all_content = Vec::new();
    let mut total_annotations = 0u32;
    let mut warnings = Vec::new();

    for (publication, annotations) in items {
        if annotations.is_empty() {
            continue;
        }

        // Add publication header
        let pub_header = match options.output_format {
            NoteOutputFormat::Markdown => format!("# {}\n\n", publication.title),
            NoteOutputFormat::Typst => format!("= {}\n\n", publication.title),
        };
        all_content.push(pub_header);

        match importer.import_as_section_with_publication(annotations, publication, Some(options)) {
            Ok(content) => {
                all_content.push(content);
                all_content.push("\n\n".to_string());
                total_annotations += annotations.len() as u32;
            }
            Err(e) => {
                warnings.push(format!(
                    "Failed to import annotations for '{}': {}",
                    publication.title, e
                ));
            }
        }
    }

    BatchImportResult {
        content: all_content.join("").trim().to_string(),
        annotation_count: total_annotations,
        publication_count: items.len() as u32,
        warnings,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_domain::{AnnotationColor, Author, Rect};

    fn sample_highlight() -> Annotation {
        Annotation {
            id: "test-id".to_string(),
            publication_id: "pub-123".to_string(),
            page_number: 42,
            annotation_type: AnnotationType::Highlight,
            rects: vec![Rect::new(0.0, 0.0, 100.0, 20.0)],
            color: AnnotationColor::yellow(),
            content: None,
            selected_text: Some("Important finding about X".to_string()),
            created_at: "2024-01-01T00:00:00Z".to_string(),
            modified_at: "2024-01-01T00:00:00Z".to_string(),
            author: None,
        }
    }

    fn sample_note() -> Annotation {
        Annotation {
            id: "note-id".to_string(),
            publication_id: "pub-123".to_string(),
            page_number: 15,
            annotation_type: AnnotationType::Note,
            rects: vec![Rect::new(0.0, 0.0, 10.0, 10.0)],
            color: AnnotationColor::yellow(),
            content: Some("This contradicts earlier findings".to_string()),
            selected_text: None,
            created_at: "2024-01-01T00:00:00Z".to_string(),
            modified_at: "2024-01-01T00:00:00Z".to_string(),
            author: None,
        }
    }

    fn sample_publication() -> Publication {
        let mut pub_ = Publication::new(
            "smith2024machine".to_string(),
            "article".to_string(),
            "Machine Learning for Science".to_string(),
        );
        pub_.year = Some(2024);
        pub_.authors = vec![Author::new("Smith".to_string())];
        pub_
    }

    #[test]
    fn test_import_annotation() {
        let importer = NoteImporter::new();
        let annotation = sample_highlight();
        let note = importer.import_annotation(&annotation).unwrap();

        assert_eq!(note.content, "Important finding about X");
        assert_eq!(note.page, Some(42));
    }

    #[test]
    fn test_import_with_publication() {
        let importer = NoteImporter::new();
        let annotation = sample_highlight();
        let publication = sample_publication();
        let note = importer
            .import_annotation_with_publication(&annotation, &publication)
            .unwrap();

        assert_eq!(note.citation_key, Some("smith2024machine".to_string()));
        assert!(note.source_publication.is_some());
    }

    #[test]
    fn test_format_markdown() {
        let note = ImportedNote {
            content: "Test content".to_string(),
            annotation_type: AnnotationType::Highlight,
            page: Some(10),
            source_publication: None,
            citation_key: Some("smith2023".to_string()),
            annotation_id: None,
        };

        let options = ImportOptions::markdown();
        let formatted = note.format(&options);

        assert!(formatted.contains("> Test content"));
        assert!(formatted.contains("(p. 10)"));
        assert!(formatted.contains("[@smith2023]"));
    }

    #[test]
    fn test_format_typst_block_quote() {
        let note = ImportedNote {
            content: "Test content".to_string(),
            annotation_type: AnnotationType::Highlight,
            page: Some(10),
            source_publication: None,
            citation_key: Some("smith2023".to_string()),
            annotation_id: None,
        };

        let options = ImportOptions::typst().with_quote_style(QuoteStyle::Block);
        let formatted = note.format(&options);

        assert!(formatted.contains("#quote(attribution:"));
        assert!(formatted.contains("@smith2023, p. 10"));
        assert!(formatted.contains("Test content"));
    }

    #[test]
    fn test_format_typst_margin_note() {
        let note = ImportedNote {
            content: "Side comment".to_string(),
            annotation_type: AnnotationType::Highlight,
            page: Some(5),
            source_publication: None,
            citation_key: None,
            annotation_id: None,
        };

        let options = ImportOptions::typst().with_quote_style(QuoteStyle::MarginNote);
        let formatted = note.format(&options);

        assert!(formatted.contains("#margin-note["));
        assert!(formatted.contains("Side comment"));
    }

    #[test]
    fn test_format_typst_inline() {
        let note = ImportedNote {
            content: "Brief quote".to_string(),
            annotation_type: AnnotationType::Highlight,
            page: None,
            source_publication: None,
            citation_key: Some("jones2020".to_string()),
            annotation_id: None,
        };

        let options = ImportOptions::typst().with_quote_style(QuoteStyle::Inline);
        let formatted = note.format(&options);

        assert!(formatted.contains("\"Brief quote\""));
        assert!(formatted.contains("@jones2020"));
    }

    #[test]
    fn test_import_as_section_typst() {
        let importer = NoteImporter::new();
        let annotations = vec![sample_highlight(), sample_note()];
        let publication = sample_publication();
        let options = ImportOptions::typst()
            .with_grouping(true)
            .with_header("Reading Notes");

        let result = importer
            .import_as_section_with_publication(&annotations, &publication, Some(&options))
            .unwrap();

        assert!(result.contains("== Reading Notes"));
        assert!(result.contains("=== Highlights"));
        assert!(result.contains("=== Notes"));
        assert!(result.contains("@smith2024machine"));
    }

    #[test]
    fn test_filter_by_type() {
        let importer = NoteImporter::new();
        let annotations = vec![sample_highlight(), sample_note()];
        let options = ImportOptions::default().with_types(vec![AnnotationType::Highlight]);

        let result = importer.import_as_section(&annotations, Some(&options)).unwrap();

        assert!(result.contains("Important finding"));
        assert!(!result.contains("contradicts"));
    }

    #[test]
    fn test_typst_quote_helper() {
        let quote = NoteImporter::format_as_typst_quote(
            "The universe is expanding",
            "hubble1929",
            Some(42),
        );

        assert!(quote.contains("#quote(attribution: [@hubble1929, p. 42])"));
        assert!(quote.contains("The universe is expanding"));
    }

    #[test]
    fn test_typst_margin_note_helper() {
        let note = NoteImporter::format_as_typst_margin_note("Remember this point");
        assert!(note.contains("#margin-note[Remember this point]"));
    }

    #[test]
    fn test_batch_import() {
        let pub1 = sample_publication();
        let annotations1 = vec![sample_highlight()];

        let mut pub2 = Publication::new(
            "jones2020".to_string(),
            "article".to_string(),
            "Deep Learning".to_string(),
        );
        pub2.year = Some(2020);
        let annotations2 = vec![sample_note()];

        let items = vec![
            (pub1, annotations1),
            (pub2, annotations2),
        ];

        let result = batch_import(&items, &ImportOptions::typst());

        assert_eq!(result.publication_count, 2);
        assert_eq!(result.annotation_count, 2);
        assert!(result.content.contains("Machine Learning for Science"));
        assert!(result.content.contains("Deep Learning"));
        assert!(result.warnings.is_empty());
    }

    #[test]
    fn test_escape_typst_special_chars() {
        let note = ImportedNote {
            content: "Formula: $E=mc^2$ and @ref".to_string(),
            annotation_type: AnnotationType::Note,
            page: None,
            source_publication: None,
            citation_key: None,
            annotation_id: None,
        };

        let options = ImportOptions::typst();
        let formatted = note.format(&options);

        assert!(formatted.contains("\\$"));
        assert!(formatted.contains("\\@"));
    }
}
