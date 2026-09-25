import Foundation
import ImploreCore
import ImploreRustCore
import ImpressLogging
import PublicationManagerCore
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
            backfillStoreIfNeeded()
        } catch {
            lastError = error
            logError("Failed to load library: \(error)", category: "library")
        }
    }

    /// Stage 0 (GUI unification): one-time backfill of the JSON library into
    /// the shared item store — folders become figure-collection items,
    /// figures carry their folder as envelope parent. JSON stays
    /// authoritative for this GUI until the store-read flag flips; the
    /// watermark in sync_metadata makes this a no-op on every later launch.
    private func backfillStoreIfNeeded() {
        let folders = library.folders.map {
            ImploreStoreAdapter.FolderBackfillRow(
                id: $0.id, name: $0.name,
                sortOrder: Int($0.sortOrder), isCollapsed: $0.collapsed)
        }
        let figures = library.figures.map {
            ImploreStoreAdapter.FigureBackfillRow(
                id: $0.id, title: $0.title, folderID: $0.folderId, format: "png")
        }
        if ImploreStoreAdapter.shared.migrateLibraryIfNeeded(
            folders: folders, figures: figures) {
            logInfo(
                "Backfilled \(figures.count) figures / \(folders.count) folders into the shared store",
                category: "library")
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
    @discardableResult
    public func addFigure(_ figure: LibraryFigure) -> ImploreStoreAdapter.FigureWrite {
        var newLibrary = library
        newLibrary.figures.append(figure)
        newLibrary.modifiedAt = ISO8601DateFormatter().string(from: Date())
        library = newLibrary
        saveLibrary()

        // Mirror into the shared store WITH its rendered artifact, so other
        // apps' plot panes and View tabs have an image to draw.
        return writeFigureToStore(figure, reason: "create")
    }

    /// The one path from a library figure to its store row + artifact
    /// (`ImploreStoreAdapter.storeFigure`), with the three-point trace.
    @discardableResult
    func writeFigureToStore(_ figure: LibraryFigure, reason: String) -> ImploreStoreAdapter.FigureWrite {
        logInfo(
            "figure \(reason) \(figure.id): rendering artifact (\(figure.viewStateSnapshot.utf8.count) B view state)",
            category: "figures")
        let write = ImploreStoreAdapter.shared.storeFigure(
            figureID: figure.id,
            title: figure.title,
            caption: nil,
            viewStateJSON: figure.viewStateSnapshot
        )
        announceStoreWrite(figureID: figure.id, structural: reason == "create")
        if let artifact = write.artifact {
            logInfo(
                "figure \(reason) \(figure.id): saved=\(write.saved) data_hash=\(artifact.dataHash.prefix(12)) \(artifact.width)x\(artifact.height) \(artifact.format)",
                category: "figures")
            if let released = write.releasedHash {
                logInfo("figure \(reason) \(figure.id): released superseded artifact \(released.prefix(12))", category: "figures")
            }
        } else {
            logError(
                "figure \(reason) \(figure.id): saved=\(write.saved) with NO artifact: \(write.renderError ?? "unknown")",
                category: "figures")
        }
        return write
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

        // The store row (and its artifact, unless another row names the same
        // bytes) goes too; deleting only the JSON entry orphaned the row.
        let deletion = ImploreStoreAdapter.shared.deleteFigure(figureID: id)
        if deletion.rowDeleted { announceStoreWrite(figureID: id, structural: true) }
        logInfo(
            "figure delete \(id): row=\(deletion.rowDeleted) data_hash=\(deletion.dataHash.map { String($0.prefix(12)) } ?? "none") blobReleased=\(deletion.blobReleased) exports=\(deletion.exportsRemoved)",
            category: "figures")
    }

    /// The adapter writes through its own store handle, so the chassis in
    /// THIS process (implore's View tab, a `plot` pane) would otherwise hear
    /// of it only through the cross-process Darwin note, after its coalesce
    /// window. Tell the chassis bus directly: a new or deleted row is
    /// structural, an edit names the figure.
    private func announceStoreWrite(figureID: String, structural: Bool) {
        let uuid = UUID(uuidString: figureID)
        RustStoreAdapter.shared.noteExternalMutation(
            structural: structural || uuid == nil,
            affectedIDs: uuid.map { [$0] },
            kind: .otherField)
    }

    /// Get a figure by ID
    public func figure(id: String) -> LibraryFigure? {
        library.figures.first { $0.id == id }
    }

    /// Update a figure
    @discardableResult
    public func updateFigure(_ figure: LibraryFigure) -> ImploreStoreAdapter.FigureWrite? {
        var newLibrary = library
        if let index = newLibrary.figures.firstIndex(where: { $0.id == figure.id }) {
            newLibrary.figures[index] = figure
            newLibrary.modifiedAt = ISO8601DateFormatter().string(from: Date())
            library = newLibrary
            saveLibrary()

            // Re-render: an edit is a new artifact (a new data_hash).
            return writeFigureToStore(figure, reason: "update")
        }
        return nil
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
            // Keep the store mirror's parent chain consistent for other apps.
            ImploreStoreAdapter.shared.setFigureFolder(figureID: id, folderID: folderId)
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

