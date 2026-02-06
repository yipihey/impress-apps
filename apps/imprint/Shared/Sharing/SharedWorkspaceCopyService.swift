//
//  SharedWorkspaceCopyService.swift
//  imprint
//
//  Deep-copies folder tree + document references between private and shared stores.
//  Only metadata is shared; actual .imprint files need iCloud Drive sharing separately.
//

import Foundation
import CoreData
import OSLog
import ImpressLogging

private let logger = Logger(subsystem: "com.imbib.imprint", category: "sharing")

public actor SharedWorkspaceCopyService {

    public static let shared = SharedWorkspaceCopyService()

    private init() {}

    // MARK: - Copy to Shared Store

    /// Copy a folder and its entire subtree to a new workspace in the shared store.
    @MainActor
    public func copyFolderToSharedStore(
        _ folder: CDFolder,
        context: NSManagedObjectContext
    ) throws -> CDWorkspace {
        guard let sharedStore = ImprintPersistenceController.shared.sharedStore else {
            throw ImprintSharingError.sharedStoreUnavailable
        }

        // Create a workspace in the shared store to hold the folder tree
        let targetWorkspace = CDWorkspace(context: context)
        context.assign(targetWorkspace, to: sharedStore)
        targetWorkspace.id = UUID()
        targetWorkspace.name = folder.name
        targetWorkspace.isDefault = false
        targetWorkspace.dateCreated = Date()

        // Deep-copy the folder tree
        deepCopyFolder(
            folder,
            into: targetWorkspace,
            parent: nil,
            context: context,
            sharedStore: sharedStore
        )

        try context.save()
        logger.infoCapture("Copied folder '\(folder.name)' to shared store", category: "sharing")
        return targetWorkspace
    }

    // MARK: - Copy to Private Store

    /// Copy a shared workspace's folder tree back to the private store.
    @MainActor
    public func copyWorkspaceToPrivateStore(
        _ workspace: CDWorkspace,
        context: NSManagedObjectContext
    ) throws {
        guard let privateStore = ImprintPersistenceController.shared.privateStore else {
            throw ImprintSharingError.sharedStoreUnavailable
        }

        // Get or create default workspace in private store
        let defaultWorkspace = ImprintPersistenceController.shared.defaultWorkspace()
        guard let targetWorkspace = defaultWorkspace else {
            throw ImprintSharingError.copyFailed("No default workspace found in private store")
        }

        // Copy all root folders
        for folder in workspace.sortedRootFolders {
            deepCopyFolder(
                folder,
                into: targetWorkspace,
                parent: nil,
                context: context,
                sharedStore: privateStore
            )
        }

        try context.save()
        logger.infoCapture("Copied workspace '\(workspace.name)' to private store", category: "sharing")
    }

    // MARK: - Deep Copy

    @MainActor
    private func deepCopyFolder(
        _ source: CDFolder,
        into workspace: CDWorkspace,
        parent: CDFolder?,
        context: NSManagedObjectContext,
        sharedStore: NSPersistentStore
    ) {
        let newFolder = CDFolder(context: context)
        context.assign(newFolder, to: sharedStore)
        newFolder.id = UUID()
        newFolder.name = source.name
        newFolder.sortOrder = source.sortOrder
        newFolder.dateCreated = Date()
        newFolder.parentFolder = parent

        if parent == nil {
            newFolder.workspace = workspace
            let rootSet = workspace.mutableSetValue(forKey: "rootFolders")
            rootSet.add(newFolder)
        } else {
            let childSet = parent!.mutableSetValue(forKey: "childFolders")
            childSet.add(newFolder)
        }

        // Copy document references
        for docRef in source.documentRefs ?? [] {
            let newRef = CDDocumentReference(context: context)
            context.assign(newRef, to: sharedStore)
            newRef.id = UUID()
            newRef.documentUUID = docRef.documentUUID
            newRef.fileBookmark = docRef.fileBookmark
            newRef.cachedTitle = docRef.cachedTitle
            newRef.cachedAuthors = docRef.cachedAuthors
            newRef.dateAdded = Date()
            newRef.sortOrder = docRef.sortOrder

            let docRefSet = newFolder.mutableSetValue(forKey: "documentRefs")
            docRefSet.add(newRef)
            newRef.folder = newFolder
        }

        // Recursively copy children
        for child in source.sortedChildren {
            deepCopyFolder(
                child,
                into: workspace,
                parent: newFolder,
                context: context,
                sharedStore: sharedStore
            )
        }
    }
}
