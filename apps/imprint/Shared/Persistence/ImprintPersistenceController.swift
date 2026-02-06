//
//  ImprintPersistenceController.swift
//  imprint
//
//  Core Data stack for imprint project hierarchy and document references.
//  Uses NSPersistentCloudKitContainer for CloudKit sharing.
//

import Foundation
import CoreData
import OSLog
import ImpressLogging
#if canImport(CloudKit)
import CloudKit
#endif

private let logger = Logger(subsystem: "com.imbib.imprint", category: "persistence")

// MARK: - Persistence Controller

public final class ImprintPersistenceController: @unchecked Sendable {

    // MARK: - Shared Instance

    public static let shared: ImprintPersistenceController = {
        // CloudKit sharing will be enabled in a future release once the container schema is finalized.
        // For now, use local-only storage to avoid CloudKit initialization crashes.
        logger.info("Using local-only storage for project hierarchy")
        return ImprintPersistenceController(enableCloudKit: false)
    }()

    /// Preview/testing instance with in-memory store
    public static let preview = ImprintPersistenceController(inMemory: true)

    // MARK: - Properties

    public let container: NSPersistentContainer
    public var viewContext: NSManagedObjectContext { container.viewContext }

    /// Private store (user's own data)
    public private(set) var privateStore: NSPersistentStore?
    /// Shared store (CloudKit shared zones)
    public private(set) var sharedStore: NSPersistentStore?

    private static let cloudKitContainerID = "iCloud.com.imbib.shared"

    // MARK: - Initialization

    public init(inMemory: Bool = false, enableCloudKit: Bool = false) {
        let model = Self.createManagedObjectModel()

        if enableCloudKit {
            container = NSPersistentCloudKitContainer(name: "ImprintProjects", managedObjectModel: model)
            logger.info("Using NSPersistentCloudKitContainer")
        } else {
            container = NSPersistentContainer(name: "ImprintProjects", managedObjectModel: model)
            logger.info("Using standard NSPersistentContainer")
        }

        if let privateDesc = container.persistentStoreDescriptions.first {
            if inMemory {
                privateDesc.url = URL(fileURLWithPath: "/dev/null")
            }

            if enableCloudKit {
                privateDesc.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: Self.cloudKitContainerID
                )
                privateDesc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                privateDesc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

                // Add shared store for CloudKit shared zones
                let sharedStoreURL: URL
                if inMemory {
                    sharedStoreURL = URL(fileURLWithPath: "/dev/null")
                } else if let customURL = privateDesc.url {
                    sharedStoreURL = customURL
                        .deletingLastPathComponent()
                        .appendingPathComponent("imprint-shared.sqlite")
                } else {
                    sharedStoreURL = NSPersistentContainer.defaultDirectoryURL()
                        .appendingPathComponent("imprint-shared.sqlite")
                }

                let sharedDesc = NSPersistentStoreDescription(url: sharedStoreURL)
                let sharedOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: Self.cloudKitContainerID
                )
                sharedOptions.databaseScope = .shared
                sharedDesc.cloudKitContainerOptions = sharedOptions
                sharedDesc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                sharedDesc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

                container.persistentStoreDescriptions = [privateDesc, sharedDesc]
            }
        }

        let expectedStoreCount = container.persistentStoreDescriptions.count
        var loadedStoreCount = 0

        container.loadPersistentStores { [weak self] description, error in
            guard let self = self else { return }

            if let error = error as NSError? {
                logger.error("Failed to load persistent store: \(error), \(error.userInfo)")
                return
            }

            logger.info("Loaded persistent store: \(description.url?.absoluteString ?? "unknown")")

            if let loadedStore = self.container.persistentStoreCoordinator.persistentStore(for: description.url!) {
                if description.cloudKitContainerOptions?.databaseScope == .shared {
                    self.sharedStore = loadedStore
                } else {
                    self.privateStore = loadedStore
                }
            }

            loadedStoreCount += 1
            guard loadedStoreCount == expectedStoreCount else { return }

            logger.info("All stores loaded successfully")
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - Default Workspace

    /// Ensures the default workspace exists. Call on first launch.
    @MainActor
    public func ensureDefaultWorkspace() {
        let context = viewContext
        let request = NSFetchRequest<CDWorkspace>(entityName: "Workspace")
        request.predicate = NSPredicate(format: "isDefault == YES")
        request.fetchLimit = 1

        do {
            let results = try context.fetch(request)
            if results.isEmpty {
                let workspace = CDWorkspace(context: context)
                workspace.id = CDWorkspace.canonicalDefaultWorkspaceID
                workspace.name = "My Projects"
                workspace.isDefault = true
                workspace.dateCreated = Date()
                try context.save()
                logger.infoCapture("Created default workspace 'My Projects'", category: "folders")
            }
        } catch {
            logger.error("Failed to ensure default workspace: \(error.localizedDescription)")
        }
    }

    /// Fetch the default workspace
    @MainActor
    public func defaultWorkspace() -> CDWorkspace? {
        let request = NSFetchRequest<CDWorkspace>(entityName: "Workspace")
        request.predicate = NSPredicate(format: "isDefault == YES")
        request.fetchLimit = 1
        return try? viewContext.fetch(request).first
    }

    // MARK: - Programmatic Model

    private static let cachedModel: NSManagedObjectModel = createManagedObjectModelInternal()

    private static func createManagedObjectModel() -> NSManagedObjectModel {
        return cachedModel
    }

    private static func createManagedObjectModelInternal() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let workspaceEntity = createWorkspaceEntity()
        let folderEntity = createFolderEntity()
        let docRefEntity = createDocumentReferenceEntity()

        // Set up relationships
        setupWorkspaceFoldersRelationship(workspace: workspaceEntity, folder: folderEntity)
        setupWorkspaceDocRefsRelationship(workspace: workspaceEntity, docRef: docRefEntity)
        setupFolderHierarchyRelationship(folder: folderEntity)
        setupFolderDocRefsRelationship(folder: folderEntity, docRef: docRefEntity)

        model.entities = [workspaceEntity, folderEntity, docRefEntity]
        return model
    }

    // MARK: - Entity Creation

    private static func createWorkspaceEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "Workspace"
        entity.managedObjectClassName = "CDWorkspace"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()
        properties.append(id)

        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false
        name.defaultValue = ""
        properties.append(name)

        let isDefault = NSAttributeDescription()
        isDefault.name = "isDefault"
        isDefault.attributeType = .booleanAttributeType
        isDefault.isOptional = false
        isDefault.defaultValue = false
        properties.append(isDefault)

        let dateCreated = NSAttributeDescription()
        dateCreated.name = "dateCreated"
        dateCreated.attributeType = .dateAttributeType
        dateCreated.isOptional = false
        dateCreated.defaultValue = Date()
        properties.append(dateCreated)

        entity.properties = properties
        return entity
    }

    private static func createFolderEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "Folder"
        entity.managedObjectClassName = "CDFolder"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()
        properties.append(id)

        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false
        name.defaultValue = ""
        properties.append(name)

        let sortOrder = NSAttributeDescription()
        sortOrder.name = "sortOrder"
        sortOrder.attributeType = .integer16AttributeType
        sortOrder.isOptional = false
        sortOrder.defaultValue = Int16(0)
        properties.append(sortOrder)

        let dateCreated = NSAttributeDescription()
        dateCreated.name = "dateCreated"
        dateCreated.attributeType = .dateAttributeType
        dateCreated.isOptional = true
        properties.append(dateCreated)

        entity.properties = properties
        return entity
    }

    private static func createDocumentReferenceEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "DocumentReference"
        entity.managedObjectClassName = "CDDocumentReference"

        var properties: [NSPropertyDescription] = []

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false
        id.defaultValue = UUID()
        properties.append(id)

        let documentUUID = NSAttributeDescription()
        documentUUID.name = "documentUUID"
        documentUUID.attributeType = .UUIDAttributeType
        documentUUID.isOptional = true
        properties.append(documentUUID)

        let fileBookmark = NSAttributeDescription()
        fileBookmark.name = "fileBookmark"
        fileBookmark.attributeType = .binaryDataAttributeType
        fileBookmark.isOptional = true
        properties.append(fileBookmark)

        let cachedTitle = NSAttributeDescription()
        cachedTitle.name = "cachedTitle"
        cachedTitle.attributeType = .stringAttributeType
        cachedTitle.isOptional = true
        properties.append(cachedTitle)

        let cachedAuthors = NSAttributeDescription()
        cachedAuthors.name = "cachedAuthors"
        cachedAuthors.attributeType = .stringAttributeType
        cachedAuthors.isOptional = true
        properties.append(cachedAuthors)

        let dateAdded = NSAttributeDescription()
        dateAdded.name = "dateAdded"
        dateAdded.attributeType = .dateAttributeType
        dateAdded.isOptional = false
        dateAdded.defaultValue = Date()
        properties.append(dateAdded)

        let sortOrder = NSAttributeDescription()
        sortOrder.name = "sortOrder"
        sortOrder.attributeType = .integer16AttributeType
        sortOrder.isOptional = false
        sortOrder.defaultValue = Int16(0)
        properties.append(sortOrder)

        entity.properties = properties
        return entity
    }

    // MARK: - Relationship Setup

    private static func setupWorkspaceFoldersRelationship(
        workspace: NSEntityDescription,
        folder: NSEntityDescription
    ) {
        let workspaceToFolders = NSRelationshipDescription()
        workspaceToFolders.name = "rootFolders"
        workspaceToFolders.destinationEntity = folder
        workspaceToFolders.isOptional = true
        workspaceToFolders.deleteRule = .cascadeDeleteRule

        let folderToWorkspace = NSRelationshipDescription()
        folderToWorkspace.name = "workspace"
        folderToWorkspace.destinationEntity = workspace
        folderToWorkspace.maxCount = 1
        folderToWorkspace.isOptional = true
        folderToWorkspace.deleteRule = .nullifyDeleteRule

        workspaceToFolders.inverseRelationship = folderToWorkspace
        folderToWorkspace.inverseRelationship = workspaceToFolders

        workspace.properties.append(workspaceToFolders)
        folder.properties.append(folderToWorkspace)
    }

    private static func setupWorkspaceDocRefsRelationship(
        workspace: NSEntityDescription,
        docRef: NSEntityDescription
    ) {
        let workspaceToDocRefs = NSRelationshipDescription()
        workspaceToDocRefs.name = "documentRefs"
        workspaceToDocRefs.destinationEntity = docRef
        workspaceToDocRefs.isOptional = true
        workspaceToDocRefs.deleteRule = .cascadeDeleteRule

        let docRefToWorkspace = NSRelationshipDescription()
        docRefToWorkspace.name = "workspace"
        docRefToWorkspace.destinationEntity = workspace
        docRefToWorkspace.maxCount = 1
        docRefToWorkspace.isOptional = true
        docRefToWorkspace.deleteRule = .nullifyDeleteRule

        workspaceToDocRefs.inverseRelationship = docRefToWorkspace
        docRefToWorkspace.inverseRelationship = workspaceToDocRefs

        workspace.properties.append(workspaceToDocRefs)
        docRef.properties.append(docRefToWorkspace)
    }

    private static func setupFolderHierarchyRelationship(folder: NSEntityDescription) {
        let folderToParent = NSRelationshipDescription()
        folderToParent.name = "parentFolder"
        folderToParent.destinationEntity = folder
        folderToParent.maxCount = 1
        folderToParent.isOptional = true
        folderToParent.deleteRule = .nullifyDeleteRule

        let folderToChildren = NSRelationshipDescription()
        folderToChildren.name = "childFolders"
        folderToChildren.destinationEntity = folder
        folderToChildren.isOptional = true
        folderToChildren.deleteRule = .cascadeDeleteRule

        folderToParent.inverseRelationship = folderToChildren
        folderToChildren.inverseRelationship = folderToParent

        folder.properties.append(contentsOf: [folderToParent, folderToChildren])
    }

    private static func setupFolderDocRefsRelationship(
        folder: NSEntityDescription,
        docRef: NSEntityDescription
    ) {
        let folderToDocRefs = NSRelationshipDescription()
        folderToDocRefs.name = "documentRefs"
        folderToDocRefs.destinationEntity = docRef
        folderToDocRefs.isOptional = true
        folderToDocRefs.deleteRule = .cascadeDeleteRule

        let docRefToFolder = NSRelationshipDescription()
        docRefToFolder.name = "folder"
        docRefToFolder.destinationEntity = folder
        docRefToFolder.maxCount = 1
        docRefToFolder.isOptional = true
        docRefToFolder.deleteRule = .nullifyDeleteRule

        folderToDocRefs.inverseRelationship = docRefToFolder
        docRefToFolder.inverseRelationship = folderToDocRefs

        folder.properties.append(folderToDocRefs)
        docRef.properties.append(docRefToFolder)
    }
}
