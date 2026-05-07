//
//  ManuscriptBundleBuilder.swift
//  CounselEngine
//
//  Phase 8.3: builds a `.tar.zst` manuscript bundle from a directory tree
//  (or a single file) and stores it content-addressed in the blob root,
//  identical to imbib's BlobStore convention. Returns a Result carrying
//  the SHA-256, on-disk URL, parsed manifest, and archive size.
//
//  Determinism: file mtimes are normalised to a fixed UTC epoch in a
//  staging copy, the file list is sorted, and tar runs against the
//  staging copy so identical inputs produce identical archive bytes for
//  a given user account. Cross-account determinism is out of scope for
//  v1 (would require uid/gid override which macOS bsdtar lacks in
//  create mode).
//

import CryptoKit
import Foundation
import Darwin
import OSLog
import ImpressLogging

private let bundleBuilderLogger = Logger(subsystem: "com.impress.impel", category: "bundle-builder")

/// Result of building a bundle.
public struct BundleBuildResult: Sendable {
    public let sha256: String
    public let archiveURL: URL
    public let manifest: ManuscriptBundleManifest
    public let archiveSize: Int
}

/// Errors raised by the bundle builder.
public enum BundleBuilderError: Error, LocalizedError, Sendable {
    case directoryNotFound(URL)
    case fileNotFound(URL)
    case noEntriesAfterExclude(URL)
    case mainSourceNotFound(String)
    case mainSourceNotFile(String)
    case ambiguousMainSource(candidates: [String])
    case stagingFailed(String)
    case tarFailed(exitCode: Int32, stderr: String)
    case ioError(Error)

    public var errorDescription: String? {
        switch self {
        case .directoryNotFound(let u):
            return "ManuscriptBundleBuilder: directory not found at \(u.path)"
        case .fileNotFound(let u):
            return "ManuscriptBundleBuilder: file not found at \(u.path)"
        case .noEntriesAfterExclude(let u):
            return "ManuscriptBundleBuilder: \(u.path) contained no files after applying excludes"
        case .mainSourceNotFound(let p):
            return "ManuscriptBundleBuilder: requested main_source \"\(p)\" not present"
        case .mainSourceNotFile(let p):
            return "ManuscriptBundleBuilder: main_source \"\(p)\" is not a regular file"
        case .ambiguousMainSource(let candidates):
            let list = candidates.joined(separator: ", ")
            return "ManuscriptBundleBuilder: could not infer main_source; candidates: [\(list)] — pass `mainSource` explicitly"
        case .stagingFailed(let s):
            return "ManuscriptBundleBuilder: staging failed: \(s)"
        case .tarFailed(let code, let stderr):
            return "ManuscriptBundleBuilder: tar failed (exit \(code)): \(stderr)"
        case .ioError(let e):
            return "ManuscriptBundleBuilder: I/O error: \(e.localizedDescription)"
        }
    }
}

public actor ManuscriptBundleBuilder {

    public struct Options: Sendable {
        public var mainSource: String?
        public var sourceFormat: BundleSourceFormat?
        public var engine: BundleCompileEngine?
        public var extraExcludes: [String]
        public var compressionLevel: Int

        public init(
            mainSource: String? = nil,
            sourceFormat: BundleSourceFormat? = nil,
            engine: BundleCompileEngine? = nil,
            extraExcludes: [String] = [],
            compressionLevel: Int = 9
        ) {
            self.mainSource = mainSource
            self.sourceFormat = sourceFormat
            self.engine = engine
            self.extraExcludes = extraExcludes
            self.compressionLevel = compressionLevel
        }
    }

    private let blobRootURL: URL

    public init(blobRootURL: URL = ManuscriptBundleBuilder.defaultBlobRoot) {
        self.blobRootURL = blobRootURL
    }

    /// Default content-addressed blob root, matching imbib's BlobStore.
    public static var defaultBlobRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("impress", isDirectory: true)
            .appendingPathComponent("content", isDirectory: true)
    }

    /// Default exclude globs applied to every directory build (in addition
    /// to `options.extraExcludes`). Patterns are basename-matched unless
    /// they contain a slash.
    public static let defaultExcludeGlobs: [String] = [
        "*.aux", "*.log", "*.synctex.gz", "*.toc", "*.out",
        "*.fls", "*.fdb_latexmk", "*.bbl-toc", "*.run.xml",
        "_minted-*", "auto", ".git", ".DS_Store",
        "node_modules", ".vscode", ".idea",
    ]

    // MARK: - Build (directory)

    public func buildFromDirectory(
        _ dir: URL,
        options: Options = Options()
    ) async throws -> BundleBuildResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw BundleBuilderError.directoryNotFound(dir)
        }

        let excludeGlobs = Self.defaultExcludeGlobs + options.extraExcludes
        let allEntries = try walkAndClassify(rootDir: dir, excludeGlobs: excludeGlobs)
        guard !allEntries.isEmpty else {
            throw BundleBuilderError.noEntriesAfterExclude(dir)
        }

        let mainSourcePath = try resolveMainSource(
            requested: options.mainSource,
            entries: allEntries
        )

        // Re-classify the main entry's role.
        var entries = allEntries
        if let idx = entries.firstIndex(where: { $0.path == mainSourcePath }) {
            entries[idx] = BundleEntry(path: mainSourcePath, role: .main)
        }
        entries.sort { $0.path < $1.path }

        let format = options.sourceFormat ?? Self.inferFormat(fromPath: mainSourcePath)
        let engine = options.engine ?? Self.defaultEngine(forFormat: format)

        let manifest = ManuscriptBundleManifest(
            mainSource: mainSourcePath,
            sourceFormat: format,
            entries: entries,
            compile: BundleCompileSpec(engine: engine),
            excludeGlobs: excludeGlobs.sorted()
        )
        try manifest.validate()

        let archiveData = try await packDirectory(
            sourceDir: dir,
            entries: entries,
            manifest: manifest,
            compressionLevel: options.compressionLevel
        )

        return try storeArchive(data: archiveData, manifest: manifest)
    }

    // MARK: - Build (single file)

    public func buildFromSingleFile(
        _ file: URL,
        format: BundleSourceFormat? = nil,
        engine: BundleCompileEngine? = nil
    ) async throws -> BundleBuildResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else {
            throw BundleBuilderError.fileNotFound(file)
        }

        let basename = file.lastPathComponent
        let resolvedFormat = format ?? Self.inferFormat(fromPath: basename)
        let resolvedEngine = engine ?? Self.defaultEngine(forFormat: resolvedFormat)

        let entries = [BundleEntry(path: basename, role: .main)]
        let manifest = ManuscriptBundleManifest(
            mainSource: basename,
            sourceFormat: resolvedFormat,
            entries: entries,
            compile: BundleCompileSpec(engine: resolvedEngine),
            excludeGlobs: []
        )
        try manifest.validate()

        // Stage just the one file in a temp parent dir, then pack.
        let tempParent = try makeTempDirectory(prefix: "impress-bundle-stage-")
        defer { try? FileManager.default.removeItem(at: tempParent) }
        let stagedFile = tempParent.appendingPathComponent(basename)
        try fm.copyItem(at: file, to: stagedFile)

        let archiveData = try await packDirectory(
            sourceDir: tempParent,
            entries: entries,
            manifest: manifest,
            compressionLevel: 9
        )
        return try storeArchive(data: archiveData, manifest: manifest)
    }

    // MARK: - Walk + classify

    private func walkAndClassify(
        rootDir: URL,
        excludeGlobs: [String]
    ) throws -> [BundleEntry] {
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        let rootPath = rootDir.standardizedFileURL.path
        var collected: [BundleEntry] = []

        guard let enumerator = fm.enumerator(
            at: rootDir,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        while let url = enumerator.nextObject() as? URL {
            let standardized = url.standardizedFileURL.path
            let relative = String(standardized.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative.isEmpty { continue }

            // Match excludes against the relative path AND any path component.
            if Self.shouldExclude(relativePath: relative, globs: excludeGlobs) {
                // If a directory matches, skip its contents.
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try? url.resourceValues(forKeys: resourceKeys)
            if values?.isRegularFile != true { continue }

            let role = Self.roleForPath(relative)
            collected.append(BundleEntry(path: relative, role: role))
        }
        return collected
    }

    static func shouldExclude(relativePath: String, globs: [String]) -> Bool {
        let basename = (relativePath as NSString).lastPathComponent
        for glob in globs {
            if glob.contains("/") {
                // Match against the full relative path.
                if fnmatchHelper(glob, relativePath) { return true }
            } else {
                // Match against basename or any path component.
                let components = relativePath.split(separator: "/").map(String.init)
                if components.contains(where: { fnmatchHelper(glob, $0) }) {
                    return true
                }
                if fnmatchHelper(glob, basename) { return true }
            }
        }
        return false
    }

    static func fnmatchHelper(_ pattern: String, _ subject: String) -> Bool {
        pattern.withCString { p in
            subject.withCString { s in
                fnmatch(p, s, 0) == 0
            }
        }
    }

    static func roleForPath(_ path: String) -> BundleEntryRole {
        let lower = path.lowercased()
        let basename = (path as NSString).lastPathComponent.lowercased()
        let ext = (basename as NSString).pathExtension

        if lower.hasPrefix("figures/") || lower.hasPrefix("images/") || lower.hasPrefix("img/") {
            return .figure
        }
        if lower.hasPrefix("supplements/") || lower.hasPrefix("supplementary/") {
            return .supplement
        }
        if lower.hasPrefix("chapters/") || lower.hasPrefix("sections/") {
            return .chapter
        }
        if ["bib", "bbl"].contains(ext) {
            return .bibliography
        }
        if ["png", "jpg", "jpeg", "gif", "svg", "eps", "tiff", "tif", "bmp", "webp"].contains(ext) {
            return .figure
        }
        if ["cls", "sty", "ttf", "otf", "fd"].contains(ext) {
            return .aux
        }
        if basename.hasPrefix("appendix") {
            return .supplement
        }
        return .aux
    }

    // MARK: - Main source inference

    private func resolveMainSource(
        requested: String?,
        entries: [BundleEntry]
    ) throws -> String {
        if let req = requested {
            guard entries.contains(where: { $0.path == req }) else {
                throw BundleBuilderError.mainSourceNotFound(req)
            }
            return req
        }

        // Prefer canonical names at the bundle root.
        let canonicalNames = [
            "main.tex", "paper.tex", "manuscript.tex", "ms.tex",
            "main.typ", "paper.typ", "manuscript.typ", "ms.typ",
            "main.md", "paper.md", "README.md", "index.md",
            "index.html",
        ]
        for canonical in canonicalNames {
            if entries.contains(where: { $0.path == canonical }) {
                return canonical
            }
        }

        // Otherwise, prefer single root-level source files in priority order.
        let rootSourceExtensions: [String] = ["tex", "typ", "md", "html"]
        for ext in rootSourceExtensions {
            let rootMatches = entries.filter { entry -> Bool in
                let p = entry.path
                let isRoot = !p.contains("/")
                let pathExt = (p as NSString).pathExtension.lowercased()
                return isRoot && pathExt == ext
            }
            if rootMatches.count == 1 {
                return rootMatches[0].path
            }
            if rootMatches.count > 1 {
                throw BundleBuilderError.ambiguousMainSource(
                    candidates: rootMatches.map(\.path)
                )
            }
        }

        // No root-level source file; fall back to scanning sub-dirs.
        for ext in rootSourceExtensions {
            let matches = entries.filter { ($0.path as NSString).pathExtension.lowercased() == ext }
            if matches.count == 1 {
                return matches[0].path
            }
            if matches.count > 1 {
                throw BundleBuilderError.ambiguousMainSource(
                    candidates: matches.map(\.path)
                )
            }
        }

        throw BundleBuilderError.mainSourceNotFound("(no source file detected)")
    }

    static func inferFormat(fromPath path: String) -> BundleSourceFormat {
        switch (path as NSString).pathExtension.lowercased() {
        case "tex": return .tex
        case "typ": return .typst
        case "md", "markdown": return .markdown
        case "html", "htm": return .html
        default: return .tex
        }
    }

    static func defaultEngine(forFormat format: BundleSourceFormat) -> BundleCompileEngine {
        switch format {
        case .tex: return .pdflatex
        case .typst: return .typst
        case .markdown, .html: return .none
        }
    }

    // MARK: - Pack directory → archive bytes

    /// The fixed-epoch mtime stamped on every staged file for deterministic
    /// archive bytes. 2020-01-01 00:00:00 UTC.
    private static let canonicalMTime: timespec = {
        var ts = timespec()
        ts.tv_sec = 1_577_836_800 // 2020-01-01T00:00:00Z
        ts.tv_nsec = 0
        return ts
    }()

    private func packDirectory(
        sourceDir: URL,
        entries: [BundleEntry],
        manifest: ManuscriptBundleManifest,
        compressionLevel: Int
    ) async throws -> Data {
        let staging = try makeTempDirectory(prefix: "impress-bundle-pack-")
        defer { try? FileManager.default.removeItem(at: staging) }

        // Copy each entry into staging, preserving relative path.
        for entry in entries {
            let src = sourceDir.appendingPathComponent(entry.path)
            let dst = staging.appendingPathComponent(entry.path)
            let dstDir = dst.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: dstDir,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: src, to: dst)
        }

        // Write canonical manifest.json into staging root.
        let manifestData = try manifest.canonicalJSON()
        let manifestURL = staging.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: .atomic)

        // Normalise mtime on all staged files (and dirs).
        try normaliseMTimes(in: staging)

        // Build the sorted file list for tar, including manifest.json.
        var allPaths = entries.map(\.path)
        allPaths.append("manifest.json")
        allPaths.sort()

        let archiveURL = staging
            .deletingLastPathComponent()
            .appendingPathComponent("\(staging.lastPathComponent).tar.zst")
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        try runTar(
            stagingDir: staging,
            sortedPaths: allPaths,
            outputURL: archiveURL,
            compressionLevel: compressionLevel
        )

        return try Data(contentsOf: archiveURL)
    }

    private func normaliseMTimes(in dir: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }

        var ts = [timespec](repeating: Self.canonicalMTime, count: 2)

        // Set mtime on all enumerated items.
        while let url = enumerator.nextObject() as? URL {
            url.path.withCString { path in
                _ = utimensat(AT_FDCWD, path, &ts, 0)
            }
        }
        // And on the staging root itself.
        dir.path.withCString { path in
            _ = utimensat(AT_FDCWD, path, &ts, 0)
        }
    }

    private func runTar(
        stagingDir: URL,
        sortedPaths: [String],
        outputURL: URL,
        compressionLevel: Int
    ) throws {
        let fileListURL = stagingDir
            .deletingLastPathComponent()
            .appendingPathComponent("\(stagingDir.lastPathComponent).filelist.txt")
        defer { try? FileManager.default.removeItem(at: fileListURL) }
        let listContent = sortedPaths.joined(separator: "\n") + "\n"
        try listContent.write(to: fileListURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "--zstd",
            "--options", "zstd:compression-level=\(compressionLevel)",
            "-C", stagingDir.path,
            "-T", fileListURL.path,
            "-cf", outputURL.path,
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe() // discard stdout

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "(unreadable)"
            throw BundleBuilderError.tarFailed(
                exitCode: process.terminationStatus,
                stderr: stderr
            )
        }
    }

    // MARK: - Store

    private func storeArchive(
        data: Data,
        manifest: ManuscriptBundleManifest
    ) throws -> BundleBuildResult {
        let sha = computeSHA256(of: data)
        let url = blobURL(sha256: sha, ext: "tar.zst")

        if !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            bundleBuilderLogger.infoCapture(
                "ManuscriptBundleBuilder: stored \(data.count) bytes as \(sha.prefix(12))....tar.zst",
                category: "bundles"
            )
        } else {
            bundleBuilderLogger.debugCapture(
                "ManuscriptBundleBuilder: bundle already in blob root: \(sha.prefix(12))…",
                category: "bundles"
            )
        }

        return BundleBuildResult(
            sha256: sha,
            archiveURL: url,
            manifest: manifest,
            archiveSize: data.count
        )
    }

    // MARK: - Helpers

    nonisolated private func blobURL(sha256: String, ext: String) -> URL {
        precondition(sha256.count == 64, "expected 64-char SHA-256")
        let prefix1 = String(sha256.prefix(2))
        let prefix2 = String(sha256.dropFirst(2).prefix(2))
        return blobRootURL
            .appendingPathComponent(prefix1, isDirectory: true)
            .appendingPathComponent(prefix2, isDirectory: true)
            .appendingPathComponent("\(sha256).\(ext)")
    }

    nonisolated private func makeTempDirectory(prefix: String) throws -> URL {
        let tempBase = FileManager.default.temporaryDirectory
        let dir = tempBase.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private func computeSHA256(of data: Data) -> String {
        SHA256.hash(data: data)
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}
