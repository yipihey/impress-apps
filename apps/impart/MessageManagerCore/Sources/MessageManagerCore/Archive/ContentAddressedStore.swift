//
//  ContentAddressedStore.swift
//  MessageManagerCore
//
//  SHA256-based content-addressed storage for attachments.
//  Ensures deduplication and integrity of archived files.
//

import CommonCrypto
import Foundation

// MARK: - Content Hash

/// A SHA256 content hash.
public struct ContentHash: Hashable, Codable, Sendable {
    /// The hex-encoded SHA256 hash.
    public let hex: String

    /// Create from a hex string.
    public init(hex: String) {
        self.hex = hex.lowercased()
    }

    /// Compute hash from data.
    public init(data: Data) {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        self.hex = hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Compute hash from a file.
    public init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        self.init(data: data)
    }

    /// First 8 characters for short display.
    public var shortHex: String {
        String(hex.prefix(8))
    }
}

extension ContentHash: CustomStringConvertible {
    public var description: String {
        hex
    }
}

// MARK: - Stored File Info

/// Information about a file stored in the content-addressed store.
public struct StoredFileInfo: Codable, Sendable {
    /// Content hash.
    public let hash: ContentHash

    /// Original filename.
    public let originalFilename: String

    /// MIME type.
    public let mimeType: String

    /// File size in bytes.
    public let size: Int64

    /// When the file was stored.
    public let storedAt: Date

    /// File extension derived from filename or MIME type.
    public var fileExtension: String {
        let ext = (originalFilename as NSString).pathExtension
        if !ext.isEmpty {
            return ext
        }
        // Derive from MIME type
        return mimeTypeToExtension(mimeType)
    }

    /// Path within the content-addressed store.
    public var storagePath: String {
        "\(hash.hex).\(fileExtension)"
    }

    public init(
        hash: ContentHash,
        originalFilename: String,
        mimeType: String,
        size: Int64,
        storedAt: Date = Date()
    ) {
        self.hash = hash
        self.originalFilename = originalFilename
        self.mimeType = mimeType
        self.size = size
        self.storedAt = storedAt
    }
}

// MARK: - Content Addressed Store

/// Actor-based content-addressed storage for attachments.
public actor ContentAddressedStore {

    // MARK: - Properties

    /// Base directory for storage.
    private let baseDirectory: URL

    /// Index of stored files (hash -> info).
    private var index: [String: StoredFileInfo] = [:]

    /// Total size of stored files.
    private var totalSize: Int64 = 0

    // MARK: - Initialization

    /// Initialize with a base directory.
    public init(baseDirectory: URL) throws {
        self.baseDirectory = baseDirectory

        // Create directory if needed
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )

        // Load existing index
        try loadIndex()
    }

    // MARK: - Storage Operations

    /// Store data, returning its content hash.
    /// If the content already exists, returns the existing hash without re-storing.
    public func store(
        data: Data,
        originalFilename: String,
        mimeType: String
    ) throws -> StoredFileInfo {
        let hash = ContentHash(data: data)

        // Check if already stored
        if let existing = index[hash.hex] {
            return existing
        }

        // Determine extension
        let ext = (originalFilename as NSString).pathExtension.isEmpty
            ? mimeTypeToExtension(mimeType)
            : (originalFilename as NSString).pathExtension

        // Store the file
        let filename = "\(hash.hex).\(ext)"
        let fileURL = baseDirectory.appendingPathComponent(filename)
        try data.write(to: fileURL)

        // Create info
        let info = StoredFileInfo(
            hash: hash,
            originalFilename: originalFilename,
            mimeType: mimeType,
            size: Int64(data.count)
        )

        // Update index
        index[hash.hex] = info
        totalSize += info.size

        return info
    }

    /// Store a file from a URL.
    public func store(
        fileURL: URL,
        mimeType: String? = nil
    ) throws -> StoredFileInfo {
        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let mime = mimeType ?? mimeTypeFromExtension(fileURL.pathExtension)

        return try store(data: data, originalFilename: filename, mimeType: mime)
    }

    /// Retrieve data by hash.
    public func retrieve(hash: ContentHash) throws -> Data? {
        guard let info = index[hash.hex] else {
            return nil
        }

        let fileURL = baseDirectory.appendingPathComponent(info.storagePath)
        return try Data(contentsOf: fileURL)
    }

    /// Retrieve data by hash string.
    public func retrieve(hashHex: String) throws -> Data? {
        try retrieve(hash: ContentHash(hex: hashHex))
    }

    /// Check if content exists.
    public func exists(hash: ContentHash) -> Bool {
        index[hash.hex] != nil
    }

    /// Get info for a hash.
    public func info(hash: ContentHash) -> StoredFileInfo? {
        index[hash.hex]
    }

    /// Get all stored file infos.
    public func allFiles() -> [StoredFileInfo] {
        Array(index.values)
    }

    /// Get total storage size.
    public func storageSize() -> Int64 {
        totalSize
    }

    /// Get file count.
    public func fileCount() -> Int {
        index.count
    }

    // MARK: - Index Management

    /// Load the index from disk.
    private func loadIndex() throws {
        let indexURL = baseDirectory.appendingPathComponent("index.json")

        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            // Scan directory for existing files
            try scanDirectory()
            return
        }

        let data = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let infos = try decoder.decode([StoredFileInfo].self, from: data)

        for info in infos {
            index[info.hash.hex] = info
            totalSize += info.size
        }
    }

    /// Save the index to disk.
    public func saveIndex() throws {
        let indexURL = baseDirectory.appendingPathComponent("index.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(Array(index.values))
        try data.write(to: indexURL)
    }

    /// Scan directory for existing files.
    private func scanDirectory() throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        )

        for url in contents where url.pathExtension != "json" {
            let filename = url.lastPathComponent
            let parts = filename.split(separator: ".")

            guard parts.count >= 2 else { continue }

            let hashHex = String(parts[0])
            let ext = String(parts[1])

            // Verify hash
            guard let data = try? Data(contentsOf: url) else { continue }
            let computedHash = ContentHash(data: data)

            guard computedHash.hex == hashHex else {
                // Hash mismatch - file may be corrupted
                continue
            }

            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])

            let info = StoredFileInfo(
                hash: computedHash,
                originalFilename: filename,
                mimeType: mimeTypeFromExtension(ext),
                size: Int64(resourceValues.fileSize ?? 0),
                storedAt: resourceValues.creationDate ?? Date()
            )

            index[hashHex] = info
            totalSize += info.size
        }
    }

    // MARK: - Verification

    /// Verify integrity of all stored files.
    public func verifyIntegrity() async -> [String: Bool] {
        var results: [String: Bool] = [:]

        for (hashHex, info) in index {
            let fileURL = baseDirectory.appendingPathComponent(info.storagePath)

            guard let data = try? Data(contentsOf: fileURL) else {
                results[hashHex] = false
                continue
            }

            let computedHash = ContentHash(data: data)
            results[hashHex] = computedHash.hex == hashHex
        }

        return results
    }

    /// Remove files that fail integrity check.
    public func removeCorrupted() async throws -> Int {
        let integrity = await verifyIntegrity()
        var removed = 0

        for (hashHex, valid) in integrity where !valid {
            if let info = index[hashHex] {
                let fileURL = baseDirectory.appendingPathComponent(info.storagePath)
                try? FileManager.default.removeItem(at: fileURL)
                totalSize -= info.size
                index.removeValue(forKey: hashHex)
                removed += 1
            }
        }

        try saveIndex()
        return removed
    }
}

// MARK: - MIME Type Utilities

/// Map MIME type to file extension.
private func mimeTypeToExtension(_ mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "application/pdf": return "pdf"
    case "image/jpeg": return "jpg"
    case "image/png": return "png"
    case "image/gif": return "gif"
    case "text/plain": return "txt"
    case "text/html": return "html"
    case "text/markdown": return "md"
    case "application/json": return "json"
    case "application/zip": return "zip"
    case "application/x-bibtex": return "bib"
    default:
        // Try to extract from subtype
        let parts = mimeType.split(separator: "/")
        if parts.count == 2 {
            return String(parts[1])
        }
        return "bin"
    }
}

/// Map file extension to MIME type.
private func mimeTypeFromExtension(_ ext: String) -> String {
    switch ext.lowercased() {
    case "pdf": return "application/pdf"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "txt": return "text/plain"
    case "html", "htm": return "text/html"
    case "md", "markdown": return "text/markdown"
    case "json": return "application/json"
    case "zip": return "application/zip"
    case "bib": return "application/x-bibtex"
    default: return "application/octet-stream"
    }
}
