import Foundation
import ImploreCore
import ImploreRustCore
import ImpressLogging
import SwiftUI

/// Manages the figure library persistence and operations.
///
/// This service handles saving, loading, and organizing figures
/// in the user's library.
@MainActor @Observable
public final class LibraryManager {
    /// Shared instance
    public static let shared = LibraryManager()

    /// The current library
    public private(set) var library: FigureLibrary

    /// Currently selected folder
    public var selectedFolderId: String?

    /// Currently selected figure
    public var selectedFigureId: String?

    /// Search query for filtering
    public var searchQuery: String = ""

    /// Whether the library is currently loading
    public private(set) var isLoading: Bool = false

    /// Error from last operation
    public var lastError: Error?

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

    /// Load the library from disk via Rust serde.
    public func loadLibrary() {
        isLoading = true
        defer { isLoading = false }

        guard FileManager.default.fileExists(atPath: libraryURL.path) else {
            return
        }

        do {
            library = try loadLibraryJson(path: libraryURL.path)
        } catch {
            lastError = error
            logError("Failed to load library: \(error)", category: "library")
        }
    }

    /// Save the library to disk via Rust serde.
    public func saveLibrary() {
        do {
            try saveLibraryJson(library: library, path: libraryURL.path)
        } catch {
            lastError = error
            logError("Failed to save library: \(error)", category: "library")
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

        // Mirror into the shared impress-core store so other apps can discover figures.
        ImploreStoreAdapter.shared.storeFigure(
            figureID: figure.id,
            format: "png",  // default; refined during actual export
            title: figure.title,
            caption: nil,
            assetData: figure.thumbnail,
            scriptHash: nil
        )
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

            // Sync updated metadata to shared impress-core store.
            ImploreStoreAdapter.shared.storeFigure(
                figureID: figure.id,
                format: "png",
                title: figure.title,
                caption: nil,
                assetData: figure.thumbnail,
                scriptHash: nil
            )
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

