//
//  PDFCloudService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import CoreData
import OSLog

/// Service for managing on-demand PDF sync on iOS.
///
/// This service handles:
/// - Downloading PDFs from CloudKit on-demand
/// - Evicting local PDFs to free space (while keeping cloud copy)
/// - Calculating local PDF storage usage
/// - Batch downloading all PDFs (for "Sync All" mode)
///
/// ## Design
/// Since `NSPersistentCloudKitContainer` automatically downloads CKAssets (fileData),
/// we work with the CloudKit sync rather than against it:
/// 1. Let CloudKit sync `fileData` normally
/// 2. On iOS (when "Sync All" is OFF), evict `fileData` after sync to free space
/// 3. Track cloud availability with `pdfCloudAvailable` and `isLocallyMaterialized`
/// 4. Re-fetch from CloudKit on-demand when user opens PDF
public actor PDFCloudService {

    // MARK: - Singleton

    public static let shared = PDFCloudService()

    // MARK: - Properties

    private let persistenceController: PersistenceController

    private init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - Settings

    /// Whether to sync all PDFs on iOS (user setting)
    /// This is nonisolated since it only reads from SyncedSettingsStore which is thread-safe.
    public nonisolated var syncAllPDFs: Bool {
        SyncedSettingsStore.shared.bool(forKey: .iosSyncAllPDFs) ?? false
    }

    /// Update the sync all PDFs setting
    public func setSyncAllPDFs(_ value: Bool) {
        SyncedSettingsStore.shared.set(value, forKey: .iosSyncAllPDFs)

        if value {
            // User enabled "Sync All" - start downloading all PDFs
            Task {
                try? await downloadAllPDFs()
            }
        }
    }

    // MARK: - Download PDF from CloudKit

    /// Download PDF from CloudKit for a linked file.
    ///
    /// This triggers CloudKit to re-sync the `fileData` for the linked file,
    /// then writes it to disk.
    ///
    /// - Parameters:
    ///   - linkedFile: The linked file to download
    ///   - library: The library containing the file
    /// - Returns: URL where the PDF was written
    @MainActor
    public func downloadPDF(for linkedFile: CDLinkedFile, in library: CDLibrary?) async throws -> URL {
        Logger.files.info("PDFCloudService: Downloading PDF for \(linkedFile.filename)")

        // Check if we already have fileData from CloudKit
        if let fileData = linkedFile.fileData {
            // Write to disk and return
            let url = try writeToDisk(fileData, linkedFile: linkedFile, library: library)
            linkedFile.isLocallyMaterialized = true
            try? linkedFile.managedObjectContext?.save()
            Logger.files.info("PDFCloudService: PDF already had fileData, wrote to disk: \(url.lastPathComponent)")
            return url
        }

        // If no fileData, we need to trigger a CloudKit refresh
        // The fileData may have been evicted or not yet synced
        Logger.files.info("PDFCloudService: No fileData available, triggering CloudKit refresh")

        // Refresh the object from the persistent store
        linkedFile.managedObjectContext?.refresh(linkedFile, mergeChanges: true)

        // Wait a moment for CloudKit to potentially sync
        try await Task.sleep(for: .seconds(2))

        // Check again
        if let fileData = linkedFile.fileData {
            let url = try writeToDisk(fileData, linkedFile: linkedFile, library: library)
            linkedFile.isLocallyMaterialized = true
            try? linkedFile.managedObjectContext?.save()
            Logger.files.info("PDFCloudService: CloudKit provided fileData, wrote to disk: \(url.lastPathComponent)")
            return url
        }

        // Still no data - file may not exist in CloudKit
        Logger.files.error("PDFCloudService: Unable to download PDF - no fileData available in CloudKit")
        throw PDFCloudError.notAvailableInCloud
    }

    /// Write PDF data to disk at the appropriate location.
    @MainActor
    private func writeToDisk(_ data: Data, linkedFile: CDLinkedFile, library: CDLibrary?) throws -> URL {
        let normalizedPath = linkedFile.relativePath.precomposedStringWithCanonicalMapping
        let destinationURL: URL

        if let library = library {
            destinationURL = library.containerURL.appendingPathComponent(normalizedPath)
        } else {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw PDFCloudError.noStorageDirectory
            }
            destinationURL = appSupport.appendingPathComponent("imbib/\(normalizedPath)")
        }

        // Create directory if needed
        let directoryURL = destinationURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        // Write the data
        try data.write(to: destinationURL)
        Logger.files.info("PDFCloudService: Wrote \(data.count) bytes to \(destinationURL.lastPathComponent)")

        return destinationURL
    }

    // MARK: - Evict Local PDF

    /// Evict local PDF data to free space while keeping the cloud copy.
    ///
    /// This clears `fileData` and marks `isLocallyMaterialized = false`.
    /// The PDF can be re-downloaded on-demand later.
    ///
    /// - Parameter linkedFile: The linked file to evict
    @MainActor
    public func evictLocalPDF(_ linkedFile: CDLinkedFile) async throws {
        guard linkedFile.isPDF else {
            Logger.files.warning("PDFCloudService: Cannot evict non-PDF file: \(linkedFile.filename)")
            return
        }

        guard linkedFile.pdfCloudAvailable else {
            Logger.files.warning("PDFCloudService: Cannot evict PDF not available in cloud: \(linkedFile.filename)")
            throw PDFCloudError.notAvailableInCloud
        }

        Logger.files.info("PDFCloudService: Evicting local PDF: \(linkedFile.filename)")

        // Clear the fileData to free memory/disk
        linkedFile.fileData = nil
        linkedFile.isLocallyMaterialized = false

        // Optionally delete the file from disk too
        if let library = linkedFile.publication?.libraries?.first {
            let normalizedPath = linkedFile.relativePath.precomposedStringWithCanonicalMapping
            let fileURL = library.containerURL.appendingPathComponent(normalizedPath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
                Logger.files.info("PDFCloudService: Deleted local file: \(fileURL.lastPathComponent)")
            }
        }

        try? linkedFile.managedObjectContext?.save()
        Logger.files.info("PDFCloudService: Evicted PDF: \(linkedFile.filename)")
    }

    // MARK: - Evict Newly Downloaded PDFs (iOS Auto-Eviction)

    /// Evict PDFs that were just downloaded via CloudKit sync.
    ///
    /// This should be called after CloudKit sync completes on iOS when "Sync All" is OFF.
    /// It finds files with fileData but not marked as locally materialized and clears them.
    @MainActor
    public func evictNewlyDownloadedPDFs() async {
        #if os(iOS)
        // Only evict on iOS and only if "Sync All" is OFF
        guard !syncAllPDFs else {
            Logger.files.debug("PDFCloudService: Sync All is ON, not evicting PDFs")
            return
        }

        Logger.files.info("PDFCloudService: Checking for PDFs to evict after CloudKit sync")

        let context = persistenceController.viewContext

        // Find linked files with fileData that aren't marked as locally materialized
        // These are files that CloudKit just synced but we want to evict
        let request = NSFetchRequest<CDLinkedFile>(entityName: "LinkedFile")
        request.predicate = NSPredicate(
            format: "fileData != nil AND isLocallyMaterialized == NO AND pdfCloudAvailable == YES"
        )

        do {
            let filesToEvict = try context.fetch(request)
            Logger.files.info("PDFCloudService: Found \(filesToEvict.count) PDFs to evict")

            for file in filesToEvict {
                file.fileData = nil
                Logger.files.debug("PDFCloudService: Evicted fileData for: \(file.filename)")
            }

            if !filesToEvict.isEmpty {
                try? context.save()
                Logger.files.info("PDFCloudService: Evicted \(filesToEvict.count) PDFs to free space")
            }
        } catch {
            Logger.files.error("PDFCloudService: Failed to fetch files for eviction: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Calculate Local Storage

    /// Calculate the total storage used by locally downloaded PDFs.
    ///
    /// - Returns: Total bytes used by local PDFs
    @MainActor
    public func localPDFStorageSize() async -> Int64 {
        let context = persistenceController.viewContext

        // Find all linked files with fileData
        let request = NSFetchRequest<CDLinkedFile>(entityName: "LinkedFile")
        request.predicate = NSPredicate(format: "fileData != nil")

        do {
            let files = try context.fetch(request)
            let totalSize = files.reduce(Int64(0)) { sum, file in
                sum + (file.fileData?.count ?? 0).int64Value
            }
            Logger.files.debug("PDFCloudService: Local PDF storage: \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")
            return totalSize
        } catch {
            Logger.files.error("PDFCloudService: Failed to calculate storage: \(error.localizedDescription)")
            return 0
        }
    }

    /// Calculate the total storage used by locally downloaded PDFs (on disk).
    ///
    /// - Returns: Total bytes used by local PDF files on disk
    @MainActor
    public func localPDFStorageSizeOnDisk() async -> Int64 {
        let context = persistenceController.viewContext

        // Find all linked files that are PDFs and locally materialized
        let request = NSFetchRequest<CDLinkedFile>(entityName: "LinkedFile")
        request.predicate = NSPredicate(format: "fileType == 'pdf' AND isLocallyMaterialized == YES")

        do {
            let files = try context.fetch(request)
            let totalSize = files.reduce(Int64(0)) { sum, file in
                sum + file.fileSize
            }
            return totalSize
        } catch {
            Logger.files.error("PDFCloudService: Failed to calculate on-disk storage: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Batch Download All PDFs

    /// Download all PDFs that are available in cloud but not locally materialized.
    ///
    /// This is called when user enables "Sync All PDFs" mode.
    @MainActor
    public func downloadAllPDFs() async throws {
        Logger.files.info("PDFCloudService: Starting batch download of all PDFs")

        let context = persistenceController.viewContext

        // Find all cloud-available PDFs that aren't locally materialized
        let request = NSFetchRequest<CDLinkedFile>(entityName: "LinkedFile")
        request.predicate = NSPredicate(
            format: "pdfCloudAvailable == YES AND isLocallyMaterialized == NO AND fileType == 'pdf'"
        )

        let filesToDownload = try context.fetch(request)
        Logger.files.info("PDFCloudService: Found \(filesToDownload.count) PDFs to download")

        var successCount = 0
        var errorCount = 0

        for file in filesToDownload {
            do {
                let library = file.publication?.libraries?.first
                _ = try await downloadPDF(for: file, in: library)
                successCount += 1
            } catch {
                Logger.files.error("PDFCloudService: Failed to download \(file.filename): \(error.localizedDescription)")
                errorCount += 1
            }
        }

        Logger.files.info("PDFCloudService: Batch download complete. Success: \(successCount), Errors: \(errorCount)")
    }

    // MARK: - Clear Downloaded PDFs

    /// Clear all locally downloaded PDFs to free space.
    ///
    /// This is a user-initiated action from settings.
    @MainActor
    public func clearAllDownloadedPDFs() async throws {
        Logger.files.info("PDFCloudService: Clearing all downloaded PDFs")

        let context = persistenceController.viewContext

        // Find all locally materialized PDFs that are also in cloud
        let request = NSFetchRequest<CDLinkedFile>(entityName: "LinkedFile")
        request.predicate = NSPredicate(
            format: "pdfCloudAvailable == YES AND isLocallyMaterialized == YES AND fileType == 'pdf'"
        )

        let files = try context.fetch(request)
        Logger.files.info("PDFCloudService: Found \(files.count) PDFs to clear")

        for file in files {
            try await evictLocalPDF(file)
        }

        Logger.files.info("PDFCloudService: Cleared all downloaded PDFs")
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

// MARK: - Int Extension

private extension Int {
    var int64Value: Int64 { Int64(self) }
}
