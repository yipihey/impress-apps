import AppIntents
import Foundation

// MARK: - Veusz Plot Entity

/// AppEntity representation of a tracked Veusz plot inside an imprint manuscript.
///
/// Mirrors `VeuszPlotRef` (which lives in the imprint app target) but stays free
/// of app-target dependencies so it can compile inside the ImprintCore package
/// shared by intents and the system shortcuts surface.
@available(macOS 14.0, iOS 17.0, *)
public struct VeuszPlotEntity: AppEntity, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Veusz Plot"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) Veusz plots")
        )
    }

    public static var defaultQuery = VeuszPlotEntityQuery()

    public let id: UUID
    public let title: String
    public let documentID: UUID
    public let renderedFormat: String  // "svg" | "png" | "pdf"
    public let renderedRelativePath: String
    public let lastRenderedAt: Date?

    public var displayRepresentation: DisplayRepresentation {
        let subtitle: String
        if let lastRenderedAt {
            subtitle = "Rendered \(lastRenderedAt.formatted(.relative(presentation: .named)))"
        } else {
            subtitle = "Not yet rendered"
        }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "chart.xyaxis.line")
        )
    }

    public init(
        id: UUID,
        title: String,
        documentID: UUID,
        renderedFormat: String = "svg",
        renderedRelativePath: String,
        lastRenderedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.documentID = documentID
        self.renderedFormat = renderedFormat
        self.renderedRelativePath = renderedRelativePath
        self.lastRenderedAt = lastRenderedAt
    }
}

// MARK: - Queries

@available(macOS 14.0, iOS 17.0, *)
public struct VeuszPlotEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [VeuszPlotEntity] {
        guard let service = await ImprintIntentServiceLocator.service else { return [] }
        return try await service.veuszPlotsForIds(identifiers)
    }

    public func suggestedEntities() async throws -> [VeuszPlotEntity] {
        guard let service = await ImprintIntentServiceLocator.service else { return [] }
        return try await service.listVeuszPlots(documentID: nil)
    }
}

@available(macOS 14.0, iOS 17.0, *)
public struct VeuszPlotEntityStringQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [VeuszPlotEntity] {
        guard let service = await ImprintIntentServiceLocator.service else { return [] }
        return try await service.veuszPlotsForIds(identifiers)
    }

    public func entities(matching string: String) async throws -> [VeuszPlotEntity] {
        guard let service = await ImprintIntentServiceLocator.service else { return [] }
        return try await service.searchVeuszPlotsByTitle(string)
    }

    public func suggestedEntities() async throws -> [VeuszPlotEntity] {
        guard let service = await ImprintIntentServiceLocator.service else { return [] }
        return try await service.listVeuszPlots(documentID: nil)
    }
}
