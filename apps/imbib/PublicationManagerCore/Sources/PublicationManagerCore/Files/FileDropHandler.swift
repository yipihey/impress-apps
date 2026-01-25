//
//  FileDropHandler.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
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
public final class FileDropHandler: ObservableObject {

    // MARK: - Accepted Types

    /// UTTypes accepted for file drops.
    public static let acceptedTypes: [UTType] = [
        .fileURL,           // File URLs
        .item,              // Generic items (covers most file types)
        .data,              // Raw data
        .pdf,               // PDFs explicitly
        .image,             // Images
        .plainText,         // Text files
        .sourceCode,        // Source code
        .archive,           // Archives (.zip, .tar.gz, etc.)
    ]

    // MARK: - Properties

    /// The attachment manager used for importing files.
    /// Internal access for use by DragDropCoordinator.
    let attachmentManager: AttachmentManager

    /// Import progress (current, total)
    @Published public var importProgress: (current: Int, total: Int)?

    /// Whether import is in progress
    @Published public var isImporting: Bool = false

    /// Last error that occurred
    @Published public var lastError: Error?

    /// Pending duplicate that needs user confirmation
    @Published public var pendingDuplicate: PendingDuplicateInfo?

    // MARK: - Initialization

    public init(attachmentManager: AttachmentManager = .shared) {
        self.attachmentManager = attachmentManager
    }

    // MARK: - Drop Handling

    /// Validate whether a drop can be accepted.
    ///
    /// - Parameter info: Drop info from SwiftUI
    /// - Returns: Whether the drop is acceptable
    public func validateDrop(info: DropInfo) -> Bool {
        // Accept if any of our types are present
        for type in Self.acceptedTypes {
            if info.hasItemsConforming(to: [type]) {
                return true
            }
        }
        return false
    }

    /// Handle a drop operation by extracting URLs and importing files.
    ///
    /// - Parameters:
    ///   - info: Drop info from SwiftUI
    ///   - publication: The publication to attach files to
    ///   - library: The library containing the publication
    /// - Returns: Whether the drop was handled
    @discardableResult
    public func handleDrop(
        info: DropInfo,
        for publication: CDPublication,
        in library: CDLibrary?
    ) -> Bool {
        Logger.files.infoCapture("Handling file drop for \(publication.citeKey)", category: "files")

        // Extract file URLs from providers
        let providers = info.itemProviders(for: Self.acceptedTypes)
        guard !providers.isEmpty else {
            Logger.files.warningCapture("No valid items in drop", category: "files")
            return false
        }

        // Start async import
        Task {
            await importFromProviders(providers, for: publication, in: library)
        }

        return true
    }

    /// Handle drop from NSItemProviders directly (for programmatic use).
    ///
    /// - Parameters:
    ///   - providers: Array of item providers
    ///   - publication: The publication to attach files to
    ///   - library: The library containing the publication
    public func handleDrop(
        providers: [NSItemProvider],
        for publication: CDPublication,
        in library: CDLibrary?
    ) async {
        await importFromProviders(providers, for: publication, in: library)
    }

    // MARK: - Import Logic

    /// Extract URLs and import files from NSItemProviders.
    private func importFromProviders(
        _ providers: [NSItemProvider],
        for publication: CDPublication,
        in library: CDLibrary?
    ) async {
        isImporting = true
        lastError = nil

        // Collect all URLs from providers
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

        // Import files with duplicate checking
        await importURLsWithDuplicateCheck(urls, for: publication, in: library)
    }

    /// Import URLs with duplicate checking for each file.
    private func importURLsWithDuplicateCheck(
        _ urls: [URL],
        for publication: CDPublication,
        in library: CDLibrary?
    ) async {
        importProgress = (current: 0, total: urls.count)

        for (index, url) in urls.enumerated() {
            importProgress = (current: index + 1, total: urls.count)

            // Check for duplicate
            if let result = attachmentManager.checkForDuplicate(sourceURL: url, in: publication) {
                switch result {
                case .noDuplicate(let hash):
                    // Import with precomputed hash
                    do {
                        let _ = try attachmentManager.importAttachment(
                            from: url,
                            for: publication,
                            in: library,
                            precomputedHash: hash
                        )
                        Logger.files.infoCapture("Imported: \(url.lastPathComponent)", category: "files")
                    } catch {
                        Logger.files.errorCapture("Import failed: \(error.localizedDescription)", category: "files")
                        lastError = error
                    }

                case .duplicate(let existingFile, let hash):
                    // Pause and ask user
                    let remaining = Array(urls.dropFirst(index + 1))
                    pendingDuplicate = PendingDuplicateInfo(
                        sourceURL: url,
                        existingFilename: existingFile.effectiveDisplayName,
                        precomputedHash: hash,
                        publication: publication,
                        library: library,
                        remainingURLs: remaining
                    )
                    Logger.files.infoCapture("Duplicate found, waiting for user decision: \(url.lastPathComponent)", category: "files")
                    // Stop processing - will resume after user decision
                    return
                }
            } else {
                // Could not check (error getting file info) - import anyway
                do {
                    let _ = try attachmentManager.importAttachment(
                        from: url,
                        for: publication,
                        in: library
                    )
                } catch {
                    Logger.files.errorCapture("Import failed: \(error.localizedDescription)", category: "files")
                    lastError = error
                }
            }

            // Clean up this URL
            url.stopAccessingSecurityScopedResource()
        }

        // All done
        isImporting = false
        importProgress = nil
        Logger.files.infoCapture("Drop import completed", category: "files")
    }

    // MARK: - Duplicate Resolution

    /// Resolve a pending duplicate file.
    ///
    /// - Parameter proceed: If true, import the file anyway. If false, skip it.
    public func resolveDuplicate(proceed: Bool) {
        guard let pending = pendingDuplicate else { return }
        pendingDuplicate = nil

        Task {
            if proceed {
                // Import with pre-computed hash
                do {
                    let _ = try attachmentManager.importAttachment(
                        from: pending.sourceURL,
                        for: pending.publication,
                        in: pending.library,
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

            // Clean up this URL
            pending.sourceURL.stopAccessingSecurityScopedResource()

            // Continue with remaining files
            if !pending.remainingURLs.isEmpty {
                await importURLsWithDuplicateCheck(
                    pending.remainingURLs,
                    for: pending.publication,
                    in: pending.library
                )
            } else {
                // All done
                isImporting = false
                importProgress = nil
                Logger.files.infoCapture("Drop import completed", category: "files")
            }
        }
    }

    /// Extract a file URL from an NSItemProvider.
    private func extractURL(from provider: NSItemProvider) async -> URL? {
        // Try file URL first (most common)
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            do {
                let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let url = url {
                            // Copy to temp location since the provided URL is temporary
                            let tempDir = FileManager.default.temporaryDirectory
                            let tempURL = tempDir.appendingPathComponent(url.lastPathComponent)

                            do {
                                // Remove existing if any
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

        // Try item identifier for other types
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

            // Determine extension
            let ext = type.preferredFilenameExtension ?? "dat"

            // Save to temp file
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

    /// Publication to attach to
    public let publication: CDPublication

    /// Library containing the publication
    public let library: CDLibrary?

    /// Remaining URLs to import after this one is resolved
    public let remainingURLs: [URL]
}

// MARK: - File Drop Error

/// Errors that can occur during file drop handling.
public enum FileDropError: LocalizedError {
    case noURL
    case noData
    case securityAccess
    case importFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .noURL:
            return "Could not extract file URL from dropped item"
        case .noData:
            return "Could not extract data from dropped item"
        case .securityAccess:
            return "Could not access dropped file due to security restrictions"
        case .importFailed(let error):
            return "Import failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - SwiftUI Drop Delegate

/// A SwiftUI DropDelegate for file drops on publications.
public struct FileDropDelegate: DropDelegate {

    let handler: FileDropHandler
    let publication: CDPublication
    let library: CDLibrary?

    /// Called when files are hovered over the drop target.
    public var onTargeted: ((Bool) -> Void)?

    public init(
        handler: FileDropHandler,
        publication: CDPublication,
        library: CDLibrary?,
        onTargeted: ((Bool) -> Void)? = nil
    ) {
        self.handler = handler
        self.publication = publication
        self.library = library
        self.onTargeted = onTargeted
    }

    public func validateDrop(info: DropInfo) -> Bool {
        handler.validateDrop(info: info)
    }

    public func dropEntered(info: DropInfo) {
        onTargeted?(true)
    }

    public func dropExited(info: DropInfo) {
        onTargeted?(false)
    }

    public func performDrop(info: DropInfo) -> Bool {
        onTargeted?(false)
        return handler.handleDrop(info: info, for: publication, in: library)
    }
}

// MARK: - View Extension

public extension View {

    /// Add a file drop target for a publication.
    ///
    /// - Parameters:
    ///   - publication: The publication to attach dropped files to
    ///   - library: The library containing the publication
    ///   - handler: The FileDropHandler to use
    ///   - isTargeted: Binding to track when files are hovering
    /// - Returns: Modified view with drop handling
    func fileDropTarget(
        for publication: CDPublication,
        in library: CDLibrary?,
        handler: FileDropHandler,
        isTargeted: Binding<Bool>? = nil
    ) -> some View {
        self.onDrop(
            of: FileDropHandler.acceptedTypes,
            delegate: FileDropDelegate(
                handler: handler,
                publication: publication,
                library: library,
                onTargeted: { targeted in
                    isTargeted?.wrappedValue = targeted
                }
            )
        )
    }
}
