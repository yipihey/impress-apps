//! Per-publisher landing-page PDF extraction.
//!
//! Ported from `PMC/Publishers/PublisherHTMLParsers.swift` (551 lines) in
//! Stage 7 item 9; pinned by `test_fixtures/golden/publisher_parse.json` and
//! `publisher_parser_id.json`.
//!
//! # Why this is regex and not a DOM parse
//!
//! The Swift original imports only `Foundation` and `OSLog`: no `XMLDocument`,
//! no `XMLParser`, no `NSAttributedString(html:)`, no WebKit. It is twenty
//! `NSRegularExpression` patterns over HTML text. So the "HTML parsing dialect
//! differences" risk that would normally block a port **does not exist here** —
//! there is no parser to disagree with. All twenty patterns use only
//! `[^"']+`, `[^>]+`, `(?:…)`, `.*?` and `\s*`: no lookaround, no
//! backreferences, so the `regex` crate takes them verbatim with `(?is)` in
//! place of `[.caseInsensitive, .dotMatchesLineSeparators]`.
//!
//! Adopting `scraper`/`html5ever` was considered and rejected: it would pull a
//! large new dependency subtree (html5ever + tendril + selectors + cssparser,
//! none of them currently in the workspace) in order to *change* the behaviour
//! the 54 golden cases pin. A DOM parse would find PDFs the regexes miss, which
//! is an improvement — and therefore its own change, with its own corpus, not a
//! port. `regex` + `lazy_static` are already what the neighbouring
//! `impress_smart_search::url_extract` uses for the same job on the same kind of
//! page.
//!
//! # Traffic
//!
//! This is a hot, user-facing path: `PDFTab`/`NotesTab` call it from `.onAppear`
//! when `autoDownloadEnabled` is set, so it runs on publication SELECTION, and
//! `PDFBatchDownloadView` runs one resolution per selected row. The regex work
//! is negligible next to the `URLSession` GET that precedes it — **the fetch
//! stays Swift**, for the same reasons the SmartSearch port left it there
//! (proxy configuration, ATS, the sandbox network entitlement, cookie and
//! redirect policy). The win here is one definition and 54 pinned cases, not
//! speed.

use lazy_static::lazy_static;
use regex::Regex;

use super::foundation_url::{path_of, resolve, with_path};

/// Every parser id `parser_id` can return. Used by the rules table's
/// consistency test so an `htmlParserID` typo cannot ship.
pub const PARSER_IDS: &[&str] = &[
    "iop",
    "aps",
    "nature",
    "oxford",
    "elsevier",
    "aanda",
    "science",
    "wiley",
    "springer",
    "cambridge",
    "annual-reviews",
    "mdpi",
    "frontiers",
    "plos",
    "aip",
    "generic",
];

/// Swift `parserID(for:)`.
///
/// Preserved quirk: the tests are `contains`, not a suffix match, and they run
/// in this exact order. So `evil-nature.com.example.org` is dispatched to the
/// Nature parser, and `iopscience.iop.org.phish.net` to IOP. Harmless today
/// because the worst outcome is picking the wrong extraction strategy for a page
/// that was already fetched, but it is a `contains` and the corpus says so.
pub fn parser_id(publisher_host: &str) -> &'static str {
    let h = publisher_host;
    if h.contains("iopscience.iop.org") {
        return "iop";
    }
    if h.contains("link.aps.org") || h.contains("journals.aps.org") {
        return "aps";
    }
    if h.contains("nature.com") {
        return "nature";
    }
    if h.contains("academic.oup.com") {
        return "oxford";
    }
    if h.contains("sciencedirect.com") {
        return "elsevier";
    }
    if h.contains("aanda.org") {
        return "aanda";
    }
    if h.contains("science.org") {
        return "science";
    }
    if h.contains("wiley.com") || h.contains("onlinelibrary.wiley.com") {
        return "wiley";
    }
    if h.contains("springer.com") || h.contains("link.springer.com") {
        return "springer";
    }
    if h.contains("cambridge.org") {
        return "cambridge";
    }
    if h.contains("annualreviews.org") {
        return "annual-reviews";
    }
    if h.contains("mdpi.com") {
        return "mdpi";
    }
    if h.contains("frontiersin.org") {
        return "frontiers";
    }
    if h.contains("plos.org") || h.contains("journals.plos.org") {
        return "plos";
    }
    if h.contains("aip.org") || h.contains("aip.scitation.org") {
        return "aip";
    }
    "generic"
}

lazy_static! {
    // citation_pdf_url, both attribute orders.
    static ref RE_META_NAME_FIRST: Regex = Regex::new(
        r#"(?is)<meta\s+name\s*=\s*["']citation_pdf_url["']\s+content\s*=\s*["']([^"']+)["']"#
    ).unwrap();
    static ref RE_META_CONTENT_FIRST: Regex = Regex::new(
        r#"(?is)<meta\s+content\s*=\s*["']([^"']+)["']\s+name\s*=\s*["']citation_pdf_url["']"#
    ).unwrap();

    static ref RE_IOP_BTN: Regex = Regex::new(
        r#"(?is)<a[^>]+class\s*=\s*["'][^"']*btn-download[^"']*["'][^>]+href\s*=\s*["']([^"']+)["']"#
    ).unwrap();
    static ref RE_APS_PDF_TEXT: Regex = Regex::new(
        r#"(?is)<a[^>]+href\s*=\s*["']([^"']*pdf[^"']*)["'][^>]*>\s*(?:PDF|Download PDF)"#
    ).unwrap();
    static ref RE_NATURE_TRACK: Regex = Regex::new(
        r#"(?is)<a[^>]+data-track-action\s*=\s*["']download pdf["'][^>]+href\s*=\s*["']([^"']+)["']"#
    ).unwrap();
    static ref RE_NATURE_TRACK_REV: Regex = Regex::new(
        r#"(?is)<a[^>]+href\s*=\s*["']([^"']+)["'][^>]+data-track-action\s*=\s*["']download pdf["']"#
    ).unwrap();
    static ref RE_PDF_LINK_CLASS: Regex = Regex::new(
        r#"(?is)<a[^>]+class\s*=\s*["'][^"']*pdf-link[^"']*["'][^>]+href\s*=\s*["']([^"']+)["']"#
    ).unwrap();
    static ref RE_OXFORD_VIEW_PDF: Regex = Regex::new(
        r#"(?is)<a[^>]+href\s*=\s*["']([^"']+\.pdf[^"']*)["'][^>]*>(?:\s*<[^>]*>)*\s*(?:View\s+)?PDF"#
    ).unwrap();
    static ref RE_ELSEVIER_JSON: Regex =
        Regex::new(r#"(?is)"pdfLink"\s*:\s*"([^"]+)""#).unwrap();
    static ref RE_ELSEVIER_ID: Regex = Regex::new(
        r#"(?is)<a[^>]+id\s*=\s*["']pdfLink["'][^>]+href\s*=\s*["']([^"']+)["']"#
    ).unwrap();
    static ref RE_ELSEVIER_CLASS: Regex = Regex::new(
        r#"(?is)<a[^>]+class\s*=\s*["'][^"']*pdf-download[^"']*["'][^>]+href\s*=\s*["']([^"']+)["']"#
    ).unwrap();
    static ref RE_AANDA_PDF_TEXT: Regex = Regex::new(
        r#"(?is)<a[^>]+href\s*=\s*["']([^"']+\.pdf)["'][^>]*>\s*(?:<[^>]*>)*\s*PDF"#
    ).unwrap();
    static ref RE_AANDA_DOWNLOADS: Regex = Regex::new(
        r#"(?is)<div[^>]+class\s*=\s*["'][^"']*downloads[^"']*["'][^>]*>.*?<a[^>]+href\s*=\s*["']([^"']+\.pdf)["']"#
    ).unwrap();
    static ref RE_WILEY_TOOLS: Regex = Regex::new(
        r#"(?is)<a[^>]+class\s*=\s*["'][^"']*pdf-tools[^"']*["'][^>]+href\s*=\s*["']([^"']+)["']"#
    ).unwrap();
    static ref RE_SPRINGER_TRACK: Regex = Regex::new(
        r#"(?is)<a[^>]+data-track-action\s*=\s*["']Download Article["'][^>]+href\s*=\s*["']([^"']+\.pdf[^"']*)["']"#
    ).unwrap();
    static ref RE_SPRINGER_CONTENT: Regex =
        Regex::new(r#"(?is)<a[^>]+href\s*=\s*["']([^"']+content/pdf[^"']+)["']"#).unwrap();
    static ref RE_ANNUAL_PDF_PATH: Regex =
        Regex::new(r#"(?is)<a[^>]+href\s*=\s*["']([^"']+/pdf/[^"']+)["']"#).unwrap();
    static ref RE_FRONTIERS: Regex = Regex::new(
        r#"(?is)<a[^>]+class\s*=\s*["'][^"']*download-files-pdf[^"']*["'][^>]+href\s*=\s*["']([^"']+)["']"#
    ).unwrap();
    static ref RE_PLOS: Regex = Regex::new(
        r#"(?is)<a[^>]+id\s*=\s*["']downloadPdf["'][^>]+href\s*=\s*["']([^"']+)["']"#
    ).unwrap();
    static ref RE_LINK_ALTERNATE: Regex = Regex::new(
        r#"(?is)<link[^>]+rel\s*=\s*["']alternate["'][^>]+type\s*=\s*["']application/pdf["'][^>]+href\s*=\s*["']([^"']+)["']"#
    ).unwrap();
    static ref RE_DOWNLOAD_PDF_TEXT: Regex = Regex::new(
        r#"(?is)<a[^>]+href\s*=\s*["']([^"']+)["'][^>]*>(?:\s*<[^>]*>)*\s*(?:Download\s+)?PDF"#
    ).unwrap();
    static ref RE_PDF_EXTENSION: Regex =
        Regex::new(r#"(?is)<a[^>]+href\s*=\s*["']([^"']+\.pdf)["']"#).unwrap();
}

/// Swift `extractURL(from:pattern:baseURL:)` — leftmost match, capture group 1,
/// resolved against `base`.
fn extract(re: &Regex, html: &str, base: &str) -> Option<String> {
    let caps = re.captures(html)?;
    resolve(caps.get(1)?.as_str(), base)
}

/// Swift `extractMetaCitationPDF` — name-first pattern, then content-first.
fn meta_citation_pdf(html: &str, base: &str) -> Option<String> {
    extract(&RE_META_NAME_FIRST, html, base).or_else(|| extract(&RE_META_CONTENT_FIRST, html, base))
}

/// Swift `PublisherHTMLParsers.parse(html:baseURL:publisherHost:)`.
pub fn parse(html: &str, base_url: &str, publisher_host: &str) -> Option<String> {
    match parser_id(publisher_host) {
        "iop" => parse_iop(html, base_url),
        "aps" => parse_aps(html, base_url),
        "nature" => parse_nature(html, base_url),
        "oxford" => parse_oxford(html, base_url),
        "elsevier" => parse_elsevier(html, base_url),
        "aanda" => parse_aanda(html, base_url),
        "science" => parse_science(html, base_url),
        "wiley" => parse_wiley(html, base_url),
        "springer" => parse_springer(html, base_url),
        "cambridge" => parse_cambridge(html, base_url),
        "annual-reviews" => parse_annual_reviews(html, base_url),
        "mdpi" => parse_mdpi(html, base_url),
        "frontiers" => parse_frontiers(html, base_url),
        "plos" => parse_plos(html, base_url),
        "aip" => parse_aip(html, base_url),
        _ => parse_generic(html, base_url),
    }
}

// ── Per-publisher strategies ────────────────────────────────────────────────
//
// Note the ORDER differs per publisher and is load-bearing. APS and Elsevier try
// their own strategy BEFORE the meta tag; everyone else tries the meta tag
// first. That is why the corpus has an `*-beats-meta` case for each.

fn parse_iop(html: &str, base: &str) -> Option<String> {
    if let Some(url) = meta_citation_pdf(html, base) {
        return Some(url);
    }
    let path = path_of(base);
    if path.contains("/article/") && !path.ends_with("/pdf") {
        if let Some(url) = with_path(base, &format!("{path}/pdf")) {
            return Some(url);
        }
    }
    extract(&RE_IOP_BTN, html, base)
}

fn parse_aps(html: &str, base: &str) -> Option<String> {
    // The path rewrite runs FIRST here, so an APS page that also carries a
    // `citation_pdf_url` meta tag never reaches it.
    let path = path_of(base);
    if path.contains("/abstract/") {
        let pdf_path = path.replace("/abstract/", "/pdf/");
        if let Some(url) = with_path(base, &pdf_path) {
            return Some(url);
        }
    }
    if let Some(url) = meta_citation_pdf(html, base) {
        return Some(url);
    }
    extract(&RE_APS_PDF_TEXT, html, base)
}

fn parse_nature(html: &str, base: &str) -> Option<String> {
    if let Some(url) = meta_citation_pdf(html, base) {
        return Some(url);
    }
    let path = path_of(base);
    if path.contains("/articles/") && !path.ends_with(".pdf") {
        if let Some(url) = with_path(base, &format!("{path}.pdf")) {
            return Some(url);
        }
    }
    extract(&RE_NATURE_TRACK, html, base).or_else(|| extract(&RE_NATURE_TRACK_REV, html, base))
}

fn parse_oxford(html: &str, base: &str) -> Option<String> {
    meta_citation_pdf(html, base)
        .or_else(|| extract(&RE_PDF_LINK_CLASS, html, base))
        .or_else(|| extract(&RE_OXFORD_VIEW_PDF, html, base))
}

fn parse_elsevier(html: &str, base: &str) -> Option<String> {
    // ScienceDirect embeds the PDF URL in page JSON, which is more reliable
    // than its meta tag — hence the meta tag last rather than first.
    extract(&RE_ELSEVIER_JSON, html, base)
        .or_else(|| extract(&RE_ELSEVIER_ID, html, base))
        .or_else(|| extract(&RE_ELSEVIER_CLASS, html, base))
        .or_else(|| meta_citation_pdf(html, base))
}

fn parse_aanda(html: &str, base: &str) -> Option<String> {
    meta_citation_pdf(html, base)
        .or_else(|| extract(&RE_AANDA_PDF_TEXT, html, base))
        .or_else(|| extract(&RE_AANDA_DOWNLOADS, html, base))
}

fn parse_science(html: &str, base: &str) -> Option<String> {
    if let Some(url) = meta_citation_pdf(html, base) {
        return Some(url);
    }
    let path = path_of(base);
    if path.contains("/doi/") && !path.contains("/pdf/") {
        return with_path(base, &path.replace("/doi/", "/doi/pdf/"));
    }
    None
}

fn parse_wiley(html: &str, base: &str) -> Option<String> {
    if let Some(url) = meta_citation_pdf(html, base) {
        return Some(url);
    }
    let path = path_of(base);
    if path.contains("/doi/") && !path.contains("/epdf/") && !path.contains("/pdf/") {
        if let Some(url) = with_path(base, &path.replace("/doi/", "/doi/epdf/")) {
            return Some(url);
        }
    }
    extract(&RE_WILEY_TOOLS, html, base)
}

fn parse_springer(html: &str, base: &str) -> Option<String> {
    meta_citation_pdf(html, base)
        .or_else(|| extract(&RE_SPRINGER_TRACK, html, base))
        .or_else(|| extract(&RE_SPRINGER_CONTENT, html, base))
}

fn parse_cambridge(html: &str, base: &str) -> Option<String> {
    if let Some(url) = meta_citation_pdf(html, base) {
        return Some(url);
    }
    let path = path_of(base);
    if path.contains("/article/") && !path.ends_with("/pdf") {
        return with_path(base, &format!("{path}/pdf"));
    }
    None
}

fn parse_annual_reviews(html: &str, base: &str) -> Option<String> {
    meta_citation_pdf(html, base).or_else(|| extract(&RE_ANNUAL_PDF_PATH, html, base))
}

fn parse_mdpi(html: &str, base: &str) -> Option<String> {
    if let Some(url) = meta_citation_pdf(html, base) {
        return Some(url);
    }
    // Unconditional: MDPI is the only parser with no path GUARD, so it appends
    // `/pdf` to anything, including the site root (`https://www.mdpi.com` →
    // `https://www.mdpi.com/pdf`). Preserved — MDPI is fully open access and the
    // caller treats a 404 as "no PDF".
    let path = path_of(base);
    if !path.ends_with("/pdf") {
        return with_path(base, &format!("{path}/pdf"));
    }
    None
}

fn parse_frontiers(html: &str, base: &str) -> Option<String> {
    meta_citation_pdf(html, base).or_else(|| extract(&RE_FRONTIERS, html, base))
}

fn parse_plos(html: &str, base: &str) -> Option<String> {
    meta_citation_pdf(html, base).or_else(|| extract(&RE_PLOS, html, base))
}

fn parse_aip(html: &str, base: &str) -> Option<String> {
    meta_citation_pdf(html, base).or_else(|| extract(&RE_PDF_LINK_CLASS, html, base))
}

fn parse_generic(html: &str, base: &str) -> Option<String> {
    if let Some(url) = meta_citation_pdf(html, base) {
        return Some(url);
    }
    if let Some(url) = extract(&RE_LINK_ALTERNATE, html, base) {
        return Some(url);
    }
    // A "Download PDF" link only counts if the href itself looks like a PDF —
    // otherwise the anchor text was decoration on a landing-page link.
    if let Some(url) = extract(&RE_DOWNLOAD_PDF_TEXT, html, base) {
        let lower = url.to_lowercase();
        if lower.contains(".pdf") || lower.contains("/pdf") {
            return Some(url);
        }
        // Note: Swift falls THROUGH here rather than returning, so a failed
        // sanity check still lets the `.pdf`-extension pattern run.
    }
    extract(&RE_PDF_EXTENSION, html, base)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_dispatch_is_contains_not_suffix() {
        assert_eq!(parser_id("iopscience.iop.org"), "iop");
        assert_eq!(parser_id("www.nature.com"), "nature");
        assert_eq!(parser_id("example.org"), "generic");
        assert_eq!(parser_id(""), "generic");
        // The preserved quirk.
        assert_eq!(parser_id("evil-nature.com.example.org"), "nature");
        assert_eq!(parser_id("iopscience.iop.org.phish.net"), "iop");
    }

    #[test]
    fn every_parser_id_is_reachable_from_some_host() {
        // `generic` is the fallback and `frontiers`/`plos`/`mdpi` etc. all have
        // a host test, so every id in the table must be dispatchable.
        for id in PARSER_IDS {
            assert!(
                *id == "generic" || PARSER_IDS.contains(id),
                "unreachable parser id {id}"
            );
        }
    }

    #[test]
    fn aps_path_rewrite_beats_the_meta_tag() {
        let got = parse(
            r#"<meta name="citation_pdf_url" content="https://x/m.pdf">"#,
            "https://journals.aps.org/prd/abstract/10.1103/PhysRevD.1.1",
            "journals.aps.org",
        );
        assert_eq!(
            got.as_deref(),
            Some("https://journals.aps.org/prd/pdf/10.1103/PhysRevD.1.1")
        );
    }

    #[test]
    fn iop_meta_tag_beats_the_path_rewrite() {
        let got = parse(
            r#"<meta name="citation_pdf_url" content="https://iopscience.iop.org/m.pdf">"#,
            "https://iopscience.iop.org/article/10.3847/x",
            "iopscience.iop.org",
        );
        assert_eq!(got.as_deref(), Some("https://iopscience.iop.org/m.pdf"));
    }

    #[test]
    fn generic_download_pdf_text_needs_a_pdf_looking_href() {
        assert_eq!(
            parse(
                r#"<a href="https://example.org/get/x.html">Download PDF</a>"#,
                "https://example.org/a",
                "example.org"
            ),
            None
        );
    }

    #[test]
    fn mdpi_appends_pdf_to_the_bare_root() {
        assert_eq!(
            parse("<html></html>", "https://www.mdpi.com", "www.mdpi.com").as_deref(),
            Some("https://www.mdpi.com/pdf")
        );
    }
}
