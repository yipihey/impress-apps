//
//  DocumentMetadataCacheService.swift
//  imprint
//
//  Refreshes cached titles and authors on CDDocumentReference objects
//  by reading metadata.json from .imprint packages.
//

import Foundation
import CoreData
import OSLog

private let logger = Logger(subsystem: "com.imbib.imprint", category: "metadata-cache")

public actor DocumentMetadataCacheService {

    public static let shared = DocumentMetadataCacheService()

    /// Refresh cached metadata for all document references.
    /// Only reads metadata.json, not the full document.
    @MainActor
    public func refreshAll() {
        let context = ImprintPersistenceController.shared.viewContext
        let request = NSFetchRequest<CDDocumentReference>(entityName: "DocumentReference")

        do {
            let refs = try context.fetch(request)
            var updatedCount = 0

            for ref in refs {
                guard let bookmarkData = ref.fileBookmark else { continue }

                do {
                    var isStale = false
                    let url = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )

                    guard url.startAccessingSecurityScopedResource() else { continue }
                    defer { url.stopAccessingSecurityScopedResource() }

                    // Refresh stale bookmark
                    if isStale {
                        DocumentBookmarkService.refreshStaleBookmark(for: ref)
                    }

                    // Read metadata.json
                    let metadataURL = url.appendingPathComponent("metadata.json")
                    guard let data = try? Data(contentsOf: metadataURL),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }

                    let title = json["title"] as? String
                    let authors = json["authors"] as? String

                    if ref.cachedTitle != title || ref.cachedAuthors != authors {
                        ref.cachedTitle = title
                        ref.cachedAuthors = authors
                        updatedCount += 1
                    }
                } catch {
                    logger.warning("Failed to read metadata for ref \(ref.id): \(error.localizedDescription)")
                }
            }

            if context.hasChanges {
                try context.save()
                logger.info("Refreshed metadata cache: \(updatedCount) documents updated")
            }
        } catch {
            logger.error("Failed to refresh metadata cache: \(error.localizedDescription)")
        }
    }
}
