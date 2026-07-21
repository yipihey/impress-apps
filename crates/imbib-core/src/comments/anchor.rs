//! Range re-anchoring for range-anchored comments.
//!
//! A range-anchored comment stores byte offsets (`anchor_start`/`anchor_end`)
//! into a body text, the snippet those offsets covered (`anchor_text`), and
//! the hash of the body the range was valid against (`anchored_body_hash`).
//! When the body changes, [`reanchor`] resolves the stored anchor against the
//! new body.
//!
//! This is the load-bearing logic for comment survival across edits; it lives
//! in Rust so macOS, iOS, and headless tests all share one implementation.
//! All offsets are **byte** offsets into UTF-8 text. The function never
//! panics: invalid offsets (out of range, not on a char boundary, start > end)
//! simply fail the exact-match fast path and fall through to snippet search.

/// Outcome of resolving a stored comment anchor against a body text.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "native", derive(uniffi::Enum))]
pub enum AnchorResolution {
    /// The stored hash matches the current body and the stored byte range is
    /// valid and still covers `anchor_text`: the range is usable as-is.
    Exact { start: u64, end: u64 },
    /// The body changed (or the stored range was invalid) but `anchor_text`
    /// occurs in the new body. When it occurs more than once, the occurrence
    /// whose start is closest to the original `anchor_start` wins (ties go to
    /// the earlier occurrence). Persist the new range with
    /// `update_comment_anchor`.
    Moved { start: u64, end: u64 },
    /// `anchor_text` is empty/absent or no longer occurs in the body. The
    /// comment survives as a document-level comment without a range.
    Orphaned,
}

/// Resolve a stored comment anchor against `body`.
///
/// * `anchor_start`/`anchor_end` — stored byte offsets (end exclusive).
/// * `anchor_text` — the snippet the range covered when the comment was
///   created (or last re-anchored). Empty means "no usable anchor".
/// * `hash_matches` — whether the current body's content hash equals the
///   stored `anchored_body_hash`. Callers compare hashes; this function only
///   trusts the boolean.
///
/// Never panics, for arbitrary (even inconsistent) inputs: offsets are
/// validated against `body`'s length and char boundaries before any slicing.
pub fn reanchor(
    body: &str,
    anchor_start: usize,
    anchor_end: usize,
    anchor_text: &str,
    hash_matches: bool,
) -> AnchorResolution {
    if anchor_text.is_empty() {
        return AnchorResolution::Orphaned;
    }

    // Fast path: body unchanged since the range was stored. Still validate
    // defensively — offsets from persistence are untrusted input.
    if hash_matches
        && anchor_start <= anchor_end
        && anchor_end <= body.len()
        && body.is_char_boundary(anchor_start)
        && body.is_char_boundary(anchor_end)
        && &body[anchor_start..anchor_end] == anchor_text
    {
        return AnchorResolution::Exact {
            start: anchor_start as u64,
            end: anchor_end as u64,
        };
    }

    // Body changed (or stored range was inconsistent): search for the
    // snippet, preferring the occurrence closest to the original start.
    let mut best: Option<usize> = None;
    for (idx, _) in body.match_indices(anchor_text) {
        match best {
            None => best = Some(idx),
            Some(current) => {
                if idx.abs_diff(anchor_start) < current.abs_diff(anchor_start) {
                    best = Some(idx);
                } else {
                    // match_indices yields ascending offsets, so distances
                    // only grow from here.
                    break;
                }
            }
        }
    }

    match best {
        Some(start) => AnchorResolution::Moved {
            start: start as u64,
            end: (start + anchor_text.len()) as u64,
        },
        None => AnchorResolution::Orphaned,
    }
}

/// FFI wrapper for [`reanchor`] (owned types for UniFFI).
///
/// Offsets larger than the platform's `usize` are clamped, which safely
/// resolves as "not the exact range" and falls through to snippet search.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn reanchor_comment(
    body: String,
    anchor_start: u64,
    anchor_end: u64,
    anchor_text: String,
    hash_matches: bool,
) -> AnchorResolution {
    let start = usize::try_from(anchor_start).unwrap_or(usize::MAX);
    let end = usize::try_from(anchor_end).unwrap_or(usize::MAX);
    reanchor(&body, start, end, &anchor_text, hash_matches)
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn exact_when_hash_matches() {
        let body = "The quick brown fox jumps over the lazy dog.";
        let res = reanchor(body, 4, 9, "quick", true);
        assert_eq!(res, AnchorResolution::Exact { start: 4, end: 9 });
    }

    #[test]
    fn moved_single_occurrence() {
        // Text inserted before the snippet: hash differs, offsets stale.
        let body = "Well, the quick brown fox jumps.";
        let res = reanchor(body, 4, 9, "quick", false);
        assert_eq!(res, AnchorResolution::Moved { start: 10, end: 15 });
    }

    #[test]
    fn moved_multiple_prefers_closest() {
        // "cat" occurs at bytes 0, 20, and 40. Original start 25 → the
        // occurrence at 20 is closest.
        let body = "cat ................cat ................cat";
        assert_eq!(body.find("cat"), Some(0));
        let res = reanchor(body, 25, 28, "cat", false);
        assert_eq!(res, AnchorResolution::Moved { start: 20, end: 23 });
    }

    #[test]
    fn moved_multiple_tie_prefers_earlier() {
        // "ab" at 0 and 8; original start 4 is equidistant → earlier wins.
        let body = "ab......ab";
        let res = reanchor(body, 4, 6, "ab", false);
        assert_eq!(res, AnchorResolution::Moved { start: 0, end: 2 });
    }

    #[test]
    fn orphaned_when_text_missing() {
        let res = reanchor("completely rewritten paragraph", 4, 9, "quick", false);
        assert_eq!(res, AnchorResolution::Orphaned);
    }

    #[test]
    fn orphaned_on_empty_anchor_text() {
        assert_eq!(
            reanchor("some body", 0, 0, "", true),
            AnchorResolution::Orphaned
        );
        assert_eq!(
            reanchor("some body", 2, 5, "", false),
            AnchorResolution::Orphaned
        );
    }

    #[test]
    fn multibyte_emoji_shift() {
        // Emoji (4 bytes each) inserted before the snippet.
        let body = "🦀🦀 the quick fox";
        // "quick" now starts at 2*4 + 5 = 13.
        let res = reanchor(body, 4, 9, "quick", false);
        assert_eq!(res, AnchorResolution::Moved { start: 13, end: 18 });
        if let AnchorResolution::Moved { start, end } = res {
            assert_eq!(&body[start as usize..end as usize], "quick");
        }
    }

    #[test]
    fn multibyte_combining_chars() {
        // "é" as e + U+0301 (combining acute): "cafe\u{301}" is 6 bytes.
        let body = "un cafe\u{301} noir";
        let anchor = "cafe\u{301}";
        // Exact when hash matches and offsets are right (start 3, 6 bytes).
        let res = reanchor(body, 3, 3 + anchor.len(), anchor, true);
        assert_eq!(
            res,
            AnchorResolution::Exact {
                start: 3,
                end: 3 + anchor.len() as u64
            }
        );
        // Stale offsets landing mid-codepoint must not panic and must re-find.
        let res = reanchor(body, 8, 8 + anchor.len(), anchor, false);
        assert_eq!(
            res,
            AnchorResolution::Moved {
                start: 3,
                end: 3 + anchor.len() as u64
            }
        );
    }

    #[test]
    fn stale_offsets_inside_multibyte_char_do_not_panic() {
        let body = "héllo wörld";
        // Byte 2 is inside the 'é' sequence; hash claims match — the exact
        // path must reject it (char boundary) and fall through to search.
        let res = reanchor(body, 2, 4, "llo", true);
        assert_eq!(res, AnchorResolution::Moved { start: 3, end: 6 });
    }

    #[test]
    fn anchor_at_body_end() {
        let body = "ends with anchor";
        let res = reanchor(body, 10, 16, "anchor", true);
        assert_eq!(res, AnchorResolution::Exact { start: 10, end: 16 });
        // Same range after a prefix edit.
        let body2 = "now it ends with anchor";
        let res2 = reanchor(body2, 10, 16, "anchor", false);
        assert_eq!(res2, AnchorResolution::Moved { start: 17, end: 23 });
    }

    #[test]
    fn out_of_range_offsets_do_not_panic() {
        assert_eq!(
            reanchor("short", 100, 200, "missing", true),
            AnchorResolution::Orphaned
        );
        assert_eq!(
            reanchor("short", 3, 1, "short", true), // start > end
            AnchorResolution::Moved { start: 0, end: 5 }
        );
    }

    proptest! {
        /// Never panics for arbitrary bodies, snippets, offsets, and hash
        /// flags — and any returned range is valid: on char boundaries,
        /// within the body, and slicing it yields exactly `anchor_text`.
        #[test]
        fn reanchor_never_panics_and_returns_valid_ranges(
            body in "\\PC*",
            anchor_text in "\\PC*",
            anchor_start in 0usize..4096,
            anchor_end in 0usize..4096,
            hash_matches: bool,
        ) {
            let res = reanchor(&body, anchor_start, anchor_end, &anchor_text, hash_matches);
            match res {
                AnchorResolution::Exact { start, end }
                | AnchorResolution::Moved { start, end } => {
                    let (s, e) = (start as usize, end as usize);
                    prop_assert!(s <= e && e <= body.len());
                    prop_assert!(body.is_char_boundary(s) && body.is_char_boundary(e));
                    prop_assert_eq!(&body[s..e], anchor_text.as_str());
                }
                AnchorResolution::Orphaned => {
                    // Orphaned must be honest: either no snippet or no match.
                    prop_assert!(
                        anchor_text.is_empty() || !body.contains(&anchor_text)
                    );
                }
            }
        }
    }
}
