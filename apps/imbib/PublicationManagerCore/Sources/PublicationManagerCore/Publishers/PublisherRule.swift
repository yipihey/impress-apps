//
//  PublisherRule.swift
//  PublicationManagerCore
//
//  Data types for publisher PDF resolution rules.
//

import Foundation

// MARK: - Publisher Rule

/// Rule for resolving PDF URLs for a specific publisher.
///
/// Publisher rules define how to construct PDF URLs from DOIs and what to expect
/// when accessing publisher content.
public struct PublisherRule: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let doiPrefixes: [String]
    public let pdfURLPattern: String?
    public let requiresProxy: Bool
    public let captchaRisk: CaptchaRisk
    public let preferOpenAlex: Bool
    public let notes: String?

    public init(
        id: String,
        name: String,
        doiPrefixes: [String],
        pdfURLPattern: String? = nil,
        requiresProxy: Bool = false,
        captchaRisk: CaptchaRisk = .low,
        preferOpenAlex: Bool = false,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.doiPrefixes = doiPrefixes
        self.pdfURLPattern = pdfURLPattern
        self.requiresProxy = requiresProxy
        self.captchaRisk = captchaRisk
        self.preferOpenAlex = preferOpenAlex
        self.notes = notes
    }

    /// Check if this rule matches a DOI.
    public func matches(doi: String) -> Bool {
        doiPrefixes.contains { doi.hasPrefix($0) }
    }

    /// Construct a PDF URL from a DOI using this rule's pattern.
    public func constructPDFURL(doi: String) -> URL? {
        guard let pattern = pdfURLPattern else { return nil }

        var urlString = pattern.replacingOccurrences(of: "{doi}", with: doi)

        // Handle special patterns
        if urlString.contains("{articleID}") {
            // For publishers like Nature that use article ID
            // Find the prefix that matches and extract the suffix
            for prefix in doiPrefixes {
                if doi.hasPrefix(prefix) {
                    let articleID = String(doi.dropFirst(prefix.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    urlString = urlString.replacingOccurrences(of: "{articleID}", with: articleID)
                    break
                }
            }
        }

        if urlString.contains("{arxivID}") {
            // For arXiv DOIs
            if let arxivID = extractArXivID(from: doi) {
                urlString = urlString.replacingOccurrences(of: "{arxivID}", with: arxivID)
            } else {
                return nil
            }
        }

        return URL(string: urlString)
    }

    private func extractArXivID(from doi: String) -> String? {
        // arXiv DOI format: 10.48550/arXiv.2311.12345
        let prefix = "10.48550/arXiv."
        guard doi.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(doi.dropFirst(prefix.count))
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
public struct PublisherRulesFile: Sendable, Codable {
    public let version: String
    public let rules: [PublisherRule]

    public init(version: String, rules: [PublisherRule]) {
        self.version = version
        self.rules = rules
    }
}
