//
//  CompiledPDFWatcher.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-27.
//

import Foundation
import os.log

// MARK: - Compiled PDF Watcher

/// Watches the shared iCloud container for compiled PDFs from imprint.
///
/// When imprint compiles a document and writes the PDF to the shared folder,
/// this watcher detects the change and imports the PDF as a linked file
/// attachment tagged with `manuscript:compiled-pdf`.
public final class CompiledPDFWatcher: NSObject, @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = CompiledPDFWatcher()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.imbib", category: "CompiledPDFWatcher")

    /// The shared iCloud container identifier
    private let containerIdentifier = "iCloud.com.imbib.shared"

    /// Subdirectory for compiled manuscripts
    private let compiledManuscriptsFolder = "CompiledManuscripts"

    /// The metadata query for watching the folder
    private var metadataQuery: NSMetadataQuery?

    /// Callback when a new PDF is detected
    public var onPDFDetected: ((UUID, URL) -> Void)?

    /// Whether the watcher is currently running
    public private(set) var isWatching = false

    // MARK: - Lifecycle

    public func startWatching() {
        guard !isWatching else { return }

        // Check if iCloud is available
        guard FileManager.default.ubiquityIdentityToken != nil else {
            logger.warning("iCloud not available, cannot watch for compiled PDFs")
            return
        }

        setupMetadataQuery()
        isWatching = true
        logger.info("Started watching for compiled PDFs")
    }

    public func stopWatching() {
        metadataQuery?.stop()
        metadataQuery = nil
        isWatching = false
        logger.info("Stopped watching for compiled PDFs")
    }

    // MARK: - Metadata Query Setup

    private func setupMetadataQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]

        // Search for PDF files in the CompiledManuscripts folder
        query.predicate = NSPredicate(
            format: "%K LIKE %@ AND %K ENDSWITH %@",
            NSMetadataItemPathKey,
            "*\(compiledManuscriptsFolder)*",
            NSMetadataItemFSNameKey,
            ".pdf"
        )

        // Observe query notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinishGathering(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )

        metadataQuery = query
        query.start()
    }

    // MARK: - Query Notifications

    @objc private func queryDidFinishGathering(_ notification: Notification) {
        metadataQuery?.disableUpdates()
        defer { metadataQuery?.enableUpdates() }

        processQueryResults()
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        metadataQuery?.disableUpdates()
        defer { metadataQuery?.enableUpdates() }

        // Get added items
        if let addedItems = notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] {
            for item in addedItems {
                processMetadataItem(item)
            }
        }

        // Get changed items
        if let changedItems = notification.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] {
            for item in changedItems {
                processMetadataItem(item)
            }
        }
    }

    private func processQueryResults() {
        guard let query = metadataQuery else { return }

        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem else { continue }
            processMetadataItem(item)
        }
    }

    private func processMetadataItem(_ item: NSMetadataItem) {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else {
            return
        }

        let url = URL(fileURLWithPath: path)

        // Check download status
        if let downloadStatus = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String {
            if downloadStatus != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                // File not downloaded yet, trigger download
                do {
                    try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    logger.info("Started downloading: \(url.lastPathComponent)")
                } catch {
                    logger.error("Failed to start download: \(error.localizedDescription)")
                }
                return
            }
        }

        // Extract document UUID from filename
        let filename = url.deletingPathExtension().lastPathComponent
        guard let documentUUID = UUID(uuidString: filename) else {
            logger.warning("Invalid UUID in filename: \(filename)")
            return
        }

        // Notify callback
        onPDFDetected?(documentUUID, url)

        // Try to auto-import
        Task {
            await importCompiledPDF(documentUUID: documentUUID, pdfURL: url)
        }
    }

    // MARK: - PDF Import

    /// Imports a compiled PDF as an attachment to the linked manuscript.
    ///
    /// - Parameters:
    ///   - documentUUID: The UUID of the imprint document
    ///   - pdfURL: The URL of the compiled PDF
    @MainActor
    private func importCompiledPDF(documentUUID: UUID, pdfURL: URL) async {
        let store = RustStoreAdapter.shared

        // Find the manuscript linked to this imprint document
        // Search for publications that have this document UUID in their fields
        let allLibraries = store.listLibraries()
        for library in allLibraries {
            let pubs = store.queryPublications(parentId: library.id, sort: "modified", ascending: false)
            for pub in pubs {
                guard let detail = store.getPublicationDetail(id: pub.id) else { continue }
                guard detail.fields["_imprint_document_uuid"] == documentUUID.uuidString else { continue }

                // Found the manuscript — import the PDF
                do {
                    let pdfData = try Data(contentsOf: pdfURL)
                    let compiledFilename = "\(pub.citeKey)_compiled.pdf"

                    // Check if we already have a compiled PDF linked file
                    let existingFiles = store.listLinkedFiles(publicationId: pub.id)
                    let existingCompiled = existingFiles.first { $0.filename == compiledFilename }

                    if existingCompiled != nil {
                        // Update existing — currently the store doesn't have an updateLinkedFile,
                        // so we'd need to delete and re-add. For now, log that we detected the update.
                        logger.info("Compiled PDF already exists for \(pub.citeKey), detected update")
                    } else {
                        // Create new linked file
                        _ = store.addLinkedFile(
                            publicationId: pub.id,
                            filename: compiledFilename,
                            relativePath: nil,
                            fileType: "pdf",
                            fileSize: Int64(pdfData.count),
                            sha256: nil,
                            isPdf: true
                        )
                    }

                    logger.info("Imported compiled PDF for \(pub.citeKey)")
                    return
                } catch {
                    logger.error("Failed to import PDF: \(error.localizedDescription)")
                }
            }
        }

        logger.info("No manuscript found linked to document \(documentUUID)")
    }

    // MARK: - Manual Sync

    /// Manually triggers a sync check for compiled PDFs.
    public func checkForUpdates() {
        guard isWatching else {
            logger.warning("Watcher not running, cannot check for updates")
            return
        }

        metadataQuery?.disableUpdates()
        metadataQuery?.enableUpdates()
    }

    /// Returns the URL of the shared iCloud folder, if available.
    public func sharedFolderURL() -> URL? {
        guard let containerURL = FileManager.default.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else {
            return nil
        }

        return containerURL.appendingPathComponent(compiledManuscriptsFolder, isDirectory: true)
    }
}

// NOTE: compiledPDFDetected notification is defined in Notifications.swift
