//
//  ImprintCitationIntents.swift
//  PublicationManagerCore
//
//  AppIntents for integration with imprint manuscript editor.
//  Provides citation search, BibTeX retrieval, and paper metadata access.
//

import AppIntents
import Foundation

// MARK: - Search Citations Intent

/// Search the imbib library for citations to use in imprint.
///
/// This intent returns actual paper data, enabling imprint to display
/// search results and allow users to insert citations.
@available(iOS 16.0, macOS 13.0, *)
public struct SearchCitationsIntent: AppIntent {

    public static var title: LocalizedStringResource = "Search Citations"

    public static var description = IntentDescription(
        "Search your imbib library for papers to cite in your manuscript.",
        categoryName: "Citations",
        searchKeywords: ["search", "citation", "paper", "reference", "imprint"]
    )

    public static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$query)") {
            \.$maxResults
        }
    }

    @Parameter(title: "Query", description: "Search query (title, author, cite key)")
    public var query: String

    @Parameter(title: "Max Results", description: "Maximum number of results", default: 20)
    public var maxResults: Int

    public init() {}

    public init(query: String, maxResults: Int = 20) {
        self.query = query
        self.maxResults = maxResults
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[ImprintPaperEntity]> {
        // Check if automation is enabled
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        // Search library
        let filters = SearchFilters(limit: maxResults)
        let papers = try await AutomationService.shared.searchLibrary(query: query, filters: filters)

        // Convert to imprint paper entities
        let entities = papers.prefix(maxResults).map { ImprintPaperEntity(from: $0) }

        return .result(value: Array(entities))
    }
}

// MARK: - Get BibTeX For Cite Keys Intent

/// Get BibTeX entries for specified cite keys.
///
/// This intent retrieves the BibTeX data for papers identified by their cite keys,
/// enabling imprint to generate a complete bibliography file.
@available(iOS 16.0, macOS 13.0, *)
public struct GetBibTeXForCiteKeysIntent: AppIntent {

    public static var title: LocalizedStringResource = "Get BibTeX for Cite Keys"

    public static var description = IntentDescription(
        "Get BibTeX entries for papers by their cite keys.",
        categoryName: "Citations",
        searchKeywords: ["bibtex", "citation", "export", "bibliography"]
    )

    public static var parameterSummary: some ParameterSummary {
        Summary("Get BibTeX for \(\.$citeKeys)")
    }

    @Parameter(title: "Cite Keys", description: "List of cite keys to fetch BibTeX for")
    public var citeKeys: [String]

    public init() {}

    public init(citeKeys: [String]) {
        self.citeKeys = citeKeys
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Check if automation is enabled
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        guard !citeKeys.isEmpty else {
            return .result(value: "")
        }

        // Build BibTeX string from found papers
        var bibtexEntries: [String] = []

        for citeKey in citeKeys {
            let identifier = PaperIdentifier.citeKey(citeKey)
            if let paper = try await AutomationService.shared.getPaper(identifier: identifier) {
                if !paper.bibtex.isEmpty {
                    bibtexEntries.append(paper.bibtex)
                }
            }
        }

        // Combine all entries with double newlines
        let combinedBibTeX = bibtexEntries.joined(separator: "\n\n")

        return .result(value: combinedBibTeX)
    }
}

// MARK: - Get Paper Metadata Intent

/// Get metadata for a specific paper by cite key.
///
/// This intent retrieves full metadata for a single paper, useful for
/// displaying paper details in imprint's citation view.
@available(iOS 16.0, macOS 13.0, *)
public struct GetPaperMetadataIntent: AppIntent {

    public static var title: LocalizedStringResource = "Get Paper Metadata"

    public static var description = IntentDescription(
        "Get metadata for a paper by its cite key.",
        categoryName: "Citations",
        searchKeywords: ["paper", "metadata", "citation", "details"]
    )

    public static var parameterSummary: some ParameterSummary {
        Summary("Get metadata for \(\.$citeKey)")
    }

    @Parameter(title: "Cite Key", description: "The cite key of the paper")
    public var citeKey: String

    public init() {}

    public init(citeKey: String) {
        self.citeKey = citeKey
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<ImprintPaperEntity?> {
        // Check if automation is enabled
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        let identifier = PaperIdentifier.citeKey(citeKey)
        guard let paper = try await AutomationService.shared.getPaper(identifier: identifier) else {
            return .result(value: nil)
        }

        return .result(value: ImprintPaperEntity(from: paper))
    }
}

// MARK: - Get BibTeX for Papers Intent

/// Get BibTeX entries for paper entities.
///
/// This intent accepts paper entities directly (from picker) and returns their BibTeX.
@available(iOS 16.0, macOS 13.0, *)
public struct GetBibTeXForPapersIntent: AppIntent {

    public static var title: LocalizedStringResource = "Get BibTeX for Papers"

    public static var description = IntentDescription(
        "Get BibTeX entries for selected papers.",
        categoryName: "Citations"
    )

    public static var parameterSummary: some ParameterSummary {
        Summary("Get BibTeX for \(\.$papers)")
    }

    @Parameter(title: "Papers", description: "Papers to get BibTeX for")
    public var papers: [ImprintPaperEntity]

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        let citeKeys = papers.map { $0.citeKey }
        var bibtexEntries: [String] = []

        for citeKey in citeKeys {
            let identifier = PaperIdentifier.citeKey(citeKey)
            if let paper = try await AutomationService.shared.getPaper(identifier: identifier) {
                if !paper.bibtex.isEmpty {
                    bibtexEntries.append(paper.bibtex)
                }
            }
        }

        return .result(value: bibtexEntries.joined(separator: "\n\n"))
    }
}

// MARK: - Imprint Paper Entity

/// Paper entity optimized for imprint integration.
///
/// Contains all fields needed for citation management in imprint,
/// including BibTeX data for bibliography generation.
@available(iOS 16.0, macOS 13.0, *)
public struct ImprintPaperEntity: AppEntity, Sendable {

    // MARK: - Type Display

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Citation"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) citations")
        )
    }

    // MARK: - Entity Query

    public static var defaultQuery = ImprintPaperEntityQuery()

    // MARK: - Properties

    public let id: UUID
    public let citeKey: String
    public let title: String
    public let authors: String
    public let year: Int?
    public let venue: String?
    public let abstract: String?
    public let bibtex: String?
    public let hasPDF: Bool
    public let isRead: Bool

    // MARK: - Display Representation

    public var displayRepresentation: DisplayRepresentation {
        var subtitle = title
        if let year = year {
            subtitle = "\(title) (\(year))"
        }

        return DisplayRepresentation(
            title: "\(citeKey)",
            subtitle: "\(subtitle)",
            image: hasPDF ? .init(systemName: "doc.text.fill") : .init(systemName: "doc.text")
        )
    }

    // MARK: - Initialization

    public init(
        id: UUID,
        citeKey: String,
        title: String,
        authors: String,
        year: Int?,
        venue: String?,
        abstract: String?,
        bibtex: String?,
        hasPDF: Bool,
        isRead: Bool
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.abstract = abstract
        self.bibtex = bibtex
        self.hasPDF = hasPDF
        self.isRead = isRead
    }

    /// Create from PaperResult.
    public init(from result: PaperResult) {
        self.id = result.id
        self.citeKey = result.citeKey
        self.title = result.title
        self.authors = result.authors.joined(separator: ", ")
        self.year = result.year
        self.venue = result.venue
        self.abstract = result.abstract
        self.bibtex = result.bibtex
        self.hasPDF = result.hasPDF
        self.isRead = result.isRead
    }
}

// MARK: - Imprint Paper Entity Query

/// Query for finding papers by ID or search.
@available(iOS 16.0, macOS 13.0, *)
public struct ImprintPaperEntityQuery: EntityQuery {

    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [ImprintPaperEntity] {
        let paperIdentifiers = identifiers.map { PaperIdentifier.uuid($0) }
        let results = try await AutomationService.shared.getPapers(identifiers: paperIdentifiers)
        return results.map { ImprintPaperEntity(from: $0) }
    }

    public func suggestedEntities() async throws -> [ImprintPaperEntity] {
        // Return recent papers as suggestions
        let filters = SearchFilters(limit: 10)
        let results = try await AutomationService.shared.searchLibrary(query: "", filters: filters)
        return results.map { ImprintPaperEntity(from: $0) }
    }
}

// MARK: - Imprint Paper Entity String Query

/// Extended query supporting string-based search for the Shortcuts picker.
@available(iOS 16.0, macOS 13.0, *)
public struct ImprintPaperEntityStringQuery: EntityStringQuery {

    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [ImprintPaperEntity] {
        let paperIdentifiers = identifiers.map { PaperIdentifier.uuid($0) }
        let results = try await AutomationService.shared.getPapers(identifiers: paperIdentifiers)
        return results.map { ImprintPaperEntity(from: $0) }
    }

    public func entities(matching string: String) async throws -> [ImprintPaperEntity] {
        let results = try await AutomationService.shared.searchLibrary(
            query: string,
            filters: SearchFilters(limit: 20)
        )
        return results.map { ImprintPaperEntity(from: $0) }
    }

    public func suggestedEntities() async throws -> [ImprintPaperEntity] {
        let filters = SearchFilters(limit: 10)
        let results = try await AutomationService.shared.searchLibrary(query: "", filters: filters)
        return results.map { ImprintPaperEntity(from: $0) }
    }
}
