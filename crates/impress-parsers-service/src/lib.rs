//! `ParsersService` — the agent-facing surface of imbib's archive and publisher
//! parsers.
//!
//! Every `#[impress_method]` here becomes three things at once: an MCP tool, a
//! subcommand of the `impress` CLI, and a tool in impel's agent loop. That is
//! the point of the Stage 7 item 9 port: in Swift these parsers were reachable
//! only from imbib's import sheet and its PDF auto-download path, so an agent
//! asking "what does this mbox contain?" or "where is the PDF for this DOI?" had
//! no way to find out.
//!
//! The methods are pure — no store, no app, and **no network**. The publisher
//! methods take HTML you already have; fetching the landing page stays in Swift
//! (`URLSession` carries the proxy configuration, App Transport Security, the
//! sandbox's network entitlement and the cookie/redirect policy). Because
//! nothing here can block or fail on a closed app, this namespace needs no entry
//! in `impress-mcp`'s reachability gate.

use serde::{Deserialize, Serialize};

use impress_service_core::async_trait;
// `impress_method` is referenced as a path-only attribute on trait methods;
// `#[impress_service]` strips the attribute, so the symbol is structurally
// "unused" — keep it imported because Rust still requires the path to resolve
// when the macro expands.
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

use imbib_core::{mbox, publishers};

// ── Reports ─────────────────────────────────────────────────────────────────

/// One attachment on an mbox message. `data` is reported as a byte COUNT plus a
/// base64 preview cap rather than inline bytes: an mbox of a library export
/// carries whole PDFs, and an agent that asked for the message list should not
/// receive megabytes of base64 it did not ask for.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MboxAttachmentReport {
    pub filename: String,
    pub content_type: String,
    pub byte_count: u64,
    /// `X-Imbib-*` headers carried by the attachment part.
    pub custom_headers: serde_json::Map<String, serde_json::Value>,
}

/// One message from an mbox archive.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MboxMessageReport {
    pub from: String,
    pub subject: String,
    /// `null` when the message carried no `Message-ID`. The Swift original
    /// substituted a fresh UUID here, which made a message's identity depend on
    /// when it was imported.
    pub message_id: Option<String>,
    /// RFC 3339. `null` when neither a parseable `Date:` header nor a `From `
    /// envelope date was present.
    pub date: Option<String>,
    /// `X-Imbib-*` headers only — the metadata imbib's own exporter round-trips.
    pub custom_headers: serde_json::Map<String, serde_json::Value>,
    pub body: String,
    pub attachments: Vec<MboxAttachmentReport>,
}

/// The result of parsing a whole archive.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MboxParseReport {
    pub message_count: u64,
    pub messages: Vec<MboxMessageReport>,
    /// Set when `max_messages` truncated the list.
    pub truncated: bool,
}

/// A publisher resolution rule.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublisherRuleReport {
    pub id: String,
    pub name: String,
    pub doi_prefixes: Vec<String>,
    /// `{doi}` / `{articleID}` / `{arxivID}` template, when the publisher has a
    /// predictable PDF URL. `null` means the landing page must be scraped.
    pub pdf_url_pattern: Option<String>,
    pub requires_proxy: bool,
    /// `low` | `medium` | `high`.
    pub captcha_risk: String,
    /// True when OpenAlex's open-access URL is a better bet than the publisher.
    pub prefer_open_alex: bool,
    pub notes: Option<String>,
    /// Which landing-page extraction strategy applies.
    pub html_parser_id: Option<String>,
    pub supports_landing_page_scraping: bool,
}

impl From<&publishers::PublisherRule> for PublisherRuleReport {
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

/// Everything known about resolving one DOI to a PDF.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PdfResolutionReport {
    pub doi: String,
    /// `null` when no rule's DOI prefix matches.
    pub rule: Option<PublisherRuleReport>,
    /// The URL the rule's pattern produces, when it has one.
    pub constructed_pdf_url: Option<String>,
    /// What the agent should do next, in words.
    pub recommendation: String,
}

/// The result of scraping landing-page markup.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LandingPageReport {
    /// Which strategy ran, e.g. `iop`, `elsevier`, `generic`.
    pub parser_id: String,
    pub pdf_url: Option<String>,
}

fn to_map(
    pairs: impl IntoIterator<Item = (String, String)>,
) -> serde_json::Map<String, serde_json::Value> {
    pairs
        .into_iter()
        .map(|(k, v)| (k, serde_json::Value::String(v)))
        .collect()
}

// ── Service ─────────────────────────────────────────────────────────────────

#[impress_service]
pub trait ParsersService: Send + Sync + 'static {
    /// Parse an mbox archive (imbib's export format, or any RFC 4155 mbox) into
    /// messages: sender, subject, date, `X-Imbib-*` metadata headers, decoded
    /// body and attachment manifest. Handles RFC 2047 encoded-word subjects,
    /// quoted-printable and base64 bodies, `multipart/*` boundaries and mboxrd
    /// `>From ` unescaping. Attachment BYTES are not returned — only names,
    /// types and sizes — because a library export carries whole PDFs.
    ///
    /// `max_messages` caps the list; pass 0 for no cap.
    #[impress_method]
    async fn parse_mbox(&self, content: String, max_messages: i64) -> MboxParseReport;

    /// Decode RFC 2047 encoded-words (`=?UTF-8?B?…?=` / `=?…?Q?…?=`) in a mail
    /// header value, honouring the declared charset. Useful for reading a
    /// `Subject:` or a `filename=` parameter as a human would see it.
    #[impress_method]
    async fn decode_mime_header(&self, value: String) -> String;

    /// Decode a quoted-printable body. `charset` is the `charset=` parameter
    /// from the part's `Content-Type` — pass `UTF-8` when absent. Invalid
    /// sequences fall back to Latin-1 rather than yielding an empty string.
    #[impress_method]
    async fn decode_quoted_printable(&self, encoded: String, charset: String) -> String;

    /// Which publisher owns a DOI, whether its PDF URL is predictable, and what
    /// to try. This is the table imbib's PDF auto-download consults, so the
    /// answer is what the app would do.
    #[impress_method]
    async fn resolve_publisher_pdf(&self, doi: String) -> PdfResolutionReport;

    /// The whole publisher rule table — 16 rules covering the astronomy and
    /// physics literature. Read this to understand why a given DOI resolves the
    /// way it does.
    #[impress_method]
    async fn list_publisher_rules(&self) -> Vec<PublisherRuleReport>;

    /// Extract the PDF link from a publisher landing page's HTML, using that
    /// publisher's extraction strategy. **Does not fetch** — pass markup you
    /// already have. `publisher_host` selects the strategy; `base_url` resolves
    /// relative links.
    #[impress_method]
    async fn extract_landing_page_pdf(
        &self,
        html: String,
        base_url: String,
        publisher_host: String,
    ) -> LandingPageReport;
}

/// The one implementation. Stateless — every method is a pure function.
#[derive(Debug, Default, Clone, Copy)]
pub struct DefaultParsersService;

#[async_trait::async_trait]
impl ParsersService for DefaultParsersService {
    async fn parse_mbox(&self, content: String, max_messages: i64) -> MboxParseReport {
        let all = mbox::parse_content(&content);
        let total = all.len();
        let cap = if max_messages <= 0 {
            total
        } else {
            (max_messages as usize).min(total)
        };

        let messages = all
            .into_iter()
            .take(cap)
            .map(|m| MboxMessageReport {
                from: m.from,
                subject: m.subject,
                message_id: m.message_id,
                date: m.date.map(|d| d.to_rfc3339()),
                custom_headers: to_map(m.headers),
                body: m.body,
                attachments: m
                    .attachments
                    .into_iter()
                    .map(|a| MboxAttachmentReport {
                        filename: a.filename,
                        content_type: a.content_type,
                        byte_count: a.data.len() as u64,
                        custom_headers: to_map(a.custom_headers),
                    })
                    .collect(),
            })
            .collect();

        MboxParseReport {
            message_count: total as u64,
            messages,
            truncated: cap < total,
        }
    }

    async fn decode_mime_header(&self, value: String) -> String {
        mbox::decode_header_value(&value)
    }

    async fn decode_quoted_printable(&self, encoded: String, charset: String) -> String {
        let charset = if charset.trim().is_empty() {
            "UTF-8".to_string()
        } else {
            charset
        };
        mbox::quoted_printable_decode(&encoded, &charset)
    }

    async fn resolve_publisher_pdf(&self, doi: String) -> PdfResolutionReport {
        let rule = publishers::rule_for_doi(&doi);
        let constructed = rule.and_then(|r| r.construct_pdf_url(&doi));
        let recommendation = match (rule, constructed.as_deref()) {
            (None, _) => "No rule matches this DOI prefix. Try the generic \
                          landing-page strategy, or an open-access index."
                .to_string(),
            (Some(r), Some(_)) if r.prefer_open_alex => format!(
                "{} has a URL pattern, but prefers OpenAlex for open-access \
                 copies (captcha risk: {}).",
                r.name,
                r.captcha_risk.as_str()
            ),
            (Some(r), Some(_)) => format!(
                "Use the constructed URL. {}{}",
                if r.requires_proxy {
                    "Institutional access is usually required. "
                } else {
                    ""
                },
                if r.supports_landing_page_scraping {
                    "Fall back to scraping the landing page if it 404s."
                } else {
                    "This publisher does not support landing-page scraping."
                }
            ),
            (Some(r), None) if r.supports_landing_page_scraping => format!(
                "{} has no predictable PDF URL. Fetch the landing page and call \
                 extract-landing-page-pdf with parser {}.",
                r.name,
                r.html_parser_id.unwrap_or("generic")
            ),
            (Some(r), None) => format!(
                "{} has neither a URL pattern nor landing-page support. Use an \
                 open-access index.",
                r.name
            ),
        };

        PdfResolutionReport {
            doi,
            rule: rule.map(Into::into),
            constructed_pdf_url: constructed,
            recommendation,
        }
    }

    async fn list_publisher_rules(&self) -> Vec<PublisherRuleReport> {
        publishers::DEFAULT_RULES.iter().map(Into::into).collect()
    }

    async fn extract_landing_page_pdf(
        &self,
        html: String,
        base_url: String,
        publisher_host: String,
    ) -> LandingPageReport {
        LandingPageReport {
            parser_id: publishers::parser_id(&publisher_host).to_string(),
            pdf_url: publishers::parse(&html, &base_url, &publisher_host),
        }
    }
}

fn parsers_instance() -> DefaultParsersService {
    DefaultParsersService
}

impress_service_impl! {
    service = ParsersService,
    impl = DefaultParsersService,
    instance = || parsers_instance(),
    methods = [
        parse_mbox(content: String, max_messages: i64) -> MboxParseReport,
        decode_mime_header(value: String) -> String,
        decode_quoted_printable(encoded: String, charset: String) -> String,
        resolve_publisher_pdf(doi: String) -> PdfResolutionReport,
        list_publisher_rules() -> Vec<PublisherRuleReport>,
        extract_landing_page_pdf(
            html: String,
            base_url: String,
            publisher_host: String
        ) -> LandingPageReport,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;

    fn service() -> DefaultParsersService {
        DefaultParsersService
    }

    #[tokio::test]
    async fn parse_mbox_reports_messages_and_metadata() {
        let content = concat!(
            "From imbib@localhost Thu Jan 01 00:00:00 2024\n",
            "From: imbib <imbib@localhost>\n",
            "Subject: =?UTF-8?B?w5xiZXIgUsOpc3Vtw6k=?=\n",
            "Date: Thu, 01 Jan 2024 00:00:00 +0000\n",
            "Message-ID: <hdr@imbib.local>\n",
            "X-Imbib-Export-Version: 2\n\n",
            "the abstract\n"
        );
        let report = service().parse_mbox(content.to_string(), 0).await;
        assert_eq!(report.message_count, 1);
        assert!(!report.truncated);
        assert_eq!(report.messages[0].subject, "Über Résumé");
        assert_eq!(report.messages[0].message_id.as_deref(), Some("hdr"));
        assert!(report.messages[0].date.is_some());
        assert_eq!(
            report.messages[0].custom_headers["X-Imbib-Export-Version"],
            serde_json::Value::String("2".into())
        );
    }

    #[tokio::test]
    async fn max_messages_truncates_and_says_so() {
        let content = concat!(
            "From a@x Thu Jan 01 00:00:00 2024\nSubject: A\n\na\n",
            "From b@x Thu Jan 01 00:00:00 2024\nSubject: B\n\nb\n"
        );
        let report = service().parse_mbox(content.to_string(), 1).await;
        assert_eq!(report.message_count, 2);
        assert_eq!(report.messages.len(), 1);
        assert!(report.truncated);
    }

    #[tokio::test]
    async fn quoted_printable_defaults_to_utf8_on_a_blank_charset() {
        assert_eq!(
            service()
                .decode_quoted_printable("M=C3=BCller".into(), String::new())
                .await,
            "Müller"
        );
    }

    #[tokio::test]
    async fn resolve_publisher_pdf_explains_itself() {
        let r = service()
            .resolve_publisher_pdf("10.3847/1538-4357/abc".into())
            .await;
        assert_eq!(r.rule.as_ref().map(|x| x.id.as_str()), Some("iop-aas"));
        assert_eq!(
            r.constructed_pdf_url.as_deref(),
            Some("https://iopscience.iop.org/article/10.3847/1538-4357/abc/pdf")
        );
        assert!(!r.recommendation.is_empty());

        let unknown = service().resolve_publisher_pdf("10.9999/nope".into()).await;
        assert!(unknown.rule.is_none());
        assert!(unknown.recommendation.contains("No rule"));
    }

    #[tokio::test]
    async fn rule_table_is_complete() {
        let rules = service().list_publisher_rules().await;
        assert_eq!(rules.len(), 16);
        assert!(rules.iter().any(|r| r.id == "cambridge"));
    }

    #[tokio::test]
    async fn landing_page_extraction_names_its_strategy() {
        let r = service()
            .extract_landing_page_pdf(
                r#"<meta name="citation_pdf_url" content="https://x.org/a.pdf">"#.into(),
                "https://iopscience.iop.org/article/10.3847/x".into(),
                "iopscience.iop.org".into(),
            )
            .await;
        assert_eq!(r.parser_id, "iop");
        assert_eq!(r.pdf_url.as_deref(), Some("https://x.org/a.pdf"));
    }
}
