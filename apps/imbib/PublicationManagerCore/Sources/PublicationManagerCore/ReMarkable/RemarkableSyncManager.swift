//
//  RemarkableSyncManager.swift
//  PublicationManagerCore
//
//  Orchestrates document sync between imbib and reMarkable.
//  ADR-019: reMarkable Tablet Integration
//

import Foundation
import CoreData
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableSync")

// MARK: - Sync Manager

/// Orchestrates document sync between imbib and reMarkable.
///
/// Responsibilities:
/// - Upload PDFs to reMarkable device
/// - Import annotations from reMarkable
/// - Track sync state per document
/// - Handle conflict resolution
@MainActor @Observable
public final class RemarkableSyncManager {

    // MARK: - Singleton

    public static let shared = RemarkableSyncManager()

    // MARK: - State

    /// Current sync state.
    public private(set) var syncState: SyncState = .idle

    /// Documents pending sync.
    public private(set) var pendingCount: Int = 0

    /// Number of publications pending upload to reMarkable.
    public private(set) var pendingUploads: Int = 0

    /// Number of documents with pending annotation imports.
    public private(set) var pendingImports: Int = 0

    /// Last sync date.
    public private(set) var lastSyncDate: Date?

    /// Current sync error, if any.
    public private(set) var lastError: String?

    // MARK: - Dependencies

    private let backendManager = RemarkableBackendManager.shared
    private let settings = RemarkableSettingsStore.shared
    private var syncTask: Task<Void, Never>?

    // MARK: - Initialization

    private init() {}

    // MARK: - Sync States

    public enum SyncState: Sendable {
        case idle
        case syncing(progress: Double, message: String)
        case error(String)
    }

    // MARK: - Public API

    /// Upload a publication's PDF to reMarkable.
    ///
    /// - Parameters:
    ///   - publication: The publication to upload
    ///   - linkedFile: The PDF file to upload
    ///   - folderID: Optional folder ID on reMarkable
    /// - Returns: The created RemarkableDocument record
    @discardableResult
    public func uploadPublication(
        _ publication: CDPublication,
        linkedFile: CDLinkedFile,
        folderID: String? = nil
    ) async throws -> CDRemarkableDocument {
        let backend = try backendManager.requireActiveBackend()

        // Get PDF data
        guard let library = publication.libraries?.first as? CDLibrary else {
            throw RemarkableError.noPDFAvailable
        }

        let pdfURL = library.containerURL.appendingPathComponent(linkedFile.relativePath)
        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw RemarkableError.noPDFAvailable
        }

        let pdfData = try Data(contentsOf: pdfURL)

        // Determine filename
        let filename = linkedFile.displayName ?? linkedFile.filename

        // Upload to reMarkable
        syncState = .syncing(progress: 0.3, message: "Uploading \(filename)...")

        let remarkableID = try await backend.uploadDocument(pdfData, filename: filename, parentFolder: folderID)

        // Create tracking record in Core Data
        let context = PersistenceController.shared.viewContext
        let remarkableDoc = CDRemarkableDocument(context: context)
        remarkableDoc.id = UUID()
        remarkableDoc.remarkableDocumentID = remarkableID
        remarkableDoc.remarkableFolderID = folderID
        remarkableDoc.remarkableVersion = 1
        remarkableDoc.dateUploaded = Date()
        remarkableDoc.syncState = "synced"
        remarkableDoc.publication = publication
        remarkableDoc.linkedFile = linkedFile

        // Calculate file hash for change detection
        remarkableDoc.localFileHash = pdfData.sha256Hex

        try context.save()

        syncState = .idle
        lastSyncDate = Date()

        logger.info("Uploaded publication \(publication.citeKey) to reMarkable: \(remarkableID)")

        return remarkableDoc
    }

    /// Import annotations from reMarkable for a document.
    ///
    /// - Parameter remarkableDoc: The reMarkable document to import from
    /// - Returns: Number of annotations imported
    @discardableResult
    public func importAnnotations(for remarkableDoc: CDRemarkableDocument) async throws -> Int {
        let backend = try backendManager.requireActiveBackend()

        let docID = remarkableDoc.remarkableDocumentID
        guard !docID.isEmpty else {
            throw RemarkableError.downloadFailed("No document ID")
        }

        syncState = .syncing(progress: 0.5, message: "Downloading annotations...")

        // Download annotations
        let rawAnnotations = try await backend.downloadAnnotations(documentID: docID)

        guard !rawAnnotations.isEmpty else {
            syncState = .idle
            return 0
        }

        syncState = .syncing(progress: 0.7, message: "Converting annotations...")

        // Convert and store annotations
        let context = PersistenceController.shared.viewContext
        var importedCount = 0

        for raw in rawAnnotations {
            let annotation = CDRemarkableAnnotation(context: context)
            annotation.id = UUID()
            annotation.pageNumber = Int32(raw.pageNumber)
            annotation.annotationType = raw.type.rawValue
            annotation.layerName = raw.layerName

            // Store bounds as JSON
            annotation.bounds = raw.bounds

            annotation.strokeDataCompressed = raw.strokeData
            annotation.color = raw.color
            annotation.dateImported = Date()
            annotation.remarkableVersion = remarkableDoc.remarkableVersion
            annotation.remarkableDocument = remarkableDoc

            importedCount += 1
        }

        remarkableDoc.annotationCount = Int32(importedCount)
        remarkableDoc.lastSyncDate = Date()
        remarkableDoc.syncState = "synced"

        try context.save()

        syncState = .idle
        lastSyncDate = Date()

        // Post notification
        NotificationCenter.default.post(
            name: .remarkableAnnotationsImported,
            object: remarkableDoc,
            userInfo: ["count": importedCount]
        )

        logger.info("Imported \(importedCount) annotations from reMarkable document \(docID)")

        return importedCount
    }

    /// Sync all pending documents.
    public func syncAll() async {
        guard syncTask == nil else {
            logger.info("Sync already in progress")
            return
        }

        syncTask = Task {
            defer { syncTask = nil }

            do {
                syncState = .syncing(progress: 0, message: "Starting sync...")

                // Find documents needing sync
                let context = PersistenceController.shared.viewContext
                let request = NSFetchRequest<CDRemarkableDocument>(entityName: "RemarkableDocument")
                request.predicate = NSPredicate(format: "syncState == %@ OR syncState == %@", "pending", "conflict")

                let pendingDocs = try context.fetch(request)
                pendingCount = pendingDocs.count

                guard !pendingDocs.isEmpty else {
                    syncState = .idle
                    return
                }

                // Process each document
                for (index, doc) in pendingDocs.enumerated() {
                    let progress = Double(index) / Double(pendingDocs.count)
                    syncState = .syncing(progress: progress, message: "Syncing \(index + 1) of \(pendingDocs.count)...")

                    do {
                        _ = try await importAnnotations(for: doc)
                    } catch {
                        logger.error("Failed to sync document \(doc.remarkableDocumentID ?? "unknown"): \(error)")
                        doc.syncState = "error"
                        doc.syncError = error.localizedDescription
                    }
                }

                try context.save()
                syncState = .idle
                lastSyncDate = Date()

            } catch {
                logger.error("Sync failed: \(error)")
                syncState = .error(error.localizedDescription)
                lastError = error.localizedDescription
            }
        }

        await syncTask?.value
    }

    /// Check for updates on reMarkable and queue pending syncs.
    public func checkForUpdates() async throws {
        let backend = try backendManager.requireActiveBackend()

        syncState = .syncing(progress: 0.1, message: "Checking for updates...")

        // Get list of documents from reMarkable
        let remoteDocuments = try await backend.listDocuments()

        // Get tracked documents from Core Data
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDRemarkableDocument>(entityName: "RemarkableDocument")
        let trackedDocs = try context.fetch(request)

        var pendingUpdates = 0

        // Check for version changes
        for tracked in trackedDocs {
            let remoteID = tracked.remarkableDocumentID
            guard !remoteID.isEmpty else { continue }

            if let remote = remoteDocuments.first(where: { $0.id == remoteID }) {
                if remote.version > Int(tracked.remarkableVersion) {
                    // Remote has newer version
                    tracked.syncState = "pending"
                    pendingUpdates += 1
                    logger.debug("Document \(remoteID) has updates (v\(tracked.remarkableVersion) -> v\(remote.version))")
                }
            }
        }

        if pendingUpdates > 0 {
            try context.save()
            pendingCount = pendingUpdates
        }

        syncState = .idle

        logger.info("Found \(pendingUpdates) documents with updates")
    }

    /// Cancel the current sync operation.
    public func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
        syncState = .idle
    }

    /// Get documents tracked for a publication.
    public func remarkableDocuments(for publication: CDPublication) -> [CDRemarkableDocument] {
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDRemarkableDocument>(entityName: "RemarkableDocument")
        request.predicate = NSPredicate(format: "publication == %@", publication)

        return (try? context.fetch(request)) ?? []
    }

    /// Get or create the imbib folder on reMarkable.
    public func getOrCreateImbibFolder() async throws -> String {
        let backend = try backendManager.requireActiveBackend()
        let folderName = settings.rootFolderName

        // Check if folder exists
        let folders = try await backend.listFolders()
        if let existing = folders.first(where: { $0.name == folderName && $0.parentFolderID == nil }) {
            return existing.id
        }

        // Create folder
        return try await backend.createFolder(name: folderName, parent: nil)
    }
}

// MARK: - Data Helpers

import CryptoKit

private extension Data {
    /// Compute SHA256 hash as hex string.
    var sha256Hex: String {
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
