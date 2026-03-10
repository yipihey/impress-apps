//
//  DocumentBookmarkService.swift
//  imprint
//
//  Manages security-scoped bookmarks for .imprint document references.
//  Handles creation, resolution, and staleness refresh.
//

import Foundation
import OSLog
import ImpressLogging

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
                Logger.bookmarks.warningCapture("Could not access security-scoped resource for stale bookmark refresh", category: "bookmarks")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let newBookmark = try createBookmark(for: url)
            ref.fileBookmark = newBookmark
            try ref.managedObjectContext?.save()

            Logger.bookmarks.infoCapture("Refreshed stale bookmark for '\(ref.displayTitle)'", category: "bookmarks")
        } catch {
            Logger.bookmarks.warningCapture("Failed to refresh stale bookmark: \(error.localizedDescription)", category: "bookmarks")
        }
    }
}
