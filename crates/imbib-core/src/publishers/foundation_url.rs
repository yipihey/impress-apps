//! The three Foundation URL behaviours the publisher parsers depend on.
//!
//! `PublisherHTMLParsers` never touches `XMLDocument` or WebKit — it is regex
//! over HTML text — so the only platform surface it has is `URL` and
//! `URLComponents`. Three behaviours, each pinned by
//! `test_fixtures/golden/publisher_parse.json`:
//!
//! 1. **`URL.path` is percent-decoded** and drops one trailing slash. Supplied
//!    by [`impress_smart_search::swift_url`], written for the SmartSearch port;
//!    reused rather than rediscovered.
//! 2. **`URLComponents.path = <decoded path>` then `.url` RE-ENCODES.** Every
//!    path-rewriting parser (IOP, APS, Nature, Science, Wiley, Cambridge, MDPI)
//!    reads the decoded `path`, edits it as text, and assigns it back — so a
//!    landing-page URL with `%20` in it round-trips through a decode and a
//!    re-encode. Verified against the corpus: space → `%20`, a literal `%` →
//!    `%25`, non-ASCII → UTF-8 `%XX`, and `+ : / - . _ ~ ! $ & ' ( ) * , ; = @`
//!    all survive unencoded. Query and fragment are preserved.
//! 3. **`URL(string:)` / `URL(string:relativeTo:)`** with a `scheme != nil`
//!    test to choose between them.

use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use url::{Position, Url};

/// Foundation `CharacterSet.urlPathAllowed`, as the complement that
/// `percent_encoding` wants. Derived from the corpus, not from the docs.
const PATH_ALLOWED: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'!')
    .remove(b'$')
    .remove(b'&')
    .remove(b'\'')
    .remove(b'(')
    .remove(b')')
    .remove(b'*')
    .remove(b'+')
    .remove(b',')
    .remove(b'-')
    .remove(b'.')
    .remove(b'/')
    .remove(b':')
    .remove(b';')
    .remove(b'=')
    .remove(b'@')
    .remove(b'_')
    .remove(b'~');

/// Foundation `URL.path` — percent-decoded, one trailing slash trimmed, `""`
/// when the input carried no path.
pub fn path_of(url: &str) -> String {
    impress_smart_search::swift_url::parse(url)
        .map(|u| u.path)
        .unwrap_or_default()
}

/// `URLComponents(url:resolvingAgainstBaseURL: false)` + `components.path = p`
/// + `components.url`.
///
/// `p` is expected to be a DECODED path (i.e. something derived from
/// [`path_of`]), because that is the only way the Swift callers produce it.
pub fn with_path(base: &str, new_path: &str) -> Option<String> {
    let parsed = Url::parse(base).ok()?;
    let prefix = &parsed[..Position::BeforePath];
    let suffix = &parsed[Position::AfterPath..];
    let encoded = utf8_percent_encode(new_path, PATH_ALLOWED).to_string();
    Some(format!("{prefix}{encoded}{suffix}"))
}

/// Swift `resolveURL(_:baseURL:)`.
///
/// Decodes exactly four HTML entities — `&amp;`, `&lt;`, `&gt;`, `&quot;` — in
/// that order, trims Foundation whitespace-and-newlines, then returns the string
/// as-is if it carries a scheme, else resolves it against `base`.
///
/// The four-entity list is narrower than a real entity decoder (no `&#39;`, no
/// numeric forms) and is PRESERVED: widening it would change which href a
/// landing page resolves to, and `&amp;` is the only entity that appears in
/// practice because it is what an HTML serialiser must emit inside an attribute.
pub fn resolve(url_string: &str, base: &str) -> Option<String> {
    let decoded = url_string
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"");
    let decoded = impress_smart_search::foundation::trim_ws_nl(&decoded);

    if has_scheme(decoded) {
        // Foundation returns `absoluteString`, which for a string that parses
        // cleanly is the string. Parse only to reject garbage.
        if Url::parse(decoded).is_ok() {
            return Some(decoded.to_string());
        }
        return None;
    }

    let base_url = Url::parse(base).ok()?;
    base_url.join(decoded).ok().map(|u| u.to_string())
}

/// RFC 3986 scheme test, standing in for Foundation's `url.scheme != nil`.
/// A leading digit disqualifies, which is why a bare DOI path like
/// `10.1088/x` is treated as relative rather than as scheme `10.1088`.
fn has_scheme(s: &str) -> bool {
    let mut chars = s.char_indices();
    match chars.next() {
        Some((_, c)) if c.is_ascii_alphabetic() => {}
        _ => return false,
    }
    for (i, c) in chars {
        match c {
            ':' => return i > 0,
            c if c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.' => {}
            _ => return false,
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_is_decoded_and_trailing_slash_trimmed() {
        assert_eq!(
            path_of("https://iopscience.iop.org/article/10.1088/a%20b"),
            "/article/10.1088/a b"
        );
        assert_eq!(path_of("https://x.org/a/"), "/a");
        assert_eq!(path_of("https://x.org"), "");
    }

    #[test]
    fn assigning_a_path_reencodes_it() {
        assert_eq!(
            with_path("https://x.org/a%20b", "/a b/pdf").unwrap(),
            "https://x.org/a%20b/pdf"
        );
        assert_eq!(
            with_path("https://x.org/a", "/a%b/pdf").unwrap(),
            "https://x.org/a%25b/pdf"
        );
        assert_eq!(
            with_path("https://x.org/a", "/Müller/pdf").unwrap(),
            "https://x.org/M%C3%BCller/pdf"
        );
    }

    #[test]
    fn assigning_a_path_preserves_query_and_fragment() {
        assert_eq!(
            with_path("https://x.org/a?q=1", "/a/pdf").unwrap(),
            "https://x.org/a/pdf?q=1"
        );
        assert_eq!(
            with_path("https://x.org/a#s2", "/a/pdf").unwrap(),
            "https://x.org/a/pdf#s2"
        );
    }

    #[test]
    fn plus_and_colon_survive_reencoding() {
        assert_eq!(
            with_path("https://x.org/a", "/a+b:c/pdf").unwrap(),
            "https://x.org/a+b:c/pdf"
        );
    }

    #[test]
    fn resolve_absolute_returns_verbatim() {
        assert_eq!(
            resolve("https://x.org/g?a=1&amp;b=2.pdf", "https://y.org/").unwrap(),
            "https://x.org/g?a=1&b=2.pdf"
        );
    }

    #[test]
    fn resolve_relative_replaces_the_last_segment() {
        assert_eq!(
            resolve("sibling.pdf", "https://x.org/journal/article/1").unwrap(),
            "https://x.org/journal/article/sibling.pdf"
        );
        assert_eq!(
            resolve("/pdf/1.pdf", "https://x.org/journal/article/1").unwrap(),
            "https://x.org/pdf/1.pdf"
        );
    }

    #[test]
    fn scheme_detection_rejects_doi_shaped_paths() {
        assert!(has_scheme("https://x"));
        assert!(has_scheme("mailto:a"));
        assert!(!has_scheme("10.1088/x"));
        assert!(!has_scheme("sibling.pdf"));
        assert!(!has_scheme("/a/b"));
    }
}
