//
//  FileProviderExtension.swift
//  imbib-FileProvider
//
//  Created by Claude on 2026-01-25.
//

import FileProvider
import PublicationManagerCore
import OSLog
import UniformTypeIdentifiers

/// File Provider extension that exposes imbib PDFs in Finder.
///
/// This extension provides a read-only view of all PDFs in the user's imbib library,
/// organized by bibcode (e.g., `2025ApJ...897..123B.pdf`).
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    // MARK: - Properties

    let domain: NSFileProviderDomain
    private let logger = Logger(subsystem: "com.imbib.app.fileprovider", category: "extension")

    // MARK: - Initialization

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        logger.info("FileProviderExtension initialized for domain: \(domain.displayName)")

        // Set up Darwin notification observer for changes from main app
        Task { @MainActor in
            FileProviderDomainManager.setupDarwinNotificationObserver { [weak self] in
                self?.handleLibraryChange()
            }
        }
    }

    // MARK: - NSFileProviderReplicatedExtension

    func invalidate() {
        logger.info("FileProviderExtension invalidated")
    }

    /// Return item for a given identifier.
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        logger.debug("item(for: \(identifier.rawValue))")

        // Handle special identifiers
        if identifier == .rootContainer {
            completionHandler(RootContainerItem(), nil)
            return Progress()
        }

        if identifier == .workingSet {
            // Working set is handled by enumeration
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        // Fetch item from data service
        Task { @MainActor in
            guard let uuid = UUID(uuidString: identifier.rawValue),
                  let publication = await FileProviderDataService.shared.fetchItem(byLinkedFileID: uuid) else {
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                return
            }

            let item = FileProviderItem(publication: publication)
            completionHandler(item, nil)
        }

        return Progress()
    }

    /// Fetch contents of a file (materialize PDF).
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        logger.info("fetchContents(for: \(itemIdentifier.rawValue))")

        Task { @MainActor in
            guard let uuid = UUID(uuidString: itemIdentifier.rawValue),
                  let publication = await FileProviderDataService.shared.fetchItem(byLinkedFileID: uuid) else {
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                return
            }

            // Try to get local URL first
            if let localURL = await FileProviderDataService.shared.resolveLocalURL(for: publication) {
                let item = FileProviderItem(publication: publication)
                completionHandler(localURL, item, nil)
                return
            }

            // Materialize from CloudKit if needed
            if let materializedURL = await FileProviderDataService.shared.materializeFile(for: publication) {
                let item = FileProviderItem(publication: publication)
                completionHandler(materializedURL, item, nil)
                return
            }

            // File not available
            self.logger.error("Failed to fetch contents for: \(itemIdentifier.rawValue)")
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
        }

        return Progress()
    }

    /// Create item - not supported (read-only).
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        logger.warning("createItem rejected - extension is read-only")
        completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
        return Progress()
    }

    /// Modify item - not supported (read-only).
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        logger.warning("modifyItem rejected - extension is read-only")
        completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
        return Progress()
    }

    /// Delete item - not supported (read-only).
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        logger.warning("deleteItem rejected - extension is read-only")
        completionHandler(NSFileProviderError(.notAuthenticated))
        return Progress()
    }

    /// Return enumerator for a container.
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        logger.debug("enumerator(for: \(containerItemIdentifier.rawValue))")

        switch containerItemIdentifier {
        case .rootContainer, .workingSet:
            return FileProviderEnumerator(containerItemIdentifier: containerItemIdentifier)
        default:
            // Flat hierarchy - no sub-folders
            throw NSFileProviderError(.noSuchItem)
        }
    }

    // MARK: - Materialization Lifecycle

    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        logger.debug("materializedItemsDidChange")
        completionHandler()
    }

    func pendingItemsDidChange(completionHandler: @escaping () -> Void) {
        logger.debug("pendingItemsDidChange")
        completionHandler()
    }

    // MARK: - Private

    private func handleLibraryChange() {
        logger.info("Received library change notification")

        // Signal the system to re-enumerate
        guard let manager = NSFileProviderManager(for: domain) else {
            return
        }

        Task {
            do {
                try await manager.signalEnumerator(for: .rootContainer)
                try await manager.signalEnumerator(for: .workingSet)
            } catch {
                logger.error("Failed to signal change: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Root Container Item

/// Represents the root container (imbib Papers folder).
private final class RootContainerItem: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { FileProviderDomainManager.domainDisplayName }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
}
