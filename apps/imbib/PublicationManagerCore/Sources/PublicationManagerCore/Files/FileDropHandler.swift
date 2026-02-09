//
//  FileDropHandler.swift
//  PublicationManagerCore
//

import Foundation
import UniformTypeIdentifiers
import OSLog
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

// MARK: - File Drop Handler

/// Handles drag-and-drop file imports for publications.
///
/// Used by both the Info panel attachment section and list row drop targets.
/// Extracts URLs from dropped items and imports them as attachments.
@MainActor
@Observable
public final class FileDropHandler {

    // MARK: - Accepted Types

    /// UTTypes accepted for file drops.
    public static let acceptedTypes: [UTType] = [
        .pdf,
        .image,
        .fileURL,
        .data
    ]

    // MARK: - State

    private let attachmentManager: AttachmentManager

    /// Progress of multi-file import (current, total)
    public var importProgress: (current: Int, total: Int)?

    /// Whether import is in progress
    public var isImporting: Bool = false

    /// Last error that occurred
    public var lastError: Error?

    /// Pending duplicate that needs user confirmation
    public var pendingDuplicate: PendingDuplicateInfo?

    // MARK: - Initialization

    public init(attachmentManager: AttachmentManager = .shared) {
        self.attachmentManager = attachmentManager
    }

    // MARK: - Drop Handling

    /// Validate whether a drop can be accepted.
    public func validateDrop(info: DropInfo) -> Bool {
        for type in Self.acceptedTypes {
            if info.hasItemsConforming(to: [type]) {
                return true
            }
        }
        return false
    }

    /// Handle a drop operation by extracting URLs and importing files.
    @discardableResult
    public func handleDrop(
        info: DropInfo,
        for publicationId: UUID,
        in libraryId: UUID?
    ) -> Bool {
        Logger.files.infoCapture("Handling file drop for \(publicationId)", category: "files")

        let providers = info.itemProviders(for: Self.acceptedTypes)
        guard !providers.isEmpty else {
            Logger.files.warningCapture("No valid items in drop", category: "files")
            return false
        }

        Task {
            await importFromProviders(providers, for: publicationId, in: libraryId)
        }

        return true
    }

    /// Handle drop from NSItemProviders directly (for programmatic use).
    public func handleDrop(
        providers: [NSItemProvider],
        for publicationId: UUID,
        in libraryId: UUID?
    ) async {
        await importFromProviders(providers, for: publicationId, in: libraryId)
    }

    // MARK: - Import Logic

    /// Extract URLs and import files from NSItemProviders.
    private func importFromProviders(
        _ providers: [NSItemProvider],
        for publicationId: UUID,
        in libraryId: UUID?
    ) async {
        isImporting = true
        lastError = nil

        var urls: [URL] = []

        for provider in providers {
            if let url = await extractURL(from: provider) {
                urls.append(url)
            }
        }

        guard !urls.isEmpty else {
            Logger.files.warningCapture("No URLs extracted from drop providers", category: "files")
            isImporting = false
            return
        }

        Logger.files.infoCapture("Importing \(urls.count) files from drop", category: "files")

        await importURLsWithDuplicateCheck(urls, for: publicationId, in: libraryId)
    }

    /// Import URLs with duplicate checking for each file.
    private func importURLsWithDuplicateCheck(
        _ urls: [URL],
        for publicationId: UUID,
        in libraryId: UUID?
    ) async {
        importProgress = (current: 0, total: urls.count)

        for (index, url) in urls.enumerated() {
            importProgress = (current: index + 1, total: urls.count)

            // Check for duplicate
            if let result = attachmentManager.checkForDuplicate(sourceURL: url, in: publicationId) {
                switch result {
                case .noDuplicate(let hash):
                    do {
                        let _ = try attachmentManager.importAttachment(
                            from: url,
                            for: publicationId,
                            in: libraryId,
                            precomputedHash: hash
                        )
                        Logger.files.infoCapture("Imported: \(url.lastPathComponent)", category: "files")
                    } catch {
                        Logger.files.errorCapture("Import failed: \(error.localizedDescription)", category: "files")
                        lastError = error
                    }

                case .duplicate(let existingFile, let hash):
                    let remaining = Array(urls.dropFirst(index + 1))
                    pendingDuplicate = PendingDuplicateInfo(
                        sourceURL: url,
                        existingFilename: existingFile.filename,
                        precomputedHash: hash,
                        publicationId: publicationId,
                        libraryId: libraryId,
                        remainingURLs: remaining
                    )
                    Logger.files.infoCapture("Duplicate found, waiting for user decision: \(url.lastPathComponent)", category: "files")
                    return
                }
            } else {
                do {
                    let _ = try attachmentManager.importAttachment(
                        from: url,
                        for: publicationId,
                        in: libraryId
                    )
                } catch {
                    Logger.files.errorCapture("Import failed: \(error.localizedDescription)", category: "files")
                    lastError = error
                }
            }

            url.stopAccessingSecurityScopedResource()
        }

        // All done
        isImporting = false
        importProgress = nil
        Logger.files.infoCapture("Drop import completed", category: "files")
        NotificationCenter.default.post(name: .attachmentDidChange, object: publicationId)
    }

    // MARK: - Duplicate Resolution

    /// Resolve a pending duplicate file.
    public func resolveDuplicate(proceed: Bool) {
        guard let pending = pendingDuplicate else { return }
        pendingDuplicate = nil

        Task {
            if proceed {
                do {
                    let _ = try attachmentManager.importAttachment(
                        from: pending.sourceURL,
                        for: pending.publicationId,
                        in: pending.libraryId,
                        precomputedHash: pending.precomputedHash
                    )
                    Logger.files.infoCapture("User chose to import duplicate: \(pending.sourceURL.lastPathComponent)", category: "files")
                } catch {
                    Logger.files.errorCapture("Import failed after duplicate resolution: \(error.localizedDescription)", category: "files")
                    lastError = error
                }
            } else {
                Logger.files.infoCapture("User skipped duplicate: \(pending.sourceURL.lastPathComponent)", category: "files")
            }

            pending.sourceURL.stopAccessingSecurityScopedResource()

            if !pending.remainingURLs.isEmpty {
                await importURLsWithDuplicateCheck(
                    pending.remainingURLs,
                    for: pending.publicationId,
                    in: pending.libraryId
                )
            } else {
                isImporting = false
                importProgress = nil
                Logger.files.infoCapture("Drop import completed", category: "files")
                NotificationCenter.default.post(name: .attachmentDidChange, object: pending.publicationId)
            }
        }
    }

    /// Extract a file URL from an NSItemProvider.
    private func extractURL(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            do {
                let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let url = url {
                            let tempDir = FileManager.default.temporaryDirectory
                            let tempURL = tempDir.appendingPathComponent(url.lastPathComponent)

                            do {
                                try? FileManager.default.removeItem(at: tempURL)
                                try FileManager.default.copyItem(at: url, to: tempURL)
                                continuation.resume(returning: tempURL)
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        } else {
                            continuation.resume(throwing: FileDropError.noURL)
                        }
                    }
                }
                return url
            } catch {
                Logger.files.debugCapture("Failed to extract file URL: \(error.localizedDescription)", category: "files")
            }
        }

        for type in [UTType.pdf, UTType.image, UTType.data] {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let url = await extractItem(from: provider, type: type) {
                    return url
                }
            }
        }

        return nil
    }

    /// Extract item data and save to temp file.
    private func extractItem(from provider: NSItemProvider, type: UTType) async -> URL? {
        do {
            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let data = data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: FileDropError.noData)
                    }
                }
            }

            let ext = type.preferredFilenameExtension ?? "dat"
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try data.write(to: tempURL)

            return tempURL
        } catch {
            Logger.files.debugCapture("Failed to extract \(type.identifier): \(error.localizedDescription)", category: "files")
            return nil
        }
    }
}

// MARK: - Pending Duplicate Info

/// Information about a duplicate file pending user decision.
public struct PendingDuplicateInfo: Identifiable, Equatable {
    public let id = UUID()

    public static func == (lhs: PendingDuplicateInfo, rhs: PendingDuplicateInfo) -> Bool {
        lhs.id == rhs.id
    }

    /// URL of the source file (in temp directory)
    public let sourceURL: URL

    /// Filename of the existing identical attachment
    public let existingFilename: String

    /// Pre-computed SHA256 hash (reuse for import if user proceeds)
    public let precomputedHash: String

    /// Publication ID to attach to
    public let publicationId: UUID

    /// Library ID containing the publication
    public let libraryId: UUID?

    /// Remaining URLs to import after this one is resolved
    public let remainingURLs: [URL]
}

// MARK: - File Drop Error

public enum FileDropError: LocalizedError {
    case noURL
    case noData

    public var errorDescription: String? {
        switch self {
        case .noURL: return "Could not extract file URL from drop"
        case .noData: return "Could not extract file data from drop"
        }
    }
}
