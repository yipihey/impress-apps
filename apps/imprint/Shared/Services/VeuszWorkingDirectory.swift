import Foundation

/// Maps an imprint document's UUID to a stable on-disk working directory inside
/// the app container, used to expose `.vsz` files (and their rendered outputs)
/// to Veusz as real paths.
///
/// SwiftUI's `FileDocument` reads `.imprint` packages as in-memory `FileWrapper`
/// trees, but Veusz can only edit real files on disk. This helper materializes
/// the `figures/` portion of the package into
/// `<container>/Application Support/imprint/manuscripts/<docID>/figures/` so
/// the `VeuszPlotStore` (and the watcher) can hand stable URLs to Veusz, and
/// the next save can read the (possibly Veusz-modified) bytes back.
struct VeuszWorkingDirectory {

    /// Subdirectory inside the figures dir where rendered output (svg/png/pdf) lives.
    /// Kept as a sibling of the .vsz sources so relative paths from the manuscript
    /// (`figures/plot.svg`) work without an extra directory level.
    /// Empty string means "same directory as the .vsz files".
    static let renderedSubdirectoryName = ""

    let fileManager: FileManager
    let containerRootProvider: () -> URL

    init(
        fileManager: FileManager = .default,
        containerRootProvider: @escaping () -> URL = VeuszWorkingDirectory.defaultContainerRoot
    ) {
        self.fileManager = fileManager
        self.containerRootProvider = containerRootProvider
    }

    /// Default container root: Application Support / imprint / manuscripts.
    /// Inside a sandboxed app this resolves to the container's Application Support.
    static func defaultContainerRoot() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appending(path: "imprint/manuscripts", directoryHint: .isDirectory)
    }

    /// On-disk directory for a document's figures. Creates the directory if missing.
    func figuresDirectory(forDocumentID documentID: UUID) throws -> URL {
        let dir = containerRootProvider()
            .appending(path: documentID.uuidString, directoryHint: .isDirectory)
            .appending(path: "figures", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write each entry from `figureFiles` to the working directory, replacing any
    /// existing file with the same name. Files not present in `figureFiles` are
    /// left alone — callers that want a clean slate should call `clear` first.
    @discardableResult
    func materializeFigures(_ figureFiles: [String: Data], for documentID: UUID) throws -> URL {
        let dir = try figuresDirectory(forDocumentID: documentID)
        for (name, data) in figureFiles {
            let dest = dir.appending(path: name)
            try data.write(to: dest, options: .atomic)
        }
        return dir
    }

    /// Read every regular file under the working directory back into a `[name: Data]`
    /// dictionary so the document save path can re-wrap the figures/ FileWrapper.
    func readFigures(for documentID: UUID) throws -> [String: Data] {
        let dir = try figuresDirectory(forDocumentID: documentID)
        var result: [String: Data] = [:]
        let contents = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        for url in contents {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            result[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return result
    }

    /// URL for a named file inside the document's figures directory. Does not check existence.
    func fileURL(named name: String, forDocumentID documentID: UUID) throws -> URL {
        try figuresDirectory(forDocumentID: documentID).appending(path: name)
    }

    /// Remove the document's working directory and everything in it.
    func clear(documentID: UUID) throws {
        let docRoot = containerRootProvider().appending(path: documentID.uuidString, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: docRoot.path) {
            try fileManager.removeItem(at: docRoot)
        }
    }
}
