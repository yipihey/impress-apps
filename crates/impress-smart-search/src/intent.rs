//! Deterministic, no-LLM classification of Cmd+S search input.
//!
//! Port of `IntentClassifier.swift`. Runs on every keystroke, so everything
//! here is synchronous and allocation-light.
//!
//! Dispatch order (load-bearing — reordering changes results):
//!   1. single-line http(s) URL → identifier / fielded / url
//!   2. single-line bare identifier → identifier
//!   3. ADS field qualifiers anywhere → fielded
//!   4. ≥2 reference blocks, or one block that scores as a reference
//!   5. free text
//!
//! ## Regex dialect notes
//!
//! Swift mixes two engines here and they are *not* interchangeable:
//! `identifierMatch` uses Swift Regex `wholeMatch(of:)` (implicit full-string
//! anchoring), while `hasFieldQualifiers` / `looksLikeReference` / `doiInPath`
//! use `NSRegularExpression` searches. We reproduce the distinction with
//! `\A(?:…)\z` for the former and plain `is_match` for the latter. No pattern
//! in this file needs lookaround, so the `regex` crate covers all of them —
//! unlike [`crate::ads_normalizer`], which does.

use lazy_static::lazy_static;
use regex::Regex;
use std::collections::HashSet;

use crate::foundation::{trim_ws, trim_ws_nl};
use crate::swift_url::{self, path_segments, removing_percent_encoding, SwiftUrl};
use crate::types::{PaperIdentifier, SearchIntent};

lazy_static! {
    // --- identifier shapes (Swift Regex wholeMatch → \A..\z) ---
    static ref RE_DOI_WHOLE: Regex = Regex::new(r"\A10\.\d{4,9}/\S+\z").unwrap();
    static ref RE_ARXIV_NEW_WHOLE: Regex = Regex::new(r"\A\d{4}\.\d{4,5}(v\d+)?\z").unwrap();
    static ref RE_ARXIV_OLD_WHOLE: Regex =
        Regex::new(r"\A[a-z\-]+(\.[A-Z]{2})?/\d{7}(v\d+)?\z").unwrap();
    static ref RE_BIBCODE_WHOLE: Regex =
        Regex::new(r"\A\d{4}[A-Za-z&.][A-Za-z&.]{1,7}[.\d][.\d]+[A-Z]\z").unwrap();
    static ref RE_PMID_WHOLE: Regex = Regex::new(r"\A\d{5,9}\z").unwrap();
    static ref RE_ARXIV_EITHER_WHOLE: Regex =
        Regex::new(r"\A(\d{4}\.\d{4,5}(v\d+)?|[a-z\-]+(\.[A-Z]{2})?/\d{7}(v\d+)?)\z").unwrap();
    static ref RE_NATURE_SLUG: Regex = Regex::new(r"\A[a-z0-9._\-]+\z").unwrap();

    // --- searches ---
    static ref RE_DOI_IN_PATH: Regex = Regex::new(r"10\.\d{4,9}/[^\s?#]+").unwrap();
    static ref RE_ADS_FUNC: Regex =
        Regex::new(r"(?i)\b(citations|references|similar|trending|reviews|useful)\(").unwrap();
    static ref RE_YEAR: Regex = Regex::new(r"\b(19|20)\d{2}\b").unwrap();
    static ref RE_VOL_PAGE_1: Regex = Regex::new(r"\b\d{1,4},\s*\d{1,4}\b").unwrap();
    static ref RE_VOL_PAGE_2: Regex = Regex::new(r"(?i)\bvol\.?\s*\d+\b").unwrap();
    static ref RE_VOL_PAGE_3: Regex = Regex::new(r"(?i)\bpp?\.\s*\d+").unwrap();
    static ref RE_ET_AL: Regex = Regex::new(r"(?i)\bet\s+al\.?").unwrap();
    static ref RE_SURNAME_INITIAL: Regex = Regex::new(r"\b[A-Z][a-z]+,\s*[A-Z][a-z]*\.?").unwrap();
    static ref RE_BIBITEM_MARKER: Regex =
        Regex::new(r"(?m)^\s*(\\bibitem|\[\d{1,3}\]|\(\d{1,3}\)|\d{1,3}\.\s+[A-Z])").unwrap();
    static ref RE_NUMBERED_LINE: Regex = Regex::new(r"^[\[\(]?\d{1,3}[\]\.\)]\s+").unwrap();

    /// One compiled `\bfield:` matcher per ADS qualifier. Swift builds these
    /// on the fly from a `Set<String>` and returns on the first hit; set
    /// iteration order is unspecified but irrelevant to a boolean result.
    static ref RE_FIELD_QUALIFIERS: Vec<Regex> = ADS_FIELD_QUALIFIERS
        .iter()
        .map(|f| Regex::new(&format!(r"(?i)\b{}:", regex::escape(f))).unwrap())
        .collect();

    /// `\b<token>\b` per journal token. Note the trailing-`.` tokens
    /// ("Phys.Rev.", "Astrophys.", "Astron."): `\b` after a literal `.`
    /// requires a word character to follow, so "Astrophys. J." matches but a
    /// sentence-final "Astrophys." does not. Preserved verbatim from Swift.
    static ref RE_JOURNAL_TOKENS: Vec<Regex> = JOURNAL_TOKENS
        .iter()
        .map(|t| Regex::new(&format!(r"\b{}\b", regex::escape(t))).unwrap())
        .collect();
}

/// ADS field qualifiers that force the `.fielded` passthrough path.
pub const ADS_FIELD_QUALIFIERS: &[&str] = &[
    "author",
    "first_author",
    "title",
    "abs",
    "abstract",
    "year",
    "bibcode",
    "doi",
    "arxiv",
    "orcid",
    "aff",
    "affiliation",
    "full",
    "object",
    "body",
    "keyword",
    "property",
    "doctype",
    "collection",
    "bibstem",
    "arxiv_class",
    "identifier",
    "citations",
    "references",
    "similar",
    "trending",
    "reviews",
    "useful",
    "author_count",
    "citation_count",
    "read_count",
    "database",
    "au",
    "ti",
    "ab",
];

const JOURNAL_TOKENS: &[&str] = &[
    "ApJ",
    "ApJL",
    "ApJS",
    "MNRAS",
    "A&A",
    "AAS",
    "Nature",
    "Science",
    "PNAS",
    "PRL",
    "PRD",
    "PRA",
    "PRB",
    "PRC",
    "PRE",
    "PRX",
    "JCAP",
    "JHEP",
    "JHEPL",
    "PhysRev",
    "Phys.Rev.",
    "PhysLett",
    "PhysLet",
    "Astrophys.",
    "Astron.",
    "AstroLett",
    "Icarus",
    "Geophys",
    "JGR",
];

lazy_static! {
    /// arXiv archive prefixes accepted for the legacy `archive/YYMMNNN` form
    /// when scraping a page. Kept here (rather than in
    /// [`crate::url_extract`]) because both modules need the same whitelist.
    pub static ref ARXIV_OLD_ARCHIVES: HashSet<&'static str> = [
        "math",
        "astro-ph",
        "hep-th",
        "hep-ph",
        "hep-ex",
        "hep-lat",
        "gr-qc",
        "nucl-th",
        "nucl-ex",
        "cond-mat",
        "quant-ph",
        "q-alg",
        "alg-geom",
        "dg-ga",
        "funct-an",
        "q-bio",
        "cs",
        "nlin",
        "physics",
        "chao-dyn",
        "solv-int",
        "comp-gas",
        "adap-org",
        "atom-ph",
        "plasm-ph",
        "supr-con",
        "mtrl-th",
        "cmp-lg",
        "acc-phys",
        "patt-sol",
        "ao-sci",
        "bayes-an",
        "chem-ph",
    ]
    .into_iter()
    .collect();
}

/// Classify a user input string. Empty input → `FreeText("")`.
pub fn classify(input: &str) -> SearchIntent {
    let trimmed = trim_ws_nl(input);
    if trimmed.is_empty() {
        return SearchIntent::FreeText {
            query: String::new(),
        };
    }

    let single_line = !trimmed.contains('\n');

    // 1. URL — three short-circuits before "fetch and extract".
    if single_line {
        if let Some(url) = url_match(trimmed) {
            if let Some(id) = identifier_from_url(&url) {
                return SearchIntent::Identifier(id);
            }
            if let Some(query) = search_query_from_url(&url) {
                return SearchIntent::Fielded { query };
            }
            return SearchIntent::Url {
                url: url.absolute_string,
                host: url.host,
            };
        }
    }

    // 2. Bare identifier, single line only.
    if single_line {
        if let Some(id) = identifier_match(trimmed) {
            return SearchIntent::Identifier(id);
        }
    }

    // 3. Fielded — ADS qualifier syntax wins over reference heuristics.
    if has_field_qualifiers(trimmed) {
        return SearchIntent::Fielded {
            query: trimmed.to_string(),
        };
    }

    // 4. Reference — multi-block paste or single-string heuristic match.
    let blocks = split_reference_blocks(trimmed);
    if blocks.len() >= 2 {
        return SearchIntent::Reference { blocks };
    }
    if looks_like_reference(trimmed) {
        return SearchIntent::Reference {
            blocks: vec![trimmed.to_string()],
        };
    }

    SearchIntent::FreeText {
        query: trimmed.to_string(),
    }
}

// ---------------------------------------------------------------- URL parsing

/// Match a single bare http(s) URL. See [`crate::swift_url`] for why this is
/// not just `Url::parse`.
pub fn url_match(input: &str) -> Option<SwiftUrl> {
    swift_url::parse(input)
}

/// Recognize URLs that *are* identifier links, so the caller takes the cheap
/// identifier path instead of fetching HTML and scraping the bibliography.
pub fn identifier_from_url(url: &SwiftUrl) -> Option<PaperIdentifier> {
    let host = url.host.to_lowercase();
    let path = &url.path;

    // doi.org / dx.doi.org → the DOI is the path.
    if host == "doi.org" || host == "dx.doi.org" {
        let doi = path.trim_start_matches('/');
        if RE_DOI_WHOLE.is_match(doi) {
            return Some(PaperIdentifier::Doi(doi.to_string()));
        }
    }

    // arxiv.org/{abs,pdf,html}/<id>
    if host.ends_with("arxiv.org") {
        let segments = path_segments(path);
        if segments.len() >= 2 && matches!(segments[0], "abs" | "pdf" | "html") {
            let mut id = segments[1..].join("/");
            if let Some(stripped) = id.strip_suffix(".pdf") {
                id = stripped.to_string();
            }
            if let Some(stripped) = id.strip_suffix(".html") {
                id = stripped.to_string();
            }
            if RE_ARXIV_EITHER_WHOLE.is_match(&id) {
                return Some(PaperIdentifier::Arxiv(id));
            }
        }
    }

    // pubmed.ncbi.nlm.nih.gov/<digits>
    if host.ends_with("pubmed.ncbi.nlm.nih.gov") || host.ends_with("ncbi.nlm.nih.gov") {
        for seg in path_segments(path) {
            if RE_PMID_WHOLE.is_match(seg) {
                return Some(PaperIdentifier::Pmid(seg.to_string()));
            }
        }
    }

    // nature.com/articles/<slug> — Nature encodes the DOI suffix as the slug
    // and the prefix is always 10.1038.
    if host.ends_with("nature.com") {
        let segments = path_segments(path);
        if segments.len() >= 2 && segments[0] == "articles" {
            let slug = segments[1];
            if !slug.is_empty() && RE_NATURE_SLUG.is_match(slug) {
                return Some(PaperIdentifier::Doi(format!("10.1038/{slug}")));
            }
        }
    }

    // ui.adsabs.harvard.edu/abs/<bibcode>
    if host.ends_with("adsabs.harvard.edu") {
        let segments = path_segments(path);
        if let Some(abs_idx) = segments.iter().position(|s| *s == "abs") {
            if abs_idx + 1 < segments.len() {
                // Bibcodes in URLs are usually percent-encoded. `SwiftUrl::path`
                // already decoded once; Swift decodes again here, so we do too.
                let decoded = removing_percent_encoding(segments[abs_idx + 1]);
                if decoded.chars().count() == 19 && RE_BIBCODE_WHOLE.is_match(&decoded) {
                    return Some(PaperIdentifier::Bibcode(decoded));
                }
            }
        }
    }

    // Generic publisher landing page: any path embedding `10.NNNN/...`.
    if let Some(doi) = doi_in_path(path) {
        return Some(PaperIdentifier::Doi(doi));
    }

    None
}

/// Extract the `q=` value from an ADS search URL. Returns `None` for anything
/// that isn't an ADS search, or has no non-empty `q`.
///
/// The `q=` must be found *specifically* — not the `q=` inside `fq=` (Solr
/// filter) or `aq=`.
pub fn search_query_from_url(url: &SwiftUrl) -> Option<String> {
    let host = url.host.to_lowercase();
    if !host.ends_with("adsabs.harvard.edu") {
        return None;
    }
    let path = &url.path;
    if !path.starts_with("/search") {
        return None;
    }

    // 1. Standard query component: ?q=...
    if let Some(q) = first_query_item(&url.absolute_string, "q") {
        if !q.is_empty() {
            return Some(q);
        }
    }

    // 2. ADS slash-style: params live in the path.
    let tail = path.strip_prefix("/search/")?;
    for segment in tail.split('&') {
        let mut it = segment.splitn(2, '=');
        let key = it.next()?;
        let Some(value) = it.next() else { continue };
        if key != "q" {
            continue;
        }
        let decoded = removing_percent_encoding(value);
        return if decoded.is_empty() {
            None
        } else {
            Some(decoded)
        };
    }
    None
}

/// Foundation `URLComponents.queryItems.first(where: name == key)?.value`.
///
/// Deliberately hand-rolled rather than `Url::query_pairs()`: that helper is
/// `application/x-www-form-urlencoded`-flavoured and turns `+` into a space,
/// which `URLComponents` does not do.
fn first_query_item(absolute: &str, key: &str) -> Option<String> {
    let after_hash = absolute.split('#').next().unwrap_or(absolute);
    let query = after_hash.split_once('?')?.1;
    for pair in query.split('&') {
        let (k, v) = match pair.split_once('=') {
            Some((k, v)) => (k, v),
            // `?q` with no `=` — Foundation reports value nil, which the Swift
            // `?.value` chain treats as no match.
            None => continue,
        };
        if removing_percent_encoding(k) == key {
            return Some(removing_percent_encoding(v));
        }
    }
    None
}

/// Extract a DOI from a URL path component, trimming URL/path punctuation
/// noise from the tail (matches `trim_trailing_punct` in
/// [`crate::url_extract`], except that this variant also strips `/`).
pub fn doi_in_path(path: &str) -> Option<String> {
    let m = RE_DOI_IN_PATH.find(path)?;
    let mut doi = m.as_str().to_string();
    while let Some(last) = doi.chars().last() {
        if ".,;:)\"'/]".contains(last) {
            doi.pop();
        } else {
            break;
        }
    }
    // A real DOI has a non-empty suffix after the first slash.
    match doi.split_once('/') {
        Some((_, suffix)) if !suffix.is_empty() => Some(doi),
        _ => None,
    }
}

// --------------------------------------------------------- identifier parsing

/// Match a single bare identifier. Returns `None` for anything that isn't a
/// clean identifier, so identifiers buried in prose don't leak through.
pub fn identifier_match(input: &str) -> Option<PaperIdentifier> {
    let lower = input.to_lowercase();
    // Prefix stripping, in Swift's order. Space-separated forms ("arXiv 2602.04407",
    // "doi 10.…") are common when typed by hand; the whole-match regexes below
    // still reject prose.
    let stripped: &str = if lower.starts_with("doi:") {
        trim_spaces(&input[4..])
    } else if lower.starts_with("arxiv:") || lower.starts_with("arxiv ") {
        trim_spaces(&input[6..])
    } else if lower.starts_with("doi ") {
        trim_spaces(&input[4..])
    } else if lower.starts_with("pmid:") {
        trim_spaces(&input[5..])
    } else if lower.starts_with("bibcode:") {
        trim_spaces(&input[8..])
    } else {
        input
    };

    if RE_DOI_WHOLE.is_match(stripped) {
        return Some(PaperIdentifier::Doi(stripped.to_string()));
    }
    if RE_ARXIV_NEW_WHOLE.is_match(stripped) {
        return Some(PaperIdentifier::Arxiv(stripped.to_string()));
    }
    if RE_ARXIV_OLD_WHOLE.is_match(stripped) {
        return Some(PaperIdentifier::Arxiv(stripped.to_string()));
    }
    if stripped.chars().count() == 19 && RE_BIBCODE_WHOLE.is_match(stripped) {
        return Some(PaperIdentifier::Bibcode(stripped.to_string()));
    }
    // PMID only when prefixed — a bare 7-digit number is too ambiguous.
    if lower.starts_with("pmid:") && RE_PMID_WHOLE.is_match(stripped) {
        return Some(PaperIdentifier::Pmid(stripped.to_string()));
    }
    None
}

/// Swift `trimmingCharacters(in: .whitespaces)` — horizontal whitespace only,
/// no newlines. Distinct from the `.whitespacesAndNewlines` trim in `classify`.
fn trim_spaces(s: &str) -> &str {
    trim_ws(s)
}

// ------------------------------------------------------ fielded-query sniffing

/// True when the input carries ADS qualifier syntax (`author:`, `year:`, a
/// function operator like `citations(`, …).
///
/// Note the deliberate breadth: `\btitle:` is case-insensitive and
/// unanchored, so prose like `"Title: A Study of Things"` classifies as
/// `.fielded`. That is a real quirk with a real cost (the query goes to ADS
/// verbatim), but it is *preserved*: narrowing it is a search-behavior change
/// that belongs in its own change, not in a port.
pub fn has_field_qualifiers(text: &str) -> bool {
    for re in RE_FIELD_QUALIFIERS.iter() {
        if re.is_match(text) {
            return true;
        }
    }
    RE_ADS_FUNC.is_match(text)
}

// ------------------------------------------------------- reference heuristics

/// True when ≥2 reference signals fire on a single-line input, or any one
/// signal fires on multi-line input.
pub fn looks_like_reference(text: &str) -> bool {
    let mut score = 0;

    if RE_YEAR.is_match(text) {
        score += 1;
    }
    if RE_VOL_PAGE_1.is_match(text) || RE_VOL_PAGE_2.is_match(text) || RE_VOL_PAGE_3.is_match(text)
    {
        score += 1;
    }
    if RE_JOURNAL_TOKENS.iter().any(|re| re.is_match(text)) {
        score += 1;
    }
    if RE_ET_AL.is_match(text) {
        score += 1;
    }
    if RE_SURNAME_INITIAL.is_match(text) {
        score += 1;
    }
    if RE_BIBITEM_MARKER.is_match(text) {
        score += 1;
    }

    if text.contains('\n') {
        score >= 1
    } else {
        score >= 2
    }
}

/// Split a multi-reference paste into blocks. Three strategies, first win:
/// `\bibitem`, numbered line markers, blank-line separation.
pub fn split_reference_blocks(text: &str) -> Vec<String> {
    // Strategy 1: \bibitem
    if text.contains("\\bibitem") {
        let blocks = split_by_line_prefix(text, |line| line.starts_with("\\bibitem"));
        if blocks.len() >= 2 {
            return blocks;
        }
    }
    // Strategy 2: numbered markers at line start
    let blocks = split_by_line_prefix(text, |line| RE_NUMBERED_LINE.is_match(line));
    if blocks.len() >= 2 {
        return blocks;
    }
    // Strategy 3: blank-line separated
    let blank_split = blank_line_split(text);
    if blank_split.len() >= 2 {
        return blank_split;
    }
    vec![trim_ws_nl(text).to_string()]
}

/// Accumulate lines into blocks, starting a new block whenever `is_start`
/// fires on the line's leading-whitespace-stripped form.
///
/// Preserved quirk: any lines *before* the first start marker are silently
/// dropped (Swift appends to `current` only when it is already non-empty).
fn split_by_line_prefix<F: Fn(&str) -> bool>(text: &str, is_start: F) -> Vec<String> {
    let mut blocks: Vec<String> = Vec::new();
    let mut current = String::new();

    for line in text.split('\n') {
        // `drop(while: \.isWhitespace)` — Character.isWhitespace, *not* the
        // Foundation set, so a leading U+200B is kept here.
        let trimmed_leading = line.trim_start_matches(|c: char| c.is_whitespace());
        if is_start(trimmed_leading) {
            let finalized = trim_ws_nl(&current);
            if !finalized.is_empty() {
                blocks.push(finalized.to_string());
            }
            current = line.to_string();
        } else if !current.is_empty() {
            current.push('\n');
            current.push_str(line);
        }
    }
    let tail = trim_ws_nl(&current);
    if !tail.is_empty() {
        blocks.push(tail.to_string());
    }
    blocks
}

fn blank_line_split(text: &str) -> Vec<String> {
    let mut blocks: Vec<String> = Vec::new();
    let mut current: Vec<&str> = Vec::new();

    let flush = |current: &mut Vec<&str>, blocks: &mut Vec<String>| {
        if !current.is_empty() {
            let joined = current.join("\n");
            let block = trim_ws_nl(&joined);
            if !block.is_empty() {
                blocks.push(block.to_string());
            }
            current.clear();
        }
    };

    for line in text.split('\n') {
        // Swift `line.allSatisfy(\.isWhitespace)` — vacuously true for "".
        if line.chars().all(|c| c.is_whitespace()) {
            flush(&mut current, &mut blocks);
        } else {
            current.push(line);
        }
    }
    flush(&mut current, &mut blocks);
    blocks
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kind(input: &str) -> &'static str {
        classify(input).kind_raw_value()
    }

    #[test]
    fn empty_and_whitespace_are_free_text() {
        assert_eq!(
            classify(""),
            SearchIntent::FreeText {
                query: String::new()
            }
        );
        assert_eq!(
            classify("   \n  "),
            SearchIntent::FreeText {
                query: String::new()
            }
        );
    }

    #[test]
    fn identifiers() {
        assert_eq!(
            classify("10.1126/science.295.5552.93"),
            SearchIntent::Identifier(PaperIdentifier::Doi(
                "10.1126/science.295.5552.93".to_string()
            ))
        );
        assert_eq!(
            classify("arXiv 2602.04407"),
            SearchIntent::Identifier(PaperIdentifier::Arxiv("2602.04407".to_string()))
        );
        assert_eq!(kind("arXiv papers about dark matter"), "freeText");
        assert_eq!(kind("2301.04153V2"), "freeText"); // uppercase V rejected
        assert_eq!(kind("ASTRO-PH/0112088"), "freeText"); // uppercase archive rejected
        assert_eq!(kind("1234567"), "freeText"); // bare PMID too ambiguous
    }

    #[test]
    fn url_short_circuits() {
        assert_eq!(
            classify("https://arxiv.org/pdf/2301.04153.pdf"),
            SearchIntent::Identifier(PaperIdentifier::Arxiv("2301.04153".to_string()))
        );
        assert_eq!(
            classify("https://www.nature.com/articles/nature01080"),
            SearchIntent::Identifier(PaperIdentifier::Doi("10.1038/nature01080".to_string()))
        );
        assert_eq!(
            kind("https://en.wikipedia.org/wiki/Population_III_star"),
            "url"
        );
    }

    #[test]
    fn ads_search_url_becomes_fielded() {
        assert_eq!(
            classify(
                "https://ui.adsabs.harvard.edu/search/q=author%3A%22Abel%22%20year%3A2002&sort=date%20desc"
            ),
            SearchIntent::Fielded {
                query: "author:\"Abel\" year:2002".to_string()
            }
        );
        // trailing slash only → no q → plain url
        assert_eq!(kind("https://ui.adsabs.harvard.edu/search/"), "url");
    }

    #[test]
    fn preserved_quirk_title_colon_in_prose_is_fielded() {
        assert_eq!(kind("Title: A Study of Things"), "fielded");
        assert_eq!(kind("Note: this is interesting"), "freeText");
    }

    #[test]
    fn references() {
        assert_eq!(
            kind("Abel, T., Bryan, G. L., Norman, M. L. 2002, Science, 295, 93"),
            "reference"
        );
        let multi = "[1] Abel, T. 2002, Science, 295, 93\n[2] Bromm, V. 2004, ARA&A, 42, 79";
        match classify(multi) {
            SearchIntent::Reference { blocks } => assert_eq!(blocks.len(), 2),
            other => panic!("expected reference, got {other:?}"),
        }
    }

    #[test]
    fn preamble_before_first_marker_is_dropped() {
        let text = "Bibliography\n[1] A 2002, ApJ, 1, 1\n[2] B 2004, ApJ, 2, 2";
        let blocks = split_reference_blocks(text);
        assert_eq!(blocks.len(), 2);
        assert!(blocks[0].starts_with("[1]"));
    }
}
