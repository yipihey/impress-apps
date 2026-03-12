//
//  NLSearchService.swift
//  PublicationManagerCore
//
//  Translates natural language search descriptions into ADS/SciX query syntax
//  using deterministic pattern matching via SmartQueryTranslator.
//

import Foundation
import ImpressScixCore
import OSLog

// MARK: - NL Search State

/// State of a natural language search translation
public enum NLSearchState: Sendable, Equatable {
    case idle
    case thinking
    case translated(query: String, interpretation: String, estimatedCount: UInt32?)
    case searching
    case complete(query: String, resultCount: Int)
    case error(String)

    public var isWorking: Bool {
        switch self {
        case .thinking, .searching: return true
        default: return false
        }
    }
}

// MARK: - NL Search Result Type

/// The type of operation performed
public enum NLSearchResultType: Sendable, Equatable {
    /// A standard ADS query search
    case querySearch(query: String)
}

// MARK: - NL Search Service

/// Service that translates natural language into ADS queries using
/// deterministic pattern matching via SmartQueryTranslator.
@Observable
@MainActor
public final class NLSearchService {

    // MARK: - Properties

    public private(set) var state: NLSearchState = .idle
    public private(set) var lastNaturalLanguageInput: String = ""
    public private(set) var lastGeneratedQuery: String = ""
    public private(set) var lastInterpretation: String = ""
    public private(set) var lastResultType: NLSearchResultType?
    public private(set) var estimatedCount: UInt32?

    /// User-configurable max results (passed through to search pipeline)
    public var maxResults: Int = 0

    /// User-selected source IDs (default ADS, can include arXiv, OpenAlex, etc.)
    public var selectedSourceIDs: Set<String> = ["ads"]

    /// Whether to restrict to refereed/peer-reviewed papers
    public var refereedOnly: Bool = false

    /// When true, expand topic words using the astronomy synonym dictionary
    public var expandSynonyms: Bool = false

    /// When true, skip the background count preview (avoids Keychain access in tests)
    public var skipCountPreview: Bool = false

    // MARK: - Initialization

    public init() {}

    // MARK: - Availability

    /// Smart Search is always available (deterministic translation).
    public static var isAvailable: Bool { true }

    // MARK: - Translation

    /// Translate a natural language description into an ADS/SciX query string.
    ///
    /// Uses SmartQueryTranslator for deterministic pattern matching.
    /// If the input already looks like an ADS query (contains field qualifiers),
    /// it passes through with normalization.
    ///
    /// - Parameter naturalLanguage: The user's natural language search description
    /// - Returns: The generated ADS query string, or nil if translation failed
    public func translate(_ naturalLanguage: String) async -> String? {
        guard !naturalLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        lastNaturalLanguageInput = naturalLanguage
        state = .thinking

        Logger.viewModels.infoCapture(
            "NLSearch: translating '\(naturalLanguage)'",
            category: "nlsearch"
        )

        guard let result = SmartQueryTranslator.translate(
            naturalLanguage,
            expandSynonyms: expandSynonyms,
            refereedOnly: refereedOnly
        ) else {
            state = .error("Could not parse query")
            return nil
        }

        let finalQuery = result.query
        let interpretation = result.interpretation

        lastGeneratedQuery = finalQuery
        lastInterpretation = interpretation
        lastResultType = .querySearch(query: finalQuery)

        Logger.viewModels.infoCapture(
            "NLSearch: translated to '\(finalQuery)' — \(interpretation)",
            category: "nlsearch"
        )

        // Set state first, then fetch count in background
        estimatedCount = nil
        state = .translated(query: finalQuery, interpretation: interpretation, estimatedCount: nil)

        // Fetch count preview in background
        if !skipCountPreview {
            let capturedQuery = finalQuery
            let capturedInterpretation = interpretation
            Task.detached { [weak self] in
                guard let apiKey = await CredentialManager.shared.apiKey(for: "ads") else { return }
                do {
                    let count = try scixCount(token: apiKey, query: capturedQuery)
                    await MainActor.run {
                        self?.estimatedCount = count
                        if case .translated(let q, _, _) = self?.state, q == capturedQuery {
                            self?.state = .translated(
                                query: capturedQuery,
                                interpretation: capturedInterpretation,
                                estimatedCount: count
                            )
                        }
                    }
                } catch {
                    Logger.viewModels.warningCapture(
                        "NLSearch: count preview failed: \(error.localizedDescription)",
                        category: "nlsearch"
                    )
                }
            }
        }

        return finalQuery
    }

    // MARK: - State Management

    /// Reset to idle state (start fresh).
    public func reset() {
        state = .idle
        lastNaturalLanguageInput = ""
        lastGeneratedQuery = ""
        lastInterpretation = ""
        lastResultType = nil
        estimatedCount = nil
    }

    /// Called when the overlay closes — preserves last results.
    public func startNewConversation() {
        // No-op: kept for NLSearchOverlayView.onDisappear compatibility
    }

    /// Update state to indicate search is executing
    public func markSearching() {
        state = .searching
    }

    /// Update state to indicate search completed with results.
    public func markComplete(resultCount: Int, executedQuery: String? = nil) {
        let displayQuery = executedQuery ?? lastGeneratedQuery
        state = .complete(query: displayQuery, resultCount: resultCount)
        Logger.viewModels.infoCapture(
            "NLSearch: complete, \(resultCount) results for '\(displayQuery)'",
            category: "nlsearch"
        )
    }
}
