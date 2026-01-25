//
//  PaperEntity.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//
//  AppEntity for papers, enabling rich Shortcuts integration (ADR-018).
//

import AppIntents
import Foundation

// MARK: - Paper Entity

/// AppEntity representing a paper in the library.
///
/// This enables rich Shortcuts integration:
/// - Papers can be selected from a list
/// - Paper details can be displayed
/// - Papers can be passed between actions
@available(iOS 16.0, macOS 13.0, *)
public struct PaperEntity: AppEntity {

    // MARK: - Type Display

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Paper"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) papers")
        )
    }

    // MARK: - Entity Query

    public static var defaultQuery = PaperEntityQuery()

    // MARK: - Properties

    public let id: UUID
    public let citeKey: String
    public let title: String
    public let authors: String
    public let year: Int?
    public let venue: String?
    public let isRead: Bool
    public let hasPDF: Bool

    // MARK: - Display Representation

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(citeKey)",
            subtitle: "\(title)",
            image: hasPDF ? .init(systemName: "doc.fill") : .init(systemName: "doc")
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
        isRead: Bool,
        hasPDF: Bool
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.isRead = isRead
        self.hasPDF = hasPDF
    }

    /// Create from PaperResult.
    public init(from result: PaperResult) {
        self.id = result.id
        self.citeKey = result.citeKey
        self.title = result.title
        self.authors = result.authors.joined(separator: ", ")
        self.year = result.year
        self.venue = result.venue
        self.isRead = result.isRead
        self.hasPDF = result.hasPDF
    }
}

// MARK: - Paper Entity Query

/// Query for finding papers by ID or search.
@available(iOS 16.0, macOS 13.0, *)
public struct PaperEntityQuery: EntityQuery {

    public init() {}

    // MARK: - Entity Lookup

    public func entities(for identifiers: [UUID]) async throws -> [PaperEntity] {
        let paperIdentifiers = identifiers.map { PaperIdentifier.uuid($0) }
        let results = try await AutomationService.shared.getPapers(identifiers: paperIdentifiers)
        return results.map { PaperEntity(from: $0) }
    }

    // MARK: - Suggested Entities

    public func suggestedEntities() async throws -> [PaperEntity] {
        // Return recent unread papers as suggestions
        let filters = SearchFilters(isRead: false, limit: 10)
        let results = try await AutomationService.shared.searchLibrary(query: "", filters: filters)
        return results.map { PaperEntity(from: $0) }
    }
}

// MARK: - Paper Entity String Query

/// Extended query supporting string-based search.
@available(iOS 16.0, macOS 13.0, *)
public struct PaperEntityStringQuery: EntityStringQuery {

    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [PaperEntity] {
        let paperIdentifiers = identifiers.map { PaperIdentifier.uuid($0) }
        let results = try await AutomationService.shared.getPapers(identifiers: paperIdentifiers)
        return results.map { PaperEntity(from: $0) }
    }

    public func entities(matching string: String) async throws -> [PaperEntity] {
        let results = try await AutomationService.shared.searchLibrary(query: string, filters: SearchFilters(limit: 20))
        return results.map { PaperEntity(from: $0) }
    }

    public func suggestedEntities() async throws -> [PaperEntity] {
        let filters = SearchFilters(isRead: false, limit: 10)
        let results = try await AutomationService.shared.searchLibrary(query: "", filters: filters)
        return results.map { PaperEntity(from: $0) }
    }
}

// MARK: - Unread Papers Query

/// Query for finding unread papers.
@available(iOS 16.0, macOS 13.0, *)
public struct UnreadPapersQuery: EntityQuery {

    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [PaperEntity] {
        let paperIdentifiers = identifiers.map { PaperIdentifier.uuid($0) }
        let results = try await AutomationService.shared.getPapers(identifiers: paperIdentifiers)
        return results.map { PaperEntity(from: $0) }
    }

    public func suggestedEntities() async throws -> [PaperEntity] {
        let filters = SearchFilters(isRead: false, limit: 20)
        let results = try await AutomationService.shared.searchLibrary(query: "", filters: filters)
        return results.map { PaperEntity(from: $0) }
    }
}
