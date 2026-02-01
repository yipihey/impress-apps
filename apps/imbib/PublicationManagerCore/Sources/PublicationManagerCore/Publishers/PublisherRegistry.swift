//
//  PublisherRegistry.swift
//  PublicationManagerCore
//
//  Registry for publisher PDF resolution rules.
//

import Foundation
import OSLog

// MARK: - Publisher Registry

/// Manages publisher rules for PDF resolution.
///
/// The registry loads rules from:
/// 1. User-provided JSON file (if exists)
/// 2. Built-in default rules (fallback)
///
/// Rules are cached and can be reloaded at runtime.
public actor PublisherRegistry {

    // MARK: - Singleton

    public static let shared = PublisherRegistry()

    // MARK: - Properties

    private var rules: [PublisherRule] = []
    private var rulesByPrefix: [String: PublisherRule] = [:]
    private var customRulesPath: URL?
    private var lastLoadTime: Date?

    // MARK: - Initialization

    private init() {
        // Load default rules immediately
        loadDefaultRules()
    }

    // MARK: - Configuration

    /// Set the path to custom rules JSON file.
    ///
    /// If the file exists and is valid, its rules will override the defaults.
    public func setCustomRulesPath(_ path: URL?) {
        customRulesPath = path
        Task {
            await reloadRules()
        }
    }

    // MARK: - Rule Loading

    /// Reload rules from all sources.
    public func reloadRules() async {
        // Start with defaults
        loadDefaultRules()

        // Try to load custom rules
        if let path = customRulesPath {
            do {
                try await loadCustomRules(from: path)
                Logger.files.info("[PublisherRegistry] Loaded custom rules from \(path.path)")
            } catch {
                Logger.files.warning("[PublisherRegistry] Failed to load custom rules: \(error.localizedDescription)")
            }
        }

        lastLoadTime = Date()
    }

    private func loadDefaultRules() {
        rules = DefaultPublisherRules.rules
        rebuildIndex()
    }

    private func loadCustomRules(from url: URL) async throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let rulesFile = try decoder.decode(PublisherRulesFile.self, from: data)

        // Merge custom rules with defaults
        // Custom rules take precedence (by ID)
        var rulesByID: [String: PublisherRule] = [:]
        for rule in DefaultPublisherRules.rules {
            rulesByID[rule.id] = rule
        }
        for rule in rulesFile.rules {
            rulesByID[rule.id] = rule
        }

        rules = Array(rulesByID.values)
        rebuildIndex()
    }

    private func rebuildIndex() {
        rulesByPrefix = [:]
        for rule in rules {
            for prefix in rule.doiPrefixes {
                rulesByPrefix[prefix] = rule
            }
        }
    }

    // MARK: - Rule Lookup

    /// Find the rule that matches a DOI.
    public func rule(forDOI doi: String) -> PublisherRule? {
        // Try exact prefix match first
        for (prefix, rule) in rulesByPrefix {
            if doi.hasPrefix(prefix) {
                return rule
            }
        }

        // Fall back to iterating all rules
        return rules.first { $0.matches(doi: doi) }
    }

    /// Get all loaded rules.
    public func allRules() -> [PublisherRule] {
        rules
    }

    /// Check if a DOI has a known publisher rule.
    public func hasRule(forDOI doi: String) -> Bool {
        rule(forDOI: doi) != nil
    }

    // MARK: - URL Construction

    /// Construct a PDF URL for a DOI using publisher rules.
    public func constructPDFURL(forDOI doi: String) -> URL? {
        guard let rule = rule(forDOI: doi) else { return nil }
        return rule.constructPDFURL(doi: doi)
    }

    /// Check if a DOI requires proxy access.
    public func requiresProxy(doi: String) -> Bool {
        rule(forDOI: doi)?.requiresProxy ?? true
    }

    /// Check CAPTCHA risk for a DOI.
    public func captchaRisk(forDOI doi: String) -> CaptchaRisk {
        rule(forDOI: doi)?.captchaRisk ?? .medium
    }

    /// Check if OpenAlex should be preferred for a DOI.
    public func shouldPreferOpenAlex(doi: String) -> Bool {
        rule(forDOI: doi)?.preferOpenAlex ?? false
    }

    /// Get publisher name for a DOI.
    public func publisherName(forDOI doi: String) -> String? {
        rule(forDOI: doi)?.name
    }

    // MARK: - Statistics

    /// Get registry statistics.
    public func statistics() -> PublisherRegistryStats {
        PublisherRegistryStats(
            totalRules: rules.count,
            totalPrefixes: rulesByPrefix.count,
            lastLoadTime: lastLoadTime,
            hasCustomRules: customRulesPath != nil
        )
    }
}

// MARK: - Statistics

/// Statistics about the publisher registry.
public struct PublisherRegistryStats: Sendable {
    public let totalRules: Int
    public let totalPrefixes: Int
    public let lastLoadTime: Date?
    public let hasCustomRules: Bool
}
