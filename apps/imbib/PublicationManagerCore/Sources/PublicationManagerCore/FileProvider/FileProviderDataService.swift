//
//  FileProviderDataService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-25.
//

import Foundation
import CoreData
import OSLog

/// Service for querying and resolving publication PDFs for File Provider.
///
/// This service provides the data layer for the File Provider Extension,
/// querying Core Data for publications with PDFs and resolving their file URLs.
@MainActor
public final class FileProviderDataService: Sendable {

    // MARK: - Singleton

    public static let shared = FileProviderDataService()

    // MARK: - Properties

    private let fileManager = FileManager.default

    private nonisolated let logger = Logger(subsystem: "com.imbib.app", category: "fileprovider")

    // MARK: - Initialization

    public init() {}

    // MARK: - Query Publications

    /// Fetch all publications with PDFs.
    ///
    /// Returns lightweight DTOs suitable for File Provider enumeration.
    public func fetchPublicationsWithPDFs() async -> [FileProviderPublication] {
        let context = PersistenceController.shared.viewContext

        // Fetch all publications that have linked PDF files
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "ANY linkedFiles.fileType == %@", "pdf")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDPublication.dateModified, ascending: false)]

        do {
            let publications = try context.fetch(request)
            var results: [FileProviderPublication] = []

            for publication in publications {
                guard let linkedFiles = publication.linkedFiles else { continue }

                for linkedFile in linkedFiles where linkedFile.isPDF {
                    // Check if local file exists
                    let localExists = checkLocalFileExists(for: linkedFile, publication: publication)

                    if let item = FileProviderPublication(
                        publication: publication,
                        linkedFile: linkedFile,
                        localFileExists: localExists
                    ) {
                        results.append(item)
                    }
                }
            }

            logger.info("FileProviderDataService: Found \(results.count) PDFs")
            return results
        } catch {
            logger.error("FileProviderDataService: Failed to fetch publications: \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch a specific publication item by linked file ID.
    public func fetchItem(byLinkedFileID id: UUID) async -> FileProviderPublication? {
        let context = PersistenceController.shared.viewContext

        let request = NSFetchRequest<CDLinkedFile>(entityName: "LinkedFile")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1

        do {
            guard let linkedFile = try context.fetch(request).first,
                  let publication = linkedFile.publication else {
                return nil
            }

            let localExists = checkLocalFileExists(for: linkedFile, publication: publication)
            return FileProviderPublication(
                publication: publication,
                linkedFile: linkedFile,
                localFileExists: localExists
            )
        } catch {
            logger.error("FileProviderDataService: Failed to fetch item \(id): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - File Resolution

    /// Resolve the local file URL for a publication PDF.
    ///
    /// Returns nil if the file doesn't exist locally.
    public func resolveLocalURL(for item: FileProviderPublication) async -> URL? {
        let context = PersistenceController.shared.viewContext

        // Fetch the linked file
        let request = NSFetchRequest<CDLinkedFile>(entityName: "LinkedFile")
        request.predicate = NSPredicate(format: "id == %@", item.linkedFileID as CVarArg)
        request.fetchLimit = 1

        guard let linkedFile = try? context.fetch(request).first,
              let publication = linkedFile.publication else {
            return nil
        }

        // Get library for the publication
        let library = publication.libraries?.first

        // Use AttachmentManager to resolve URL
        let url = AttachmentManager.shared.resolveURL(for: linkedFile, in: library)

        // Verify file exists
        if let url = url, fileManager.fileExists(atPath: url.path) {
            return url
        }

        return nil
    }

    /// Materialize a CloudKit-only file to local disk.
    ///
    /// For files that only exist in CloudKit (fileData is set but no local file),
    /// this writes the data to disk and returns the file URL.
    ///
    /// - Parameters:
    ///   - item: The publication item to materialize
    ///   - destinationURL: Optional specific destination. If nil, uses the standard location.
    /// - Returns: The URL of the materialized file, or nil if failed
    public func materializeFile(for item: FileProviderPublication, to destinationURL: URL? = nil) async -> URL? {
        let context = PersistenceController.shared.viewContext

        // Fetch the linked file with CloudKit data
        let request = NSFetchRequest<CDLinkedFile>(entityName: "LinkedFile")
        request.predicate = NSPredicate(format: "id == %@", item.linkedFileID as CVarArg)
        request.fetchLimit = 1

        guard let linkedFile = try? context.fetch(request).first,
              let publication = linkedFile.publication else {
            logger.error("FileProviderDataService: Could not find linked file \(item.linkedFileID)")
            return nil
        }

        // Check if file already exists locally
        let library = publication.libraries?.first
        if let existingURL = AttachmentManager.shared.resolveURL(for: linkedFile, in: library),
           fileManager.fileExists(atPath: existingURL.path) {
            logger.debug("FileProviderDataService: File already exists at \(existingURL.path)")
            return existingURL
        }

        // Get data from CloudKit
        guard let fileData = linkedFile.fileData else {
            logger.warning("FileProviderDataService: No CloudKit data for \(item.linkedFileID)")
            return nil
        }

        // Determine destination
        let targetURL: URL
        if let destination = destinationURL {
            targetURL = destination
        } else if let library = library {
            // Use library container path
            let papersDir = library.papersContainerURL
            try? fileManager.createDirectory(at: papersDir, withIntermediateDirectories: true)
            targetURL = papersDir.appendingPathComponent(URL(fileURLWithPath: linkedFile.relativePath).lastPathComponent)
        } else {
            // Fall back to app support
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            let papersDir = appSupport.appendingPathComponent("imbib/DefaultLibrary/Papers")
            try? fileManager.createDirectory(at: papersDir, withIntermediateDirectories: true)
            targetURL = papersDir.appendingPathComponent(URL(fileURLWithPath: linkedFile.relativePath).lastPathComponent)
        }

        // Write file to disk
        do {
            try fileData.write(to: targetURL)
            logger.info("FileProviderDataService: Materialized \(targetURL.lastPathComponent) (\(fileData.count) bytes)")
            return targetURL
        } catch {
            logger.error("FileProviderDataService: Failed to write file: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Change Tracking

    /// Get current sync anchor (timestamp-based).
    ///
    /// Used by enumerator for incremental sync.
    public func currentSyncAnchor() -> Data {
        let timestamp = Date().timeIntervalSince1970
        return withUnsafeBytes(of: timestamp) { Data($0) }
    }

    /// Get publications modified since a given anchor.
    public func fetchChanges(since anchorData: Data) async -> (items: [FileProviderPublication], deleted: [UUID]) {
        guard anchorData.count == MemoryLayout<TimeInterval>.size else {
            // Invalid anchor, return all items
            let items = await fetchPublicationsWithPDFs()
            return (items, [])
        }

        let timestamp = anchorData.withUnsafeBytes { $0.load(as: TimeInterval.self) }
        let anchorDate = Date(timeIntervalSince1970: timestamp)

        let context = PersistenceController.shared.viewContext

        // Fetch publications modified since anchor
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(
            format: "dateModified > %@ AND ANY linkedFiles.fileType == %@",
            anchorDate as NSDate, "pdf"
        )
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDPublication.dateModified, ascending: false)]

        do {
            let publications = try context.fetch(request)
            var results: [FileProviderPublication] = []

            for publication in publications {
                guard let linkedFiles = publication.linkedFiles else { continue }

                for linkedFile in linkedFiles where linkedFile.isPDF {
                    let localExists = checkLocalFileExists(for: linkedFile, publication: publication)

                    if let item = FileProviderPublication(
                        publication: publication,
                        linkedFile: linkedFile,
                        localFileExists: localExists
                    ) {
                        results.append(item)
                    }
                }
            }

            // Note: Detecting deleted items requires tombstone tracking
            // For now, return empty deleted array
            return (results, [])
        } catch {
            logger.error("FileProviderDataService: Failed to fetch changes: \(error.localizedDescription)")
            return ([], [])
        }
    }

    // MARK: - Private Helpers

    private func checkLocalFileExists(for linkedFile: CDLinkedFile, publication: CDPublication) -> Bool {
        let library = publication.libraries?.first
        guard let url = AttachmentManager.shared.resolveURL(for: linkedFile, in: library) else {
            return false
        }
        return fileManager.fileExists(atPath: url.path)
    }
}
