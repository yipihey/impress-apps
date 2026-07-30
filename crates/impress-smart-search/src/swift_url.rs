//! Foundation `URL` emulation for the http(s) subset.
//!
//! The Swift classifier reads three things off a `URL`: `absoluteString`,
//! `host` and `path`. Reproducing them exactly matters, because
//! [`crate::intent`] pattern-matches on `path` — and Foundation's `path`
//! semantics differ from the `url` crate's in two ways the golden corpus
//! caught immediately:
//!
//! 1. **`path` is percent-DECODED.** `https://en.wikipedia.org/wiki/G%C3%B6del%2527s`
//!    yields `absoluteString` with the escapes intact but
//!    `path == "/wiki/Gödel%27s"` — one decoding round, so `%25` becomes a
//!    literal `%`. `url::Url::path()` returns the raw encoded form. Every
//!    `path`-matching rule (`doi_in_path`, the ADS `search/` tail split, the
//!    arXiv/bibcode segment checks) therefore runs on decoded text.
//! 2. **`path` drops one trailing slash** (`/search/` → `/search`), except
//!    when the path is exactly `/`. `url` keeps it.
//!
//! `absoluteString` also differs: Foundation does *not* synthesize a `/` path
//! for `https://example.com`, whereas `url` normalizes it to
//! `https://example.com/`. We undo that when the input had no path.
//!
//! Everything else (IDNA punycoding of the host, percent-encoding of
//! non-ASCII path bytes and spaces) the `url` crate already does the same way
//! — verified case-by-case against `intent_url_dissect.json`.

use percent_encoding::percent_decode_str;
use url::Url;

/// The three Foundation `URL` projections the classifier consumes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SwiftUrl {
    /// Foundation `URL.absoluteString`.
    pub absolute_string: String,
    /// Foundation `URL.host` (lowercased by callers, not here).
    pub host: String,
    /// Foundation `URL.path` — percent-decoded, trailing slash trimmed.
    pub path: String,
}

/// Parse `input` the way `URL(string:)` does, keeping only http(s) URLs that
/// have a host. Mirrors `IntentClassifier.urlMatch`, whose guard is:
/// `^https?://` prefix, parseable, scheme in {http, https}, non-nil host.
pub fn parse(input: &str) -> Option<SwiftUrl> {
    // Swift checks the literal prefix with a regex before constructing the
    // URL, so `HTTPS://x` (uppercase scheme) never reaches `URL(string:)`.
    // Reproduce that ordering: the prefix test is case-SENSITIVE.
    if !(input.starts_with("http://") || input.starts_with("https://")) {
        return None;
    }
    // WHATWG (and therefore `Url::parse`) *strips* ASCII tab and newline
    // before parsing, so "https://a.com\nhttps://b.com" would silently become
    // one URL with host "a.comhttps". Foundation rejects such a string
    // outright. Reject first.
    if input.contains(['\t', '\n', '\r']) {
        return None;
    }
    // Foundation rejects a bare authority-less URL and anything with a space
    // in the authority; `Url::parse` agrees on both.
    let parsed = Url::parse(input).ok()?;
    let scheme = parsed.scheme();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let host = parsed.host_str()?.to_string();
    if host.is_empty() {
        return None;
    }

    // --- absoluteString -------------------------------------------------
    // `Url::parse` guarantees a path of at least "/". Foundation leaves the
    // path empty when the input had none, so strip the synthesized slash.
    let mut absolute_string = parsed.as_str().to_string();
    if !input_has_path(input) {
        // Only the synthesized slash goes; a query/fragment keeps its place.
        if let Some(stripped) = strip_synthesized_root_slash(&absolute_string, &parsed) {
            absolute_string = stripped;
        }
    }

    // --- path -----------------------------------------------------------
    // Foundation reports "" (not "/") when the input carried no path at all,
    // even with a query or fragment present: `https://example.com?q=1` → "".
    let path = if input_has_path(input) {
        let decoded = percent_decode_str(parsed.path())
            .decode_utf8_lossy()
            .into_owned();
        trim_one_trailing_slash(&decoded)
    } else {
        String::new()
    };

    Some(SwiftUrl {
        absolute_string,
        host,
        path,
    })
}

/// True when the raw input actually contained a path component, i.e. there is
/// a `/` after the `scheme://authority` part.
fn input_has_path(input: &str) -> bool {
    let after_scheme = match input.find("://") {
        Some(i) => &input[i + 3..],
        None => return false,
    };
    // The authority ends at the first `/`, `?` or `#`.
    match after_scheme.find(['/', '?', '#']) {
        Some(i) => after_scheme.as_bytes()[i] == b'/',
        None => false,
    }
}

/// Remove the `/` that `Url` synthesized for an empty path, keeping any
/// `?query` / `#fragment` attached.
fn strip_synthesized_root_slash(absolute: &str, parsed: &Url) -> Option<String> {
    // Rebuild as scheme://authority[?query][#fragment].
    let authority_end = absolute.find("://")? + 3;
    let rest = &absolute[authority_end..];
    let slash = rest.find('/')?;
    let (authority, tail) = rest.split_at(slash);
    // `tail` starts with the synthesized "/". Drop exactly that character.
    let tail = &tail[1..];
    debug_assert!(parsed.path() == "/");
    Some(format!(
        "{}{}{}",
        &absolute[..authority_end],
        authority,
        tail
    ))
}

/// Foundation drops a single trailing `/` from `path`, but keeps the root.
fn trim_one_trailing_slash(path: &str) -> String {
    if path.len() > 1 && path.ends_with('/') {
        path[..path.len() - 1].to_string()
    } else {
        path.to_string()
    }
}

/// Split a Foundation `path` into `/`-separated non-empty segments, matching
/// Swift's `path.split(separator: "/")` (which omits empty subsequences).
pub fn path_segments(path: &str) -> Vec<&str> {
    path.split('/').filter(|s| !s.is_empty()).collect()
}

/// One round of percent-decoding, mirroring Swift's
/// `String.removingPercentEncoding` (which returns nil on invalid escapes —
/// callers all use `?? original`, so lossy-with-fallback is equivalent).
pub fn removing_percent_encoding(s: &str) -> String {
    percent_decode_str(s).decode_utf8_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_non_http() {
        assert!(parse("ftp://example.com/x").is_none());
        assert!(parse("www.example.com").is_none());
        assert!(parse("https://").is_none());
        assert!(parse("mailto:a@b.com").is_none());
    }

    #[test]
    fn keeps_pathless_absolute_string_without_slash() {
        let u = parse("https://example.com").unwrap();
        assert_eq!(u.absolute_string, "https://example.com");
        assert_eq!(u.path, "");
    }

    #[test]
    fn keeps_explicit_root_slash() {
        let u = parse("https://example.com/").unwrap();
        assert_eq!(u.absolute_string, "https://example.com/");
        assert_eq!(u.path, "/");
    }

    #[test]
    fn path_is_percent_decoded_once() {
        let u = parse("https://en.wikipedia.org/wiki/Original_proof_of_G%C3%B6del%2527s_theorem")
            .unwrap();
        assert_eq!(u.path, "/wiki/Original_proof_of_Gödel%27s_theorem");
    }

    #[test]
    fn trailing_slash_trimmed_from_path_only() {
        let u = parse("https://ui.adsabs.harvard.edu/search/").unwrap();
        assert_eq!(u.path, "/search");
        assert_eq!(u.absolute_string, "https://ui.adsabs.harvard.edu/search/");
    }

    #[test]
    fn idna_host_and_encoded_path() {
        let u = parse("https://例え.jp/テスト").unwrap();
        assert_eq!(u.host, "xn--r8jz45g.jp");
        assert_eq!(
            u.absolute_string,
            "https://xn--r8jz45g.jp/%E3%83%86%E3%82%B9%E3%83%88"
        );
        assert_eq!(u.path, "/テスト");
    }

    #[test]
    fn space_is_encoded_in_absolute_string_but_not_path() {
        let u = parse("https://doi.org/10.1/x year:2002").unwrap();
        assert_eq!(u.absolute_string, "https://doi.org/10.1/x%20year:2002");
        assert_eq!(u.path, "/10.1/x year:2002");
    }

    #[test]
    fn userinfo_is_kept_in_absolute_string() {
        let u = parse("https://user:pass@example.com/path").unwrap();
        assert_eq!(u.host, "example.com");
        assert_eq!(u.absolute_string, "https://user:pass@example.com/path");
    }
}
