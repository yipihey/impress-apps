import Foundation

/// Maps a manuscript's UUID to a stable on-disk working directory under the
/// app-group container, used to expose figures (`.vsz` sources + rendered
/// outputs) to Veusz as real paths and to materialize the manuscript body
/// at toolchain-invocation time (LaTeX compile, Veusz render, export).
///
/// In the impress-wide unified store, the manuscript body lives inside the
/// SQLite item's payload (`body_content`). Toolchains still need a path,
/// so callers ask `materialize(manuscriptID:body:format:)` for a fresh
/// `.tmp/main.{typ|tex}` next to `figures/`, then call
/// `clear(materializedFor:)` in a `defer` once the toolchain returns.
///
/// Layout under `<group container>/Library/Application Support/impress/manuscripts/<id>/`:
/// ```
/// figures/        .vsz sources + rendered outputs (durable; written by Veusz)
/// .build/        LaTeX intermediate artifacts (cache; safe to delete)
/// .tmp/          ephemeral; render-time body materialization (cleared after use)
/// ```
///
/// Generalises the per-document `VeuszWorkingDirectory` that this replaces.
struct ManuscriptWorkingDirectory {

    /// Subdirectory inside the manuscript dir where rendered figure output
    /// (svg/png/pdf) lives — kept as a sibling of the .vsz sources so
    /// `\includegraphics{figures/plot.svg}` resolves without an extra
    /// directory level.
    static let figuresSubdirectoryName = "figures"

    /// Subdirectory inside the manuscript dir where the LaTeX toolchain
    /// caches intermediates. Safe to delete; recreated on next compile.
    static let buildSubdirectoryName = ".build"

    /// Subdirectory used for ephemeral render-time body materialization.
    /// Contents are not durable — cleared after every toolchain invocation.
    static let tmpSubdirectoryName = ".tmp"

    let fileManager: FileManager
    let containerRootProvider: () -> URL

    init(
        fileManager: FileManager = .default,
        containerRootProvider: @escaping () -> URL = ManuscriptWorkingDirectory.defaultContainerRoot
    ) {
        self.fileManager = fileManager
        self.containerRootProvider = containerRootProvider
    }

    /// Default container root: the app-group container's Application Support,
    /// under `impress/manuscripts/`. Shared across the suite so other apps
    /// can read manuscript figures without a cross-app round-trip.
    ///
    /// Falls back to the per-app Application Support when the app-group
    /// container is unavailable (UI tests, headless contexts).
    static func defaultContainerRoot() -> URL {
        let groupID = "group.com.impress.suite"
        if let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) {
            return groupContainer
                .appending(path: "Library/Application Support/impress/manuscripts",
                           directoryHint: .isDirectory)
        }
        // Fallback (UI tests, sandbox-disabled contexts): use per-app
        // Application Support so the rest of the code still works.
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appending(path: "impress/manuscripts", directoryHint: .isDirectory)
    }

    // MARK: - Directory shape

    /// The manuscript's top-level working directory. Creates it if missing.
    func manuscriptDirectory(for manuscriptID: UUID) throws -> URL {
        let dir = containerRootProvider()
            .appending(path: manuscriptID.uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// On-disk directory for figure sources and rendered outputs. Creates it
    /// if missing. Veusz reads/writes the .vsz files here directly.
    func figuresDirectory(forManuscriptID manuscriptID: UUID) throws -> URL {
        let dir = try manuscriptDirectory(for: manuscriptID)
            .appending(path: Self.figuresSubdirectoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// On-disk directory for LaTeX build artifacts. Creates it if missing.
    func buildDirectory(forManuscriptID manuscriptID: UUID) throws -> URL {
        let dir = try manuscriptDirectory(for: manuscriptID)
            .appending(path: Self.buildSubdirectoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// On-disk directory for ephemeral body materialization. Creates it if missing.
    func tmpDirectory(forManuscriptID manuscriptID: UUID) throws -> URL {
        let dir = try manuscriptDirectory(for: manuscriptID)
            .appending(path: Self.tmpSubdirectoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Body materialization (render-time)

    /// Materialize a manuscript's body bytes into `.tmp/main.{typ|tex}` so a
    /// toolchain that needs a real file path can find it.
    ///
    /// Returns the URL of the written file. Callers should treat this as a
    /// one-shot path: invoke the toolchain, then call `clear(materializedFor:)`
    /// (typically in a `defer`) so the next invocation gets a fresh copy.
    ///
    /// `format` selects the extension: `"typst"` → `main.typ`, `"latex"` (or
    /// any other value) → `main.tex`.
    @discardableResult
    func materialize(
        body: String,
        forManuscriptID manuscriptID: UUID,
        format: String
    ) throws -> URL {
        let dir = try tmpDirectory(forManuscriptID: manuscriptID)
        let fileName = (format == "typst") ? "main.typ" : "main.tex"
        let destination = dir.appending(path: fileName)
        try body.data(using: .utf8)?.write(to: destination, options: .atomic)
        return destination
    }

    /// Remove the manuscript's `.tmp/` directory after a toolchain invocation
    /// returns. Safe to call when the directory does not exist.
    func clear(materializedFor manuscriptID: UUID) {
        let dir = containerRootProvider()
            .appending(path: manuscriptID.uuidString, directoryHint: .isDirectory)
            .appending(path: Self.tmpSubdirectoryName, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: dir.path) {
            try? fileManager.removeItem(at: dir)
        }
    }

    // MARK: - Figure file I/O (shared with VeuszPlotStore)

    /// Write each entry from `figureFiles` to the figures directory, replacing
    /// any existing file with the same name. Files not present in
    /// `figureFiles` are left alone — callers that want a clean slate should
    /// call `clear(manuscriptID:)` first.
    @discardableResult
    func materializeFigures(
        _ figureFiles: [String: Data],
        forManuscriptID manuscriptID: UUID
    ) throws -> URL {
        let dir = try figuresDirectory(forManuscriptID: manuscriptID)
        for (name, data) in figureFiles {
            let dest = dir.appending(path: name)
            try data.write(to: dest, options: .atomic)
        }
        return dir
    }

    /// Read every regular file under the figures directory into a `[name: Data]`
    /// dictionary. Used by the export pipeline (assembling a `.imprint` bundle
    /// or a standalone `.tex` project).
    func readFigures(forManuscriptID manuscriptID: UUID) throws -> [String: Data] {
        let dir = try figuresDirectory(forManuscriptID: manuscriptID)
        var result: [String: Data] = [:]
        let contents = try fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        for url in contents {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            result[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return result
    }

    /// URL for a named file inside the manuscript's figures directory. Does
    /// not check existence — callers handle missing files themselves.
    func figureFileURL(named name: String, forManuscriptID manuscriptID: UUID) throws -> URL {
        try figuresDirectory(forManuscriptID: manuscriptID).appending(path: name)
    }

    // MARK: - Deletion

    /// Remove the manuscript's entire working directory (figures, build cache,
    /// any `.tmp/` slot). Idempotent: safe when the directory doesn't exist.
    func clear(manuscriptID: UUID) {
        let dir = containerRootProvider()
            .appending(path: manuscriptID.uuidString, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: dir.path) {
            try? fileManager.removeItem(at: dir)
        }
    }
}
