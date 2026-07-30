//! Foundation string predicates that Rust's stdlib does not match.
//!
//! The Swift original uses **three different** whitespace notions, and they
//! disagree. Substituting `str::trim()` for all of them is wrong in ways the
//! golden corpus caught on the very first run:
//!
//! | Swift | contains U+200B | contains `\n`, U+2028/9, U+0085 |
//! |---|---|---|
//! | `trimmingCharacters(in: .whitespacesAndNewlines)` | **yes** | yes |
//! | `trimmingCharacters(in: .whitespaces)` | **yes** | no |
//! | `Character.isWhitespace` | no | yes |
//! | Rust `char::is_whitespace` / `str::trim()` | no | yes |
//!
//! U+200B ZERO WIDTH SPACE is the culprit: it was reclassified from `Zs` to
//! `Cf` in Unicode 4.0, so it is not `White_Space` and Rust ignores it — but
//! Foundation's `CharacterSet.whitespaces` still contains it. Verified
//! empirically across the whole plausible range (U+0009…U+FEFF); U+200B is the
//! only codepoint where Foundation and Rust disagree, and U+180E, U+200C,
//! U+200D, U+2060 and U+FEFF are whitespace to *neither*.
//!
//! This matters in practice: pasting from a web page or a PDF very often
//! carries zero-width spaces, and `classify("\u{200B}")` must reach the same
//! "empty input" branch it reaches in Swift.

/// Foundation `CharacterSet.whitespacesAndNewlines`.
pub fn is_ws_nl(c: char) -> bool {
    c.is_whitespace() || c == '\u{200B}'
}

/// Foundation `CharacterSet.whitespaces` — horizontal only.
pub fn is_ws(c: char) -> bool {
    match c {
        // Newlines are excluded from `.whitespaces`.
        '\n' | '\u{000B}' | '\u{000C}' | '\r' | '\u{0085}' | '\u{2028}' | '\u{2029}' => false,
        _ => is_ws_nl(c),
    }
}

/// Swift `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub fn trim_ws_nl(s: &str) -> &str {
    s.trim_matches(is_ws_nl)
}

/// Swift `trimmingCharacters(in: .whitespaces)`.
pub fn trim_ws(s: &str) -> &str {
    s.trim_matches(is_ws)
}

/// Swift `components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }`.
pub fn split_ws_nl(s: &str) -> Vec<&str> {
    s.split(is_ws_nl).filter(|p| !p.is_empty()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_width_space_is_foundation_whitespace_but_not_rust() {
        assert!(is_ws_nl('\u{200B}'));
        assert!(is_ws('\u{200B}'));
        assert!(!'\u{200B}'.is_whitespace());
        assert_eq!(trim_ws_nl("\u{200B}"), "");
        assert_eq!(trim_ws_nl(" \u{200B}x\u{200B} "), "x");
    }

    #[test]
    fn newlines_are_in_the_wsnl_set_only() {
        assert!(is_ws_nl('\n'));
        assert!(!is_ws('\n'));
        assert_eq!(trim_ws("\n x \n"), "\n x \n");
        assert_eq!(trim_ws_nl("\n x \n"), "x");
    }

    #[test]
    fn non_whitespace_format_characters_stay() {
        for c in ['\u{180E}', '\u{200C}', '\u{200D}', '\u{2060}', '\u{FEFF}'] {
            assert!(!is_ws_nl(c), "{c:?} should not be whitespace");
        }
    }

    #[test]
    fn split_drops_empties() {
        assert_eq!(split_ws_nl("  a\u{200B}b \n c "), vec!["a", "b", "c"]);
        assert!(split_ws_nl("   ").is_empty());
    }
}
