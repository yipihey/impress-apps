//
//  ProjectSidebarViewModel.swift
//  imprint
//
//  View model for the project browser sidebar.
//  Manages folder hierarchy, expansion state, selection, drag-drop, and CRUD operations.
//

import Foundation
import SwiftUI
import CoreData
import UniformTypeIdentifiers
import ImpressSidebar
import OSLog
import ImpressLogging

#if os(macOS)
import AppKit
#endif

private let logger = Logger(subsystem: "com.imbib.imprint", category: "folders")

@MainActor @Observable
public final class ProjectSidebarViewModel {

    // MARK: - State

    /// Root folders in the current workspace
    var rootFolders: [CDFolder] = []

    /// Expansion state for the folder tree
    let expansionState = TreeExpansionState()

    /// Currently selected folder ID
    var selectedFolderID: UUID?

    /// Folder currently being edited inline (rename)
    var editingFolderID: UUID?

    /// The current workspace
    private(set) var workspace: CDWorkspace?

    /// Section collapse state
    var collapsedSections: Set<ImprintSidebarSection>

    /// Section ordering
    var sectionOrder: [ImprintSidebarSection]

    /// Incremented on each data change to trigger SidebarOutlineView updates
    var dataVersion: Int = 0

    /// The section currently being hovered for section reorder
    var sectionDropTarget: ImprintSidebarSection?

    // MARK: - Dependencies

    private let repository = FolderRepository.shared
    private let persistence = ImprintPersistenceController.shared

    // MARK: - Init

    init() {
        self.collapsedSections = ImprintSidebarSection.collapsedStore.loadSync()
        self.sectionOrder = ImprintSidebarSection.orderStore.loadSync()
    }

    // MARK: - Loading

    func loadWorkspace() {
        persistence.ensureDefaultWorkspace()
        workspace = persistence.defaultWorkspace()
        reloadFolders()
    }

    func reloadFolders() {
        guard let workspace = workspace else { return }
        rootFolders = workspace.sortedRootFolders
        dataVersion += 1
        logger.infoCapture("Loaded \(rootFolders.count) root folders", category: "folders")
    }

    // MARK: - Computed

    /// The currently selected folder
    var selectedFolder: CDFolder? {
        guard let id = selectedFolderID else { return nil }
        return findFolder(by: id)
    }

    #if os(macOS)
    /// Configuration for the SidebarOutlineView
    var outlineConfiguration: SidebarOutlineConfiguration<FolderNodeAdapter> {
        SidebarOutlineConfiguration(
            rootNodes: rootFolders.asFolderAdapters(),
            childrenOf: { adapter in
                adapter.folder.sortedChildren.asFolderAdapters()
            },
            capabilitiesOf: { _ in .libraryCollection },
            pasteboardType: .init(rawValue: UTType.imprintFolderID.identifier),
            onReorder: { [weak self] siblings, parent in
                self?.handleReorder(siblings: siblings, parent: parent)
            },
            onReparent: { [weak self] node, newParent in
                self?.handleReparent(node: node, newParent: newParent)
            },
            onExternalDrop: { [weak self] pasteboard, targetNode in
                self?.handleExternalDrop(pasteboard: pasteboard, targetNode: targetNode) ?? false
            },
            onRename: { [weak self] node, newName in
                self?.renameFolder(node.folder, to: newName)
            },
            contextMenu: { [weak self] node in
                self?.buildContextMenu(for: node)
            },
            canAcceptDrop: { draggedNode, targetNode in
                // Can't drop onto self
                if let target = targetNode, target.id == draggedNode.id { return false }
                // Can't drop onto a descendant
                if let target = targetNode, target.ancestorIDs.contains(draggedNode.id) { return false }
                return true
            }
        )
    }
    #endif

    // MARK: - Folder CRUD

    func createFolder(name: String = "New Folder", parent: CDFolder? = nil) {
        guard let workspace = workspace else { return }
        do {
            let folder = try repository.createFolder(name: name, parent: parent, in: workspace)
            reloadFolders()

            // Expand parent to show new folder
            if let parent = parent {
                expansionState.expand(parent.id)
            }

            // Select and begin rename
            selectedFolderID = folder.id
            editingFolderID = folder.id
        } catch {
            logger.errorCapture("Failed to create folder: \(error.localizedDescription)", category: "folders")
        }
    }

    func createSubfolder(in parent: CDFolder) {
        createFolder(name: "New Folder", parent: parent)
    }

    func renameFolder(_ folder: CDFolder, to newName: String) {
        guard !newName.isEmpty else { return }
        do {
            try repository.renameFolder(folder, to: newName)
            reloadFolders()
        } catch {
            logger.errorCapture("Failed to rename folder: \(error.localizedDescription)", category: "folders")
        }
        editingFolderID = nil
    }

    func deleteFolder(_ folder: CDFolder) {
        do {
            if selectedFolderID == folder.id {
                selectedFolderID = nil
            }
            try repository.deleteFolder(folder)
            reloadFolders()
        } catch {
            logger.errorCapture("Failed to delete folder: \(error.localizedDescription)", category: "folders")
        }
    }

    func moveFolder(_ folder: CDFolder, to newParent: CDFolder?) {
        guard let workspace = workspace else { return }
        // Prevent dropping a folder onto itself or its descendant
        if let newParent = newParent {
            if newParent.id == folder.id { return }
            if newParent.ancestors.contains(where: { $0.id == folder.id }) { return }
        }
        do {
            try repository.moveFolder(folder, to: newParent, in: workspace)
            reloadFolders()
        } catch {
            logger.errorCapture("Failed to move folder: \(error.localizedDescription)", category: "folders")
        }
    }

    // MARK: - SidebarOutlineView Callbacks

    /// Handle reorder from NSOutlineView (siblings reordered within parent)
    private func handleReorder(siblings: [FolderNodeAdapter], parent: FolderNodeAdapter?) {
        let folders = siblings.map { $0.folder }
        do {
            try repository.reorderFolders(folders)
            reloadFolders()
            logger.infoCapture("Reordered \(folders.count) sibling folders", category: "folders")
        } catch {
            logger.errorCapture("Failed to reorder folders: \(error.localizedDescription)", category: "folders")
        }
    }

    /// Handle reparent from NSOutlineView (node moved to new parent)
    private func handleReparent(node: FolderNodeAdapter, newParent: FolderNodeAdapter?) {
        let folder = node.folder
        let parentFolder = newParent?.folder
        moveFolder(folder, to: parentFolder)
        if let parentFolder = parentFolder {
            expansionState.expand(parentFolder.id)
            logger.infoCapture("Reparented '\(folder.name)' into '\(parentFolder.name)'", category: "folders")
        } else {
            logger.infoCapture("Moved '\(folder.name)' to root", category: "folders")
        }
    }

    #if os(macOS)
    /// Handle external file drops from NSOutlineView
    private func handleExternalDrop(pasteboard: NSPasteboard, targetNode: FolderNodeAdapter?) -> Bool {
        guard let targetNode = targetNode else { return false }

        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.fileURL.identifier]
        ]) as? [URL] else {
            return false
        }

        var handled = false
        for url in urls {
            guard url.pathExtension == "imprint" else { continue }
            addDocumentToFolder(url: url, folder: targetNode.folder)
            handled = true
        }
        return handled
    }

    /// Build an NSMenu for the context menu on a folder node
    private func buildContextMenu(for node: FolderNodeAdapter) -> NSMenu {
        let menu = NSMenu()
        let folder = node.folder

        let newSubfolder = NSMenuItem(title: "New Subfolder", action: #selector(ContextMenuActions.newSubfolder(_:)), keyEquivalent: "")
        newSubfolder.representedObject = folder
        newSubfolder.target = ContextMenuActions.shared
        menu.addItem(newSubfolder)

        menu.addItem(.separator())

        let rename = NSMenuItem(title: "Rename", action: #selector(ContextMenuActions.rename(_:)), keyEquivalent: "")
        rename.representedObject = folder
        rename.target = ContextMenuActions.shared
        menu.addItem(rename)

        menu.addItem(.separator())

        let share = NSMenuItem(title: "Share...", action: #selector(ContextMenuActions.share(_:)), keyEquivalent: "")
        share.representedObject = folder
        share.target = ContextMenuActions.shared
        menu.addItem(share)

        menu.addItem(.separator())

        let delete = NSMenuItem(title: "Delete", action: #selector(ContextMenuActions.delete(_:)), keyEquivalent: "")
        delete.representedObject = folder
        delete.target = ContextMenuActions.shared
        menu.addItem(delete)

        // Store a weak reference to self for the actions
        ContextMenuActions.shared.viewModel = self

        return menu
    }
    #endif

    // MARK: - Section Reordering

    @discardableResult
    func handleSectionDrop(providers: [NSItemProvider], targetSection: ImprintSidebarSection) -> Bool {
        SectionDragReorder.handleDrop(
            providers: providers,
            typeIdentifier: UTType.imprintSidebarSectionID.identifier,
            targetSection: targetSection,
            currentOrder: sectionOrder
        ) { [weak self] newOrder in
            self?.sectionOrder = newOrder
            Task { await ImprintSidebarSection.orderStore.save(newOrder) }
        }
    }

    // MARK: - Document References

    func addDocumentToFolder(url: URL, folder: CDFolder) {
        do {
            let (title, authors, docUUID) = readDocumentMetadata(from: url)
            _ = try repository.addDocumentReference(
                url: url,
                documentUUID: docUUID,
                title: title,
                authors: authors,
                to: folder
            )
            reloadFolders()
        } catch {
            logger.errorCapture("Failed to add document to folder: \(error.localizedDescription)", category: "folders")
        }
    }

    func removeDocumentReference(_ ref: CDDocumentReference) {
        do {
            try repository.removeDocumentReference(ref)
            reloadFolders()
        } catch {
            logger.errorCapture("Failed to remove document reference: \(error.localizedDescription)", category: "folders")
        }
    }

    /// Document references for the selected folder
    var selectedFolderDocRefs: [CDDocumentReference] {
        guard let folder = selectedFolder else { return [] }
        return (folder.documentRefs ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - Section Collapse

    func toggleSection(_ section: ImprintSidebarSection) {
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
        Task {
            await ImprintSidebarSection.collapsedStore.save(collapsedSections)
        }
    }

    // MARK: - Helpers

    func findFolder(by id: UUID) -> CDFolder? {
        func search(in folders: [CDFolder]) -> CDFolder? {
            for folder in folders {
                if folder.id == id { return folder }
                if let found = search(in: folder.sortedChildren) { return found }
            }
            return nil
        }
        return search(in: rootFolders)
    }

    private func readDocumentMetadata(from url: URL) -> (title: String?, authors: String?, docUUID: UUID?) {
        let metadataURL = url.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        let title = json["title"] as? String
        let authors = json["authors"] as? String
        let docUUID: UUID? = (json["id"] as? String).flatMap { UUID(uuidString: $0) }
        return (title, authors, docUUID)
    }
}

// MARK: - Context Menu Actions (NSMenu target-action bridge)

#if os(macOS)
@MainActor
final class ContextMenuActions: NSObject {
    static let shared = ContextMenuActions()
    weak var viewModel: ProjectSidebarViewModel?

    @objc func newSubfolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? CDFolder else { return }
        viewModel?.createSubfolder(in: folder)
    }

    @objc func rename(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? CDFolder else { return }
        viewModel?.editingFolderID = folder.id
    }

    @objc func share(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? CDFolder else { return }
        Task {
            do {
                let (_, share) = try await ImprintCloudKitSharingService.shared.shareFolder(folder)
                await MainActor.run {
                    guard let sharingService = NSSharingService(named: .cloudSharing) else { return }
                    sharingService.perform(withItems: [share])
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Sharing Unavailable"
                    alert.informativeText = "CloudKit sharing is not yet enabled. This feature will be available in a future release once the iCloud container schema is finalized."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    if let window = NSApp.keyWindow {
                        alert.beginSheetModal(for: window)
                    } else {
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc func delete(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? CDFolder else { return }
        viewModel?.deleteFolder(folder)
    }
}
#endif
