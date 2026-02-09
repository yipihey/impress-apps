//
//  RemarkableSyncManager.swift
//  PublicationManagerCore
//
//  Orchestrates document sync between imbib and reMarkable.
//  ADR-019: reMarkable Tablet Integration
//

import Foundation
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
    private let store = RustStoreAdapter.shared
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
    ///   - publicationID: The publication ID to upload
    ///   - linkedFile: The PDF linked file model
    ///   - folderID: Optional folder ID on reMarkable
    /// - Returns: The remarkableDocumentID string
    @discardableResult
    public func uploadPublication(
        _ publicationID: UUID,
        linkedFile: LinkedFileModel,
        folderID: String? = nil
    ) async throws -> String {
        let backend = try backendManager.requireActiveBackend()

        guard let pub = store.getPublication(id: publicationID) else {
            throw RemarkableError.noPDFAvailable
        }

        // Get PDF data from linked file path
        let libraries = store.listLibraries()
        guard let library = libraries.first(where: { lib in
            let pubs = store.queryPublications(parentId: lib.id, sort: "created", ascending: false)
            return pubs.contains(where: { $0.id == publicationID })
        }) else {
            throw RemarkableError.noPDFAvailable
        }

        // Resolve PDF path
        guard let relativePath = linkedFile.relativePath else {
            throw RemarkableError.noPDFAvailable
        }

        // Build URL from library container + relative path
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let libraryDir = appSupport.appendingPathComponent("com.impress.imbib/libraries/\(library.id.uuidString)")
        let pdfURL = libraryDir.appendingPathComponent(relativePath)

        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw RemarkableError.noPDFAvailable
        }

        let pdfData = try Data(contentsOf: pdfURL)

        // Determine filename
        let filename = linkedFile.filename

        // Upload to reMarkable
        syncState = .syncing(progress: 0.3, message: "Uploading \(filename)...")

        let remarkableID = try await backend.uploadDocument(pdfData, filename: filename, parentFolder: folderID)

        // Store the remarkable document info in the publication's fields
        store.updateField(id: publicationID, field: "_remarkable_doc_id", value: remarkableID)
        store.updateField(id: publicationID, field: "_remarkable_folder_id", value: folderID)
        store.updateField(id: publicationID, field: "_remarkable_sync_state", value: "synced")
        store.updateField(id: publicationID, field: "_remarkable_date_uploaded", value: ISO8601DateFormatter().string(from: Date()))

        syncState = .idle
        lastSyncDate = Date()

        logger.info("Uploaded publication \(pub.citeKey) to reMarkable: \(remarkableID)")

        return remarkableID
    }

    /// Import annotations from reMarkable for a publication.
    ///
    /// - Parameter publicationID: The publication to import annotations for
    /// - Returns: Number of annotations imported
    @discardableResult
    public func importAnnotations(for publicationID: UUID) async throws -> Int {
        let backend = try backendManager.requireActiveBackend()

        guard let detail = store.getPublicationDetail(id: publicationID) else {
            throw RemarkableError.downloadFailed("Publication not found")
        }

        guard let docID = detail.fields["_remarkable_doc_id"], !docID.isEmpty else {
            throw RemarkableError.downloadFailed("No reMarkable document ID")
        }

        syncState = .syncing(progress: 0.5, message: "Downloading annotations...")

        // Download annotations
        let rawAnnotations = try await backend.downloadAnnotations(documentID: docID)

        guard !rawAnnotations.isEmpty else {
            syncState = .idle
            return 0
        }

        syncState = .syncing(progress: 0.7, message: "Converting annotations...")

        // Find the linked PDF file for this publication
        let linkedFiles = store.listLinkedFiles(publicationId: publicationID)
        guard let pdfFile = linkedFiles.first(where: { $0.isPDF }) else {
            syncState = .idle
            return 0
        }

        // Convert and store annotations via RustStoreAdapter
        var importedCount = 0

        for raw in rawAnnotations {
            // Serialize CGRect to JSON string
            let boundsRect = raw.bounds
            let boundsString = "{\"x\":\(boundsRect.origin.x),\"y\":\(boundsRect.origin.y),\"width\":\(boundsRect.width),\"height\":\(boundsRect.height)}"

            let _ = store.createAnnotation(
                linkedFileId: pdfFile.id,
                annotationType: raw.type.rawValue,
                pageNumber: Int64(raw.pageNumber),
                boundsJson: boundsString,
                color: raw.color,
                contents: nil,
                selectedText: nil
            )
            importedCount += 1
        }

        // Update sync state in publication fields
        store.updateField(id: publicationID, field: "_remarkable_sync_state", value: "synced")
        store.updateField(id: publicationID, field: "_remarkable_last_sync", value: ISO8601DateFormatter().string(from: Date()))
        store.updateField(id: publicationID, field: "_remarkable_annotation_count", value: String(importedCount))

        syncState = .idle
        lastSyncDate = Date()

        // Post notification
        NotificationCenter.default.post(
            name: .remarkableAnnotationsImported,
            object: publicationID,
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

                // Find documents needing sync by searching all publications
                let libraries = store.listLibraries()
                var pendingPubs: [(UUID, String)] = [] // (publicationID, remarkableDocID)

                for library in libraries {
                    let pubs = store.queryPublications(parentId: library.id, sort: "modified", ascending: false)
                    for pub in pubs {
                        guard let detail = store.getPublicationDetail(id: pub.id) else { continue }
                        let syncStateStr = detail.fields["_remarkable_sync_state"]
                        if syncStateStr == "pending" || syncStateStr == "conflict" {
                            if let docID = detail.fields["_remarkable_doc_id"] {
                                pendingPubs.append((pub.id, docID))
                            }
                        }
                    }
                }

                pendingCount = pendingPubs.count

                guard !pendingPubs.isEmpty else {
                    syncState = .idle
                    return
                }

                // Process each document
                for (index, (pubID, _)) in pendingPubs.enumerated() {
                    let progress = Double(index) / Double(pendingPubs.count)
                    syncState = .syncing(progress: progress, message: "Syncing \(index + 1) of \(pendingPubs.count)...")

                    do {
                        _ = try await importAnnotations(for: pubID)
                    } catch {
                        logger.error("Failed to sync publication \(pubID): \(error)")
                        store.updateField(id: pubID, field: "_remarkable_sync_state", value: "error")
                        store.updateField(id: pubID, field: "_remarkable_sync_error", value: error.localizedDescription)
                    }
                }

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

        // Get tracked documents from all libraries
        let libraries = store.listLibraries()
        var pendingUpdates = 0

        for library in libraries {
            let pubs = store.queryPublications(parentId: library.id, sort: "modified", ascending: false)
            for pub in pubs {
                guard let detail = store.getPublicationDetail(id: pub.id) else { continue }
                guard let remoteID = detail.fields["_remarkable_doc_id"], !remoteID.isEmpty else { continue }
                let trackedVersion = Int(detail.fields["_remarkable_version"] ?? "0") ?? 0

                if let remote = remoteDocuments.first(where: { $0.id == remoteID }) {
                    if remote.version > trackedVersion {
                        // Remote has newer version
                        store.updateField(id: pub.id, field: "_remarkable_sync_state", value: "pending")
                        pendingUpdates += 1
                        logger.debug("Document \(remoteID) has updates (v\(trackedVersion) -> v\(remote.version))")
                    }
                }
            }
        }

        if pendingUpdates > 0 {
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

    /// Get reMarkable document info for a publication.
    public func remarkableDocumentInfo(for publicationID: UUID) -> (docID: String, syncState: String, annotationCount: Int)? {
        guard let detail = store.getPublicationDetail(id: publicationID) else { return nil }
        guard let docID = detail.fields["_remarkable_doc_id"], !docID.isEmpty else { return nil }
        let syncStateStr = detail.fields["_remarkable_sync_state"] ?? "unknown"
        let annotationCount = Int(detail.fields["_remarkable_annotation_count"] ?? "0") ?? 0
        return (docID: docID, syncState: syncStateStr, annotationCount: annotationCount)
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
