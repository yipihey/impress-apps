import AppIntents
import Foundation

// MARK: - Figure Entity

@available(macOS 14.0, *)
public struct FigureEntity: AppEntity, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Figure"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) figures")
        )
    }

    public static var defaultQuery = FigureEntityQuery()

    public let id: UUID
    public let title: String
    public let datasetName: String
    public let format: String
    public let createdAt: Date
    public let modifiedAt: Date

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(datasetName)",
            image: .init(systemName: "chart.xyaxis.line")
        )
    }

    public init(id: UUID, title: String, datasetName: String = "", format: String = "png", createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.datasetName = datasetName
        self.format = format
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

// MARK: - Figure Entity Query

@available(macOS 14.0, *)
public struct FigureEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [FigureEntity] {
        guard let service = await ImploreIntentServiceLocator.service else { return [] }
        return try await service.figuresForIds(identifiers)
    }

    public func suggestedEntities() async throws -> [FigureEntity] {
        guard let service = await ImploreIntentServiceLocator.service else { return [] }
        return try await service.listFigures(dataset: nil)
    }
}

@available(macOS 14.0, *)
public struct FigureEntityStringQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [FigureEntity] {
        guard let service = await ImploreIntentServiceLocator.service else { return [] }
        return try await service.figuresForIds(identifiers)
    }

    public func entities(matching string: String) async throws -> [FigureEntity] {
        guard let service = await ImploreIntentServiceLocator.service else { return [] }
        return try await service.searchFiguresByTitle(string)
    }

    public func suggestedEntities() async throws -> [FigureEntity] {
        guard let service = await ImploreIntentServiceLocator.service else { return [] }
        return try await service.listFigures(dataset: nil)
    }
}
