//! What a paper is called on the tablet.
//!
//! The tablet shows a document's name, not a filename, and names it from
//! the stem of the file we upload. A reader scanning a folder wants the
//! first author, the year and the title — the citekey alone is opaque.
//! Deterministic on purpose: the engine matches an upload back to its
//! listing entry by this name.

use impress_remarkable::rmdoc::SourceKind;

/// The bibliographic bits a name is built from.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct NameInputs {
    pub cite_key: String,
    pub first_author_family: Option<String>,
    pub year: Option<i32>,
    pub title: Option<String>,
}

impl NameInputs {
    /// Derive the inputs from a list row's display fields. `author_string`
    /// is imbib's "; "-joined (or "A and B") author list.
    pub fn from_display(
        cite_key: &str,
        author_string: &str,
        year: Option<i32>,
        title: &str,
    ) -> Self {
        Self {
            cite_key: cite_key.to_string(),
            first_author_family: first_author_family(author_string),
            year,
            title: (!title.trim().is_empty()).then(|| title.trim().to_string()),
        }
    }
}

/// The family name of the first author in an imbib author string.
pub fn first_author_family(author_string: &str) -> Option<String> {
    let first = author_string
        .split(';')
        .next()
        .map(str::trim)
        .filter(|s| !s.is_empty())?;
    let first = first
        .split(" and ")
        .next()
        .map(str::trim)
        .filter(|s| !s.is_empty())?;
    let family = match first.split_once(',') {
        // "Abel, Tom"
        Some((family, _)) => family.trim().to_string(),
        // "Tom Abel"
        None => first
            .split_whitespace()
            .last()
            .map(|word| {
                word.trim_matches(|c: char| !c.is_alphanumeric())
                    .to_string()
            })
            .unwrap_or_default(),
    };
    (!family.is_empty()).then_some(family)
}

const MAX_TITLE_CHARS: usize = 60;

/// `"{Family} {Year} – {Title}"`, each part dropped when unknown, the
/// title cut at a word boundary; the citekey when nothing else is known.
pub fn visible_name(inputs: &NameInputs) -> String {
    let mut head = String::new();
    if let Some(family) = inputs
        .first_author_family
        .as_deref()
        .map(sanitize)
        .filter(|s| !s.is_empty())
    {
        head.push_str(&family);
    }
    if let Some(year) = inputs.year {
        if !head.is_empty() {
            head.push(' ');
        }
        head.push_str(&year.to_string());
    }
    let title = inputs
        .title
        .as_deref()
        .map(sanitize)
        .map(|t| truncate_words(&t, MAX_TITLE_CHARS))
        .filter(|t| !t.is_empty());
    let name = match (head.is_empty(), title) {
        (false, Some(title)) => format!("{head} – {title}"),
        (false, None) => head,
        (true, Some(title)) => title,
        (true, None) => String::new(),
    };
    if name.is_empty() {
        sanitize(&inputs.cite_key)
    } else {
        name
    }
}

/// The name used when another document in the same folder already has it.
pub fn with_collision_suffix(name: &str, cite_key: &str) -> String {
    format!("{name} [{}]", sanitize(cite_key))
}

/// The filename to upload: the tablet takes the display name from the stem.
pub fn upload_filename(name: &str, kind: SourceKind) -> String {
    format!("{name}.{}", kind.extension())
}

/// A library or collection name as a tablet folder name.
pub fn folder_name(raw: &str) -> String {
    let name = sanitize(raw);
    if name.is_empty() {
        "Untitled".into()
    } else {
        name
    }
}

/// Strip what a filename must not carry, collapse whitespace, trim.
pub fn sanitize(raw: &str) -> String {
    let replaced: String = raw
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '-',
            c if c.is_control() => ' ',
            c => c,
        })
        .collect();
    replaced
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches(|c: char| c == '.' || c == ' ')
        .to_string()
}

fn truncate_words(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let mut out = String::new();
    for word in text.split(' ') {
        let candidate_len =
            out.chars().count() + word.chars().count() + usize::from(!out.is_empty());
        if candidate_len > max_chars {
            break;
        }
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(word);
    }
    if out.is_empty() {
        // A single enormous word: cut it hard.
        out = text.chars().take(max_chars).collect();
    }
    format!("{}…", out.trim_end_matches([',', ':', ';']))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn family_names_come_out_of_both_author_spellings() {
        assert_eq!(
            first_author_family("Abel, Tom; Bryan, Greg").as_deref(),
            Some("Abel")
        );
        assert_eq!(
            first_author_family("Tom Abel and Greg Bryan").as_deref(),
            Some("Abel")
        );
        assert_eq!(first_author_family("").as_deref(), None);
        assert_eq!(
            first_author_family("van der Waals, J.").as_deref(),
            Some("van der Waals")
        );
    }

    #[test]
    fn names_are_deterministic_and_readable() {
        let inputs = NameInputs::from_display(
            "Abel2002",
            "Abel, Tom; Bryan, Greg; Norman, Michael",
            Some(2002),
            "The Formation of the First Star in the Universe",
        );
        assert_eq!(
            visible_name(&inputs),
            "Abel 2002 – The Formation of the First Star in the Universe"
        );
        assert_eq!(visible_name(&inputs), visible_name(&inputs.clone()));
        assert_eq!(
            with_collision_suffix(&visible_name(&inputs), "Abel2002"),
            "Abel 2002 – The Formation of the First Star in the Universe [Abel2002]"
        );
        assert_eq!(
            upload_filename("Abel 2002 – First star", SourceKind::Epub),
            "Abel 2002 – First star.epub"
        );
    }

    #[test]
    fn long_titles_are_cut_at_a_word_and_bad_characters_removed() {
        let inputs = NameInputs {
            cite_key: "x".into(),
            first_author_family: Some("Smith/Jones".into()),
            year: None,
            title: Some(
                "A very: long <title> that keeps going and going and going well past sixty characters in total"
                    .into(),
            ),
        };
        let name = visible_name(&inputs);
        assert!(
            name.starts_with("Smith-Jones – A very- long -title- that keeps going"),
            "{name}"
        );
        assert!(name.ends_with('…'));
        assert!(!name.contains('/') && !name.contains('<'));
        assert!(name.chars().count() <= "Smith-Jones – ".len() + MAX_TITLE_CHARS + 1);
    }

    #[test]
    fn a_bare_record_falls_back_to_the_citekey() {
        let inputs = NameInputs {
            cite_key: "Anon:2020".into(),
            ..Default::default()
        };
        assert_eq!(visible_name(&inputs), "Anon-2020");
        assert_eq!(
            folder_name("  Cosmology / Reionization  "),
            "Cosmology - Reionization"
        );
        assert_eq!(folder_name(""), "Untitled");
    }
}
