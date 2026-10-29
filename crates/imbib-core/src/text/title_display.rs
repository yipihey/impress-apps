//! A title set in capitals throughout, shown in title case.
//!
//! Crossref deposits World Scientific chapters and older ApJ papers as
//! `THE DARK MATTER HALO OF M31`. When no other source had the title cased
//! (koine's merge prefers one that does), the display recases it. The
//! stored title is never changed: this is a reading aid, and it guesses.
//!
//! What it keeps in capitals, because it is probably an acronym or a
//! numeral: a word of one or two letters that is not a short function word
//! (`HI`, `UV`, `X`), a word with no vowel (`SDSS`, `CMB`, `JWST`, `LCDM`),
//! a word with a digit (`M31`, `21CM`), and a Roman numeral (`III`, `IV`).
//! An acronym with vowels (`ALMA`, `WMAP`) comes out `Alma`: the guess
//! that costs least.

use std::borrow::Cow;

/// Function words set lower case inside a title.
const SMALL: &[&str] = &[
    "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "of", "on", "or",
    "per", "the", "to", "via", "vs", "with",
];

/// Whether a title is set in capitals throughout: letters, and none lower
/// case. Four letters or fewer is too short to tell from an acronym.
/// The same rule as koine's `federation::shouts`.
pub fn shouts(title: &str) -> bool {
    let letters = title.chars().filter(|c| c.is_alphabetic()).count();
    letters > 4 && !title.chars().any(char::is_lowercase)
}

/// `title` in title case when it [`shouts`], else unchanged.
pub fn display_title(title: &str) -> Cow<'_, str> {
    if !shouts(title) {
        return Cow::Borrowed(title);
    }
    let mut out = String::with_capacity(title.len());
    let mut first = true;
    let mut word = String::new();
    for c in title.chars() {
        if c.is_alphanumeric() {
            word.push(c);
        } else {
            if !word.is_empty() {
                out.push_str(&recase(&word, first));
                first = false;
                word.clear();
            }
            out.push(c);
        }
    }
    if !word.is_empty() {
        out.push_str(&recase(&word, first));
    }
    Cow::Owned(out)
}

fn recase(word: &str, first: bool) -> String {
    let lower = word.to_lowercase();
    let letters = word.chars().filter(|c| c.is_alphabetic()).count();
    let small = SMALL.contains(&lower.as_str());
    if small {
        return if first { capitalise(&lower) } else { lower };
    }
    let keep = letters <= 2
        || word.chars().any(|c| c.is_ascii_digit())
        || !lower.chars().any(|c| "aeiouy".contains(c))
        || (letters <= 4 && word.chars().all(|c| "IVXLC".contains(c)));
    if keep {
        word.to_string()
    } else {
        capitalise(&lower)
    }
}

fn capitalise(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_title_in_capitals_is_shown_in_title_case() {
        assert_eq!(
            display_title(
                "THE DARK MATTER HALO CONCENTRATION AND STELLAR INITIAL MASS FUNCTION OF M31"
            ),
            "The Dark Matter Halo Concentration and Stellar Initial Mass Function of M31"
        );
        assert_eq!(
            display_title("THE PROLATE SHAPE OF THE GALACTIC DARK-MATTER HALO"),
            "The Prolate Shape of the Galactic Dark-Matter Halo"
        );
        assert_eq!(
            display_title("HI 21CM MAPS FROM SDSS AND JWST: PAPER III"),
            "HI 21CM Maps from SDSS and JWST: Paper III"
        );
    }

    #[test]
    fn a_cased_or_short_title_is_left_alone() {
        assert!(matches!(
            display_title("Galactic Halo of Dark Matter"),
            Cow::Borrowed(_)
        ));
        assert!(matches!(display_title("ALMA"), Cow::Borrowed(_)));
        assert_eq!(
            display_title("The first stars in ΛCDM"),
            "The first stars in ΛCDM"
        );
    }
}
