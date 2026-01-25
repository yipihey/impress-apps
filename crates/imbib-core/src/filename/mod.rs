//! PDF filename generation with human-readable names

use crate::domain::Publication;
use lazy_static::lazy_static;
use regex::Regex;

lazy_static! {
    static ref UNSAFE_CHARS: Regex = Regex::new(r#"[<>:"/\\|?*\x00-\x1f]"#).unwrap();
    static ref MULTIPLE_SPACES: Regex = Regex::new(r"\s+").unwrap();
    static ref MULTIPLE_UNDERSCORES: Regex = Regex::new(r"_+").unwrap();
}

/// Options for filename generation
#[derive(uniffi::Record, Clone, Debug)]
pub struct FilenameOptions {
    pub max_length: u32,
    pub include_year: bool,
    pub title_words: u32,
    pub separator: String,
}

impl Default for FilenameOptions {
    fn default() -> Self {
        Self {
            max_length: 100,
            include_year: true,
            title_words: 3,
            separator: "_".to_string(),
        }
    }
}

pub(crate) fn default_filename_options_internal() -> FilenameOptions {
    FilenameOptions::default()
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn default_filename_options() -> FilenameOptions {
    default_filename_options_internal()
}

pub(crate) fn generate_pdf_filename_internal(
    publication: &Publication,
    options: &FilenameOptions,
) -> String {
    let mut parts = Vec::new();

    // Author (first author's family name)
    let author = publication
        .authors
        .first()
        .map(|a| sanitize_component(&a.family_name))
        .unwrap_or_else(|| "Unknown".to_string());
    parts.push(author);

    // Year
    if options.include_year {
        if let Some(year) = publication.year {
            parts.push(year.to_string());
        }
    }

    // Title (first N significant words)
    let title = extract_title_words(&publication.title, options.title_words as usize);
    if !title.is_empty() {
        parts.push(title);
    }

    let filename = parts.join(&options.separator);
    let truncated = truncate_filename(&filename, options.max_length as usize);

    format!("{}.pdf", truncated)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn generate_pdf_filename(publication: &Publication, options: &FilenameOptions) -> String {
    generate_pdf_filename_internal(publication, options)
}

pub(crate) fn generate_pdf_filename_from_metadata_internal(
    title: String,
    authors: Vec<String>,
    year: Option<i32>,
    options: &FilenameOptions,
) -> String {
    let mut parts = Vec::new();

    // Author
    let author = authors
        .first()
        .map(|a| {
            // Extract family name (last word or before comma)
            if let Some(pos) = a.find(',') {
                sanitize_component(&a[..pos])
            } else {
                a.split_whitespace()
                    .last()
                    .map(sanitize_component)
                    .unwrap_or_else(|| "Unknown".to_string())
            }
        })
        .unwrap_or_else(|| "Unknown".to_string());
    parts.push(author);

    // Year
    if options.include_year {
        if let Some(y) = year {
            parts.push(y.to_string());
        }
    }

    // Title
    let title_part = extract_title_words(&title, options.title_words as usize);
    if !title_part.is_empty() {
        parts.push(title_part);
    }

    let filename = parts.join(&options.separator);
    let truncated = truncate_filename(&filename, options.max_length as usize);

    format!("{}.pdf", truncated)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn generate_pdf_filename_from_metadata(
    title: String,
    authors: Vec<String>,
    year: Option<i32>,
    options: &FilenameOptions,
) -> String {
    generate_pdf_filename_from_metadata_internal(title, authors, year, options)
}

fn sanitize_component(input: &str) -> String {
    let cleaned = UNSAFE_CHARS.replace_all(input, "");
    let normalized = MULTIPLE_SPACES.replace_all(&cleaned, " ");
    let trimmed = normalized.trim();

    // Convert spaces to underscores and remove leading/trailing underscores
    let result: String = trimmed
        .chars()
        .map(|c| if c == ' ' { '_' } else { c })
        .collect();

    MULTIPLE_UNDERSCORES
        .replace_all(&result, "_")
        .trim_matches('_')
        .to_string()
}

fn extract_title_words(title: &str, max_words: usize) -> String {
    // Skip common articles and prepositions at the start
    let skip_words = [
        "a", "an", "the", "on", "in", "of", "for", "to", "and", "with", "by", "from", "at",
    ];

    let words: Vec<&str> = title
        .split_whitespace()
        .filter(|w| w.len() > 1) // Skip single chars
        .filter(|w| !skip_words.contains(&w.to_lowercase().as_str()))
        .take(max_words)
        .collect();

    words
        .iter()
        .map(|w| sanitize_component(w))
        .filter(|w| !w.is_empty())
        .collect::<Vec<_>>()
        .join("_")
}

fn truncate_filename(filename: &str, max_length: usize) -> String {
    if filename.len() <= max_length {
        filename.to_string()
    } else {
        // Truncate at word boundary if possible
        let truncated = &filename[..max_length];
        if let Some(pos) = truncated.rfind('_') {
            truncated[..pos].to_string()
        } else {
            truncated.to_string()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::Author;

    #[test]
    fn test_generate_filename() {
        let mut pub_ = Publication::new(
            "einstein1905".to_string(),
            "article".to_string(),
            "On the Electrodynamics of Moving Bodies".to_string(),
        );
        pub_.year = Some(1905);
        pub_.authors.push(Author::new("Einstein".to_string()));

        let filename = generate_pdf_filename(&pub_, &default_filename_options());
        assert_eq!(filename, "Einstein_1905_Electrodynamics_Moving_Bodies.pdf");
    }

    #[test]
    fn test_generate_filename_no_year() {
        let mut pub_ = Publication::new(
            "einstein".to_string(),
            "article".to_string(),
            "On the Electrodynamics of Moving Bodies".to_string(),
        );
        pub_.authors.push(Author::new("Einstein".to_string()));

        let options = FilenameOptions {
            include_year: false,
            ..Default::default()
        };
        let filename = generate_pdf_filename(&pub_, &options);
        assert_eq!(filename, "Einstein_Electrodynamics_Moving_Bodies.pdf");
    }

    #[test]
    fn test_generate_filename_no_author() {
        let pub_ = Publication::new(
            "test".to_string(),
            "article".to_string(),
            "A Great Paper".to_string(),
        );

        let filename = generate_pdf_filename(&pub_, &default_filename_options());
        assert!(filename.starts_with("Unknown_"));
    }

    #[test]
    fn test_sanitize_unsafe_chars() {
        let result = sanitize_component("Test: A <File> Name?");
        assert_eq!(result, "Test_A_File_Name");
    }

    #[test]
    fn test_extract_title_words_skips_articles() {
        let result = extract_title_words("The Role of the Electron", 3);
        assert_eq!(result, "Role_Electron");
    }

    #[test]
    fn test_truncate_filename() {
        let long_name = "Einstein_1905_Very_Long_Title_That_Goes_On_Forever";
        let truncated = truncate_filename(long_name, 30);
        assert!(truncated.len() <= 30);
        assert!(!truncated.ends_with('_'));
    }

    #[test]
    fn test_generate_from_metadata() {
        let filename = generate_pdf_filename_from_metadata(
            "A Great Paper About Physics".to_string(),
            vec!["Smith, John".to_string()],
            Some(2024),
            &default_filename_options(),
        );
        assert_eq!(filename, "Smith_2024_Great_Paper_About.pdf");
    }
}
