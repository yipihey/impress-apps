//
//  SearchIntents.swift
//  PublicationManagerCore
//
//  Search-related Siri Shortcuts intents (ADR-018 enhanced).
//

import AppIntents
import Foundation

// MARK: - Search Source Enum

/// Available search sources for the SearchPapersIntent.
@available(iOS 16.0, macOS 13.0, *)
public enum SearchSourceOption: String, AppEnum {
    case all = "all"
    case arxiv = "arxiv"
    case ads = "ads"
    case crossref = "crossref"
    case pubmed = "pubmed"
    case semanticScholar = "semantic_scholar"
    case openAlex = "openalex"
    case dblp = "dblp"
    case library = "library"  // ADR-018: Search local library

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Search Source"
    }

    public static var caseDisplayRepresentations: [SearchSourceOption: DisplayRepresentation] {
        [
            .all: DisplayRepresentation(title: "All Online Sources"),
            .library: DisplayRepresentation(title: "My Library"),
            .arxiv: DisplayRepresentation(title: "arXiv"),
            .ads: DisplayRepresentation(title: "NASA ADS"),
            .crossref: DisplayRepresentation(title: "Crossref"),
            .pubmed: DisplayRepresentation(title: "PubMed"),
            .semanticScholar: DisplayRepresentation(title: "Semantic Scholar"),
            .openAlex: DisplayRepresentation(title: "OpenAlex"),
            .dblp: DisplayRepresentation(title: "DBLP")
        ]
    }

    /// Convert to source ID used by the automation system.
    var sourceID: String? {
        switch self {
        case .all: return nil
        case .library: return "library"
        case .arxiv: return "arxiv"
        case .ads: return "ads"
        case .crossref: return "crossref"
        case .pubmed: return "pubmed"
        case .semanticScholar: return "semantic_scholar"
        case .openAlex: return "openalex"
        case .dblp: return "dblp"
        }
    }

    /// Source IDs for external search.
    var externalSourceIDs: [String]? {
        switch self {
        case .all, .library: return nil
        case .arxiv: return ["arxiv"]
        case .ads: return ["ads"]
        case .crossref: return ["crossref"]
        case .pubmed: return ["pubmed"]
        case .semanticScholar: return ["semantic_scholar"]
        case .openAlex: return ["openalex"]
        case .dblp: return ["dblp"]
        }
    }
}

// MARK: - Search Papers Intent (ADR-018 Enhanced)

/// Search for papers across scientific databases and return results.
///
/// ADR-018 Enhancement: Now returns actual [PaperEntity] data instead of
/// just triggering a UI navigation. This enables Shortcuts to work with
/// search results programmatically.
@available(iOS 16.0, macOS 13.0, *)
public struct SearchPapersIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Search Papers"

    public static var description = IntentDescription(
        "Search for scientific papers and return results.",
        categoryName: "Search",
        searchKeywords: ["search", "find", "paper", "article", "research"]
    )

    public static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$query)") {
            \.$source
            \.$maxResults
        }
    }

    @Parameter(title: "Query", description: "The search query (title, author, keywords)")
    public var query: String

    @Parameter(title: "Source", description: "Where to search", default: .library)
    public var source: SearchSourceOption

    @Parameter(title: "Max Results", description: "Maximum number of results to return", default: 20)
    public var maxResults: Int

    public var automationCommand: AutomationCommand {
        .search(query: query, source: source.sourceID, maxResults: maxResults)
    }

    public init() {}

    public init(query: String, source: SearchSourceOption = .library, maxResults: Int = 20) {
        self.query = query
        self.source = source
        self.maxResults = maxResults
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[PaperEntity]> {
        // Check if automation is enabled
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        let papers: [PaperResult]

        if source == .library {
            // Search local library
            let filters = SearchFilters(limit: maxResults)
            papers = try await AutomationService.shared.searchLibrary(query: query, filters: filters)
        } else {
            // Search external sources
            let result = try await AutomationService.shared.searchExternal(
                sources: source.externalSourceIDs,
                query: query,
                maxResults: maxResults
            )
            papers = result.papers
        }

        // Also trigger UI navigation for visual feedback
        await URLSchemeHandler.shared.execute(automationCommand)

        // Return entity results
        return .result(value: papers.prefix(maxResults).map { PaperEntity(from: $0) })
    }
}

// MARK: - Search Library Intent

/// Search the local library and return matching papers.
@available(iOS 16.0, macOS 13.0, *)
public struct SearchLibraryIntent: AppIntent {

    public static var title: LocalizedStringResource = "Search My Library"

    public static var description = IntentDescription(
        "Search your local paper library.",
        categoryName: "Search"
    )

    public static var parameterSummary: some ParameterSummary {
        Summary("Search library for \(\.$query)") {
            \.$maxResults
            \.$unreadOnly
        }
    }

    @Parameter(title: "Query", description: "Search query (title, author, cite key)")
    public var query: String

    @Parameter(title: "Max Results", default: 20)
    public var maxResults: Int

    @Parameter(title: "Unread Only", default: false)
    public var unreadOnly: Bool

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[PaperEntity]> {
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        let filters = SearchFilters(
            isRead: unreadOnly ? false : nil,
            limit: maxResults
        )
        let papers = try await AutomationService.shared.searchLibrary(query: query, filters: filters)

        return .result(value: papers.map { PaperEntity(from: $0) })
    }
}

// MARK: - Search External Intent

/// Search external sources (ADS, arXiv, etc.) and return results.
@available(iOS 16.0, macOS 13.0, *)
public struct SearchExternalIntent: AppIntent {

    public static var title: LocalizedStringResource = "Search Online Databases"

    public static var description = IntentDescription(
        "Search scientific databases like ADS, arXiv, and Crossref.",
        categoryName: "Search"
    )

    public static var parameterSummary: some ParameterSummary {
        Summary("Search online for \(\.$query)") {
            \.$source
            \.$maxResults
        }
    }

    @Parameter(title: "Query", description: "Search query")
    public var query: String

    @Parameter(title: "Source", default: .all)
    public var source: SearchSourceOption

    @Parameter(title: "Max Results", default: 20)
    public var maxResults: Int

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[PaperEntity]> {
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        let result = try await AutomationService.shared.searchExternal(
            sources: source.externalSourceIDs,
            query: query,
            maxResults: maxResults
        )

        return .result(value: result.papers.map { PaperEntity(from: $0) })
    }
}

// MARK: - Search Category Intent

/// Search within a specific arXiv category.
@available(iOS 16.0, macOS 13.0, *)
public struct SearchCategoryIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Search arXiv Category"

    public static var description = IntentDescription(
        "Search for recent papers in an arXiv category.",
        categoryName: "Search"
    )

    @Parameter(title: "Category", description: "The arXiv category (e.g., astro-ph.CO, hep-th)")
    public var category: String

    public var automationCommand: AutomationCommand {
        .searchCategory(category: category)
    }

    public init() {}

    public init(category: String) {
        self.category = category
    }

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}

// MARK: - Show Search Intent

/// Navigate to the search view.
@available(iOS 16.0, macOS 13.0, *)
public struct ShowSearchIntent: AppIntent, AutomationIntent {

    public static var title: LocalizedStringResource = "Show Search"

    public static var description = IntentDescription(
        "Open the search view in imbib.",
        categoryName: "Navigation"
    )

    public var automationCommand: AutomationCommand {
        .navigate(target: .search)
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await performAutomation()
    }
}
