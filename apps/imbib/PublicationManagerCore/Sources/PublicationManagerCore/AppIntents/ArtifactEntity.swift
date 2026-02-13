//
//  ArtifactEntity.swift
//  PublicationManagerCore
//
//  AppEntity for research artifacts, enabling Shortcuts integration.
//

import AppIntents
import Foundation

// MARK: - Artifact Type Enum for App Intents

@available(iOS 16.0, macOS 13.0, *)
public enum ArtifactTypeAppEnum: String, AppEnum {
    case presentation = "impress/artifact/presentation"
    case poster = "impress/artifact/poster"
    case dataset = "impress/artifact/dataset"
    case webpage = "impress/artifact/webpage"
    case note = "impress/artifact/note"
    case media = "impress/artifact/media"
    case code = "impress/artifact/code"
    case general = "impress/artifact/general"

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Artifact Type")
    }

    public static var caseDisplayRepresentations: [ArtifactTypeAppEnum: DisplayRepresentation] {
        [
            .presentation: "Presentation",
            .poster: "Poster",
            .dataset: "Dataset",
            .webpage: "Web Page",
            .note: "Note",
            .media: "Media",
            .code: "Code",
            .general: "General",
        ]
    }

    public var toArtifactType: ArtifactType {
        ArtifactType(rawValue: rawValue) ?? .general
    }
}

// MARK: - Artifact Entity

/// AppEntity representing a research artifact.
@available(iOS 16.0, macOS 13.0, *)
public struct ArtifactEntity: AppEntity {

    // MARK: - Type Display

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Research Artifact"),
            numericFormat: LocalizedStringResource("\(placeholder: .int) artifacts")
        )
    }

    // MARK: - Entity Query

    public static let defaultQuery = ArtifactEntityQuery()

    // MARK: - Properties

    public let id: UUID
    public let title: String
    public let typeName: String
    public let typeSchema: String
    public let isRead: Bool
    public let isStarred: Bool
    public let created: Date

    // MARK: - Display Representation

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(typeName)",
            image: .init(systemName: iconForType)
        )
    }

    private var iconForType: String {
        ArtifactType(rawValue: typeSchema)?.iconName ?? "archivebox"
    }

    // MARK: - Initialization

    public init(from artifact: ResearchArtifact) {
        self.id = artifact.id
        self.title = artifact.title
        self.typeName = artifact.schema.displayName
        self.typeSchema = artifact.schema.rawValue
        self.isRead = artifact.isRead
        self.isStarred = artifact.isStarred
        self.created = artifact.created
    }
}

// MARK: - Artifact Entity Query

@available(iOS 16.0, macOS 13.0, *)
public struct ArtifactEntityQuery: EntityQuery {

    public init() {}

    @MainActor
    public func entities(for identifiers: [UUID]) async throws -> [ArtifactEntity] {
        identifiers.compactMap { id in
            guard let artifact = RustStoreAdapter.shared.getArtifact(id: id) else { return nil }
            return ArtifactEntity(from: artifact)
        }
    }

    @MainActor
    public func suggestedEntities() async throws -> [ArtifactEntity] {
        let artifacts = RustStoreAdapter.shared.listArtifacts(limit: 10)
        return artifacts.map { ArtifactEntity(from: $0) }
    }
}

// MARK: - Artifact Entity String Query

@available(iOS 16.0, macOS 13.0, *)
public struct ArtifactEntityStringQuery: EntityStringQuery {

    public init() {}

    @MainActor
    public func entities(for identifiers: [UUID]) async throws -> [ArtifactEntity] {
        identifiers.compactMap { id in
            guard let artifact = RustStoreAdapter.shared.getArtifact(id: id) else { return nil }
            return ArtifactEntity(from: artifact)
        }
    }

    @MainActor
    public func entities(matching string: String) async throws -> [ArtifactEntity] {
        let artifacts = RustStoreAdapter.shared.searchArtifacts(query: string)
        return artifacts.prefix(20).map { ArtifactEntity(from: $0) }
    }

    @MainActor
    public func suggestedEntities() async throws -> [ArtifactEntity] {
        let artifacts = RustStoreAdapter.shared.listArtifacts(limit: 10)
        return artifacts.map { ArtifactEntity(from: $0) }
    }
}
