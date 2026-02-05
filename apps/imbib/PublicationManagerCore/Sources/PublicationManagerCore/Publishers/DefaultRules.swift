//
//  DefaultRules.swift
//  PublicationManagerCore
//
//  Built-in publisher rules compiled into the app.
//

import Foundation

// MARK: - Default Publisher Rules

/// Default publisher rules compiled into the app.
///
/// These rules provide a reliable fallback when no custom rules are configured.
/// They can be overridden by user-provided JSON rules.
public struct DefaultPublisherRules {

    /// All default rules.
    public static let rules: [PublisherRule] = [
        // IOP Publishing - AAS Journals (ApJ, AJ, ApJL, etc.)
        PublisherRule(
            id: "iop-aas",
            name: "IOP Publishing (AAS Journals)",
            doiPrefixes: ["10.3847/"],
            pdfURLPattern: "https://iopscience.iop.org/article/{doi}/pdf",
            requiresProxy: true,
            captchaRisk: .low,
            notes: "American Astronomical Society journals hosted by IOP",
            htmlParserID: "iop",
            supportsLandingPageScraping: true
        ),

        // IOP Publishing - Legacy ApJ DOIs
        PublisherRule(
            id: "iop-legacy",
            name: "IOP Publishing (Legacy ApJ)",
            doiPrefixes: ["10.1086/"],
            pdfURLPattern: "https://iopscience.iop.org/article/{doi}/pdf",
            requiresProxy: true,
            captchaRisk: .low,
            notes: "Legacy Astrophysical Journal DOIs before 2016",
            htmlParserID: "iop",
            supportsLandingPageScraping: true
        ),

        // IOP Publishing - Other IOP Journals
        PublisherRule(
            id: "iop-journals",
            name: "IOP Publishing",
            doiPrefixes: ["10.1088/"],
            pdfURLPattern: "https://iopscience.iop.org/article/{doi}/pdf",
            requiresProxy: true,
            captchaRisk: .low,
            notes: "IOP physics journals (JCAP, CQG, etc.)",
            htmlParserID: "iop",
            supportsLandingPageScraping: true
        ),

        // APS - Physical Review Journals
        PublisherRule(
            id: "aps",
            name: "American Physical Society",
            doiPrefixes: ["10.1103/"],
            pdfURLPattern: "https://link.aps.org/pdf/{doi}",
            requiresProxy: true,
            captchaRisk: .low,
            notes: "Physical Review journals (PRL, PRD, PRX, etc.)",
            htmlParserID: "aps",
            supportsLandingPageScraping: true
        ),

        // Nature Publishing Group
        PublisherRule(
            id: "nature",
            name: "Nature Publishing Group",
            doiPrefixes: ["10.1038/"],
            pdfURLPattern: "https://www.nature.com/articles/{articleID}.pdf",
            requiresProxy: true,
            captchaRisk: .medium,
            notes: "Nature, Nature Astronomy, Nature Physics, etc.",
            htmlParserID: "nature",
            supportsLandingPageScraping: true
        ),

        // Science (AAAS)
        PublisherRule(
            id: "science",
            name: "Science (AAAS)",
            doiPrefixes: ["10.1126/"],
            pdfURLPattern: "https://www.science.org/doi/pdf/{doi}",
            requiresProxy: true,
            captchaRisk: .high,
            preferOpenAlex: true,
            notes: "Science and Science Advances - high CAPTCHA risk",
            htmlParserID: "science",
            supportsLandingPageScraping: false  // High CAPTCHA risk
        ),

        // Elsevier
        PublisherRule(
            id: "elsevier",
            name: "Elsevier",
            doiPrefixes: ["10.1016/"],
            pdfURLPattern: nil,
            requiresProxy: true,
            captchaRisk: .high,
            preferOpenAlex: true,
            notes: "No predictable PDF URL pattern - use OpenAlex OA",
            htmlParserID: "elsevier",
            supportsLandingPageScraping: true
        ),

        // Wiley
        PublisherRule(
            id: "wiley",
            name: "Wiley",
            doiPrefixes: ["10.1002/", "10.1111/"],
            pdfURLPattern: nil,
            requiresProxy: true,
            captchaRisk: .medium,
            preferOpenAlex: true,
            notes: "Complex URL pattern - prefer OpenAlex",
            htmlParserID: "wiley",
            supportsLandingPageScraping: true
        ),

        // A&A (Astronomy & Astrophysics)
        PublisherRule(
            id: "aanda",
            name: "Astronomy & Astrophysics",
            doiPrefixes: ["10.1051/0004-6361"],
            pdfURLPattern: nil,  // Complex pattern based on article year/number
            requiresProxy: false,
            captchaRisk: .low,
            preferOpenAlex: true,
            notes: "Usually open access - prefer OpenAlex",
            htmlParserID: "aanda",
            supportsLandingPageScraping: true
        ),

        // MNRAS (Oxford)
        PublisherRule(
            id: "mnras",
            name: "MNRAS (Oxford Academic)",
            doiPrefixes: ["10.1093/mnras"],
            pdfURLPattern: nil,
            requiresProxy: true,
            captchaRisk: .medium,
            preferOpenAlex: true,
            notes: "Oxford Academic has complex authentication",
            htmlParserID: "oxford",
            supportsLandingPageScraping: true
        ),

        // MDPI (Open Access)
        PublisherRule(
            id: "mdpi",
            name: "MDPI",
            doiPrefixes: ["10.3390/"],
            pdfURLPattern: nil,
            requiresProxy: false,
            captchaRisk: .low,
            preferOpenAlex: true,
            notes: "Fully open access - use OpenAlex for direct URL",
            htmlParserID: "mdpi",
            supportsLandingPageScraping: true
        ),

        // arXiv
        PublisherRule(
            id: "arxiv",
            name: "arXiv",
            doiPrefixes: ["10.48550/arXiv."],
            pdfURLPattern: "https://arxiv.org/pdf/{arxivID}.pdf",
            requiresProxy: false,
            captchaRisk: .low,
            notes: "arXiv preprints - always accessible",
            supportsLandingPageScraping: false  // Direct pattern works
        ),

        // AIP (American Institute of Physics)
        PublisherRule(
            id: "aip",
            name: "American Institute of Physics",
            doiPrefixes: ["10.1063/"],
            pdfURLPattern: nil,
            requiresProxy: true,
            captchaRisk: .medium,
            preferOpenAlex: true,
            notes: "AIP journals (JCP, APL, etc.)",
            htmlParserID: "aip",
            supportsLandingPageScraping: true
        ),

        // Annual Reviews
        PublisherRule(
            id: "annual-reviews",
            name: "Annual Reviews",
            doiPrefixes: ["10.1146/"],
            pdfURLPattern: nil,
            requiresProxy: true,
            captchaRisk: .low,
            preferOpenAlex: true,
            notes: "Annual Review journals",
            htmlParserID: "annual-reviews",
            supportsLandingPageScraping: true
        ),

        // Springer
        PublisherRule(
            id: "springer",
            name: "Springer",
            doiPrefixes: ["10.1007/"],
            pdfURLPattern: nil,
            requiresProxy: true,
            captchaRisk: .medium,
            preferOpenAlex: true,
            notes: "Springer journals and books",
            htmlParserID: "springer",
            supportsLandingPageScraping: true
        ),

        // Cambridge University Press
        PublisherRule(
            id: "cambridge",
            name: "Cambridge University Press",
            doiPrefixes: ["10.1017/"],
            pdfURLPattern: nil,
            requiresProxy: true,
            captchaRisk: .medium,
            preferOpenAlex: true,
            notes: "Cambridge journals (PASA, etc.)",
            htmlParserID: "cambridge",
            supportsLandingPageScraping: true
        ),
    ]

    /// Find the rule that matches a DOI.
    public static func rule(forDOI doi: String) -> PublisherRule? {
        rules.first { $0.matches(doi: doi) }
    }

    /// Get publisher name for a DOI.
    public static func publisherName(forDOI doi: String) -> String? {
        rule(forDOI: doi)?.name
    }

    /// Check if DOI is from a publisher with high CAPTCHA risk.
    public static func hasHighCaptchaRisk(_ doi: String) -> Bool {
        rule(forDOI: doi)?.captchaRisk == .high
    }

    /// Check if OpenAlex should be preferred for this DOI.
    public static func shouldPreferOpenAlex(_ doi: String) -> Bool {
        rule(forDOI: doi)?.preferOpenAlex ?? false
    }
}
