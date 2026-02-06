//
//  ManagedObjects.swift
//  imprint
//
//  Core Data managed object subclasses for the imprint project hierarchy.
//

import Foundation
import CoreData

// MARK: - Workspace

@objc(CDWorkspace)
public class CDWorkspace: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId { return existingId }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var name: String
    @NSManaged public var isDefault: Bool
    @NSManaged public var dateCreated: Date

    // Relationships
    @NSManaged public var rootFolders: Set<CDFolder>?
    @NSManaged public var documentRefs: Set<CDDocumentReference>?

    /// Well-known UUID for the default workspace, shared across devices.
    public static let canonicalDefaultWorkspaceID = UUID(uuidString: "00000000-0000-0000-0001-000000000001")!
}

public extension CDWorkspace {
    /// Root folders sorted by sortOrder, then name
    var sortedRootFolders: [CDFolder] {
        (rootFolders ?? [])
            .filter { $0.parentFolder == nil }
            .sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.name < $1.name
            }
    }
}

// MARK: - Folder

@objc(CDFolder)
public class CDFolder: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId { return existingId }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    @NSManaged public var name: String
    @NSManaged public var sortOrder: Int16
    @NSManaged public var dateCreated: Date?

    // Relationships
    @NSManaged public var parentFolder: CDFolder?
    @NSManaged public var childFolders: Set<CDFolder>?
    @NSManaged public var documentRefs: Set<CDDocumentReference>?
    @NSManaged public var workspace: CDWorkspace?
}

// MARK: - Folder Helpers

public extension CDFolder {
    /// Depth in hierarchy (0 = root)
    var depth: Int {
        var d = 0
        var current = parentFolder
        while current != nil {
            d += 1
            current = current?.parentFolder
        }
        return d
    }

    /// Whether this folder has any child folders
    var hasChildren: Bool {
        !(childFolders?.isEmpty ?? true)
    }

    /// Sorted child folders by sortOrder, then name
    var sortedChildren: [CDFolder] {
        (childFolders ?? []).sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name < $1.name
        }
    }

    /// All ancestor folders from root to parent
    var ancestors: [CDFolder] {
        var result: [CDFolder] = []
        var current = parentFolder
        while let c = current {
            result.insert(c, at: 0)
            current = c.parentFolder
        }
        return result
    }

    /// All document references in this folder and all descendants
    var allDocumentRefsIncludingDescendants: Set<CDDocumentReference> {
        var result = documentRefs ?? []
        for child in childFolders ?? [] {
            result.formUnion(child.allDocumentRefsIncludingDescendants)
        }
        return result
    }

    /// Count of document references directly in this folder
    var documentCount: Int {
        documentRefs?.count ?? 0
    }

    /// Recursive count of all document references (this folder + descendants)
    var recursiveDocumentCount: Int {
        allDocumentRefsIncludingDescendants.count
    }
}

// MARK: - Document Reference

@objc(CDDocumentReference)
public class CDDocumentReference: NSManagedObject, Identifiable {
    @NSManaged private var primitiveId: UUID?

    public var id: UUID {
        get {
            willAccessValue(forKey: "id")
            defer { didAccessValue(forKey: "id") }
            if let existingId = primitiveId { return existingId }
            let newId = UUID()
            primitiveId = newId
            return newId
        }
        set {
            willChangeValue(forKey: "id")
            primitiveId = newValue
            didChangeValue(forKey: "id")
        }
    }

    /// UUID of the ImprintDocument this references
    @NSManaged public var documentUUID: UUID?
    /// Security-scoped bookmark data for sandbox file access
    @NSManaged public var fileBookmark: Data?
    /// Cached title from document metadata
    @NSManaged public var cachedTitle: String?
    /// Cached authors from document metadata
    @NSManaged public var cachedAuthors: String?
    /// When this reference was added to the folder
    @NSManaged public var dateAdded: Date
    /// Sort order within the folder
    @NSManaged public var sortOrder: Int16

    // Relationships
    @NSManaged public var folder: CDFolder?
    @NSManaged public var workspace: CDWorkspace?
}

public extension CDDocumentReference {
    /// Display title, falling back to "Untitled" if no cached title
    var displayTitle: String {
        if let title = cachedTitle, !title.isEmpty { return title }
        return "Untitled"
    }
}
