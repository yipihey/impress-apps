//
//  CollectionEntity.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//
//  AppEntity for collections, enabling rich Shortcuts integration (ADR-018).
//

import AppIntents
import Foundation

// MARK: - Collection Entity

/// AppEntity representing a collection in the library.
///
/// This enables rich Shortcuts integration:
/// - Collections can be selected from a list
/// - Collections can be passed between actions
@available(iOS 16.0, macOS 13.0, *)
public struct CollectionEntity: AppEntity {

    // MARK: - Type Display

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Collection"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) collections")
        )
    }

    // MARK: - Entity Query

    public static var defaultQuery = CollectionEntityQuery()

    // MARK: - Properties

    public let id: UUID
    public let name: String
    public let paperCount: Int
    public let isSmartCollection: Bool
    public let libraryName: String?

    // MARK: - Display Representation

    public var displayRepresentation: DisplayRepresentation {
        let subtitle: String
        if isSmartCollection {
            subtitle = "Smart Collection • \(paperCount) papers"
        } else {
            subtitle = "\(paperCount) papers"
        }

        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            image: isSmartCollection ? .init(systemName: "gearshape") : .init(systemName: "folder")
        )
    }

    // MARK: - Initialization

    public init(
        id: UUID,
        name: String,
        paperCount: Int,
        isSmartCollection: Bool,
        libraryName: String?
    ) {
        self.id = id
        self.name = name
        self.paperCount = paperCount
        self.isSmartCollection = isSmartCollection
        self.libraryName = libraryName
    }

    /// Create from CollectionResult.
    public init(from result: CollectionResult) {
        self.id = result.id
        self.name = result.name
        self.paperCount = result.paperCount
        self.isSmartCollection = result.isSmartCollection
        self.libraryName = result.libraryName
    }
}

// MARK: - Collection Entity Query

/// Query for finding collections by ID or search.
@available(iOS 16.0, macOS 13.0, *)
public struct CollectionEntityQuery: EntityQuery {

    public init() {}

    // MARK: - Entity Lookup

    public func entities(for identifiers: [UUID]) async throws -> [CollectionEntity] {
        let allCollections = try await AutomationService.shared.listCollections(libraryID: nil)
        return allCollections
            .filter { identifiers.contains($0.id) }
            .map { CollectionEntity(from: $0) }
    }

    // MARK: - Suggested Entities

    public func suggestedEntities() async throws -> [CollectionEntity] {
        let collections = try await AutomationService.shared.listCollections(libraryID: nil)
        return collections.prefix(10).map { CollectionEntity(from: $0) }
    }
}

// MARK: - Collection Entity String Query

/// Extended query supporting string-based search.
@available(iOS 16.0, macOS 13.0, *)
public struct CollectionEntityStringQuery: EntityStringQuery {

    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [CollectionEntity] {
        let allCollections = try await AutomationService.shared.listCollections(libraryID: nil)
        return allCollections
            .filter { identifiers.contains($0.id) }
            .map { CollectionEntity(from: $0) }
    }

    public func entities(matching string: String) async throws -> [CollectionEntity] {
        let allCollections = try await AutomationService.shared.listCollections(libraryID: nil)
        let lowercaseQuery = string.lowercased()
        return allCollections
            .filter { $0.name.lowercased().contains(lowercaseQuery) }
            .prefix(20)
            .map { CollectionEntity(from: $0) }
    }

    public func suggestedEntities() async throws -> [CollectionEntity] {
        let collections = try await AutomationService.shared.listCollections(libraryID: nil)
        return collections.prefix(10).map { CollectionEntity(from: $0) }
    }
}

// MARK: - Library Entity

/// AppEntity representing a library.
@available(iOS 16.0, macOS 13.0, *)
public struct LibraryEntity: AppEntity {

    // MARK: - Type Display

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Library"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) libraries")
        )
    }

    // MARK: - Entity Query

    public static var defaultQuery = LibraryEntityQuery()

    // MARK: - Properties

    public let id: UUID
    public let name: String
    public let paperCount: Int
    public let collectionCount: Int
    public let isDefault: Bool
    public let isInbox: Bool

    // MARK: - Display Representation

    public var displayRepresentation: DisplayRepresentation {
        var subtitle = "\(paperCount) papers"
        if collectionCount > 0 {
            subtitle += " • \(collectionCount) collections"
        }
        if isInbox {
            subtitle = "Inbox • " + subtitle
        }

        let imageName: String
        if isInbox {
            imageName = "tray"
        } else if isDefault {
            imageName = "star.fill"
        } else {
            imageName = "books.vertical"
        }

        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            image: .init(systemName: imageName)
        )
    }

    // MARK: - Initialization

    public init(
        id: UUID,
        name: String,
        paperCount: Int,
        collectionCount: Int,
        isDefault: Bool,
        isInbox: Bool
    ) {
        self.id = id
        self.name = name
        self.paperCount = paperCount
        self.collectionCount = collectionCount
        self.isDefault = isDefault
        self.isInbox = isInbox
    }

    /// Create from LibraryResult.
    public init(from result: LibraryResult) {
        self.id = result.id
        self.name = result.name
        self.paperCount = result.paperCount
        self.collectionCount = result.collectionCount
        self.isDefault = result.isDefault
        self.isInbox = result.isInbox
    }
}

// MARK: - Library Entity Query

/// Query for finding libraries by ID.
@available(iOS 16.0, macOS 13.0, *)
public struct LibraryEntityQuery: EntityQuery {

    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [LibraryEntity] {
        let allLibraries = try await AutomationService.shared.listLibraries()
        return allLibraries
            .filter { identifiers.contains($0.id) }
            .map { LibraryEntity(from: $0) }
    }

    public func suggestedEntities() async throws -> [LibraryEntity] {
        let libraries = try await AutomationService.shared.listLibraries()
        return libraries.map { LibraryEntity(from: $0) }
    }
}
