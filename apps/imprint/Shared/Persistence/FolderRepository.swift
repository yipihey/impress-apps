//
//  FolderRepository.swift
//  imprint
//
//  Actor-based CRUD operations for the folder hierarchy.
//  Uses mutableSetValue(forKey:) for to-many relationship mutations.
//

import Foundation
import CoreData
import OSLog
import ImpressLogging

public actor FolderRepository {

    public static let shared = FolderRepository()

    private nonisolated var persistence: ImprintPersistenceController {
        ImprintPersistenceController.shared
    }

    // MARK: - Folder CRUD

    /// Create a new folder
    @MainActor
    public func createFolder(
        name: String,
        parent: CDFolder? = nil,
        in workspace: CDWorkspace
    ) throws -> CDFolder {
        let context = persistence.viewContext

        // Determine sort order (append at end)
        let siblings: [CDFolder]
        if let parent = parent {
            siblings = parent.sortedChildren
        } else {
            siblings = workspace.sortedRootFolders
        }
        let nextSortOrder = Int16((siblings.last?.sortOrder ?? -1) + 1)

        let folder = CDFolder(context: context)
        folder.id = UUID()
        folder.name = name
        folder.sortOrder = nextSortOrder
        folder.dateCreated = Date()
        folder.parentFolder = parent

        // Use mutableSetValue for to-many relationship mutations
        if let parent = parent {
            let childSet = parent.mutableSetValue(forKey: "childFolders")
            childSet.add(folder)
        } else {
            let rootSet = workspace.mutableSetValue(forKey: "rootFolders")
            rootSet.add(folder)
            folder.workspace = workspace
        }

        context.undoManager?.setActionName("Create Folder")
        context.processPendingChanges()
        try context.save()

        Logger.folders.infoCapture("Created folder '\(name)' (parent: \(parent?.name ?? "root"), sortOrder: \(nextSortOrder))", category: "folders")
        return folder
    }

    /// Rename a folder
    @MainActor
    public func renameFolder(_ folder: CDFolder, to newName: String) throws {
        let context = persistence.viewContext
        let oldName = folder.name
        folder.name = newName
        context.undoManager?.setActionName("Rename Folder")
        context.processPendingChanges()
        try context.save()
        Logger.folders.infoCapture("Renamed folder '\(oldName)' → '\(newName)'", category: "folders")
    }

    /// Move a folder to a new parent (or to root if parent is nil)
    @MainActor
    public func moveFolder(_ folder: CDFolder, to newParent: CDFolder?, in workspace: CDWorkspace) throws {
        let context = persistence.viewContext

        // Remove from old parent
        if let oldParent = folder.parentFolder {
            let oldChildSet = oldParent.mutableSetValue(forKey: "childFolders")
            oldChildSet.remove(folder)
        } else if let oldWorkspace = folder.workspace {
            let rootSet = oldWorkspace.mutableSetValue(forKey: "rootFolders")
            rootSet.remove(folder)
        }

        // Add to new parent
        if let newParent = newParent {
            let newChildSet = newParent.mutableSetValue(forKey: "childFolders")
            newChildSet.add(folder)
            folder.parentFolder = newParent
            folder.workspace = nil
        } else {
            folder.parentFolder = nil
            folder.workspace = workspace
            let rootSet = workspace.mutableSetValue(forKey: "rootFolders")
            rootSet.add(folder)
        }

        // Assign sort order at end of new siblings
        let siblings: [CDFolder]
        if let newParent = newParent {
            siblings = newParent.sortedChildren
        } else {
            siblings = workspace.sortedRootFolders
        }
        folder.sortOrder = Int16((siblings.filter { $0 !== folder }.last?.sortOrder ?? -1) + 1)

        context.undoManager?.setActionName("Move Folder")
        context.processPendingChanges()
        try context.save()
        Logger.folders.infoCapture("Moved folder '\(folder.name)' to \(newParent?.name ?? "root")", category: "folders")
    }

    /// Delete a folder and all its contents (children cascade via Core Data)
    @MainActor
    public func deleteFolder(_ folder: CDFolder) throws {
        let context = persistence.viewContext
        let name = folder.name
        context.undoManager?.setActionName("Delete Folder")
        context.delete(folder)
        context.processPendingChanges()
        try context.save()
        Logger.folders.infoCapture("Deleted folder '\(name)'", category: "folders")
    }

    /// Reorder folders within the same parent
    @MainActor
    public func reorderFolders(_ folders: [CDFolder]) throws {
        let context = persistence.viewContext
        for (index, folder) in folders.enumerated() {
            folder.sortOrder = Int16(index)
        }
        context.undoManager?.setActionName("Reorder Folders")
        context.processPendingChanges()
        try context.save()
        Logger.folders.infoCapture("Reordered \(folders.count) folders", category: "folders")
    }

    // MARK: - Document Reference CRUD

    /// Add a document reference to a folder
    @MainActor
    public func addDocumentReference(
        url: URL,
        documentUUID: UUID? = nil,
        title: String? = nil,
        authors: String? = nil,
        to folder: CDFolder
    ) throws -> CDDocumentReference {
        let context = persistence.viewContext

        // Create bookmark for sandbox access
        let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Determine sort order
        let existingRefs = (folder.documentRefs ?? []).sorted { $0.sortOrder < $1.sortOrder }
        let nextSortOrder = Int16((existingRefs.last?.sortOrder ?? -1) + 1)

        let ref = CDDocumentReference(context: context)
        ref.id = UUID()
        ref.documentUUID = documentUUID
        ref.fileBookmark = bookmarkData
        ref.cachedTitle = title
        ref.cachedAuthors = authors
        ref.dateAdded = Date()
        ref.sortOrder = nextSortOrder

        // Use mutableSetValue for to-many
        let docRefSet = folder.mutableSetValue(forKey: "documentRefs")
        docRefSet.add(ref)
        ref.folder = folder

        context.undoManager?.setActionName("Add Document")
        context.processPendingChanges()
        try context.save()
        Logger.folders.infoCapture("Added document ref '\(title ?? "Untitled")' to folder '\(folder.name)'", category: "folders")
        return ref
    }

    /// Move a document reference to a different folder. Removes it from the
    /// current folder's set (if any), appends it to the target folder's set
    /// with a fresh sortOrder, and saves. Idempotent — no-op if `ref` is
    /// already in `newFolder`.
    @MainActor
    public func moveDocumentReference(_ ref: CDDocumentReference, to newFolder: CDFolder) throws {
        let context = persistence.viewContext
        let title = ref.displayTitle
        let oldFolder = ref.folder

        if oldFolder?.id == newFolder.id {
            Logger.folders.debugCapture(
                "moveDocumentReference no-op: '\(title)' already in '\(newFolder.name)'",
                category: "folders"
            )
            return
        }

        let oldName = oldFolder?.name ?? "(none)"
        let oldCountBefore = oldFolder?.documentRefs?.count ?? 0
        let newCountBefore = newFolder.documentRefs?.count ?? 0

        // Compute the new sortOrder BEFORE touching the relationships, so
        // reading `newFolder.documentRefs` gives a clean picture.
        let existingRefs = (newFolder.documentRefs ?? []).sorted { $0.sortOrder < $1.sortOrder }
        let newSortOrder = Int16((existingRefs.last?.sortOrder ?? -1) + 1)

        // Reparent via the single inverse: setting `ref.folder` updates both
        // sides of the relationship automatically (Core Data uses the inverse
        // to sync the old folder's `documentRefs`). Explicit
        // mutableSetValue manipulation is only necessary when there's no
        // inverse or we bypass the inverse — since CDDocumentReference.folder
        // is the inverse of CDFolder.documentRefs, setting `ref.folder`
        // alone is the canonical, race-free way to move.
        ref.folder = newFolder
        ref.sortOrder = newSortOrder

        context.undoManager?.setActionName("Move Document")
        context.processPendingChanges()
        try context.save()

        // Refresh the old folder so its `documentRefs` relationship reflects
        // the inverse update. CoreData usually does this automatically on
        // save, but explicitly refreshing guarantees the UI sees the change.
        if let oldFolder {
            context.refresh(oldFolder, mergeChanges: true)
        }
        context.refresh(newFolder, mergeChanges: true)

        let oldCountAfter = oldFolder?.documentRefs?.count ?? 0
        let newCountAfter = newFolder.documentRefs?.count ?? 0
        Logger.folders.infoCapture(
            "Moved ref '\(title)': '\(oldName)' → '\(newFolder.name)' (sortOrder \(newSortOrder)). " +
            "Counts — \(oldName): \(oldCountBefore)→\(oldCountAfter), \(newFolder.name): \(newCountBefore)→\(newCountAfter)",
            category: "folders"
        )
    }

    /// Remove a document reference
    @MainActor
    public func removeDocumentReference(_ ref: CDDocumentReference) throws {
        let context = persistence.viewContext
        let title = ref.displayTitle
        let folderName = ref.folder?.name ?? "unknown"
        context.undoManager?.setActionName("Remove Document")
        context.delete(ref)
        context.processPendingChanges()
        try context.save()
        Logger.folders.infoCapture("Removed document ref '\(title)' from folder '\(folderName)'", category: "folders")
    }

    // MARK: - Fetch

    /// Fetch root folders in a workspace
    @MainActor
    public func fetchRootFolders(in workspace: CDWorkspace) -> [CDFolder] {
        workspace.sortedRootFolders
    }

    /// Fetch document references in a folder
    @MainActor
    public func fetchDocumentRefs(in folder: CDFolder) -> [CDDocumentReference] {
        (folder.documentRefs ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Fetch all folders in a workspace (flat list)
    @MainActor
    public func fetchAllFolders(in workspace: CDWorkspace) throws -> [CDFolder] {
        let context = persistence.viewContext
        let request = NSFetchRequest<CDFolder>(entityName: "Folder")
        return try context.fetch(request)
    }
}
