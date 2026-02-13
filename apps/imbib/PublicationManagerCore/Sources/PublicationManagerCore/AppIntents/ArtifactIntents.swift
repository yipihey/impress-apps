//
//  ArtifactIntents.swift
//  PublicationManagerCore
//
//  Siri Shortcuts intents for research artifact operations.
//

import AppIntents
import Foundation

// MARK: - Create Artifact Intent

/// Create a new research artifact.
@available(iOS 16.0, macOS 13.0, *)
public struct CreateArtifactIntent: AppIntent {

    public static let title: LocalizedStringResource = "Create Research Artifact"

    public static let description = IntentDescription(
        "Create a new research artifact in imbib. Artifacts capture non-paper items like notes, webpages, datasets, and presentations.",
        categoryName: "Artifacts"
    )

    @Parameter(title: "Type")
    public var artifactType: ArtifactTypeAppEnum

    @Parameter(title: "Title")
    public var title_param: String

    @Parameter(title: "Source URL", default: nil)
    public var sourceURL: String?

    @Parameter(title: "Notes", default: nil)
    public var notes: String?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<ArtifactEntity> {
        let artifact = RustStoreAdapter.shared.createArtifact(
            type: artifactType.toArtifactType,
            title: title_param,
            sourceURL: sourceURL,
            notes: notes
        )

        guard let artifact else {
            throw IntentError.executionFailed("Failed to create artifact")
        }

        return .result(value: ArtifactEntity(from: artifact))
    }
}

// MARK: - Search Artifacts Intent

/// Search research artifacts by query.
@available(iOS 16.0, macOS 13.0, *)
public struct SearchArtifactsIntent: AppIntent {

    public static let title: LocalizedStringResource = "Search Research Artifacts"

    public static let description = IntentDescription(
        "Search research artifacts in imbib by title, notes, or other metadata.",
        categoryName: "Artifacts"
    )

    @Parameter(title: "Query")
    public var query: String

    @Parameter(title: "Type Filter", default: nil)
    public var artifactType: ArtifactTypeAppEnum?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[ArtifactEntity]> {
        let type = artifactType?.toArtifactType
        let artifacts = RustStoreAdapter.shared.searchArtifacts(query: query, type: type)
        let entities = artifacts.prefix(20).map { ArtifactEntity(from: $0) }
        return .result(value: Array(entities))
    }
}

// MARK: - List Recent Artifacts Intent

/// List recently captured research artifacts.
@available(iOS 16.0, macOS 13.0, *)
public struct ListRecentArtifactsIntent: AppIntent {

    public static let title: LocalizedStringResource = "List Recent Artifacts"

    public static let description = IntentDescription(
        "List recently captured research artifacts, optionally filtered by type.",
        categoryName: "Artifacts"
    )

    @Parameter(title: "Type Filter", default: nil)
    public var artifactType: ArtifactTypeAppEnum?

    @Parameter(title: "Limit", default: 10)
    public var limit: Int

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[ArtifactEntity]> {
        let type = artifactType?.toArtifactType
        let artifacts = RustStoreAdapter.shared.listArtifacts(
            type: type,
            limit: UInt32(min(limit, 50))
        )
        let entities = artifacts.map { ArtifactEntity(from: $0) }
        return .result(value: entities)
    }
}

// MARK: - Open Artifact Intent

/// Open a research artifact in imbib.
@available(iOS 16.0, macOS 13.0, *)
public struct OpenArtifactIntent: AppIntent {

    public static let title: LocalizedStringResource = "Open Artifact"

    public static let description = IntentDescription(
        "Open a research artifact in imbib's detail view.",
        categoryName: "Artifacts"
    )

    public static let openAppWhenRun: Bool = true

    @Parameter(title: "Artifact")
    public var artifact: ArtifactEntity

    public init() {}

    public func perform() async throws -> some IntentResult {
        // Open via URL scheme
        let urlString = "imbib://artifact/\(artifact.id.uuidString)"
        if let url = URL(string: urlString) {
            _ = await URLSchemeHandler.shared.handle(url)
        }
        return .result()
    }
}
