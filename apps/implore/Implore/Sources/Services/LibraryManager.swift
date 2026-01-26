import Foundation
import ImploreCore
import SwiftUI

/// Manages the figure library persistence and operations.
///
/// This service handles saving, loading, and organizing figures
/// in the user's library.
@MainActor
public final class LibraryManager: ObservableObject {
    /// Shared instance
    public static let shared = LibraryManager()

    /// The current library
    @Published public private(set) var library: FigureLibrary

    /// Currently selected folder
    @Published public var selectedFolderId: String?

    /// Currently selected figure
    @Published public var selectedFigureId: String?

    /// Search query for filtering
    @Published public var searchQuery: String = ""

    /// Whether the library is currently loading
    @Published public private(set) var isLoading: Bool = false

    /// Error from last operation
    @Published public var lastError: Error?

    private let libraryURL: URL

    private init() {
        // Determine library storage location
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let imploreDir = appSupport.appendingPathComponent("implore", isDirectory: true)
        self.libraryURL = imploreDir.appendingPathComponent("library.json")

        // Initialize with empty or loaded library
        self.library = FigureLibrary(
            id: UUID().uuidString,
            name: "My Figures",
            figures: [],
            folders: [],
            createdAt: ISO8601DateFormatter().string(from: Date()),
            modifiedAt: ISO8601DateFormatter().string(from: Date())
        )

        // Load library if it exists
        loadLibrary()
    }

    /// Load the library from disk
    public func loadLibrary() {
        isLoading = true
        defer { isLoading = false }

        guard FileManager.default.fileExists(atPath: libraryURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: libraryURL)
            let decoder = JSONDecoder()
            library = try decoder.decode(FigureLibrary.self, from: data)
        } catch {
            lastError = error
            print("Failed to load library: \(error)")
        }
    }

    /// Save the library to disk
    public func saveLibrary() {
        do {
            // Ensure directory exists
            let directory = libraryURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(library)
            try data.write(to: libraryURL)
        } catch {
            lastError = error
            print("Failed to save library: \(error)")
        }
    }

    // MARK: - Figure Operations

    /// Add a new figure to the library
    public func addFigure(_ figure: LibraryFigure) {
        var newLibrary = library
        newLibrary.figures.append(figure)
        newLibrary.modifiedAt = ISO8601DateFormatter().string(from: Date())
        library = newLibrary
        saveLibrary()
    }

    /// Remove a figure from the library
    public func removeFigure(id: String) {
        var newLibrary = library
        newLibrary.figures.removeAll { $0.id == id }
        newLibrary.modifiedAt = ISO8601DateFormatter().string(from: Date())
        library = newLibrary
        saveLibrary()

        if selectedFigureId == id {
            selectedFigureId = nil
        }
    }

    /// Get a figure by ID
    public func figure(id: String) -> LibraryFigure? {
        library.figures.first { $0.id == id }
    }

    /// Update a figure
    public func updateFigure(_ figure: LibraryFigure) {
        var newLibrary = library
        if let index = newLibrary.figures.firstIndex(where: { $0.id == figure.id }) {
            newLibrary.figures[index] = figure
            newLibrary.modifiedAt = ISO8601DateFormatter().string(from: Date())
            library = newLibrary
            saveLibrary()
        }
    }

    // MARK: - Folder Operations

    /// Create a new folder
    public func createFolder(name: String) -> FigureFolder {
        let folder = FigureFolder(
            id: UUID().uuidString,
            name: name,
            figureIds: [],
            collapsed: false,
            sortOrder: Int32(library.folders.count)
        )

        var newLibrary = library
        newLibrary.folders.append(folder)
        newLibrary.modifiedAt = ISO8601DateFormatter().string(from: Date())
        library = newLibrary
        saveLibrary()

        return folder
    }

    /// Remove a folder
    public func removeFolder(id: String) {
        var newLibrary = library

        // Move all figures in this folder to unfiled
        for index in newLibrary.figures.indices {
            if newLibrary.figures[index].folderId == id {
                newLibrary.figures[index].folderId = nil
            }
        }

        newLibrary.folders.removeAll { $0.id == id }
        newLibrary.modifiedAt = ISO8601DateFormatter().string(from: Date())
        library = newLibrary
        saveLibrary()

        if selectedFolderId == id {
            selectedFolderId = nil
        }
    }

    /// Move a figure to a folder
    public func moveFigure(id: String, toFolder folderId: String?) {
        var newLibrary = library
        if let index = newLibrary.figures.firstIndex(where: { $0.id == id }) {
            newLibrary.figures[index].folderId = folderId
            newLibrary.modifiedAt = ISO8601DateFormatter().string(from: Date())
            library = newLibrary
            saveLibrary()
        }
    }

    /// Toggle folder collapsed state
    public func toggleFolderCollapsed(id: String) {
        var newLibrary = library
        if let index = newLibrary.folders.firstIndex(where: { $0.id == id }) {
            newLibrary.folders[index].collapsed.toggle()
            library = newLibrary
            saveLibrary()
        }
    }

    // MARK: - Filtered Views

    /// Figures that are not in any folder
    public var unfiledFigures: [LibraryFigure] {
        library.figures.filter { $0.folderId == nil }
    }

    /// Figures in a specific folder
    public func figures(inFolder folderId: String) -> [LibraryFigure] {
        library.figures.filter { $0.folderId == folderId }
    }

    /// Filtered figures based on search query
    public var filteredFigures: [LibraryFigure] {
        guard !searchQuery.isEmpty else {
            return library.figures
        }

        let query = searchQuery.lowercased()
        return library.figures.filter { figure in
            figure.title.lowercased().contains(query) ||
            figure.tags.contains { $0.lowercased().contains(query) }
        }
    }

    /// Figures with auto-update links
    public var autoUpdateFigures: [LibraryFigure] {
        library.figures.filter { figure in
            figure.imprintLinks.contains { $0.autoUpdate }
        }
    }
}

// MARK: - Codable Support for FigureLibrary

extension FigureLibrary: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, figures, folders, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            figures: try container.decode([LibraryFigure].self, forKey: .figures),
            folders: try container.decode([FigureFolder].self, forKey: .folders),
            createdAt: try container.decode(String.self, forKey: .createdAt),
            modifiedAt: try container.decode(String.self, forKey: .modifiedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(figures, forKey: .figures)
        try container.encode(folders, forKey: .folders)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}

extension LibraryFigure: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, thumbnail, sessionId, viewStateSnapshot
        case datasetSource, imprintLinks, tags, folderId, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            thumbnail: try container.decodeIfPresent(Data.self, forKey: .thumbnail),
            sessionId: try container.decode(String.self, forKey: .sessionId),
            viewStateSnapshot: try container.decode(String.self, forKey: .viewStateSnapshot),
            datasetSource: try container.decode(DatasetSource.self, forKey: .datasetSource),
            imprintLinks: try container.decode([ImprintLink].self, forKey: .imprintLinks),
            tags: try container.decode([String].self, forKey: .tags),
            folderId: try container.decodeIfPresent(String.self, forKey: .folderId),
            createdAt: try container.decode(String.self, forKey: .createdAt),
            modifiedAt: try container.decode(String.self, forKey: .modifiedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(viewStateSnapshot, forKey: .viewStateSnapshot)
        try container.encode(datasetSource, forKey: .datasetSource)
        try container.encode(imprintLinks, forKey: .imprintLinks)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(folderId, forKey: .folderId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}

extension FigureFolder: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, figureIds, collapsed, sortOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            figureIds: try container.decode([String].self, forKey: .figureIds),
            collapsed: try container.decode(Bool.self, forKey: .collapsed),
            sortOrder: try container.decode(Int32.self, forKey: .sortOrder)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(figureIds, forKey: .figureIds)
        try container.encode(collapsed, forKey: .collapsed)
        try container.encode(sortOrder, forKey: .sortOrder)
    }
}

extension ImprintLink: Codable {
    enum CodingKeys: String, CodingKey {
        case documentId, documentTitle, figureLabel, autoUpdate, lastSynced
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            documentId: try container.decode(String.self, forKey: .documentId),
            documentTitle: try container.decode(String.self, forKey: .documentTitle),
            figureLabel: try container.decode(String.self, forKey: .figureLabel),
            autoUpdate: try container.decode(Bool.self, forKey: .autoUpdate),
            lastSynced: try container.decodeIfPresent(String.self, forKey: .lastSynced)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(documentId, forKey: .documentId)
        try container.encode(documentTitle, forKey: .documentTitle)
        try container.encode(figureLabel, forKey: .figureLabel)
        try container.encode(autoUpdate, forKey: .autoUpdate)
        try container.encodeIfPresent(lastSynced, forKey: .lastSynced)
    }
}

extension DatasetSource: Codable {
    enum CodingKeys: String, CodingKey {
        case type, path, datasetPath, `extension`, delimiter, format, generatorId, paramsJson, generatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "hdf5":
            let path = try container.decode(String.self, forKey: .path)
            let datasetPath = try container.decode(String.self, forKey: .datasetPath)
            self = .hdf5(path: path, datasetPath: datasetPath)
        case "fits":
            let path = try container.decode(String.self, forKey: .path)
            let ext = try container.decode(UInt32.self, forKey: .extension)
            self = .fits(path: path, extension: ext)
        case "csv":
            let path = try container.decode(String.self, forKey: .path)
            let delimiter = try container.decodeIfPresent(String.self, forKey: .delimiter)
            self = .csv(path: path, delimiter: delimiter)
        case "parquet":
            let path = try container.decode(String.self, forKey: .path)
            self = .parquet(path: path)
        case "inMemory":
            let format = try container.decode(String.self, forKey: .format)
            self = .inMemory(format: format)
        case "generated":
            let generatorId = try container.decode(String.self, forKey: .generatorId)
            let paramsJson = try container.decode(String.self, forKey: .paramsJson)
            let generatedAt = try container.decode(String.self, forKey: .generatedAt)
            self = .generated(generatorId: generatorId, paramsJson: paramsJson, generatedAt: generatedAt)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown DatasetSource type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .hdf5(let path, let datasetPath):
            try container.encode("hdf5", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(datasetPath, forKey: .datasetPath)
        case .fits(let path, let ext):
            try container.encode("fits", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(ext, forKey: .extension)
        case .csv(let path, let delimiter):
            try container.encode("csv", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(delimiter, forKey: .delimiter)
        case .parquet(let path):
            try container.encode("parquet", forKey: .type)
            try container.encode(path, forKey: .path)
        case .inMemory(let format):
            try container.encode("inMemory", forKey: .type)
            try container.encode(format, forKey: .format)
        case .generated(let generatorId, let paramsJson, let generatedAt):
            try container.encode("generated", forKey: .type)
            try container.encode(generatorId, forKey: .generatorId)
            try container.encode(paramsJson, forKey: .paramsJson)
            try container.encode(generatedAt, forKey: .generatedAt)
        }
    }
}
