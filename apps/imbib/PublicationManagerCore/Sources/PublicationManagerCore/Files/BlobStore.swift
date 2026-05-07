import CryptoKit
import Foundation
import ImpressLogging
import OSLog

/// Content-addressed blob storage for the impress journal pipeline.
///
/// Reifies the convention documented in
/// `crates/impress-core/src/schemas/manuscript_section.rs:11-15`: large
/// content lives at `~/.local/share/impress/content/{prefix}/{prefix2}/{sha256}.{ext}`.
///
/// Used by the journal snapshot job (per ADR-0011 D4) to store compiled
/// manuscript PDFs and `.tar.zst` source archives. The two-level path
/// prefix keeps any directory's child count well below filesystem limits
/// even at large scale.
///
/// Garbage collection (`unreferencedSweep`) moves orphan blobs into a
/// dated `.tombstones/` folder rather than deleting them, so a researcher
/// can always recover an accidentally-orphaned snapshot.
public actor BlobStore {

    // MARK: - Singleton

    /// Default singleton rooted at the platform's content-addressed
    /// location: `~/.local/share/impress/content/` on macOS,
    /// `<AppSupport>/impress/content/` on iOS (the bundle pipeline is
    /// macOS-only, but BlobStore is part of PublicationManagerCore which
    /// is shared between platforms).
    public static let shared: BlobStore = BlobStore(rootURL: defaultRootURL())

    /// Compute the default content-addressed root for the current platform.
    public static func defaultRootURL() -> URL {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("impress", isDirectory: true)
            .appendingPathComponent("content", isDirectory: true)
        #else
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("impress", isDirectory: true)
            .appendingPathComponent("content", isDirectory: true)
        #endif
    }

    // MARK: - Properties

    /// Root directory for the content-addressed store.
    public let rootURL: URL

    private let tombstonesDirName = ".tombstones"

    // MARK: - Init

    /// Construct a BlobStore rooted at the given URL. Used by tests with a
    /// temporary directory; production code uses ``shared``.
    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    // MARK: - Store

    /// Store `data` at the content-addressed path for its SHA-256.
    ///
    /// Idempotent: if the blob already exists at the computed path, no write
    /// occurs. Returns the hash and final URL in either case.
    ///
    /// - Parameters:
    ///   - data: The bytes to store.
    ///   - ext: File extension WITHOUT the leading dot (e.g. `"pdf"`,
    ///          `"tar.zst"`).
    /// - Returns: Tuple of `(sha256, url)` for the stored blob.
    public func store(data: Data, ext: String) async throws -> (sha256: String, url: URL) {
        let sha256 = Self.computeSHA256(data: data)
        let url = blobURL(sha256: sha256, ext: ext)

        if FileManager.default.fileExists(atPath: url.path) {
            Logger.files.debugCapture(
                "BlobStore: blob already exists at \(url.lastPathComponent); skipping write",
                category: "blobstore"
            )
            return (sha256, url)
        }

        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            Logger.files.errorCapture(
                "BlobStore: failed to create directory \(parent.path): \(error)",
                category: "blobstore"
            )
            throw BlobStoreError.cannotCreateDirectory(parent)
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.files.errorCapture(
                "BlobStore: write failed for \(url.path): \(error)",
                category: "blobstore"
            )
            throw BlobStoreError.writeFailed(url, error)
        }

        Logger.files.infoCapture(
            "BlobStore: stored \(data.count) bytes as \(sha256.prefix(12))....\(ext)",
            category: "blobstore"
        )
        return (sha256, url)
    }

    // MARK: - Locate

    /// Return the URL for an existing blob, or nil if it does not exist.
    public func locate(sha256: String, ext: String) -> URL? {
        let url = blobURL(sha256: sha256, ext: ext)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Sweep

    /// Move blobs whose SHA-256 is NOT in `referencedHashes` into
    /// `{rootURL}/.tombstones/{date}/`. Does not delete: tombstoned files
    /// remain on disk for later recovery (or eventual manual cleanup).
    ///
    /// - Parameter referencedHashes: The set of SHA-256 strings still
    ///   referenced by items in the store. Anything else is orphan.
    /// - Returns: URLs of the tombstoned files (their new locations).
    public func unreferencedSweep(referencedHashes: Set<String>) async throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootURL.path) else { return [] }

        let tombstoneRoot = rootURL.appendingPathComponent(tombstonesDirName, isDirectory: true)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let dateFolder = tombstoneRoot.appendingPathComponent(
            dateFormatter.string(from: Date()),
            isDirectory: true
        )

        var moved: [URL] = []
        let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            // Skip anything inside the tombstones tree itself.
            if url.path.hasPrefix(tombstoneRoot.path) { continue }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            // Filename pattern: {sha256}.{ext} — strip first `.` to recover hash.
            let filename = url.lastPathComponent
            guard let sha = Self.parseSHA256(fromFilename: filename) else {
                Logger.files.warningCapture(
                    "BlobStore: skipping unrecognized filename during sweep: \(filename)",
                    category: "blobstore"
                )
                continue
            }
            if referencedHashes.contains(sha) { continue }

            // Lazily create the date folder on first move.
            if moved.isEmpty {
                try fm.createDirectory(at: dateFolder, withIntermediateDirectories: true)
            }

            let destination = dateFolder.appendingPathComponent(filename)
            do {
                // If a blob with the same name was tombstoned today already
                // (rare; SHA collision is impossible), append a UUID suffix.
                let finalDestination: URL
                if fm.fileExists(atPath: destination.path) {
                    finalDestination = dateFolder.appendingPathComponent(
                        "\(filename).\(UUID().uuidString)"
                    )
                } else {
                    finalDestination = destination
                }
                try fm.moveItem(at: url, to: finalDestination)
                moved.append(finalDestination)
            } catch {
                Logger.files.errorCapture(
                    "BlobStore: failed to tombstone \(url.path): \(error)",
                    category: "blobstore"
                )
                throw BlobStoreError.writeFailed(destination, error)
            }
        }

        Logger.files.infoCapture(
            "BlobStore: sweep moved \(moved.count) unreferenced blob(s) to tombstones",
            category: "blobstore"
        )
        return moved
    }

    // MARK: - Path helpers

    /// Compute the on-disk URL for `{sha256}.{ext}` using two-level prefixing.
    private func blobURL(sha256: String, ext: String) -> URL {
        precondition(sha256.count == 64, "expected 64-char SHA-256, got \(sha256.count)")
        let prefix1 = String(sha256.prefix(2))
        let prefix2 = String(sha256.dropFirst(2).prefix(2))
        return rootURL
            .appendingPathComponent(prefix1, isDirectory: true)
            .appendingPathComponent(prefix2, isDirectory: true)
            .appendingPathComponent("\(sha256).\(ext)")
    }

    /// Compute SHA-256 over `data` and return as lowercase hex.
    /// Synchronous on-disk lookup using the default content-addressed
    /// path (`~/.local/share/impress/content/{sha[0:2]}/{sha[2:4]}/{sha}.{ext}`).
    /// Used by `ManuscriptBridge.getRevisionPDFURL` to resolve PDFs written
    /// by impel (JournalSnapshotJob) without requiring the actor's async
    /// path. Returns nil if the file does not exist.
    nonisolated public static func staticLocateOnDisk(sha256: String, ext: String) -> URL? {
        guard sha256.count == 64 else { return nil }
        let prefix1 = String(sha256.prefix(2))
        let prefix2 = String(sha256.dropFirst(2).prefix(2))
        let url = defaultRootURL()
            .appendingPathComponent(prefix1, isDirectory: true)
            .appendingPathComponent(prefix2, isDirectory: true)
            .appendingPathComponent("\(sha256).\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated public static func computeSHA256(data: Data) -> String {
        SHA256.hash(data: data)
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }

    /// Recover the SHA-256 from a blob filename of the form `{sha256}.{ext}`.
    /// Handles compound extensions like `tar.zst` correctly: the hash is
    /// everything before the FIRST dot.
    nonisolated public static func parseSHA256(fromFilename filename: String) -> String? {
        guard let dotIndex = filename.firstIndex(of: ".") else { return nil }
        let candidate = String(filename[..<dotIndex])
        return candidate.count == 64 && candidate.allSatisfy(\.isHexDigit) ? candidate : nil
    }
}

// MARK: - Errors

/// Errors that can occur during BlobStore operations.
public enum BlobStoreError: Error, LocalizedError {
    case cannotCreateDirectory(URL)
    case writeFailed(URL, Error)
    case invalidFilename(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory(let url):
            return "BlobStore: cannot create directory at \(url.path)"
        case .writeFailed(let url, let error):
            return "BlobStore: write failed for \(url.lastPathComponent): \(error.localizedDescription)"
        case .invalidFilename(let name):
            return "BlobStore: invalid blob filename \(name) (expected {sha256}.{ext})"
        }
    }
}

// MARK: - Hex digit helper

private extension Character {
    var isHexDigit: Bool {
        switch self {
        case "0"..."9", "a"..."f", "A"..."F": return true
        default: return false
        }
    }
}
