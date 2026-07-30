//! Golden-corpus parity for the Stage 7 item 9 parser batch.
//!
//! `test_fixtures/golden/{mime_*,mbox_*,publisher_*,abstract_*,pdf_*,artifact_*}.json`
//! was captured from the Swift implementations of `MIMEDecoder`, `MboxParser`,
//! `PublisherHTMLParsers`, `PublisherRule`, `AbstractParser` and the pure-logic
//! halves of `PDFMetadataExtractor` / `ArtifactMetadataExtractor` **before**
//! their bodies became FFI shims. These tests assert the Rust ports reproduce
//! that behaviour.
//!
//! Deliberate divergences are listed per-section with the reason. An unlisted
//! mismatch fails the build. There is no regeneration path.

mod common;

use common::fixtures::load_fixture;
use serde_json::Value;

// ── Plumbing ────────────────────────────────────────────────────────────────

fn golden(name: &str) -> Vec<Value> {
    let raw = load_fixture(&format!("golden/{name}"));
    let parsed: Value =
        serde_json::from_str(&raw).unwrap_or_else(|e| panic!("bad golden {name}: {e}"));
    parsed
        .as_array()
        .unwrap_or_else(|| panic!("{name} is not an array"))
        .clone()
}

#[derive(Default)]
struct Report {
    lines: Vec<String>,
    checked: usize,
}

impl Report {
    fn push(&mut self, scope: impl AsRef<str>, detail: String) {
        self.lines.push(format!("[{}] {detail}", scope.as_ref()));
    }

    fn eq<T: PartialEq + std::fmt::Debug>(&mut self, scope: impl AsRef<str>, want: T, got: T) {
        self.checked += 1;
        if want != got {
            self.push(scope, format!("want {want:?}, got {got:?}"));
        }
    }

    fn assert_empty(self, what: &str, min_checks: usize) {
        assert!(
            self.checked >= min_checks,
            "{what}: only {} assertions ran, expected at least {min_checks} — \
             the corpus shrank or a loop stopped early",
            self.checked
        );
        if !self.lines.is_empty() {
            let shown: Vec<_> = self.lines.iter().take(40).cloned().collect();
            panic!(
                "{} golden mismatches for {what} (of {} checks):\n{}",
                self.lines.len(),
                self.checked,
                shown.join("\n")
            );
        }
    }
}

fn s(v: &Value) -> &str {
    v.as_str().unwrap_or_default()
}

fn opt(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string)
}

// ── Item 9.1: MIME primitives ───────────────────────────────────────────────

/// Swift decoded every `=XX` octet to one Latin-1 scalar, so a UTF-8 sequence
/// became mojibake. The port keeps the *tokenizer* byte-exact — proven here via
/// `quoted_printable_decode_swift`, which is the Latin-1 projection of the very
/// same token stream production uses — and fixes only the rendering. See
/// `docs/parser-batch-swift-rust-split.md` §1.
#[test]
fn quoted_printable_tokenizer_matches_swift_exactly() {
    use imbib_core::mbox::quoted_printable_decode_swift;

    let mut report = Report::default();
    for case in golden("mime_quoted_printable_decode.json") {
        let input = s(&case["input"]);
        report.eq(
            format!("{input:?}"),
            s(&case["output"]).to_string(),
            quoted_printable_decode_swift(input),
        );
    }
    report.assert_empty("quoted-printable (Swift projection)", 28);
}

/// The fix, stated as a test rather than a comment: every corpus case whose
/// Swift output was mojibake now round-trips.
#[test]
fn quoted_printable_utf8_round_trips_after_the_fix() {
    use imbib_core::mbox::quoted_printable_decode;

    // Each pair is (quoted-printable source, the text that produced it).
    for (encoded, want) in [
        ("=E2=80=94", "—"),
        ("M=C3=BCller", "Müller"),
        ("caf=C3=A9", "café"),
        ("=E2=80=9Cquoted=E2=80=9D", "“quoted”"),
        ("mixed =C3=BC and =3D and plain", "mixed ü and = and plain"),
    ] {
        assert_eq!(
            quoted_printable_decode(encoded, "UTF-8"),
            want,
            "utf-8 quoted-printable still corrupt for {encoded:?}"
        );
    }
}

#[test]
fn base64_decode_matches_swift() {
    use base64::Engine as _;
    use imbib_core::mbox::base64_decode;

    let mut report = Report::default();
    for case in golden("mime_base64_decode.json") {
        let input = s(&case["input"]);
        let want = opt(&case["output"]);
        let got = base64_decode(input).map(|b| base64::engine::general_purpose::STANDARD.encode(b));
        report.eq(format!("{input:?}"), want, got);
    }
    report.assert_empty("base64 decode", 14);
}

#[test]
fn unescape_from_lines_matches_swift() {
    use imbib_core::mbox::unescape_from_lines;

    let mut report = Report::default();
    for case in golden("mime_unescape_from_lines.json") {
        let input = s(&case["input"]);
        report.eq(
            format!("{input:?}"),
            s(&case["output"]).to_string(),
            unescape_from_lines(input),
        );
    }
    report.assert_empty("mboxrd unescaping", 18);
}

#[test]
fn extract_boundary_matches_swift() {
    use imbib_core::mbox::extract_boundary;

    let mut report = Report::default();
    for case in golden("mime_extract_boundary.json") {
        let input = s(&case["input"]);
        report.eq(
            format!("{input:?}"),
            opt(&case["output"]),
            extract_boundary(input),
        );
    }
    report.assert_empty("boundary extraction", 15);
}

/// The only divergences are the `Q`-encoded words whose declared charset Swift
/// ignored. `B` words, unknown charsets, malformed words and the non-`B`/`Q`
/// letter all match exactly.
const HEADER_DECODE_DIVERGENCES: &[(&str, &str)] = &[
    (
        "=?UTF-8?Q?M=C3=BCller?=",
        "Swift routed `Q` through its Latin-1 quoted-printable decoder and \
         ignored the declared charset, yielding `MÃ¼ller`. RFC 2047 §4.2 says \
         the octets are in the named charset. `B` words were already correct, \
         which is why the bug survived: imbib's own exporter emits `B`.",
    ),
    (
        "=?ISO-8859-2?Q?a=B1b?=",
        "The same `Q` bug in its subtler form: 0xB1 is `±` in Latin-1 and `ą` \
         (a-ogonek) in ISO-8859-2, so Swift silently transliterated Polish and \
         Czech names into punctuation. No character is lost or gained, which is \
         why nothing looked broken.",
    ),
];

#[test]
fn decode_header_value_matches_swift_except_q_charset() {
    use imbib_core::mbox::{decode_header_value, decode_header_value_swift};

    let mut report = Report::default();
    let mut divergences_hit = 0;
    for case in golden("mime_decode_header_value.json") {
        let input = s(&case["input"]);
        let want = s(&case["output"]).to_string();

        // The Swift projection must match everywhere, with no exemptions: it is
        // the proof that the port reproduces the original's decisions.
        report.eq(
            format!("swift {input:?}"),
            want.clone(),
            decode_header_value_swift(input),
        );

        let got = decode_header_value(input);
        if let Some((_, _reason)) = HEADER_DECODE_DIVERGENCES.iter().find(|(i, _)| *i == input) {
            divergences_hit += 1;
            assert_ne!(
                got, want,
                "{input:?} is listed as a divergence but now agrees with Swift — \
                 remove the entry"
            );
            continue;
        }
        report.eq(format!("fixed {input:?}"), want, got);
    }
    assert_eq!(
        divergences_hit,
        HEADER_DECODE_DIVERGENCES.len(),
        "a listed header-decode divergence is no longer in the corpus"
    );
    report.assert_empty("RFC 2047 header decoding", 40);
}

/// Parts whose decoded CONTENT legitimately changed. Everything structural
/// (part count, content type, transfer encoding, filename, headers) must still
/// match for these.
const MULTIPART_CONTENT_DIVERGENCES: &[(&str, &str)] = &[(
    "quoted-printable-part",
    "The part declares `charset=utf-8` and `Content-Transfer-Encoding: \
     quoted-printable`; Swift decoded the octets as Latin-1 and stored \
     `MÃ¼ller wrote: a note`. Fixed — this is the attachment-side face of the \
     same bug as the body-side `quoted-printable-body` case.",
)];

#[test]
fn multipart_decode_matches_swift() {
    use base64::Engine as _;
    use imbib_core::mbox::decode_multipart;

    let mut report = Report::default();
    let mut divergences_hit = 0;
    for case in golden("mime_multipart_decode.json") {
        let name = s(&case["name"]);
        let content_diverges = MULTIPART_CONTENT_DIVERGENCES
            .iter()
            .any(|(n, _)| *n == name);
        if content_diverges {
            divergences_hit += 1;
        }
        let parts = decode_multipart(s(&case["content"]), s(&case["boundary"]));
        let want_parts = case["parts"].as_array().unwrap();

        report.eq(format!("{name}/count"), want_parts.len(), parts.len());
        for (index, want) in want_parts.iter().enumerate() {
            let Some(got) = parts.get(index) else {
                continue;
            };
            let scope = format!("{name}/part{index}");
            report.eq(
                format!("{scope}/contentType"),
                s(&want["contentType"]).to_string(),
                got.content_type.clone(),
            );
            report.eq(
                format!("{scope}/transferEncoding"),
                opt(&want["transferEncoding"]),
                got.transfer_encoding.clone(),
            );
            report.eq(
                format!("{scope}/filename"),
                opt(&want["filename"]),
                got.filename.clone(),
            );
            // Header maps: compare as sorted pairs so ordering is irrelevant.
            let want_headers: Vec<(String, String)> = want["headers"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.clone(), s(v).to_string()))
                .collect();
            let got_headers: Vec<(String, String)> = got
                .headers
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect();
            report.eq(format!("{scope}/headers"), want_headers, got_headers);
            if !content_diverges {
                report.eq(
                    format!("{scope}/content"),
                    s(&want["contentBase64"]).to_string(),
                    base64::engine::general_purpose::STANDARD.encode(&got.content),
                );
            }
        }
    }
    assert_eq!(
        divergences_hit,
        MULTIPART_CONTENT_DIVERGENCES.len(),
        "a listed multipart divergence is no longer in the corpus"
    );
    report.assert_empty("multipart decode", 60);
}

/// The multipart divergence, asserted positively.
#[test]
fn multipart_quoted_printable_part_decodes_correctly_now() {
    use imbib_core::mbox::decode_multipart;

    let case = golden("mime_multipart_decode.json")
        .into_iter()
        .find(|c| s(&c["name"]) == "quoted-printable-part")
        .expect("missing corpus case");
    let parts = decode_multipart(s(&case["content"]), s(&case["boundary"]));
    assert_eq!(
        String::from_utf8_lossy(&parts[0].content).trim(),
        "Müller wrote: a note"
    );
}

// ── Item 9.1: whole-mbox parsing ────────────────────────────────────────────

/// Cases whose Swift result differed because of a fixed bug. Each entry names
/// the corpus case and the field that legitimately changed.
const MBOX_DIVERGENCES: &[(&str, &str, &str)] = &[
    (
        "quoted-printable-body",
        "body",
        "Swift's Latin-1-per-octet quoted-printable decode corrupted every \
         non-ASCII abstract on imbib's OWN export→import round trip \
         (`Müller` → `MÃ¼ller`). Fixed; see the header-decode divergence.",
    ),
    (
        "lowercase-header-names",
        "from/subject/messageID",
        "Swift subscripted the header dictionary with exact-case keys, so a \
         third-party mbox written with `subject:` imported with an empty title \
         and `unknown@imbib.local` as the sender. RFC 5322 §1.2.2 makes field \
         names case-insensitive.",
    ),
    (
        "encoded-word-subject",
        "from",
        "The `From` header is `=?UTF-8?B?…?=`, which both sides decode \
         identically — but Swift then decoded the *already-decoded* value a \
         second time in `parseMessage`. Listed because the port decodes once.",
    ),
];

fn mbox_divergence(name: &str) -> Option<&'static str> {
    MBOX_DIVERGENCES
        .iter()
        .find(|(n, _, _)| *n == name)
        .map(|(_, f, _)| *f)
}

#[test]
fn mbox_parse_matches_swift() {
    use base64::Engine as _;
    use imbib_core::mbox::parse_content;

    let mut report = Report::default();
    let mut names_seen: Vec<String> = Vec::new();

    for case in golden("mbox_parse.json") {
        let name = s(&case["name"]).to_string();
        names_seen.push(name.clone());
        let diverges = mbox_divergence(&name).is_some();

        let messages = parse_content(s(&case["content"]));
        let want_messages = case["messages"].as_array().unwrap();
        report.eq(format!("{name}/count"), want_messages.len(), messages.len());

        for (index, want) in want_messages.iter().enumerate() {
            let Some(got) = messages.get(index) else {
                continue;
            };
            let scope = format!("{name}/msg{index}");

            if !diverges {
                report.eq(
                    format!("{scope}/from"),
                    s(&want["from"]).to_string(),
                    got.from.clone(),
                );
                report.eq(
                    format!("{scope}/subject"),
                    s(&want["subject"]).to_string(),
                    got.subject.clone(),
                );
                report.eq(
                    format!("{scope}/messageID"),
                    opt(&want["messageID"]),
                    got.message_id.clone(),
                );
                report.eq(
                    format!("{scope}/body"),
                    s(&want["body"]).to_string(),
                    got.body.clone(),
                );
                // Swift minted a UUID for a missing Message-ID; the port reports
                // the absence instead, so the assertion is on the SHAPE. Gated
                // with the rest because a case-sensitivity divergence changes
                // whether the id was found at all.
                report.eq(
                    format!("{scope}/messageIDAbsent"),
                    want["messageIDIsGeneratedUUID"].as_bool().unwrap(),
                    got.message_id.is_none(),
                );
            }

            report.eq(
                format!("{scope}/dateAbsent"),
                want["dateIsWallClockFallback"].as_bool().unwrap(),
                got.date.is_none(),
            );
            if let Some(want_date) = want["date"].as_str() {
                let got_date = got
                    .date
                    .map(|d| d.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string());
                report.eq(
                    format!("{scope}/date"),
                    Some(want_date.to_string()),
                    got_date,
                );
            }

            // Headers and attachments are unaffected by every listed divergence.
            let want_headers: Vec<(String, String)> = want["headers"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.clone(), s(v).to_string()))
                .collect();
            report.eq(
                format!("{scope}/headers"),
                want_headers,
                got.headers
                    .iter()
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect::<Vec<_>>(),
            );

            let want_attachments = want["attachments"].as_array().unwrap();
            report.eq(
                format!("{scope}/attachmentCount"),
                want_attachments.len(),
                got.attachments.len(),
            );
            for (ai, wa) in want_attachments.iter().enumerate() {
                let Some(ga) = got.attachments.get(ai) else {
                    continue;
                };
                report.eq(
                    format!("{scope}/att{ai}/filename"),
                    s(&wa["filename"]).to_string(),
                    ga.filename.clone(),
                );
                report.eq(
                    format!("{scope}/att{ai}/contentType"),
                    s(&wa["contentType"]).to_string(),
                    ga.content_type.clone(),
                );
                report.eq(
                    format!("{scope}/att{ai}/data"),
                    s(&wa["dataBase64"]).to_string(),
                    base64::engine::general_purpose::STANDARD.encode(&ga.data),
                );
            }
        }
    }

    for (name, _, _) in MBOX_DIVERGENCES {
        assert!(
            names_seen.iter().any(|n| n == name),
            "listed mbox divergence {name:?} is no longer in the corpus"
        );
    }
    report.assert_empty("mbox parsing", 150);
}

/// The divergences are only defensible if the fixed behaviour is actually right.
/// Assert the corrected values directly, so "we changed it" cannot quietly
/// become "we broke it differently".
#[test]
fn mbox_fixed_cases_produce_the_right_answer() {
    use imbib_core::mbox::parse_content;

    let corpus = golden("mbox_parse.json");
    let case = |name: &str| {
        corpus
            .iter()
            .find(|c| s(&c["name"]) == name)
            .unwrap_or_else(|| panic!("missing corpus case {name}"))
            .clone()
    };

    let qp = parse_content(s(&case("quoted-printable-body")["content"]));
    assert_eq!(qp[0].body.trim(), "Müller measured 50% of the sample.");

    let lower = parse_content(s(&case("lowercase-header-names")["content"]));
    assert_eq!(lower[0].subject, "lowercase subject");
    assert_eq!(lower[0].from, "A <a@example.com>");
    assert_eq!(lower[0].message_id.as_deref(), Some("lower"));

    let enc = parse_content(s(&case("encoded-word-subject")["content"]));
    assert_eq!(enc[0].subject, "Über Résumé");
    assert_eq!(enc[0].from, "Müller <m@example.com>");
}

// ── Item 9.3: publishers ────────────────────────────────────────────────────

#[test]
fn parser_id_dispatch_matches_swift() {
    use imbib_core::publishers::parser_id;

    let mut report = Report::default();
    for case in golden("publisher_parser_id.json") {
        let host = s(&case["host"]);
        report.eq(
            format!("{host:?}"),
            s(&case["parserID"]).to_string(),
            parser_id(host).to_string(),
        );
    }
    report.assert_empty("publisher host dispatch", 28);
}

#[test]
fn publisher_html_parsing_matches_swift() {
    use imbib_core::publishers::parse;

    let mut report = Report::default();
    for case in golden("publisher_parse.json") {
        let name = s(&case["name"]);
        report.eq(
            name,
            opt(&case["pdfURL"]),
            parse(s(&case["html"]), s(&case["baseURL"]), s(&case["host"])),
        );
    }
    report.assert_empty("publisher landing-page parsing", 54);
}

/// The rule TABLE, field by field. This is what stops the Rust copy from
/// becoming the fourth drifted definition.
#[test]
fn default_publisher_rules_table_matches_swift() {
    use imbib_core::publishers::DEFAULT_RULES;

    let want = golden("publisher_default_rules.json");
    let mut got: Vec<_> = DEFAULT_RULES.iter().collect();
    got.sort_by_key(|r| r.id);

    let mut report = Report::default();
    report.eq("row count", want.len(), got.len());

    for (w, g) in want.iter().zip(got.iter()) {
        let id = s(&w["id"]);
        report.eq(format!("{id}/id"), id.to_string(), g.id.to_string());
        report.eq(
            format!("{id}/name"),
            s(&w["name"]).to_string(),
            g.name.to_string(),
        );
        report.eq(
            format!("{id}/doiPrefixes"),
            w["doiPrefixes"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| s(v).to_string())
                .collect::<Vec<_>>(),
            g.doi_prefixes
                .iter()
                .map(|p| p.to_string())
                .collect::<Vec<_>>(),
        );
        report.eq(
            format!("{id}/pdfURLPattern"),
            opt(&w["pdfURLPattern"]),
            g.pdf_url_pattern.map(str::to_string),
        );
        report.eq(
            format!("{id}/requiresProxy"),
            w["requiresProxy"].as_bool().unwrap(),
            g.requires_proxy,
        );
        report.eq(
            format!("{id}/captchaRisk"),
            s(&w["captchaRisk"]).to_string(),
            g.captcha_risk.as_str().to_string(),
        );
        report.eq(
            format!("{id}/preferOpenAlex"),
            w["preferOpenAlex"].as_bool().unwrap(),
            g.prefer_open_alex,
        );
        report.eq(
            format!("{id}/notes"),
            opt(&w["notes"]),
            g.notes.map(str::to_string),
        );
        report.eq(
            format!("{id}/htmlParserID"),
            opt(&w["htmlParserID"]),
            g.html_parser_id.map(str::to_string),
        );
        report.eq(
            format!("{id}/supportsLandingPageScraping"),
            w["supportsLandingPageScraping"].as_bool().unwrap(),
            g.supports_landing_page_scraping,
        );
    }
    report.assert_empty("default publisher rules table", 160);
}

#[test]
fn publisher_rule_matching_and_url_construction_match_swift() {
    use imbib_core::publishers::rules_for_doi;

    let mut report = Report::default();
    for case in golden("publisher_rule_match.json") {
        let doi = s(&case["doi"]);
        let mut matched: Vec<_> = rules_for_doi(doi);
        matched.sort_by_key(|r| r.id);

        report.eq(
            format!("{doi:?}/matchingRuleIDs"),
            case["matchingRuleIDs"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| s(v).to_string())
                .collect::<Vec<_>>(),
            matched.iter().map(|r| r.id.to_string()).collect::<Vec<_>>(),
        );

        let want_urls = case["constructedURLs"].as_array().unwrap();
        for (index, w) in want_urls.iter().enumerate() {
            let Some(g) = matched.get(index) else {
                continue;
            };
            let rule_id = s(&w["ruleID"]);
            report.eq(
                format!("{doi:?}/{rule_id}/ruleID"),
                rule_id.to_string(),
                g.id.to_string(),
            );
            report.eq(
                format!("{doi:?}/{rule_id}/url"),
                opt(&w["url"]),
                g.construct_pdf_url(doi),
            );
        }
    }
    report.assert_empty("publisher rule matching", 40);
}
