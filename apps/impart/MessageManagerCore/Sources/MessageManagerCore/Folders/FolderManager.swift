//
//  FolderManager.swift
//  MessageManagerCore
//
//  Actor-based manager for folder CRUD operations.
//  Handles system folder creation, hierarchy management, and validation.
//

import CoreData
import Foundation
import OSLog

private let folderLogger = Logger(subsystem: "com.impart", category: "folders")

// MARK: - Folder Manager

/// Actor-based service for folder management.
public actor FolderManager {

    private let persistenceController: PersistenceController

    public init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    /// Convenience initializer using shared persistence controller.
    @MainActor
    public init() {
        self.persistenceController = .shared
    }

    // MARK: - System Folders

    /// System folders to create for each account.
    private static let systemFolders: [(name: String, role: FolderRole, sortOrder: Int16)] = [
        ("Inbox", .inbox, 0),
        ("Sent", .sent, 1),
        ("Drafts", .drafts, 2),
        ("Archive", .archive, 3),
        ("Trash", .trash, 4),
        ("Spam", .spam, 5),
        ("Agents", .agents, 6)
    ]

    /// Ensure system folders exist for an account.
    public func ensureSystemFolders(for accountId: UUID) async throws {
        try await persistenceController.performBackgroundTask { context in
            // Fetch account
            let accountFetch: NSFetchRequest<CDAccount> = NSFetchRequest(entityName: "CDAccount")
            accountFetch.predicate = NSPredicate(format: "id == %@", accountId as CVarArg)
            guard let account = try context.fetch(accountFetch).first else {
                throw FolderError.accountNotFound
            }

            // Check existing system folders
            let existingFetch: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
            existingFetch.predicate = NSPredicate(
                format: "account == %@ AND isSystemFolder == YES",
                account
            )
            let existing = try context.fetch(existingFetch)
            let existingRoles = Set(existing.map(\.roleRaw))

            // Create missing system folders
            for (name, role, sortOrder) in Self.systemFolders {
                if !existingRoles.contains(role.rawValue) {
                    let folder = NSEntityDescription.insertNewObject(
                        forEntityName: "CDFolder",
                        into: context
                    ) as! CDFolder

                    folder.id = UUID()
                    folder.name = name
                    folder.fullPath = name
                    folder.roleRaw = role.rawValue
                    folder.isSystemFolder = true
                    folder.isVirtualFolder = false
                    folder.messageCount = 0
                    folder.unreadCount = 0
                    folder.dateCreated = Date()
                    folder.sortOrder = sortOrder
                    folder.account = account

                    folderLogger.info("Created system folder '\(name)' for account \(accountId)")
                }
            }

            try context.save()
        }
    }

    // MARK: - Folder CRUD

    /// Create a new folder.
    public func createFolder(
        name: String,
        parent: UUID? = nil,
        accountId: UUID
    ) async throws -> UUID {
        try await persistenceController.performBackgroundTask { context in
            // Fetch account
            let accountFetch: NSFetchRequest<CDAccount> = NSFetchRequest(entityName: "CDAccount")
            accountFetch.predicate = NSPredicate(format: "id == %@", accountId as CVarArg)
            guard let account = try context.fetch(accountFetch).first else {
                throw FolderError.accountNotFound
            }

            // Fetch parent folder if specified
            var parentFolder: CDFolder?
            if let parentId = parent {
                let parentFetch: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
                parentFetch.predicate = NSPredicate(format: "id == %@", parentId as CVarArg)
                parentFolder = try context.fetch(parentFetch).first
            }

            // Compute full path
            let fullPath: String
            if let parent = parentFolder {
                fullPath = "\(parent.fullPath)/\(name)"
            } else {
                fullPath = name
            }

            // Check for duplicate name at same level
            let duplicateFetch: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
            if let parentFolder = parentFolder {
                duplicateFetch.predicate = NSPredicate(
                    format: "account == %@ AND parentFolder == %@ AND name == %@",
                    account, parentFolder, name
                )
            } else {
                duplicateFetch.predicate = NSPredicate(
                    format: "account == %@ AND parentFolder == nil AND name == %@",
                    account, name
                )
            }
            if try !context.fetch(duplicateFetch).isEmpty {
                throw FolderError.duplicateName
            }

            // Create folder
            let folder = NSEntityDescription.insertNewObject(
                forEntityName: "CDFolder",
                into: context
            ) as! CDFolder

            let folderId = UUID()
            folder.id = folderId
            folder.name = name
            folder.fullPath = fullPath
            folder.roleRaw = FolderRole.custom.rawValue
            folder.isSystemFolder = false
            folder.isVirtualFolder = false
            folder.messageCount = 0
            folder.unreadCount = 0
            folder.dateCreated = Date()
            folder.sortOrder = 100  // User folders after system folders
            folder.account = account
            folder.parentFolder = parentFolder

            try context.save()

            folderLogger.info("Created folder '\(name)' with ID \(folderId)")
            return folderId
        }
    }

    /// Rename a folder.
    public func renameFolder(_ folderId: UUID, to newName: String) async throws {
        try await persistenceController.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
            fetchRequest.predicate = NSPredicate(format: "id == %@", folderId as CVarArg)

            guard let folder = try context.fetch(fetchRequest).first else {
                throw FolderError.folderNotFound
            }

            // Can't rename system folders
            guard !folder.isSystemFolder else {
                throw FolderError.cannotModifySystemFolder
            }

            // Check for duplicate name at same level
            guard let account = folder.account else {
                throw FolderError.accountNotFound
            }

            let duplicateFetch: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
            if let parentFolder = folder.parentFolder {
                duplicateFetch.predicate = NSPredicate(
                    format: "account == %@ AND parentFolder == %@ AND name == %@ AND id != %@",
                    account, parentFolder, newName, folderId as CVarArg
                )
            } else {
                duplicateFetch.predicate = NSPredicate(
                    format: "account == %@ AND parentFolder == nil AND name == %@ AND id != %@",
                    account, newName, folderId as CVarArg
                )
            }
            if try !context.fetch(duplicateFetch).isEmpty {
                throw FolderError.duplicateName
            }

            let oldName = folder.name
            folder.name = newName

            // Update full path
            if let parent = folder.parentFolder {
                folder.fullPath = "\(parent.fullPath)/\(newName)"
            } else {
                folder.fullPath = newName
            }

            // Update child folder paths recursively
            Self.updateChildPaths(of: folder)

            try context.save()

            folderLogger.info("Renamed folder from '\(oldName)' to '\(newName)'")
        }
    }

    /// Update full paths of child folders recursively.
    private static func updateChildPaths(of folder: CDFolder) {
        guard let children = folder.childFolders else { return }
        for child in children {
            child.fullPath = "\(folder.fullPath)/\(child.name)"
            updateChildPaths(of: child)
        }
    }

    /// Move a folder to a new parent.
    public func moveFolder(_ folderId: UUID, to newParentId: UUID?) async throws {
        try await persistenceController.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
            fetchRequest.predicate = NSPredicate(format: "id == %@", folderId as CVarArg)

            guard let folder = try context.fetch(fetchRequest).first else {
                throw FolderError.folderNotFound
            }

            // Can't move system folders
            guard !folder.isSystemFolder else {
                throw FolderError.cannotModifySystemFolder
            }

            // Fetch new parent if specified
            var newParent: CDFolder?
            if let newParentId = newParentId {
                let parentFetch: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
                parentFetch.predicate = NSPredicate(format: "id == %@", newParentId as CVarArg)
                newParent = try context.fetch(parentFetch).first

                // Validate parent is in same account
                guard newParent?.account?.id == folder.account?.id else {
                    throw FolderError.crossAccountMove
                }

                // Validate not creating a cycle
                guard folder.canReparent(to: newParent) else {
                    throw FolderError.circularHierarchy
                }
            }

            folder.parentFolder = newParent

            // Update full path
            if let parent = newParent {
                folder.fullPath = "\(parent.fullPath)/\(folder.name)"
            } else {
                folder.fullPath = folder.name
            }

            // Update child paths
            Self.updateChildPaths(of: folder)

            try context.save()

            folderLogger.info("Moved folder \(folderId) to parent \(newParentId?.uuidString ?? "root")")
        }
    }

    /// Delete a folder.
    public func deleteFolder(
        _ folderId: UUID,
        moveMessagesTo targetFolderId: UUID? = nil
    ) async throws {
        try await persistenceController.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
            fetchRequest.predicate = NSPredicate(format: "id == %@", folderId as CVarArg)

            guard let folder = try context.fetch(fetchRequest).first else {
                throw FolderError.folderNotFound
            }

            // Can't delete system folders
            guard !folder.isSystemFolder else {
                throw FolderError.cannotModifySystemFolder
            }

            // Move messages to target folder if specified
            if let targetId = targetFolderId, let messages = folder.messages, !messages.isEmpty {
                let targetFetch: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
                targetFetch.predicate = NSPredicate(format: "id == %@", targetId as CVarArg)

                if let target = try context.fetch(targetFetch).first {
                    for message in messages {
                        message.folder = target
                    }
                }
            }

            // Delete child folders recursively
            Self.deleteChildren(of: folder, context: context)

            // Delete the folder
            context.delete(folder)

            try context.save()

            folderLogger.info("Deleted folder \(folderId)")
        }
    }

    /// Delete child folders recursively.
    private static func deleteChildren(of folder: CDFolder, context: NSManagedObjectContext) {
        guard let children = folder.childFolders else { return }
        for child in children {
            deleteChildren(of: child, context: context)
            context.delete(child)
        }
    }

    // MARK: - Smart Folders

    /// Create a smart (virtual) folder with a predicate.
    public func createSmartFolder(
        name: String,
        predicate: String,
        accountId: UUID
    ) async throws -> UUID {
        try await persistenceController.performBackgroundTask { context in
            // Validate predicate - NSPredicate throws ObjC exceptions, not Swift errors
            // Use a simple validation approach
            guard !predicate.isEmpty else {
                throw FolderError.invalidPredicate
            }

            // Fetch account
            let accountFetch: NSFetchRequest<CDAccount> = NSFetchRequest(entityName: "CDAccount")
            accountFetch.predicate = NSPredicate(format: "id == %@", accountId as CVarArg)
            guard let account = try context.fetch(accountFetch).first else {
                throw FolderError.accountNotFound
            }

            // Create smart folder
            let folder = NSEntityDescription.insertNewObject(
                forEntityName: "CDFolder",
                into: context
            ) as! CDFolder

            let folderId = UUID()
            folder.id = folderId
            folder.name = name
            folder.fullPath = name
            folder.roleRaw = FolderRole.custom.rawValue
            folder.isSystemFolder = false
            folder.isVirtualFolder = true
            folder.predicate = predicate
            folder.messageCount = 0
            folder.unreadCount = 0
            folder.dateCreated = Date()
            folder.sortOrder = 200  // Smart folders after user folders
            folder.account = account

            try context.save()

            folderLogger.info("Created smart folder '\(name)' with predicate: \(predicate)")
            return folderId
        }
    }

    // MARK: - Hierarchy Queries

    /// Get root folders for an account.
    public func getRootFolders(for accountId: UUID) async throws -> [UUID] {
        try await persistenceController.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
            fetchRequest.predicate = NSPredicate(
                format: "account.id == %@ AND parentFolder == nil",
                accountId as CVarArg
            )
            fetchRequest.sortDescriptors = [
                NSSortDescriptor(key: "sortOrder", ascending: true),
                NSSortDescriptor(key: "name", ascending: true)
            ]

            let folders = try context.fetch(fetchRequest)
            return folders.map(\.id)
        }
    }

    /// Check if reparenting is valid (no circular dependencies).
    public func canReparent(_ folderId: UUID, to newParentId: UUID?) async throws -> Bool {
        guard let newParentId = newParentId else { return true }
        guard folderId != newParentId else { return false }

        return try await persistenceController.performBackgroundTask { context in
            let folderFetch: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
            folderFetch.predicate = NSPredicate(format: "id == %@", folderId as CVarArg)
            guard let folder = try context.fetch(folderFetch).first else { return false }

            let parentFetch: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
            parentFetch.predicate = NSPredicate(format: "id == %@", newParentId as CVarArg)
            guard let parent = try context.fetch(parentFetch).first else { return false }

            return folder.canReparent(to: parent)
        }
    }
}

// MARK: - Folder Errors

public enum FolderError: LocalizedError {
    case folderNotFound
    case accountNotFound
    case duplicateName
    case cannotModifySystemFolder
    case circularHierarchy
    case crossAccountMove
    case invalidPredicate

    public var errorDescription: String? {
        switch self {
        case .folderNotFound:
            return "Folder not found"
        case .accountNotFound:
            return "Account not found"
        case .duplicateName:
            return "A folder with this name already exists"
        case .cannotModifySystemFolder:
            return "System folders cannot be modified"
        case .circularHierarchy:
            return "Cannot move folder into its own subfolder"
        case .crossAccountMove:
            return "Cannot move folder to a different account"
        case .invalidPredicate:
            return "Invalid search predicate"
        }
    }
}
