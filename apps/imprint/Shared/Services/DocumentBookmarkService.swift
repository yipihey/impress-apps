//
//  DocumentBookmarkService.swift
//  imprint
//
//  Manages security-scoped bookmarks for .imprint document references.
//  Handles creation, resolution, and staleness refresh.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imbib.imprint", category: "bookmarks")

public enum DocumentBookmarkService {

    /// Create a security-scoped bookmark for a file URL
    public static func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: [.contentModificationDateKey, .nameKey],
            relativeTo: nil
        )
    }

    /// Resolve a bookmark back to a URL. Returns (url, isStale).
    public static func resolveBookmark(_ data: Data) throws -> (URL, Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    /// Refresh a stale bookmark on a CDDocumentReference
    @MainActor
    public static func refreshStaleBookmark(for ref: CDDocumentReference) {
        guard let bookmarkData = ref.fileBookmark else { return }

        do {
            let (url, isStale) = try resolveBookmark(bookmarkData)
            guard isStale else { return }

            guard url.startAccessingSecurityScopedResource() else {
                logger.warning("Could not access security-scoped resource for stale bookmark refresh")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let newBookmark = try createBookmark(for: url)
            ref.fileBookmark = newBookmark
            try ref.managedObjectContext?.save()

            logger.info("Refreshed stale bookmark for '\(ref.displayTitle)'")
        } catch {
            logger.warning("Failed to refresh stale bookmark: \(error.localizedDescription)")
        }
    }
}
