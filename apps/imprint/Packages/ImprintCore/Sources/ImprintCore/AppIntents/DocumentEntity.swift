import AppIntents
import Foundation

// MARK: - Document Entity

@available(macOS 14.0, iOS 17.0, *)
public struct DocumentEntity: AppEntity, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Document"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) documents")
        )
    }

    public static var defaultQuery = DocumentEntityQuery()

    public let id: UUID
    public let title: String
    public let wordCount: Int
    public let lastModified: Date
    public let hasUnsavedChanges: Bool

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(wordCount) words",
            image: .init(systemName: "doc.text.fill")
        )
    }

    public init(id: UUID, title: String, wordCount: Int = 0, lastModified: Date = Date(), hasUnsavedChanges: Bool = false) {
        self.id = id
        self.title = title
        self.wordCount = wordCount
        self.lastModified = lastModified
        self.hasUnsavedChanges = hasUnsavedChanges
    }
}

// MARK: - Document Entity Query

@available(macOS 14.0, iOS 17.0, *)
public struct DocumentEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [DocumentEntity] {
        guard let service = await ImprintIntentServiceLocator.service else { return [] }
        return try await service.documentsForIds(identifiers)
    }

    public func suggestedEntities() async throws -> [DocumentEntity] {
        guard let service = await ImprintIntentServiceLocator.service else { return [] }
        return try await service.listDocuments(limit: 10)
    }
}

@available(macOS 14.0, iOS 17.0, *)
public struct DocumentEntityStringQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [DocumentEntity] {
        guard let service = await ImprintIntentServiceLocator.service else { return [] }
        return try await service.documentsForIds(identifiers)
    }

    public func entities(matching string: String) async throws -> [DocumentEntity] {
        guard let service = await ImprintIntentServiceLocator.service else { return [] }
        return try await service.searchDocumentsByTitle(string)
    }

    public func suggestedEntities() async throws -> [DocumentEntity] {
        guard let service = await ImprintIntentServiceLocator.service else { return [] }
        return try await service.listDocuments(limit: 10)
    }
}
