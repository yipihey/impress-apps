//! Publisher PDF-resolution rules.
//!
//! Ported from `PMC/Publishers/PublisherRule.swift` (131 lines) and
//! `DefaultRules.swift` (257 lines) in Stage 7 item 9. The table is pinned by
//! `test_fixtures/golden/publisher_default_rules.json` — captured from the Swift
//! declaration, so the Rust copy cannot drift from what shipped.
//!
//! # Three copies became one
//!
//! Before this port the same 16-row table existed three times in Swift, already
//! disagreeing:
//!
//! | Copy | Rows | Drift |
//! |---|---|---|
//! | `DefaultRules.swift` | 16 | the live one |
//! | `Publishers/Resources/publisher-rules.json` | 12 | bundled by `Package.swift` and **never loaded** — `setCustomRulesPath` has no callers — missing `aip`, `annual-reviews`, `springer`, `cambridge` |
//! | `Tools/pdf-resolution-test/Sources/PDFResolutionTest/TestFixtures.swift` | own `PublisherInfo` type | prefixes spelled `"10.3847"` without the trailing slash, so its matches differ |
//!
//! This is now the one definition.

use serde::Serialize;

/// Risk of hitting a CAPTCHA on a publisher's site.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CaptchaRisk {
    Low,
    Medium,
    High,
}

impl CaptchaRisk {
    /// Swift `CaptchaRisk.rawValue`.
    pub fn as_str(&self) -> &'static str {
        match self {
            CaptchaRisk::Low => "low",
            CaptchaRisk::Medium => "medium",
            CaptchaRisk::High => "high",
        }
    }

    /// Swift `CaptchaRisk.description`.
    pub fn description(&self) -> &'static str {
        match self {
            CaptchaRisk::Low => "Low risk of CAPTCHA",
            CaptchaRisk::Medium => "Moderate CAPTCHA risk",
            CaptchaRisk::High => "High CAPTCHA risk - consider browser fallback",
        }
    }
}

/// One publisher's resolution rule. Mirrors Swift `PublisherRule`.
/// Only `Serialize` is derived: the fields are `&'static str` because the table
/// is a `const`, and a borrowed-str field cannot be deserialized into a static.
/// Swift's `PublisherRulesFile` / `setCustomRulesPath` user-JSON overlay has
/// **no callers** (verified repo-wide), so nothing needs the read direction; a
/// future overlay wants an owned mirror type, not `Deserialize` here.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublisherRule {
    pub id: &'static str,
    pub name: &'static str,
    pub doi_prefixes: &'static [&'static str],
    pub pdf_url_pattern: Option<&'static str>,
    pub requires_proxy: bool,
    pub captcha_risk: CaptchaRisk,
    pub prefer_open_alex: bool,
    pub notes: Option<&'static str>,
    pub html_parser_id: Option<&'static str>,
    pub supports_landing_page_scraping: bool,
}

impl PublisherRule {
    /// Swift `matches(doi:)` — a case-SENSITIVE `hasPrefix` over `doiPrefixes`.
    ///
    /// Preserved quirk: `10.48550/ARXIV.2401.12345` matches nothing, because the
    /// prefix is spelled `10.48550/arXiv.`, even though `construct_pdf_url`'s
    /// arXiv extraction lowercases before comparing. A DOI arriving upper-cased
    /// from a source that normalises identifiers therefore silently gets no rule.
    pub fn matches(&self, doi: &str) -> bool {
        self.doi_prefixes.iter().any(|p| doi.starts_with(p))
    }

    /// Swift `constructPDFURL(doi:)` — `{doi}` / `{articleID}` / `{arxivID}`
    /// template substitution.
    ///
    /// `{articleID}` is the DOI minus the first matching prefix, with `/`
    /// trimmed from both ends. `{arxivID}` needs a DOI that embeds an arXiv id
    /// (`10.48550/arXiv.` or an arXiv-overlay prefix, see `extract_arxiv_id`)
    /// and returns `None` otherwise. Note that neither substitution validates
    /// the remainder, so `10.1038/` yields `…/articles/.pdf` — preserved,
    /// because the caller treats a 404 as "no PDF" anyway and a `None` here
    /// would skip the landing-page fallback that does work.
    pub fn construct_pdf_url(&self, doi: &str) -> Option<String> {
        let pattern = self.pdf_url_pattern?;
        let mut url = pattern.replace("{doi}", doi);

        if url.contains("{articleID}") {
            for prefix in self.doi_prefixes {
                if let Some(rest) = doi.strip_prefix(*prefix) {
                    let article_id = rest.trim_matches('/');
                    url = url.replace("{articleID}", article_id);
                    break;
                }
            }
        }

        if url.contains("{arxivID}") {
            let id = extract_arxiv_id(doi)?;
            url = url.replace("{arxivID}", &id);
        }

        // Swift returns `URL(string:)`, which is nil for a string Foundation
        // cannot parse. Every pattern here is a well-formed https URL with the
        // DOI spliced in, and a DOI cannot introduce a space, so this only ever
        // rejects genuinely broken input.
        if url.contains(' ') {
            return None;
        }
        Some(url)
    }
}

/// Swift `extractArXivID(from:)` — case-insensitive prefix test, but the
/// returned suffix is taken from the ORIGINAL string, so casing is preserved.
///
/// Besides arXiv's own DOIs, arXiv-overlay journals embed the id in theirs:
/// The Open Journal of Astrophysics mints `10.21105/astro.<id>` (the
/// registrant prefix is shared with JOSS, so the `astro.` marker is part of
/// the prefix). The Swift resolver's `extractArXivIDFromDOI` mirrors this
/// list — extend both together.
fn extract_arxiv_id(doi: &str) -> Option<String> {
    const PREFIXES: [&str; 2] = ["10.48550/arxiv.", "10.21105/astro."];
    for prefix in PREFIXES {
        if doi.len() < prefix.len() {
            continue;
        }
        if doi[..prefix.len()].eq_ignore_ascii_case(prefix) {
            return Some(doi[prefix.len()..].to_string());
        }
    }
    None
}

/// The default rule table. Order matches `DefaultRules.swift`.
pub const DEFAULT_RULES: &[PublisherRule] = &[
    PublisherRule {
        id: "iop-aas",
        name: "IOP Publishing (AAS Journals)",
        doi_prefixes: &["10.3847/"],
        pdf_url_pattern: Some("https://iopscience.iop.org/article/{doi}/pdf"),
        requires_proxy: true,
        captcha_risk: CaptchaRisk::Low,
        prefer_open_alex: false,
        notes: Some("American Astronomical Society journals hosted by IOP"),
        html_parser_id: Some("iop"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "iop-legacy",
        name: "IOP Publishing (Legacy ApJ)",
        doi_prefixes: &["10.1086/"],
        pdf_url_pattern: Some("https://iopscience.iop.org/article/{doi}/pdf"),
        requires_proxy: true,
        captcha_risk: CaptchaRisk::Low,
        prefer_open_alex: false,
        notes: Some("Legacy Astrophysical Journal DOIs before 2016"),
        html_parser_id: Some("iop"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "iop-journals",
        name: "IOP Publishing",
        doi_prefixes: &["10.1088/"],
        pdf_url_pattern: Some("https://iopscience.iop.org/article/{doi}/pdf"),
        requires_proxy: true,
        captcha_risk: CaptchaRisk::Low,
        prefer_open_alex: false,
        notes: Some("IOP physics journals (JCAP, CQG, etc.)"),
        html_parser_id: Some("iop"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "aps",
        name: "American Physical Society",
        doi_prefixes: &["10.1103/"],
        pdf_url_pattern: Some("https://link.aps.org/pdf/{doi}"),
        requires_proxy: true,
        captcha_risk: CaptchaRisk::Low,
        prefer_open_alex: false,
        notes: Some("Physical Review journals (PRL, PRD, PRX, etc.)"),
        html_parser_id: Some("aps"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "nature",
        name: "Nature Publishing Group",
        doi_prefixes: &["10.1038/"],
        pdf_url_pattern: Some("https://www.nature.com/articles/{articleID}.pdf"),
        requires_proxy: true,
        captcha_risk: CaptchaRisk::Medium,
        prefer_open_alex: false,
        notes: Some("Nature, Nature Astronomy, Nature Physics, etc."),
        html_parser_id: Some("nature"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "science",
        name: "Science (AAAS)",
        doi_prefixes: &["10.1126/"],
        pdf_url_pattern: Some("https://www.science.org/doi/pdf/{doi}"),
        requires_proxy: true,
        captcha_risk: CaptchaRisk::High,
        prefer_open_alex: true,
        notes: Some("Science and Science Advances - high CAPTCHA risk"),
        html_parser_id: Some("science"),
        supports_landing_page_scraping: false,
    },
    PublisherRule {
        id: "elsevier",
        name: "Elsevier",
        doi_prefixes: &["10.1016/"],
        pdf_url_pattern: None,
        requires_proxy: true,
        captcha_risk: CaptchaRisk::High,
        prefer_open_alex: true,
        notes: Some("No predictable PDF URL pattern - use OpenAlex OA"),
        html_parser_id: Some("elsevier"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "wiley",
        name: "Wiley",
        doi_prefixes: &["10.1002/", "10.1111/"],
        pdf_url_pattern: None,
        requires_proxy: true,
        captcha_risk: CaptchaRisk::Medium,
        prefer_open_alex: true,
        notes: Some("Complex URL pattern - prefer OpenAlex"),
        html_parser_id: Some("wiley"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "aanda",
        name: "Astronomy & Astrophysics",
        doi_prefixes: &["10.1051/0004-6361"],
        pdf_url_pattern: None,
        requires_proxy: false,
        captcha_risk: CaptchaRisk::Low,
        prefer_open_alex: true,
        notes: Some("Usually open access - prefer OpenAlex"),
        html_parser_id: Some("aanda"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "mnras",
        name: "MNRAS (Oxford Academic)",
        doi_prefixes: &["10.1093/mnras"],
        pdf_url_pattern: None,
        requires_proxy: true,
        captcha_risk: CaptchaRisk::Medium,
        prefer_open_alex: true,
        notes: Some("Oxford Academic has complex authentication"),
        html_parser_id: Some("oxford"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "mdpi",
        name: "MDPI",
        doi_prefixes: &["10.3390/"],
        pdf_url_pattern: None,
        requires_proxy: false,
        captcha_risk: CaptchaRisk::Low,
        prefer_open_alex: true,
        notes: Some("Fully open access - use OpenAlex for direct URL"),
        html_parser_id: Some("mdpi"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "arxiv",
        name: "arXiv",
        doi_prefixes: &["10.48550/arXiv."],
        pdf_url_pattern: Some("https://arxiv.org/pdf/{arxivID}.pdf"),
        requires_proxy: false,
        captcha_risk: CaptchaRisk::Low,
        prefer_open_alex: false,
        notes: Some("arXiv preprints - always accessible"),
        html_parser_id: None,
        supports_landing_page_scraping: false,
    },
    PublisherRule {
        id: "theoj-astro",
        name: "The Open Journal of Astrophysics",
        doi_prefixes: &["10.21105/astro."],
        pdf_url_pattern: Some("https://arxiv.org/pdf/{arxivID}.pdf"),
        requires_proxy: false,
        captcha_risk: CaptchaRisk::Low,
        prefer_open_alex: false,
        notes: Some(
            "arXiv overlay journal - the DOI suffix is the arXiv id. Fetch \
             from arXiv: the hosted PDF endpoint (astro.theoj.org) serves \
             empty bodies, and the landing page's citation_pdf_url points at \
             that same endpoint, so scraping it can only rediscover the \
             broken URL.",
        ),
        html_parser_id: None,
        supports_landing_page_scraping: false,
    },
    PublisherRule {
        id: "aip",
        name: "American Institute of Physics",
        doi_prefixes: &["10.1063/"],
        pdf_url_pattern: None,
        requires_proxy: true,
        captcha_risk: CaptchaRisk::Medium,
        prefer_open_alex: true,
        notes: Some("AIP journals (JCP, APL, etc.)"),
        html_parser_id: Some("aip"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "annual-reviews",
        name: "Annual Reviews",
        doi_prefixes: &["10.1146/"],
        pdf_url_pattern: None,
        requires_proxy: true,
        captcha_risk: CaptchaRisk::Low,
        prefer_open_alex: true,
        notes: Some("Annual Review journals"),
        html_parser_id: Some("annual-reviews"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "springer",
        name: "Springer",
        doi_prefixes: &["10.1007/"],
        pdf_url_pattern: None,
        requires_proxy: true,
        captcha_risk: CaptchaRisk::Medium,
        prefer_open_alex: true,
        notes: Some("Springer journals and books"),
        html_parser_id: Some("springer"),
        supports_landing_page_scraping: true,
    },
    PublisherRule {
        id: "cambridge",
        name: "Cambridge University Press",
        doi_prefixes: &["10.1017/"],
        pdf_url_pattern: None,
        requires_proxy: true,
        captcha_risk: CaptchaRisk::Medium,
        prefer_open_alex: true,
        notes: Some("Cambridge journals (PASA, etc.)"),
        html_parser_id: Some("cambridge"),
        supports_landing_page_scraping: true,
    },
];

/// Every rule whose prefixes match `doi`, in table order.
///
/// **Divergence (nondeterminism removed):** Swift's `PublisherRegistry`
/// answered `rule(forDOI:)` by iterating a `[String: PublisherRule]` Dictionary,
/// so when two prefixes both matched, the winner was *unspecified* — and it did
/// not prefer the longer prefix either. `10.1093/mnras…` matches only `mnras`
/// today so nothing was observably broken, but the next overlapping pair would
/// have been a coin flip per process launch. [`rule_for_doi`] resolves it.
pub fn rules_for_doi(doi: &str) -> Vec<&'static PublisherRule> {
    DEFAULT_RULES.iter().filter(|r| r.matches(doi)).collect()
}

/// The single rule that governs `doi`: **longest matching prefix wins**, with
/// table order as the tiebreak. See [`rules_for_doi`] for why this is not just
/// `.first()`.
pub fn rule_for_doi(doi: &str) -> Option<&'static PublisherRule> {
    DEFAULT_RULES
        .iter()
        .filter(|r| r.matches(doi))
        .max_by_key(|r| {
            r.doi_prefixes
                .iter()
                .filter(|p| doi.starts_with(**p))
                .map(|p| p.len())
                .max()
                .unwrap_or(0)
        })
}

/// Swift `PublisherRegistry.rule(forID:)`.
pub fn rule_for_id(id: &str) -> Option<&'static PublisherRule> {
    DEFAULT_RULES.iter().find(|r| r.id == id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_rule_id_is_unique() {
        let mut ids: Vec<_> = DEFAULT_RULES.iter().map(|r| r.id).collect();
        let before = ids.len();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), before, "duplicate rule id in DEFAULT_RULES");
    }

    #[test]
    fn every_html_parser_id_is_a_real_parser() {
        for rule in DEFAULT_RULES {
            if let Some(id) = rule.html_parser_id {
                assert!(
                    super::super::html::PARSER_IDS.contains(&id),
                    "{}: htmlParserID {id:?} has no parser",
                    rule.id
                );
            }
        }
    }

    #[test]
    fn arxiv_prefix_match_is_case_sensitive_but_extraction_is_not() {
        let arxiv = rule_for_id("arxiv").unwrap();
        assert!(arxiv.matches("10.48550/arXiv.2401.12345"));
        assert!(!arxiv.matches("10.48550/ARXIV.2401.12345"));
        // Extraction lowercases, so a rule reached by any other route works.
        assert_eq!(
            arxiv.construct_pdf_url("10.48550/ARXIV.2401.12345"),
            Some("https://arxiv.org/pdf/2401.12345.pdf".to_string())
        );
    }

    #[test]
    fn overlay_journal_doi_resolves_to_arxiv() {
        // The Open Journal of Astrophysics is an arXiv overlay: its DOI
        // suffix is the arXiv id, and its own hosted PDF endpoint is not
        // trustworthy (serves empty bodies), so the rule sends the fetch to
        // arXiv.
        let rule = rule_for_doi("10.21105/astro.2106.03528").expect("OJA rule");
        assert_eq!(rule.id, "theoj-astro");
        assert!(!rule.supports_landing_page_scraping);
        assert_eq!(
            rule.construct_pdf_url("10.21105/astro.2106.03528"),
            Some("https://arxiv.org/pdf/2106.03528.pdf".to_string())
        );
        // JOSS shares the 10.21105 registrant and must NOT match.
        assert_eq!(rule_for_doi("10.21105/joss.01234"), None);
    }

    #[test]
    fn article_id_substitution_strips_the_prefix() {
        let nature = rule_for_id("nature").unwrap();
        assert_eq!(
            nature.construct_pdf_url("10.1038/nature12373"),
            Some("https://www.nature.com/articles/nature12373.pdf".to_string())
        );
    }

    #[test]
    fn longest_prefix_wins_where_swift_was_a_coin_flip() {
        // 10.1093/mnras… is matched by `mnras` only today; the assertion is on
        // the mechanism, so an added overlapping prefix stays deterministic.
        assert_eq!(
            rule_for_doi("10.1093/mnras/stab123").map(|r| r.id),
            Some("mnras")
        );
        assert_eq!(rule_for_doi("10.9999/nope"), None);
    }
}
