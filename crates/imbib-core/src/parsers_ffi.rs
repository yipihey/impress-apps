//! UniFFI surface for the Stage 7 item 9 parser batch.
//!
//! `imbib-core` hosts these bindings for the same reason it hosts
//! [`crate::smart_search_ffi`]: PMC already links `ImbibCore.xcframework`, so the
//! surface reaches every app embedding PMC with **no new xcframework**, no new
//! checksum and no change to any app's build settings.
//!
//! What is here is only record shuffling. The logic lives in [`crate::mbox`] and
//! [`crate::publishers`], which know nothing about UniFFI and are tested
//! directly against the golden corpus.

use crate::{mbox, publishers};

// ── mbox / MIME ─────────────────────────────────────────────────────────────

/// One decoded MIME part. Flattened `mbox::MimePart`; `headers` is a sorted
/// key/value list because UniFFI has no ordered-map record.
#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiMimePart {
    pub content_type: String,
    pub transfer_encoding: Option<String>,
    pub filename: Option<String>,
    pub header_names: Vec<String>,
    pub header_values: Vec<String>,
    pub content: Vec<u8>,
}

impl From<mbox::MimePart> for FfiMimePart {
    fn from(p: mbox::MimePart) -> Self {
        let (header_names, header_values) = p.headers.into_iter().unzip();
        Self {
            content_type: p.content_type,
            transfer_encoding: p.transfer_encoding,
            filename: p.filename,
            header_names,
            header_values,
            content: p.content,
        }
    }
}

/// An attachment on an mbox message.
#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiMboxAttachment {
    pub filename: String,
    pub content_type: String,
    pub data: Vec<u8>,
    pub custom_header_names: Vec<String>,
    pub custom_header_values: Vec<String>,
}

/// A parsed mbox message.
///
/// `message_id` and `date_unix_seconds` are `Option`: Swift's parser substituted
/// a fresh UUID and `Date()` respectively, which made both untestable and made a
/// message's identity depend on when it was imported. The absence is now
/// reported and the Swift shim supplies its own fallback, unchanged, so callers
/// see the same values they always did.
#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiMboxMessage {
    pub from: String,
    pub subject: String,
    pub message_id: Option<String>,
    pub date_unix_seconds: Option<i64>,
    pub header_names: Vec<String>,
    pub header_values: Vec<String>,
    pub body: String,
    pub attachments: Vec<FfiMboxAttachment>,
}

impl From<mbox::MboxMessage> for FfiMboxMessage {
    fn from(m: mbox::MboxMessage) -> Self {
        let (header_names, header_values) = m.headers.into_iter().unzip();
        Self {
            from: m.from,
            subject: m.subject,
            message_id: m.message_id,
            date_unix_seconds: m.date.map(|d| d.timestamp()),
            header_names,
            header_values,
            body: m.body,
            attachments: m
                .attachments
                .into_iter()
                .map(|a| {
                    let (custom_header_names, custom_header_values) =
                        a.custom_headers.into_iter().unzip();
                    FfiMboxAttachment {
                        filename: a.filename,
                        content_type: a.content_type,
                        data: a.data,
                        custom_header_names,
                        custom_header_values,
                    }
                })
                .collect(),
        }
    }
}

/// Parse a whole mbox document into messages.
#[uniffi::export]
pub fn mbox_parse(content: String) -> Vec<FfiMboxMessage> {
    mbox::parse_content(&content)
        .into_iter()
        .map(Into::into)
        .collect()
}

/// Split a multipart body on its boundary (`multipart/mixed`, `alternative`, …).
#[uniffi::export]
pub fn mime_decode_multipart(content: String, boundary: String) -> Vec<FfiMimePart> {
    mbox::decode_multipart(&content, &boundary)
        .into_iter()
        .map(Into::into)
        .collect()
}

/// Charset-aware quoted-printable decode. Pass the `charset=` parameter from the
/// part's `Content-Type`, or `"UTF-8"` when absent.
#[uniffi::export]
pub fn mime_quoted_printable_decode(encoded: String, charset: String) -> String {
    mbox::quoted_printable_decode(&encoded, &charset)
}

/// Base64 decode with Foundation's semantics: whitespace stripped, padding
/// required, `nil` on any error.
#[uniffi::export]
pub fn mime_base64_decode(encoded: String) -> Option<Vec<u8>> {
    mbox::base64_decode(&encoded)
}

/// Decode RFC 2047 encoded-words in a header value.
#[uniffi::export]
pub fn mime_decode_header_value(value: String) -> String {
    mbox::decode_header_value(&value)
}

/// Extract the `boundary=` parameter from a `Content-Type`.
#[uniffi::export]
pub fn mime_extract_boundary(content_type: String) -> Option<String> {
    mbox::extract_boundary(&content_type)
}

/// mboxrd unescaping: drop one `>` from `>+From ` lines.
#[uniffi::export]
pub fn mime_unescape_from_lines(text: String) -> String {
    mbox::unescape_from_lines(&text)
}

// ── Publishers ──────────────────────────────────────────────────────────────

/// One publisher resolution rule.
#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiPublisherRule {
    pub id: String,
    pub name: String,
    pub doi_prefixes: Vec<String>,
    pub pdf_url_pattern: Option<String>,
    pub requires_proxy: bool,
    /// `low` | `medium` | `high`.
    pub captcha_risk: String,
    pub prefer_open_alex: bool,
    pub notes: Option<String>,
    pub html_parser_id: Option<String>,
    pub supports_landing_page_scraping: bool,
}

impl From<&publishers::PublisherRule> for FfiPublisherRule {
    fn from(r: &publishers::PublisherRule) -> Self {
        Self {
            id: r.id.to_string(),
            name: r.name.to_string(),
            doi_prefixes: r.doi_prefixes.iter().map(|p| p.to_string()).collect(),
            pdf_url_pattern: r.pdf_url_pattern.map(str::to_string),
            requires_proxy: r.requires_proxy,
            captcha_risk: r.captcha_risk.as_str().to_string(),
            prefer_open_alex: r.prefer_open_alex,
            notes: r.notes.map(str::to_string),
            html_parser_id: r.html_parser_id.map(str::to_string),
            supports_landing_page_scraping: r.supports_landing_page_scraping,
        }
    }
}

/// The whole default rule table, in declaration order.
#[uniffi::export]
pub fn publisher_default_rules() -> Vec<FfiPublisherRule> {
    publishers::DEFAULT_RULES.iter().map(Into::into).collect()
}

/// The rule governing `doi` — longest matching DOI prefix wins.
#[uniffi::export]
pub fn publisher_rule_for_doi(doi: String) -> Option<FfiPublisherRule> {
    publishers::rule_for_doi(&doi).map(Into::into)
}

/// The rule with this id.
#[uniffi::export]
pub fn publisher_rule_for_id(id: String) -> Option<FfiPublisherRule> {
    publishers::rule_for_id(&id).map(Into::into)
}

/// Build a PDF URL from a DOI using the rule's pattern.
#[uniffi::export]
pub fn publisher_construct_pdf_url(rule_id: String, doi: String) -> Option<String> {
    publishers::rule_for_id(&rule_id)?.construct_pdf_url(&doi)
}

/// Which extraction strategy a hostname selects.
#[uniffi::export]
pub fn publisher_parser_id(publisher_host: String) -> String {
    publishers::parser_id(&publisher_host).to_string()
}

/// Extract a PDF URL from landing-page HTML. **The fetch stays Swift** — this is
/// the half after the bytes arrive.
#[uniffi::export]
pub fn publisher_extract_pdf_url(
    html: String,
    base_url: String,
    publisher_host: String,
) -> Option<String> {
    publishers::parse(&html, &base_url, &publisher_host)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mbox_round_trips_through_the_ffi_shape() {
        let msgs = mbox_parse(
            concat!(
                "From s@example.com Thu Jan 01 00:00:00 2024\n",
                "Subject: T\nMessage-ID: <x@y>\n\nbody\n"
            )
            .to_string(),
        );
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].subject, "T");
        assert_eq!(msgs[0].message_id.as_deref(), Some("x"));
    }

    #[test]
    fn publisher_table_survives_the_ffi_shape() {
        let rules = publisher_default_rules();
        assert_eq!(rules.len(), publishers::DEFAULT_RULES.len());
        assert!(rules.iter().any(|r| r.id == "iop-aas"));
        assert_eq!(
            publisher_rule_for_doi("10.3847/1538-4357/x".into())
                .map(|r| r.id)
                .as_deref(),
            Some("iop-aas")
        );
    }

    #[test]
    fn header_and_value_lists_stay_aligned() {
        let msgs = mbox_parse(
            concat!(
                "From s@example.com Thu Jan 01 00:00:00 2024\n",
                "X-Imbib-CiteKey: k1\nX-Imbib-Year: 2024\n\nb\n"
            )
            .to_string(),
        );
        assert_eq!(msgs[0].header_names.len(), msgs[0].header_values.len());
        assert_eq!(
            msgs[0].header_names,
            vec!["X-Imbib-CiteKey", "X-Imbib-Year"]
        );
        assert_eq!(msgs[0].header_values, vec!["k1", "2024"]);
    }
}

// ── Abstracts (item 9.2) ────────────────────────────────────────────────────

/// One segment of a parsed abstract. `kind` is `text` | `inlineMath` |
/// `displayMath`; a flat record rather than an enum because Swift's
/// `AbstractSegment` is already the shape the renderer wants.
#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiAbstractSegment {
    pub kind: String,
    pub value: String,
}

/// Split an abstract into prose and math segments, after arXiv de-escaping,
/// MathML→LaTeX conversion, HTML entity decoding and `<sub>`/`<sup>` rewriting.
#[uniffi::export]
pub fn abstract_parse(text: String) -> Vec<FfiAbstractSegment> {
    crate::text::parse_abstract(&text)
        .into_iter()
        .map(|segment| FfiAbstractSegment {
            kind: segment.kind().to_string(),
            value: segment.value().to_string(),
        })
        .collect()
}

/// Cheap sniff for math delimiters or MathML in an abstract.
#[uniffi::export]
pub fn abstract_contains_math(text: String) -> bool {
    crate::text::abstract_contains_math(&text)
}

/// Convert `<inline-formula>` / `<mml:math>` markup to LaTeX, targeting a LaTeX
/// renderer (MathJax/SwiftMath). Distinct from `parse_mathml`, which targets
/// Unicode super/subscripts for the search index.
#[uniffi::export]
pub fn abstract_mathml_to_latex(text: String) -> String {
    crate::text::mathml_to_latex(&text)
}

// ── PDF / artifact pure logic (item 9.4) ────────────────────────────────────

/// The fields `bestTitle` / `bestAuthors` / `bestYear` resolve from.
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct FfiPdfExtractedFields {
    pub title: Option<String>,
    pub author: Option<String>,
    pub heuristic_title: Option<String>,
    pub heuristic_authors: Vec<String>,
    pub heuristic_year: Option<i32>,
    pub first_page_text: Option<String>,
    pub extracted_doi: Option<String>,
    pub extracted_arxiv_id: Option<String>,
    pub extracted_bibcode: Option<String>,
}

/// What the pure logic concludes from those fields.
#[derive(uniffi::Record, Clone, Debug)]
pub struct FfiPdfBestFields {
    pub best_title: Option<String>,
    pub best_authors: Vec<String>,
    pub best_year: Option<i32>,
    pub has_identifier: bool,
}

impl From<FfiPdfExtractedFields> for crate::pdf::PdfExtractedFields {
    fn from(f: FfiPdfExtractedFields) -> Self {
        Self {
            title: f.title,
            author: f.author,
            heuristic_title: f.heuristic_title,
            heuristic_authors: f.heuristic_authors,
            heuristic_year: f.heuristic_year,
            first_page_text: f.first_page_text,
            extracted_doi: f.extracted_doi,
            extracted_arxiv_id: f.extracted_arxiv_id,
            extracted_bibcode: f.extracted_bibcode,
        }
    }
}

/// Whether a PDF `titleAttribute` value is worth trusting, or is a PII code, a
/// bare DOI, a `Microsoft Word - …` artefact, `Untitled`, or too short.
#[uniffi::export]
pub fn pdf_is_plausible_title(candidate: String) -> bool {
    crate::pdf::is_plausible_title(&candidate)
}

/// Resolve the best title/authors/year from everything the extractor found.
#[uniffi::export]
pub fn pdf_best_fields(fields: FfiPdfExtractedFields) -> FfiPdfBestFields {
    let f: crate::pdf::PdfExtractedFields = fields.into();
    FfiPdfBestFields {
        best_title: f.best_title(),
        best_authors: f.best_authors(),
        best_year: f.best_year(),
        has_identifier: f.has_identifier(),
    }
}

/// `<meta property="…" content="…">` — both attribute orders, first match wins.
#[uniffi::export]
pub fn html_meta_property(html: String, property: String) -> Option<String> {
    crate::pdf::extract_meta_content_property(&html, &property)
}

/// `<meta name="…" content="…">`. Note there is no reversed-order pattern here;
/// Swift had none either.
#[uniffi::export]
pub fn html_meta_name(html: String, name: String) -> Option<String> {
    crate::pdf::extract_meta_content_name(&html, &name)
}

/// Classify an artifact from its filename alone — the filename hints and the
/// extension table. Returns `None` when only `UTType` can decide, which is why
/// the Swift caller keeps its `conforms(to:)` tail.
#[uniffi::export]
pub fn artifact_type_from_filename(path: String) -> Option<String> {
    crate::pdf::infer_artifact_type_from_filename(&path).map(|t| t.as_str().to_string())
}
