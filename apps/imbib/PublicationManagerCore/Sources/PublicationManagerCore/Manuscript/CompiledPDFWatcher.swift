//
//  CompiledPDFWatcher.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-27.
//

import Foundation
import CoreData
import os.log

// MARK: - Compiled PDF Watcher

/// Watches the shared iCloud container for compiled PDFs from imprint.
///
/// When imprint compiles a document and writes the PDF to the shared folder,
/// this watcher detects the change and imports the PDF as a CDLinkedFile
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

    /// View context for Core Data operations
    private var viewContext: NSManagedObjectContext?

    // MARK: - Lifecycle

    public func startWatching(context: NSManagedObjectContext) {
        guard !isWatching else { return }
        viewContext = context

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
    private func importCompiledPDF(documentUUID: UUID, pdfURL: URL) async {
        guard let context = viewContext else {
            logger.warning("No view context available for import")
            return
        }

        await MainActor.run {
            // Find the manuscript linked to this imprint document
            let fetchRequest: NSFetchRequest<CDPublication> = CDPublication.fetchRequest()
            // We need to search in rawFields since imprintDocumentUUID is stored there
            fetchRequest.predicate = NSPredicate(
                format: "rawFields CONTAINS %@",
                documentUUID.uuidString
            )

            do {
                let manuscripts = try context.fetch(fetchRequest)

                for manuscript in manuscripts {
                    // Verify this is actually linked to this document
                    guard manuscript.imprintDocumentUUID == documentUUID else {
                        continue
                    }

                    // Import or update the PDF
                    importPDF(from: pdfURL, to: manuscript, context: context)
                    logger.info("Imported compiled PDF for \(manuscript.citeKey)")
                    return
                }

                logger.info("No manuscript found linked to document \(documentUUID)")

            } catch {
                logger.error("Failed to fetch manuscripts: \(error.localizedDescription)")
            }
        }
    }

    private func importPDF(from url: URL, to manuscript: CDPublication, context: NSManagedObjectContext) {
        do {
            // Read PDF data
            let pdfData = try Data(contentsOf: url)

            // Check if we already have a compiled PDF linked file
            if let existingFileID = manuscript.compiledPDFLinkedFileID,
               let existingFile = manuscript.linkedFiles?.first(where: { $0.id == existingFileID }) {
                // Update existing file
                existingFile.fileData = pdfData
                existingFile.dateAdded = Date()
                existingFile.filename = "\(manuscript.citeKey)_compiled.pdf"
            } else {
                // Create new linked file
                let linkedFile = CDLinkedFile(context: context)
                linkedFile.id = UUID()
                linkedFile.filename = "\(manuscript.citeKey)_compiled.pdf"
                linkedFile.fileData = pdfData
                linkedFile.dateAdded = Date()
                linkedFile.mimeType = "application/pdf"
                linkedFile.isFileData = true

                // Add to manuscript
                manuscript.addToLinkedFiles(linkedFile)

                // Link as compiled PDF
                try manuscript.linkCompiledPDF(linkedFile, context: context)
            }

            try context.save()

        } catch {
            logger.error("Failed to import PDF: \(error.localizedDescription)")
        }
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

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when a compiled PDF is detected from imprint
    static let compiledPDFDetected = Notification.Name("com.imbib.compiledPDFDetected")
}
