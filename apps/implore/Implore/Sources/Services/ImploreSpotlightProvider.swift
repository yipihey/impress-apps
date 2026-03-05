import CoreSpotlight
import Foundation
import ImpressSpotlight
import UniformTypeIdentifiers

/// Adapts implore's figures for Spotlight indexing.
///
/// Reads from `LibraryManager`'s JSON-backed figure library and converts
/// `LibraryFigure` entries into `SpotlightItem`s for system Spotlight.
public struct ImploreSpotlightProvider: SpotlightItemProvider {
    public let domain = SpotlightDomain.figure
    public let legacyDomains = ["com.implore.figure"]

    public init() {}

    @MainActor
    public func allItemIDs() async -> Set<UUID> {
        let figures = LibraryManager.shared.library.figures
        var ids = Set<UUID>()
        for figure in figures {
            if let uuid = UUID(uuidString: figure.id) {
                ids.insert(uuid)
            }
        }
        return ids
    }

    @MainActor
    public func spotlightItems(for ids: [UUID]) async -> [any SpotlightItem] {
        let figures = LibraryManager.shared.library.figures
        let figuresByID = Dictionary(
            figures.compactMap { fig -> (UUID, LibraryFigure)? in
                guard let uuid = UUID(uuidString: fig.id) else { return nil }
                return (uuid, fig)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return ids.compactMap { id -> (any SpotlightItem)? in
            guard let figure = figuresByID[id] else { return nil }
            return FigureSpotlightItem(
                id: id,
                title: figure.title,
                tags: figure.tags,
                datasetDescription: figure.datasetSource.spotlightDescription
            )
        }
    }
}

// MARK: - Figure → SpotlightItem

struct FigureSpotlightItem: SpotlightItem {
    let spotlightID: UUID
    let spotlightDomain: String
    let spotlightAttributeSet: CSSearchableItemAttributeSet

    init(id: UUID, title: String, tags: [String], datasetDescription: String?) {
        self.spotlightID = id
        self.spotlightDomain = SpotlightDomain.figure

        let attrs = CSSearchableItemAttributeSet(contentType: .image)
        attrs.title = title
        attrs.displayName = title
        attrs.keywords = tags
        attrs.contentDescription = datasetDescription
        attrs.url = URL(string: "implore://open/figure/\(id.uuidString)")

        self.spotlightAttributeSet = attrs
    }
}

// MARK: - DatasetSource Description

import ImploreCore

extension DatasetSource {
    /// A human-readable description for Spotlight content description.
    var spotlightDescription: String? {
        switch self {
        case .hdf5(let path, let datasetPath):
            return "HDF5: \(URL(fileURLWithPath: path).lastPathComponent) → \(datasetPath)"
        case .fits(let path, let ext):
            return "FITS: \(URL(fileURLWithPath: path).lastPathComponent) [ext \(ext)]"
        case .csv(let path, _):
            return "CSV: \(URL(fileURLWithPath: path).lastPathComponent)"
        case .parquet(let path):
            return "Parquet: \(URL(fileURLWithPath: path).lastPathComponent)"
        case .inMemory(let format):
            return "In-memory (\(format))"
        case .generated(let generatorId, _, _):
            return "Generated: \(generatorId)"
        }
    }
}
