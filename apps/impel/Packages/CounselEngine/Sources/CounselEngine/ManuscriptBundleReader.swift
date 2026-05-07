//
//  ManuscriptBundleReader.swift
//  CounselEngine
//
//  Phase 8.3: extracts a `.tar.zst` manuscript bundle from the
//  content-addressed blob root (matching imbib's BlobStore convention)
//  to a per-process cached temp directory, returning the extraction
//  URL and parsed manifest.
//
//  The reader keeps a per-instance cache so consecutive calls for the
//  same SHA reuse the same extraction directory. The cache is opaque to
//  callers — they should not assume the path persists across process
//  restarts. For long-lived consumers (e.g. RO-Crate exports) the
//  expected pattern is: read once, copy what you need, forget.
//

import Foundation
import OSLog
import ImpressLogging

private let bundleReaderLogger = Logger(subsystem: "com.impress.impel", category: "bundle-reader")

/// Errors raised by the bundle reader.
public enum BundleReaderError: Error, LocalizedError, Sendable {
    case archiveNotFound(sha256: String)
    case manifestMissing(URL)
    case extractionFailed(exitCode: Int32, stderr: String)
    case manifestInvalid(BundleManifestError)
    case ioError(Error)

    public var errorDescription: String? {
        switch self {
        case .archiveNotFound(let sha):
            return "ManuscriptBundleReader: no .tar.zst at SHA \(sha.prefix(12))…"
        case .manifestMissing(let url):
            return "ManuscriptBundleReader: manifest.json missing in extracted bundle at \(url.path)"
        case .extractionFailed(let code, let stderr):
            return "ManuscriptBundleReader: tar extraction failed (exit \(code)): \(stderr)"
        case .manifestInvalid(let inner):
            return "ManuscriptBundleReader: manifest invalid: \(inner.localizedDescription)"
        case .ioError(let e):
            return "ManuscriptBundleReader: I/O error: \(e.localizedDescription)"
        }
    }
}

/// The result of a successful bundle read.
public struct BundleReadResult: Sendable {
    public let sha256: String
    public let extractedURL: URL
    public let manifest: ManuscriptBundleManifest
}

public actor ManuscriptBundleReader {

    private let blobRootURL: URL
    private let extractionRoot: URL
    private var cache: [String: BundleReadResult] = [:]

    public init(
        blobRootURL: URL = ManuscriptBundleBuilder.defaultBlobRoot,
        extractionRoot: URL? = nil
    ) {
        self.blobRootURL = blobRootURL
        self.extractionRoot =
            extractionRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("impress-bundle-cache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.extractionRoot,
            withIntermediateDirectories: true
        )
    }

    /// Read a bundle by its SHA-256, extracting it on first call and
    /// reusing the same directory on subsequent calls.
    public func read(sha256: String) throws -> BundleReadResult {
        if let cached = cache[sha256] {
            return cached
        }

        let archiveURL = blobURL(sha256: sha256, ext: "tar.zst")
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw BundleReaderError.archiveNotFound(sha256: sha256)
        }

        let extractDir = extractionRoot.appendingPathComponent(sha256, isDirectory: true)
        if !FileManager.default.fileExists(atPath: extractDir.path) {
            try FileManager.default.createDirectory(
                at: extractDir,
                withIntermediateDirectories: true
            )
            try runTarExtract(archiveURL: archiveURL, intoDir: extractDir)
        }

        let manifestURL = extractDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BundleReaderError.manifestMissing(extractDir)
        }
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw BundleReaderError.ioError(error)
        }
        let manifest: ManuscriptBundleManifest
        do {
            manifest = try ManuscriptBundleManifest.parse(manifestData)
        } catch let e as BundleManifestError {
            throw BundleReaderError.manifestInvalid(e)
        } catch {
            throw BundleReaderError.ioError(error)
        }

        let result = BundleReadResult(
            sha256: sha256,
            extractedURL: extractDir,
            manifest: manifest
        )
        cache[sha256] = result
        bundleReaderLogger.infoCapture(
            "ManuscriptBundleReader: extracted \(sha256.prefix(12))… → \(extractDir.path) (\(manifest.entries.count) entries)",
            category: "bundles"
        )
        return result
    }

    /// Resolve a single entry's URL within an extracted bundle. Returns
    /// nil if the entry is not in the manifest or the file is missing.
    public func entryURL(sha256: String, path: String) throws -> URL? {
        let result = try read(sha256: sha256)
        guard result.manifest.entries.contains(where: { $0.path == path }) else {
            return nil
        }
        let url = result.extractedURL.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Drop the cache entry (and on-disk extraction) for a given SHA.
    /// The next read re-extracts.
    public func evict(sha256: String) {
        cache.removeValue(forKey: sha256)
        let extractDir = extractionRoot.appendingPathComponent(sha256, isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
    }

    /// Clear the entire reader cache (and all extracted dirs under
    /// `extractionRoot`). Tests use this to enforce a clean slate.
    public func clearCache() {
        cache.removeAll()
        try? FileManager.default.removeItem(at: extractionRoot)
        try? FileManager.default.createDirectory(
            at: extractionRoot,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Helpers

    private func runTarExtract(archiveURL: URL, intoDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "--zstd",
            "-x",
            "-f", archiveURL.path,
            "-C", intoDir.path,
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "(unreadable)"
            throw BundleReaderError.extractionFailed(
                exitCode: process.terminationStatus,
                stderr: stderr
            )
        }
    }

    nonisolated private func blobURL(sha256: String, ext: String) -> URL {
        precondition(sha256.count == 64, "expected 64-char SHA-256")
        let prefix1 = String(sha256.prefix(2))
        let prefix2 = String(sha256.dropFirst(2).prefix(2))
        return blobRootURL
            .appendingPathComponent(prefix1, isDirectory: true)
            .appendingPathComponent(prefix2, isDirectory: true)
            .appendingPathComponent("\(sha256).\(ext)")
    }
}
