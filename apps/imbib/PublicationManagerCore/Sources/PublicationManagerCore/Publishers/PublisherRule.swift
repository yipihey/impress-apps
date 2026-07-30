//
//  PublisherRule.swift
//  PublicationManagerCore
//
//  Data types for publisher PDF resolution rules.
//
//  Stage 7 item 9: `matches(doi:)` and `constructPDFURL(doi:)` moved to Rust
//  (`crates/imbib-core/src/publishers/rules.rs`), along with the rule TABLE.
//

import Foundation
import ImbibRustCore

// MARK: - Publisher Rule

/// Rule for resolving PDF URLs for a specific publisher.
///
/// Publisher rules define how to construct PDF URLs from DOIs and what to expect
/// when accessing publisher content.
///
/// **The table is Rust's** (`publishers::DEFAULT_RULES`), pinned field-by-field
/// by `crates/imbib-core/test_fixtures/golden/publisher_default_rules.json`. This
/// struct is the value type the Swift call sites read; it is `Codable` only
/// because `PublisherRulesFile` is, and that file format has no writer and no
/// reader (see `PublisherRegistry`).
public struct PublisherRule: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let doiPrefixes: [String]
    public let pdfURLPattern: String?
    public let requiresProxy: Bool
    public let captchaRisk: CaptchaRisk
    public let preferOpenAlex: Bool
    public let notes: String?

    /// Parser ID for landing page HTML parsing (e.g., "iop", "aps", "nature").
    /// Used by `PublisherHTMLParsers` to select the appropriate parsing strategy.
    public let htmlParserID: String?

    /// Whether this publisher supports landing page scraping for PDF extraction.
    /// When true, the resolver will attempt to fetch and parse the landing page HTML.
    public let supportsLandingPageScraping: Bool

    public init(
        id: String,
        name: String,
        doiPrefixes: [String],
        pdfURLPattern: String? = nil,
        requiresProxy: Bool = false,
        captchaRisk: CaptchaRisk = .low,
        preferOpenAlex: Bool = false,
        notes: String? = nil,
        htmlParserID: String? = nil,
        supportsLandingPageScraping: Bool = true
    ) {
        self.id = id
        self.name = name
        self.doiPrefixes = doiPrefixes
        self.pdfURLPattern = pdfURLPattern
        self.requiresProxy = requiresProxy
        self.captchaRisk = captchaRisk
        self.preferOpenAlex = preferOpenAlex
        self.notes = notes
        self.htmlParserID = htmlParserID
        self.supportsLandingPageScraping = supportsLandingPageScraping
    }

    /// Bridge from the Rust record.
    init(ffi: FfiPublisherRule) {
        self.id = ffi.id
        self.name = ffi.name
        self.doiPrefixes = ffi.doiPrefixes
        self.pdfURLPattern = ffi.pdfUrlPattern
        self.requiresProxy = ffi.requiresProxy
        self.captchaRisk = CaptchaRisk(rawValue: ffi.captchaRisk) ?? .low
        self.preferOpenAlex = ffi.preferOpenAlex
        self.notes = ffi.notes
        self.htmlParserID = ffi.htmlParserId
        self.supportsLandingPageScraping = ffi.supportsLandingPageScraping
    }

    /// Check if this rule matches a DOI.
    ///
    /// Case-SENSITIVE `hasPrefix`, which is why `10.48550/ARXIV.…` matches no
    /// rule even though `{arxivID}` extraction lowercases. Preserved.
    public func matches(doi: String) -> Bool {
        doiPrefixes.contains { doi.hasPrefix($0) }
    }

    /// Construct a PDF URL from a DOI using this rule's pattern.
    ///
    /// `{doi}` / `{articleID}` / `{arxivID}` substitution, in Rust so the
    /// template semantics have one definition.
    public func constructPDFURL(doi: String) -> URL? {
        guard let resolved = ImbibRustCore.publisherConstructPdfUrl(ruleId: id, doi: doi) else {
            return nil
        }
        return URL(string: resolved)
    }
}

// MARK: - CAPTCHA Risk

/// Risk level of encountering CAPTCHA challenges.
public enum CaptchaRisk: String, Sendable, Codable, CaseIterable {
    case low
    case medium
    case high

    public var description: String {
        switch self {
        case .low: return "Low risk of CAPTCHA"
        case .medium: return "Moderate CAPTCHA risk"
        case .high: return "High CAPTCHA risk - consider browser fallback"
        }
    }
}

// MARK: - Publisher Rules File

/// Container for publisher rules loaded from JSON.
///
/// Retained as public API. Note that nothing writes or reads this format:
/// `PublisherRegistry.setCustomRulesPath` has no callers, and the
/// `Publishers/Resources/publisher-rules.json` the package bundles was a stale
/// 12-rule subset that was never loaded. The rule table lives in Rust.
public struct PublisherRulesFile: Sendable, Codable {
    public let version: String
    public let rules: [PublisherRule]

    public init(version: String, rules: [PublisherRule]) {
        self.version = version
        self.rules = rules
    }
}
