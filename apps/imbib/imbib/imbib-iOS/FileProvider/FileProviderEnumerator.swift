//
//  FileProviderEnumerator.swift
//  imbib-iOS-FileProvider
//
//  Created by Claude on 2026-01-25.
//

import FileProvider
import PublicationManagerCore
import OSLog

/// Enumerator for listing PDFs in the imbib library.
///
/// Provides both full enumeration and change-based updates using sync anchors.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    // MARK: - Properties

    private let containerItemIdentifier: NSFileProviderItemIdentifier
    private let logger = Logger(subsystem: "com.imbib.app.ios.fileprovider", category: "enumerator")

    // MARK: - Initialization

    init(containerItemIdentifier: NSFileProviderItemIdentifier) {
        self.containerItemIdentifier = containerItemIdentifier
        super.init()
    }

    // MARK: - NSFileProviderEnumerator

    func invalidate() {
        logger.debug("Enumerator invalidated for: \(self.containerItemIdentifier.rawValue)")
    }

    /// Enumerate all items (full enumeration).
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        logger.info("enumerateItems for: \(self.containerItemIdentifier.rawValue)")

        Task { @MainActor in
            let publications = await FileProviderDataService.shared.fetchPublicationsWithPDFs()
            let items = publications.map { FileProviderItem(publication: $0) }

            self.logger.info("Enumerated \(items.count) items")
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
        }
    }

    /// Enumerate changes since a sync anchor (incremental updates).
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        logger.info("enumerateChanges from anchor")

        Task { @MainActor in
            let (changed, deleted) = await FileProviderDataService.shared.fetchChanges(since: syncAnchor.rawValue)

            // Report updated items
            let updatedItems = changed.map { FileProviderItem(publication: $0) }
            if !updatedItems.isEmpty {
                observer.didUpdate(updatedItems)
                self.logger.info("Reported \(updatedItems.count) updated items")
            }

            // Report deleted items
            let deletedIdentifiers = deleted.map { NSFileProviderItemIdentifier($0.uuidString) }
            if !deletedIdentifiers.isEmpty {
                observer.didDeleteItems(withIdentifiers: deletedIdentifiers)
                self.logger.info("Reported \(deletedIdentifiers.count) deleted items")
            }

            // Finish with new anchor
            let newAnchor = NSFileProviderSyncAnchor(FileProviderDataService.shared.currentSyncAnchor())
            observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
        }
    }

    /// Return current sync anchor.
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task { @MainActor in
            let anchorData = FileProviderDataService.shared.currentSyncAnchor()
            let anchor = NSFileProviderSyncAnchor(anchorData)
            completionHandler(anchor)
        }
    }
}
