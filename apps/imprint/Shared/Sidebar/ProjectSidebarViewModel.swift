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
        Logger.folders.infoCapture("Loaded \(rootFolders.count) root folders", category: "sidebar")
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
            additionalDragTypes: [
                // Document references dragged from the detail list — handled in handleExternalDrop.
                .init(rawValue: UTType.imprintDocRefID.identifier)
            ],
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
            Logger.folders.errorCapture("Failed to create folder: \(error.localizedDescription)", category: "sidebar")
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
            Logger.folders.errorCapture("Failed to rename folder: \(error.localizedDescription)", category: "sidebar")
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
            Logger.folders.errorCapture("Failed to delete folder: \(error.localizedDescription)", category: "sidebar")
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
            Logger.folders.errorCapture("Failed to move folder: \(error.localizedDescription)", category: "sidebar")
        }
    }

    // MARK: - SidebarOutlineView Callbacks

    /// Handle reorder from NSOutlineView (siblings reordered within parent)
    private func handleReorder(siblings: [FolderNodeAdapter], parent: FolderNodeAdapter?) {
        let folders = siblings.map { $0.folder }
        do {
            try repository.reorderFolders(folders)
            reloadFolders()
            Logger.folders.infoCapture("Reordered \(folders.count) sibling folders", category: "sidebar")
        } catch {
            Logger.folders.errorCapture("Failed to reorder folders: \(error.localizedDescription)", category: "sidebar")
        }
    }

    /// Handle reparent from NSOutlineView (node moved to new parent)
    private func handleReparent(node: FolderNodeAdapter, newParent: FolderNodeAdapter?) {
        let folder = node.folder
        let parentFolder = newParent?.folder
        moveFolder(folder, to: parentFolder)
        if let parentFolder = parentFolder {
            expansionState.expand(parentFolder.id)
            Logger.folders.infoCapture("Reparented '\(folder.name)' into '\(parentFolder.name)'", category: "sidebar")
        } else {
            Logger.folders.infoCapture("Moved '\(folder.name)' to root", category: "sidebar")
        }
    }

    #if os(macOS)
    /// File extensions the sidebar accepts as manuscript documents.
    /// `imprint` is the native package format; the rest are LaTeX / Typst /
    /// bibliography source files that we reference directly.
    private static let supportedDocExtensions: Set<String> = [
        "imprint",
        "tex", "latex", "ltx",
        "typ", "typst",
        "bib",
        "cls", "sty", "bst",
        "md", "markdown"
    ]

    /// File extensions to skip even when they show up inside a dropped
    /// directory — LaTeX build noise, editor metadata, OS droppings.
    private static let ignoredExtensions: Set<String> = [
        "aux", "log", "out", "toc", "lof", "lot", "bbl", "blg",
        "fdb_latexmk", "fls", "synctex", "gz",
        "pdf", "dvi", "ps",
        "ds_store", "swp", "bak"
    ]

    /// Directory basenames to skip when mirroring a dropped directory.
    private static let ignoredDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", ".build", ".DS_Store",
        "_minted", "_region_", ".texpadtmp"
    ]

    /// Handle external file drops from NSOutlineView.
    ///
    /// Accepts:
    /// - Single manuscript-source files (.tex, .typ, .bib, .imprint, …) —
    ///   added as document references in the target folder.
    /// - Directories — mirrored as a subfolder tree under the target,
    ///   with every supported file inside added as a document reference
    ///   in the corresponding mirrored folder. Empty / noise-only
    ///   directories are dropped silently.
    ///
    /// When the drop lands somewhere NSOutlineView doesn't resolve to a
    /// folder (empty sidebar space, gap between rows, document-reference
    /// row) the handler falls back to: currently-selected folder → first
    /// root folder → a newly-created "Imported" root folder. This keeps
    /// drops from silently failing when the user misses a folder row by
    /// a few pixels.
    ///
    /// Every branch logs to the in-app console (Cmd+Shift+C) with the
    /// `sidebar` category so failures and happy paths are both visible.
    private func handleExternalDrop(pasteboard: NSPasteboard, targetNode: FolderNodeAdapter?) -> Bool {
        let rawTypes = pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "-"
        Logger.folders.infoCapture(
            "Drop received: targetNode='\(targetNode?.folder.name ?? "nil")' pasteboardTypes=[\(rawTypes)]",
            category: "sidebar"
        )

        // --- Doc-ref internal move (DocumentRefRow dragged from detail list) ---
        //
        // The pasteboard advertises `com.imbib.imprint.doc-ref-id`, but
        // because SwiftUI's `.draggable(Transferable)` on macOS registers
        // data via NSItemProvider's lazy mechanism, neither
        // `pasteboard.data(forType:)` nor `pasteboardItems[i].data(forType:)`
        // reliably materializes the UUID synchronously. The source-side
        // `DocRefDragItem` serializer also pins the active UUID into a
        // `DocRefDragSession` singleton — that's the authoritative read.
        let docRefType = NSPasteboard.PasteboardType(rawValue: UTType.imprintDocRefID.identifier)
        if pasteboard.types?.contains(docRefType) == true {
            // Try the pasteboard fast-path first (defensive — in case a
            // future SwiftUI version fixes the eager write).
            for item in pasteboard.pasteboardItems ?? [] {
                if let data = item.data(forType: docRefType),
                   let uuidString = String(data: data, encoding: .utf8),
                   let refUUID = UUID(uuidString: uuidString) {
                    return handleDocRefMove(refUUID: refUUID, targetNode: targetNode)
                }
            }
            if let data = pasteboard.data(forType: docRefType),
               let uuidString = String(data: data, encoding: .utf8),
               let refUUID = UUID(uuidString: uuidString) {
                return handleDocRefMove(refUUID: refUUID, targetNode: targetNode)
            }
            // Fallback: consume from the in-process session pinned by the
            // Transferable's DataRepresentation serializer.
            if let refUUID = DocRefDragSession.shared.consume() {
                Logger.folders.infoCapture(
                    "Doc-ref drop: pasteboard yielded no data; resolved via drag session (refID=\(refUUID))",
                    category: "sidebar"
                )
                return handleDocRefMove(refUUID: refUUID, targetNode: targetNode)
            }
            Logger.folders.warningCapture(
                "Doc-ref drop: pasteboard advertised \(docRefType.rawValue) but yielded no data AND the drag session was empty (items=\(pasteboard.pasteboardItems?.count ?? 0))",
                category: "sidebar"
            )
            return false
        }

        // NOTE: no filter on `urlReadingContentsConformToTypes` — that option
        // expects CONTENT-type UTIs (e.g. public.text), not URL UTIs. Passing
        // `public.file-url` silently rejects every dropped file. Our own
        // extension filter below decides which URLs we care about.
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL] else {
            Logger.folders.warningCapture(
                "Drop rejected: pasteboard had no file URLs (types=[\(rawTypes)])",
                category: "sidebar"
            )
            return false
        }

        guard !urls.isEmpty else {
            Logger.folders.warningCapture("Drop rejected: empty URL list", category: "sidebar")
            return false
        }

        guard let targetFolder = resolveDropTarget(explicit: targetNode) else {
            Logger.folders.errorCapture(
                "Drop rejected: no workspace open, cannot resolve a target folder",
                category: "sidebar"
            )
            return false
        }
        Logger.folders.infoCapture(
            "Drop target resolved to folder '\(targetFolder.name)' for \(urls.count) URL(s)",
            category: "sidebar"
        )

        var handled = false
        for url in urls {
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }

            let name = url.lastPathComponent
            if !started {
                // Not always fatal — sandboxed drops sometimes succeed
                // without an explicit scope, but log it so we can correlate
                // with later bookmark / read failures.
                Logger.folders.warningCapture(
                    "startAccessingSecurityScopedResource returned false for '\(name)' — continuing",
                    category: "sidebar"
                )
            }

            if isDirectory(url) {
                Logger.folders.infoCapture("Dropped '\(name)' kind=dir", category: "sidebar")
                if importDirectory(at: url, into: targetFolder) {
                    handled = true
                } else {
                    Logger.folders.warningCapture(
                        "Directory '\(name)' contained no supported files; nothing imported",
                        category: "sidebar"
                    )
                }
            } else {
                let ext = url.pathExtension.lowercased()
                if Self.supportedDocExtensions.contains(ext) {
                    Logger.folders.infoCapture(
                        "Dropped '\(name)' kind=file ext=\(ext) → folder '\(targetFolder.name)'",
                        category: "sidebar"
                    )
                    addDocumentToFolder(url: url, folder: targetFolder)
                    handled = true
                } else {
                    Logger.folders.warningCapture(
                        "Dropped '\(name)' kind=skipped ext='\(ext)' (not in supported set)",
                        category: "sidebar"
                    )
                }
            }
        }
        Logger.folders.infoCapture(
            "Drop processed: handled=\(handled) urls=\(urls.count) target='\(targetFolder.name)'",
            category: "sidebar"
        )
        return handled
    }

    /// Handle a drag from the detail list where the pasteboard carries a
    /// `DocRefDragItem`. Looks up the CDDocumentReference by UUID and asks
    /// the repository to reparent it.
    private func handleDocRefMove(refUUID: UUID, targetNode: FolderNodeAdapter?) -> Bool {
        guard let targetFolder = resolveDropTarget(explicit: targetNode) else {
            Logger.folders.errorCapture(
                "Doc-ref move rejected: no target folder could be resolved",
                category: "sidebar"
            )
            return false
        }
        guard let ref = findDocumentReference(id: refUUID) else {
            Logger.folders.warningCapture(
                "Doc-ref move rejected: no reference found with id \(refUUID)",
                category: "sidebar"
            )
            return false
        }
        let originalFolder = ref.folder?.name ?? "(none)"
        if ref.folder?.id == targetFolder.id {
            Logger.folders.infoCapture(
                "Doc-ref move no-op: '\(ref.displayTitle)' already in '\(targetFolder.name)'",
                category: "sidebar"
            )
            return true
        }
        do {
            try repository.moveDocumentReference(ref, to: targetFolder)
            Logger.folders.infoCapture(
                "Moved ref '\(ref.displayTitle)': '\(originalFolder)' → '\(targetFolder.name)'",
                category: "sidebar"
            )
            expansionState.expand(targetFolder.id)
            reloadFolders()
            return true
        } catch {
            Logger.folders.errorCapture(
                "Failed to move ref '\(ref.displayTitle)' to '\(targetFolder.name)': \(error.localizedDescription)",
                category: "sidebar"
            )
            return false
        }
    }

    /// Find a `CDDocumentReference` by id — walks every folder's refs since
    /// refs live under folders (not the workspace). O(total refs) but that's
    /// negligible for reasonable workspaces.
    private func findDocumentReference(id: UUID) -> CDDocumentReference? {
        func search(in folders: [CDFolder]) -> CDDocumentReference? {
            for folder in folders {
                if let ref = (folder.documentRefs ?? []).first(where: { $0.id == id }) {
                    return ref
                }
                if let found = search(in: folder.sortedChildren) {
                    return found
                }
            }
            return nil
        }
        return search(in: rootFolders)
    }

    /// Pick the folder to use for an external drop. Prefers what
    /// NSOutlineView resolved to, falling back to the selected folder, the
    /// first root folder, and finally a newly-created `Imported` folder.
    /// Returns nil only when there's no workspace.
    private func resolveDropTarget(explicit: FolderNodeAdapter?) -> CDFolder? {
        if let folder = explicit?.folder {
            return folder
        }
        if let selectedID = selectedFolderID, let selected = findFolder(by: selectedID) {
            Logger.folders.infoCapture(
                "Drop target fallback: no explicit node, using selected folder '\(selected.name)'",
                category: "sidebar"
            )
            return selected
        }
        if let first = rootFolders.first {
            Logger.folders.infoCapture(
                "Drop target fallback: no selection, using first root folder '\(first.name)'",
                category: "sidebar"
            )
            return first
        }
        guard let workspace = workspace else {
            return nil
        }
        do {
            let folder = try repository.createFolder(name: "Imported", parent: nil, in: workspace)
            Logger.folders.infoCapture(
                "Drop target fallback: created root folder 'Imported'",
                category: "sidebar"
            )
            reloadFolders()
            selectedFolderID = folder.id
            return folder
        } catch {
            Logger.folders.errorCapture(
                "Drop target fallback: failed to create 'Imported' folder: \(error.localizedDescription)",
                category: "sidebar"
            )
            return nil
        }
    }

    /// Recursively mirror a dropped directory under `parentFolder`.
    /// Creates a subfolder for the dropped directory (and each subdirectory
    /// that contains at least one supported file), then imports each
    /// supported file as a document reference. Returns `true` if anything
    /// was imported.
    @discardableResult
    private func importDirectory(at dirURL: URL, into parentFolder: CDFolder) -> Bool {
        let baseName = dirURL.lastPathComponent
        if Self.ignoredDirectoryNames.contains(baseName.lowercased()) || baseName.hasPrefix(".") {
            Logger.folders.infoCapture("Skipped directory '\(baseName)' (ignored name)", category: "sidebar")
            return false
        }

        guard let workspace = workspace else {
            Logger.folders.errorCapture(
                "importDirectory('\(baseName)') aborted: no workspace",
                category: "sidebar"
            )
            return false
        }

        // Walk children once so we can skip creating an empty folder for
        // directories that contain nothing importable.
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Logger.folders.errorCapture(
                "importDirectory('\(baseName)') read failed: \(error.localizedDescription)",
                category: "sidebar"
            )
            return false
        }

        let importableChildren = children.filter { child in
            let name = child.lastPathComponent
            if name.hasPrefix(".") { return false }
            if isDirectory(child) {
                return !Self.ignoredDirectoryNames.contains(name.lowercased())
            }
            let ext = child.pathExtension.lowercased()
            if Self.ignoredExtensions.contains(ext) { return false }
            return Self.supportedDocExtensions.contains(ext)
        }

        Logger.folders.infoCapture(
            "importDirectory('\(baseName)'): \(children.count) children, \(importableChildren.count) importable",
            category: "sidebar"
        )

        // Probe: does this subtree contain *anything* we'd import?
        // (Avoids creating empty mirror folders for directories that just
        // hold build artefacts.)
        if !containsSupportedFile(in: importableChildren) {
            Logger.folders.infoCapture(
                "importDirectory('\(baseName)') skipped: no supported files in subtree",
                category: "sidebar"
            )
            return false
        }

        let subfolder: CDFolder
        do {
            subfolder = try repository.createFolder(name: baseName, parent: parentFolder, in: workspace)
            Logger.folders.infoCapture(
                "Mirrored directory '\(baseName)' → folder under '\(parentFolder.name)'",
                category: "sidebar"
            )
        } catch {
            Logger.folders.errorCapture(
                "Failed to create folder for dropped directory '\(baseName)': \(error.localizedDescription)",
                category: "sidebar"
            )
            return false
        }

        var anyImported = false
        for child in importableChildren {
            if isDirectory(child) {
                if importDirectory(at: child, into: subfolder) { anyImported = true }
            } else {
                addDocumentToFolder(url: child, folder: subfolder)
                anyImported = true
            }
        }

        if anyImported {
            expansionState.expand(parentFolder.id)
            expansionState.expand(subfolder.id)
        } else {
            // All children turned out to be empty dirs — drop the subfolder.
            Logger.folders.infoCapture(
                "Rolling back empty mirror folder '\(baseName)' (no imports after recursion)",
                category: "sidebar"
            )
            try? repository.deleteFolder(subfolder)
        }
        reloadFolders()
        return anyImported
    }

    /// True when the subtree rooted at any of `urls` has at least one file
    /// whose extension is supported. Cheap — opens no files, just stats dirs.
    private func containsSupportedFile(in urls: [URL]) -> Bool {
        for url in urls {
            if isDirectory(url) {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                if containsSupportedFile(in: children) { return true }
            } else if Self.supportedDocExtensions.contains(url.pathExtension.lowercased()) {
                return true
            }
        }
        return false
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
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
            let resolvedTitle = title ?? url.deletingPathExtension().lastPathComponent
            _ = try repository.addDocumentReference(
                url: url,
                documentUUID: docUUID,
                title: resolvedTitle,
                authors: authors,
                to: folder
            )
            Logger.folders.infoCapture(
                "Added reference '\(resolvedTitle)' (\(url.lastPathComponent)) to folder '\(folder.name)'",
                category: "sidebar"
            )
            reloadFolders()
        } catch {
            Logger.folders.errorCapture(
                "Failed to add '\(url.lastPathComponent)' to folder '\(folder.name)': \(error.localizedDescription)",
                category: "sidebar"
            )
        }
    }

    func removeDocumentReference(_ ref: CDDocumentReference) {
        do {
            try repository.removeDocumentReference(ref)
            reloadFolders()
        } catch {
            Logger.folders.errorCapture("Failed to remove document reference: \(error.localizedDescription)", category: "sidebar")
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

    /// Extract (title, authors, documentUUID) from a dropped file.
    ///
    /// For `.imprint` packages we read the bundled `metadata.json`. For LaTeX
    /// / Typst / BibTeX / Markdown sources we look for a title (and author
    /// line for LaTeX) inside the first chunk of the file. `docUUID` is
    /// always nil for non-`.imprint` files — imprint assigns one on first
    /// open if needed.
    private func readDocumentMetadata(from url: URL) -> (title: String?, authors: String?, docUUID: UUID?) {
        let ext = url.pathExtension.lowercased()
        if ext == "imprint" {
            let metadataURL = url.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (url.deletingPathExtension().lastPathComponent, nil, nil)
            }
            let title = (json["title"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let authors = json["authors"] as? String
            let docUUID: UUID? = (json["id"] as? String).flatMap { UUID(uuidString: $0) }
            return (title, authors, docUUID)
        }
        return Self.extractSourceMetadata(from: url)
    }

    /// Read the first ~64 KiB of a source file and look for a title /
    /// author declaration. Cheap — no full-file parse, just regex on the
    /// prologue where metadata always lives. Falls back to the filename.
    static func extractSourceMetadata(from url: URL) -> (title: String?, authors: String?, docUUID: UUID?) {
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (fallbackTitle, nil, nil)
        }
        defer { try? handle.close() }
        guard let headData = try? handle.read(upToCount: 64 * 1024),
              let head = String(data: headData, encoding: .utf8)
                ?? String(data: headData, encoding: .isoLatin1) else {
            return (fallbackTitle, nil, nil)
        }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "tex", "latex", "ltx", "cls", "sty":
            let title = firstCapture(in: head, pattern: #"\\title\s*(?:\[[^\]]*\])?\s*\{((?:[^{}]|\{[^{}]*\})*)\}"#)
                ?? firstCapture(in: head, pattern: #"%\s*!TEX\s+root\s*=\s*(.+)"#)
            let authors = firstCapture(in: head, pattern: #"\\author\s*(?:\[[^\]]*\])?\s*\{((?:[^{}]|\{[^{}]*\})*)\}"#)
            return (normalizeTitle(title) ?? fallbackTitle, normalizeTitle(authors), nil)

        case "typ", "typst":
            // Typst: first `= Title` heading is the conventional document title.
            if let title = firstCapture(in: head, pattern: #"(?m)^=\s+(.+)$"#) {
                return (title.trimmingCharacters(in: .whitespaces), nil, nil)
            }
            // Or a `#let title = "…"` binding, which some templates use.
            if let title = firstCapture(in: head, pattern: #"#let\s+title\s*=\s*\"([^\"]+)\""#) {
                return (title, nil, nil)
            }
            return (fallbackTitle, nil, nil)

        case "md", "markdown":
            // YAML front-matter `title: …` first, then the first `# ` heading.
            if let title = firstCapture(in: head, pattern: #"(?m)^title:\s*(.+)$"#) {
                return (title.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")), nil, nil)
            }
            if let title = firstCapture(in: head, pattern: #"(?m)^#\s+(.+)$"#) {
                return (title.trimmingCharacters(in: .whitespaces), nil, nil)
            }
            return (fallbackTitle, nil, nil)

        case "bib", "bbl":
            // BibTeX files don't have a single title — use the filename.
            return (fallbackTitle, nil, nil)

        default:
            return (fallbackTitle, nil, nil)
        }
    }

    /// Return the first capture group of the regex against `text`, trimmed.
    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r])
    }

    /// Strip LaTeX `\foo{…}` formatting commands and collapse whitespace —
    /// good enough for the cached title we show in the sidebar.
    private static func normalizeTitle(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var s = raw
        // Remove simple inline formatting commands but keep their braces' contents.
        s = s.replacingOccurrences(of: #"\\[a-zA-Z]+\*?\s*\{"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "}", with: "")
        s = s.replacingOccurrences(of: "~", with: " ")
        // Collapse whitespace.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
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
