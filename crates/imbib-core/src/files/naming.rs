//! `Author_Year_Title.pdf` filename generation (port of PDFManager.swift rules).
//!
//! This is the lower-level entry point used by callers that have already
//! resolved an author name, year, and title — e.g. the CLI/TUI generating a
//! filename from a `\bibitem` line. The existing `crate::filename` module is
//! the higher-level Publication-driven entry point and remains the canonical
//! UniFFI surface; both share the same slug/sanitize semantics.

use unicode_normalization::UnicodeNormalization;

/// Options controlling filename generation. Defaults match Swift's PDFManager
/// (`generateFilename(for:extension:)` in `apps/imbib/.../Files/PDFManager.swift`):
///   - 40-char title budget
///   - leading "The/A/An" stripped
///   - non-alphanumerics removed (no underscores between title words)
///   - 200-char overall cap
#[derive(Debug, Clone)]
pub struct FilenameOptions {
    /// Max characters of title to include (default 40).
    pub max_title_chars: usize,
    /// File extension (without leading dot). Default `"pdf"`.
    pub extension: String,
    /// Overall filename byte cap before adding the extension (default 200).
    pub max_overall_len: usize,
    /// When `true` (Swift parity), strip "The "/"A "/"An " from the title.
    pub strip_leading_article: bool,
}

impl Default for FilenameOptions {
    fn default() -> Self {
        Self {
            max_title_chars: 40,
            extension: "pdf".to_string(),
            max_overall_len: 200,
            strip_leading_article: true,
        }
    }
}

/// Generate a human-readable filename of the form `Author_Year_Title.ext`.
///
/// Matches the Swift `PDFManager.generateFilename` rules:
///   - first author's family name → CamelCase ASCII
///   - year → 4-digit string, or `NoYear` when absent
///   - title → leading article stripped, words CamelCase-joined (no separators),
///     truncated at word boundary up to `max_title_chars`
///   - illegal filesystem characters (`/ \ : * ? " < > |`) removed
///   - whole filename capped at `max_overall_len`
pub fn generate_filename(
    author_family_name: &str,
    year: Option<i32>,
    title: &str,
    options: &FilenameOptions,
) -> String {
    let author = sanitize_component(author_family_name);
    let author = if author.is_empty() {
        "Unknown".to_string()
    } else {
        author
    };

    let year_part = match year {
        Some(y) if y > 0 => y.to_string(),
        _ => "NoYear".to_string(),
    };

    let title_part = build_title(title, options);

    let base = format!("{}_{}_{}", author, year_part, title_part);
    let capped = if base.len() > options.max_overall_len {
        // Truncate the whole base string by characters to avoid splitting a
        // multi-byte char in the middle. Filesystem cap is in *bytes* but
        // 200 ASCII-ish chars is generous enough that the worst case is
        // bounded.
        base.chars().take(options.max_overall_len).collect::<String>()
    } else {
        base
    };

    if options.extension.is_empty() {
        capped
    } else {
        format!("{}.{}", capped, options.extension)
    }
}

/// Build the title segment: strip leading article, CamelCase words, truncate.
fn build_title(title: &str, options: &FilenameOptions) -> String {
    let mut cleaned = title.trim().to_string();

    if options.strip_leading_article {
        for article in ["The ", "A ", "An "] {
            if let Some(rest) = cleaned.strip_prefix(article) {
                cleaned = rest.to_string();
                break;
            }
        }
    }

    // Split on any non-alphanumeric (Swift uses `CharacterSet.alphanumerics.inverted`)
    // then Capitalize each word and concatenate.
    let mut result = String::new();
    for word in cleaned.split(|c: char| !c.is_alphanumeric()) {
        if word.is_empty() {
            continue;
        }
        let sanitized = sanitize_component(word);
        if sanitized.is_empty() {
            continue;
        }
        // Capitalize the first character of the sanitized fragment.
        let mut chars = sanitized.chars();
        let capitalized: String = match chars.next() {
            Some(c) => c.to_uppercase().collect::<String>() + chars.as_str(),
            None => String::new(),
        };
        if result.len() + capitalized.len() > options.max_title_chars {
            break;
        }
        result.push_str(&capitalized);
    }

    if result.is_empty() {
        "Untitled".to_string()
    } else {
        result
    }
}

/// Strip diacritics (NFKD + ASCII-keep), drop unsafe filesystem characters
/// (`/ \ : * ? " < > |`) and control chars, and remove whitespace. Used for the
/// per-segment sanitization that produces e.g. `Müller` → `Muller`.
///
/// Differs from `crate::identifiers::cite_key::normalize_for_key`: that one is
/// for BibTeX cite keys (alphanumeric-only, lowercased) — this preserves
/// case so author family names stay capitalized.
pub fn sanitize_slug(input: &str) -> String {
    sanitize_component(input)
}

fn sanitize_component(input: &str) -> String {
    let unsafe_chars: &[char] = &['/', '\\', ':', '*', '?', '"', '<', '>', '|'];

    input
        .nfkd()
        // Drop combining diacritics + unsafe chars + control chars + whitespace.
        .filter(|c| {
            !unsafe_chars.contains(c)
                && !c.is_control()
                && !c.is_whitespace()
                // Keep ASCII letters/digits/`_-`; drop everything else (matches
                // `CharacterSet.alphanumerics.inverted` filtering used by
                // PDFManager.truncateTitle for word splitting).
                && (c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn einstein_basic() {
        let f = generate_filename("Einstein", Some(1905), "On the Electrodynamics of Moving Bodies", &Default::default());
        // Swift only strips leading "The/A/An" — "On" and "Of" remain as
        // title words. CamelCase concatenation removes word separators.
        assert_eq!(f, "Einstein_1905_OnTheElectrodynamicsOfMovingBodies.pdf");
    }

    #[test]
    fn strips_leading_the() {
        let f = generate_filename("Smith", Some(2024), "The Quick Brown Fox", &Default::default());
        assert_eq!(f, "Smith_2024_QuickBrownFox.pdf");
    }

    #[test]
    fn strips_leading_a_and_an() {
        let f_a = generate_filename("Smith", Some(2024), "A Tale of Two Cities", &Default::default());
        assert_eq!(f_a, "Smith_2024_TaleOfTwoCities.pdf");

        let f_an = generate_filename("Smith", Some(2024), "An Apple a Day", &Default::default());
        assert_eq!(f_an, "Smith_2024_AppleADay.pdf");
    }

    #[test]
    fn unknown_author_when_empty() {
        let f = generate_filename("", Some(2024), "Title", &Default::default());
        assert_eq!(f, "Unknown_2024_Title.pdf");
    }

    #[test]
    fn no_year_when_absent() {
        let f = generate_filename("Smith", None, "Title", &Default::default());
        assert_eq!(f, "Smith_NoYear_Title.pdf");
    }

    #[test]
    fn untitled_when_no_title() {
        let f = generate_filename("Smith", Some(2024), "", &Default::default());
        assert_eq!(f, "Smith_2024_Untitled.pdf");
    }

    #[test]
    fn diacritics_stripped() {
        let f = generate_filename("Müller", Some(2024), "Über die Quantenmechanik", &Default::default());
        // Müller → Muller, Über → Uber
        assert_eq!(f, "Muller_2024_UberDieQuantenmechanik.pdf");
    }

    #[test]
    fn unsafe_chars_stripped_from_author() {
        let f = generate_filename("Smith/Jones", Some(2024), "Title", &Default::default());
        assert_eq!(f, "SmithJones_2024_Title.pdf");
    }

    #[test]
    fn unsafe_chars_stripped_from_title() {
        let f = generate_filename("Smith", Some(2024), "Title: A <File>?", &Default::default());
        // Colon, angle brackets, question mark all dropped. Single "A" word
        // is NOT skipped (only leading-article stripping removes
        // "A "/"An "/"The " at the start of the whole title, not in the middle).
        assert_eq!(f, "Smith_2024_TitleAFile.pdf");
    }

    #[test]
    fn title_truncated_at_word_boundary() {
        let opts = FilenameOptions {
            max_title_chars: 20,
            ..Default::default()
        };
        let f = generate_filename(
            "Smith",
            Some(2024),
            "Quick Brown Fox Jumps Over The Lazy Dog",
            &opts,
        );
        // First few words concatenated up to 20 char budget.
        assert!(f.starts_with("Smith_2024_"));
        // Title part shouldn't exceed budget; words add atomically.
        let title_part = f.strip_prefix("Smith_2024_").unwrap()
            .strip_suffix(".pdf").unwrap();
        assert!(title_part.len() <= 20, "title `{}` exceeds 20-char budget", title_part);
    }

    #[test]
    fn custom_extension() {
        let opts = FilenameOptions {
            extension: "tex".to_string(),
            ..Default::default()
        };
        let f = generate_filename("Smith", Some(2024), "Paper", &opts);
        assert_eq!(f, "Smith_2024_Paper.tex");
    }

    #[test]
    fn empty_extension_omits_dot() {
        let opts = FilenameOptions {
            extension: String::new(),
            ..Default::default()
        };
        let f = generate_filename("Smith", Some(2024), "Paper", &opts);
        assert_eq!(f, "Smith_2024_Paper");
    }

    #[test]
    fn overall_cap_enforced() {
        let opts = FilenameOptions {
            max_overall_len: 30,
            max_title_chars: 200, // large title budget; overall cap kicks in
            ..Default::default()
        };
        let f = generate_filename(
            "Smith",
            Some(2024),
            "ThisIsAVeryLongTitleThatExceedsTheLimit",
            &opts,
        );
        // 30 + ".pdf"
        assert!(f.len() <= 34, "filename `{}` should be at most 34 chars", f);
    }

    #[test]
    fn sanitize_slug_strips_diacritics() {
        assert_eq!(sanitize_slug("Müller"), "Muller");
        // `Æ` does not decompose under NFKD (it is a single grapheme without
        // a canonical decomposition) so it is dropped along with other
        // non-ASCII characters. Result: "sop".
        assert_eq!(sanitize_slug("Æsop"), "sop");
        assert_eq!(sanitize_slug("naïve"), "naive");
    }

    #[test]
    fn sanitize_slug_drops_whitespace_and_unsafe() {
        assert_eq!(sanitize_slug("foo / bar : baz"), "foobarbaz");
        assert_eq!(sanitize_slug("a*b?c|d"), "abcd");
    }

    #[test]
    fn unicode_year_zero_treated_as_noyear() {
        let f = generate_filename("Smith", Some(0), "Title", &Default::default());
        assert_eq!(f, "Smith_NoYear_Title.pdf");
    }
}
