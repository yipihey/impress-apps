//
//  ArtifactImportHandler.swift
//  PublicationManagerCore
//
//  Handles importing files as research artifacts with metadata extraction.
//

import Foundation
import OSLog
import CommonCrypto

/// Handles the import pipeline: receive source -> extract metadata -> commit.
public actor ArtifactImportHandler {

    /// Shared instance.
    public static let shared = ArtifactImportHandler()

    /// The directory where artifact files are stored.
    nonisolated private var artifactStorageURL: URL {
        let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.impress.suite"
        )
        let base = groupContainer ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Import a file as a research artifact.
    /// Copies the file to the shared artifacts directory and creates the artifact record.
    @MainActor
    public func importFile(
        at sourceURL: URL,
        type: ArtifactType? = nil,
        title: String? = nil,
        notes: String? = nil,
        tags: [String] = []
    ) async -> ResearchArtifact? {
        // Extract metadata
        var metadata = ArtifactMetadataExtractor.extractFromFile(url: sourceURL)

        // Override with provided values
        if let type { metadata.artifactType = type }
        if let title { metadata.title = title }
        if let notes { metadata.notes = notes }

        let finalTitle = metadata.title ?? sourceURL.deletingPathExtension().lastPathComponent

        // Copy file to artifacts storage
        let artifactID = UUID()
        let destDir = artifactStorageURL.appendingPathComponent(artifactID.uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let destURL = destDir.appendingPathComponent(sourceURL.lastPathComponent)

            // Start accessing security-scoped resource if needed
            let didStart = sourceURL.startAccessingSecurityScopedResource()
            defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }

            try FileManager.default.copyItem(at: sourceURL, to: destURL)

            // Compute file hash
            let fileHash = sha256(of: destURL)

            Logger.library.infoCapture(
                "Imported artifact file: \(sourceURL.lastPathComponent) -> \(destURL.path)",
                category: "artifacts"
            )

            // Create the artifact record
            let artifact = RustStoreAdapter.shared.createArtifact(
                type: metadata.artifactType,
                title: finalTitle,
                sourceURL: metadata.sourceURL,
                notes: metadata.notes,
                fileName: metadata.fileName,
                fileHash: fileHash,
                fileSize: metadata.fileSize,
                fileMimeType: metadata.fileMimeType,
                captureContext: metadata.eventName,
                originalAuthor: metadata.originalAuthor,
                tags: tags
            )

            return artifact
        } catch {
            Logger.library.errorCapture("Failed to import artifact file: \(error)", category: "artifacts")
            // Clean up partial directory
            try? FileManager.default.removeItem(at: destDir)
            return nil
        }
    }

    /// Import a URL as a webpage artifact.
    @MainActor
    public func importURL(
        _ url: URL,
        title: String? = nil,
        notes: String? = nil,
        tags: [String] = []
    ) async -> ResearchArtifact? {
        var metadata = await ArtifactMetadataExtractor.extractFromURL(url: url)

        if let title { metadata.title = title }
        if let notes { metadata.notes = notes }

        let finalTitle = metadata.title ?? url.absoluteString

        let artifact = RustStoreAdapter.shared.createArtifact(
            type: .webpage,
            title: finalTitle,
            sourceURL: url.absoluteString,
            notes: metadata.notes,
            originalAuthor: metadata.originalAuthor,
            tags: tags
        )

        return artifact
    }

    /// Create a quick note artifact.
    @MainActor
    public func createNote(
        title: String,
        notes: String,
        tags: [String] = []
    ) -> ResearchArtifact? {
        return RustStoreAdapter.shared.createArtifact(
            type: .note,
            title: title,
            notes: notes,
            tags: tags
        )
    }

    // MARK: - File Storage Helpers

    /// Get the storage URL for an artifact's files.
    nonisolated public func storageURL(for artifactID: UUID) -> URL {
        artifactStorageURL.appendingPathComponent(artifactID.uuidString, isDirectory: true)
    }

    /// Get the primary file URL for an artifact.
    nonisolated public func fileURL(for artifact: ResearchArtifact) -> URL? {
        guard let fileName = artifact.fileName else { return nil }
        let dir = storageURL(for: artifact.id)
        let url = dir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Private

    nonisolated private func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
