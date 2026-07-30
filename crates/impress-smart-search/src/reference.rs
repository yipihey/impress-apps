//! Citation-reference parsing support.
//!
//! Port of the deterministic half of `ReferenceParser.swift`. The parse itself
//! is an LLM call (Apple Intelligence `@Generable ParsedCitation`, or a cloud
//! runner) and stays in Swift; what lives here is everything around it:
//!
//! * [`make_reference_prompt`] — the prompt, byte-pinned by the goldens.
//! * [`decode_cloud_json`] — parse the cloud response.
//! * [`validate`] — the part that actually protects search quality: it drops
//!   identifiers the model invented, because a hallucinated DOI resolves to
//!   the *wrong paper* silently, which is worse than no result.

use lazy_static::lazy_static;
use regex::Regex;
use serde::Deserialize;

use crate::rewriter::strip_code_fences;
use crate::types::{CitationInput, ParsedReference};

lazy_static! {
    // These mirror Swift's `range(of:options:.regularExpression)` calls, which
    // use NSRegularExpression. Its `$` might be expected to also match before a
    // single trailing newline (as ICU documents), but empirically it does not
    // here: the corpus pins `"10.1234/x\n"` and `"2301.04153\n"` as *invalid*,
    // so these anchor with `\z`, same as the Swift-Regex `wholeMatch` variants
    // in `crate::intent`. Worth stating explicitly, because a model emitting a
    // trailing newline in a DOI is exactly the case this guards.
    static ref RE_DOI: Regex = Regex::new(r"\A10\.\d{4,9}/\S+\z").unwrap();
    static ref RE_ARXIV: Regex =
        Regex::new(r"\A(\d{4}\.\d{4,5}(v\d+)?|[a-z\-]+(\.[A-Z]{2})?/\d{7}(v\d+)?)\z").unwrap();
    static ref RE_BIBCODE: Regex =
        Regex::new(r"\A\d{4}[A-Za-z&.][A-Za-z&.]{1,7}[.\d][.\d]+[A-Z]\z").unwrap();
}

/// Turn a raw model parse into a `CitationInput`, dropping anything that
/// doesn't validate. `raw` is retained as `free_text` so the resolver can fall
/// back to an all-sources search when structured ADS finds nothing.
pub fn validate(p: &ParsedReference, raw: &str) -> CitationInput {
    let doi = if RE_DOI.is_match(&p.doi) {
        Some(p.doi.clone())
    } else {
        None
    };
    let arxiv = if RE_ARXIV.is_match(&p.arxiv) {
        Some(p.arxiv.clone())
    } else {
        None
    };
    let bibcode = if p.bibcode.chars().count() == 19 && RE_BIBCODE.is_match(&p.bibcode) {
        Some(p.bibcode.clone())
    } else {
        None
    };

    CitationInput {
        authors: p
            .authors
            .iter()
            .filter(|a| !a.is_empty())
            .cloned()
            .collect(),
        title: non_empty(&p.title),
        year: if (1900..=2100).contains(&p.year) {
            Some(p.year)
        } else {
            None
        },
        journal: non_empty(&p.journal),
        volume: non_empty(&p.volume),
        pages: non_empty(&p.pages),
        doi,
        arxiv,
        bibcode,
        free_text: Some(raw.to_string()),
    }
}

fn non_empty(s: &str) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

/// `JSONDecoder` accepts a JSON float for an `Int` field when it is integral
/// (`2002.0` → 2002) and throws otherwise (`2002.7`). `serde_json` rejects both,
/// so `year` needs this to stay parity-exact — models do emit `2002.0`.
fn de_lenient_i64<'de, D>(d: D) -> Result<Option<i64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::Error as _;
    let v = Option::<serde_json::Value>::deserialize(d)?;
    match v {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(serde_json::Value::Number(n)) => {
            if let Some(i) = n.as_i64() {
                return Ok(Some(i));
            }
            match n.as_f64() {
                Some(f) if f.is_finite() && f.fract() == 0.0 => Ok(Some(f as i64)),
                _ => Err(D::Error::custom("year is not an integer")),
            }
        }
        Some(_) => Err(D::Error::custom("year must be a number")),
    }
}

#[derive(Deserialize)]
struct CloudParsedCitation {
    authors: Option<Vec<String>>,
    title: Option<String>,
    #[serde(default, deserialize_with = "de_lenient_i64")]
    year: Option<i64>,
    journal: Option<String>,
    volume: Option<String>,
    pages: Option<String>,
    doi: Option<String>,
    arxiv: Option<String>,
    bibcode: Option<String>,
    confidence: Option<f64>,
}

/// Decode a cloud model's JSON citation into a `ParsedReference`.
///
/// `JSONDecoder` semantics: unknown keys ignored, type mismatch on a known key
/// fails the whole decode. A float `year` that is integral (`2002.0`) decodes;
/// `2002.7` does not.
pub fn decode_cloud_json(text: &str) -> Option<ParsedReference> {
    let cleaned = strip_code_fences(text);
    let raw: CloudParsedCitation = serde_json::from_str(&cleaned).ok()?;
    Some(ParsedReference {
        authors: raw.authors.unwrap_or_default(),
        title: raw.title.unwrap_or_default(),
        year: raw.year.unwrap_or(0),
        journal: raw.journal.unwrap_or_default(),
        volume: raw.volume.unwrap_or_default(),
        pages: raw.pages.unwrap_or_default(),
        doi: raw.doi.unwrap_or_default(),
        arxiv: raw.arxiv.unwrap_or_default(),
        bibcode: raw.bibcode.unwrap_or_default(),
        confidence: raw.confidence.unwrap_or(0.5),
    })
}

/// The on-device citation-parsing prompt.
pub fn make_reference_prompt(block: &str) -> String {
    format!(
        "Parse this scientific bibliography reference into structured fields. \
It may be in any common style (APA, AMS, Nature, AAS, BibTeX-rendered, ADS). \
Preserve the original title capitalization. Use empty string for missing string \
fields and 0 for missing year. Do not invent DOI / arXiv / bibcode — only emit \
them if they appear verbatim in the input.

Reference:
{block}"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(doi: &str, arxiv: &str, bibcode: &str, year: i64) -> ParsedReference {
        ParsedReference {
            doi: doi.to_string(),
            arxiv: arxiv.to_string(),
            bibcode: bibcode.to_string(),
            year,
            ..Default::default()
        }
    }

    #[test]
    fn invented_identifiers_are_dropped() {
        let c = validate(
            &parsed("not-a-doi", "not-arxiv", "not-bibcode", 2002),
            "RAW",
        );
        assert!(c.doi.is_none() && c.arxiv.is_none() && c.bibcode.is_none());
        assert!(!c.has_identifier());
        assert_eq!(c.free_text.as_deref(), Some("RAW"));
    }

    #[test]
    fn valid_identifiers_survive() {
        let c = validate(
            &parsed("10.1234/y", "astro-ph/0112088", "1986ApJ...304...15B", 1986),
            "RAW",
        );
        assert_eq!(c.doi.as_deref(), Some("10.1234/y"));
        assert_eq!(c.arxiv.as_deref(), Some("astro-ph/0112088"));
        assert_eq!(c.bibcode.as_deref(), Some("1986ApJ...304...15B"));
        assert_eq!(c.year, Some(1986));
    }

    #[test]
    fn year_bounds() {
        assert_eq!(validate(&parsed("", "", "", 1899), "").year, None);
        assert_eq!(validate(&parsed("", "", "", 1900), "").year, Some(1900));
        assert_eq!(validate(&parsed("", "", "", 2100), "").year, Some(2100));
        assert_eq!(validate(&parsed("", "", "", 2101), "").year, None);
    }

    #[test]
    fn integral_float_year_decodes_but_fractional_does_not() {
        assert_eq!(
            decode_cloud_json(r#"{"year":2002.0,"authors":["Abel"]}"#)
                .unwrap()
                .year,
            2002
        );
        assert!(decode_cloud_json(r#"{"year":2002.7,"authors":["Abel"]}"#).is_none());
        assert!(decode_cloud_json(r#"{"authors":"Abel"}"#).is_none());
    }
}
