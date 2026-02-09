//
//  PDFCloudService.swift
//  PublicationManagerCore
//
//  Service for managing on-demand PDF sync on iOS.
//

import Foundation
import OSLog

/// Service for managing on-demand PDF sync on iOS.
///
/// This service handles:
/// - Downloading PDFs from cloud on-demand
/// - Evicting local PDFs to free space (while keeping cloud copy)
/// - Calculating local PDF storage usage
/// - Batch downloading all PDFs (for "Sync All" mode)
public actor PDFCloudService {

    // MARK: - Singleton

    public static let shared = PDFCloudService()

    // MARK: - Properties

    private init() {}

    /// Helper to call @MainActor RustStoreAdapter from actor context.
    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - Settings

    /// Whether to sync all PDFs on iOS (user setting)
    public nonisolated var syncAllPDFs: Bool {
        SyncedSettingsStore.shared.bool(forKey: .iosSyncAllPDFs) ?? false
    }

    /// Update the sync all PDFs setting
    public func setSyncAllPDFs(_ value: Bool) {
        SyncedSettingsStore.shared.set(value, forKey: .iosSyncAllPDFs)

        if value {
            Task {
                try? await downloadAllPDFs()
            }
        }
    }

    // MARK: - Download PDF

    /// Download PDF for a linked file.
    ///
    /// Resolves the linked file's path, reads data from disk if available,
    /// and writes it to the appropriate location.
    ///
    /// - Parameters:
    ///   - linkedFileId: The linked file ID
    ///   - libraryId: The library containing the file
    /// - Returns: URL where the PDF was written
    public func downloadPDF(for linkedFileId: UUID, in libraryId: UUID?) async throws -> URL {
        let linkedFile = await withStore { $0.getLinkedFile(id: linkedFileId) }

        guard let linkedFile else {
            throw PDFCloudError.notAvailableInCloud
        }

        Logger.files.info("PDFCloudService: Downloading PDF for \(linkedFile.filename)")

        // Resolve the file URL using AttachmentManager
        let resolvedURL = await MainActor.run {
            AttachmentManager.shared.resolveURL(for: linkedFile, in: libraryId)
        }

        if let url = resolvedURL, FileManager.default.fileExists(atPath: url.path) {
            // Mark as locally materialized
            await withStore { $0.setLocallyMaterialized(id: linkedFileId, materialized: true) }
            Logger.files.info("PDFCloudService: PDF already on disk: \(url.lastPathComponent)")
            return url
        }

        // File not found on disk
        Logger.files.error("PDFCloudService: Unable to download PDF - file not available")
        throw PDFCloudError.notAvailableInCloud
    }

    // MARK: - Evict Local PDF

    /// Evict local PDF data to free space while keeping the cloud copy.
    ///
    /// - Parameter linkedFileId: The linked file ID to evict
    public func evictLocalPDF(_ linkedFileId: UUID) async throws {
        let linkedFile = await withStore { $0.getLinkedFile(id: linkedFileId) }

        guard let linkedFile else { return }

        guard linkedFile.isPDF else {
            Logger.files.warning("PDFCloudService: Cannot evict non-PDF file: \(linkedFile.filename)")
            return
        }

        guard linkedFile.pdfCloudAvailable else {
            Logger.files.warning("PDFCloudService: Cannot evict PDF not available in cloud: \(linkedFile.filename)")
            throw PDFCloudError.notAvailableInCloud
        }

        Logger.files.info("PDFCloudService: Evicting local PDF: \(linkedFile.filename)")

        // Mark as not locally materialized
        await withStore { $0.setLocallyMaterialized(id: linkedFileId, materialized: false) }

        Logger.files.info("PDFCloudService: Evicted PDF: \(linkedFile.filename)")
    }

    // MARK: - Evict Newly Downloaded PDFs (iOS Auto-Eviction)

    /// Evict PDFs that were just downloaded via sync.
    ///
    /// Should be called after sync completes on iOS when "Sync All" is OFF.
    @MainActor
    public func evictNewlyDownloadedPDFs() async {
        #if os(iOS)
        guard !syncAllPDFs else {
            Logger.files.debug("PDFCloudService: Sync All is ON, not evicting PDFs")
            return
        }

        Logger.files.info("PDFCloudService: Checking for PDFs to evict after sync")
        // With Rust store, eviction is handled via setLocallyMaterialized flags.
        // Actual file deletion would be managed at the file system level.
        #endif
    }

    // MARK: - Calculate Local Storage

    /// Calculate the total storage used by locally downloaded PDFs (on disk).
    ///
    /// - Returns: Total bytes used by local PDF files on disk
    public func localPDFStorageSizeOnDisk() async -> Int64 {
        let libraries = await withStore { $0.listLibraries() }
        var totalSize: Int64 = 0

        for library in libraries {
            let publications = await withStore { $0.queryPublications(parentId: library.id) }
            for pub in publications {
                let linkedFiles = await withStore { $0.listLinkedFiles(publicationId: pub.id) }
                for file in linkedFiles where file.isPDF && file.isLocallyMaterialized {
                    totalSize += file.fileSize
                }
            }
        }

        return totalSize
    }

    // MARK: - Batch Download All PDFs

    /// Download all PDFs that are available in cloud but not locally materialized.
    public func downloadAllPDFs() async throws {
        Logger.files.info("PDFCloudService: Starting batch download of all PDFs")

        let libraries = await withStore { $0.listLibraries() }
        var successCount = 0
        var errorCount = 0

        for library in libraries {
            let publications = await withStore { $0.queryPublications(parentId: library.id) }

            for pub in publications {
                let linkedFiles = await withStore { $0.listLinkedFiles(publicationId: pub.id) }

                for file in linkedFiles where file.isPDF && file.pdfCloudAvailable && !file.isLocallyMaterialized {
                    do {
                        _ = try await downloadPDF(for: file.id, in: library.id)
                        successCount += 1
                    } catch {
                        Logger.files.error("PDFCloudService: Failed to download \(file.filename): \(error.localizedDescription)")
                        errorCount += 1
                    }
                }
            }
        }

        Logger.files.info("PDFCloudService: Batch download complete. Success: \(successCount), Errors: \(errorCount)")
    }

    // MARK: - Clear Downloaded PDFs

    /// Clear all locally downloaded PDFs to free space.
    public func clearAllDownloadedPDFs() async throws {
        Logger.files.info("PDFCloudService: Clearing all downloaded PDFs")

        let libraries = await withStore { $0.listLibraries() }
        var clearCount = 0

        for library in libraries {
            let publications = await withStore { $0.queryPublications(parentId: library.id) }

            for pub in publications {
                let linkedFiles = await withStore { $0.listLinkedFiles(publicationId: pub.id) }

                for file in linkedFiles where file.isPDF && file.pdfCloudAvailable && file.isLocallyMaterialized {
                    try await evictLocalPDF(file.id)
                    clearCount += 1
                }
            }
        }

        Logger.files.info("PDFCloudService: Cleared \(clearCount) downloaded PDFs")
    }
}

// MARK: - Errors

/// Errors that can occur during PDF cloud operations.
public enum PDFCloudError: LocalizedError {
    case notAvailableInCloud
    case noStorageDirectory
    case downloadFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .notAvailableInCloud:
            return "This PDF is not available in iCloud. It may not have been synced from the originating device."
        case .noStorageDirectory:
            return "Could not access the application storage directory."
        case .downloadFailed(let error):
            return "Failed to download PDF: \(error.localizedDescription)"
        }
    }
}
