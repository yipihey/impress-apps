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
    /// Plain-text absolute path mirror of the file the bookmark resolves to.
    /// Stored alongside `fileBookmark` so we can recover after a machine
    /// migration (or signing-identity change) invalidates the bookmark blob.
    @NSManaged public var fileURLString: String?
    /// Cached title from document metadata
    @NSManaged public var cachedTitle: String?
    /// Cached authors from document metadata
    @NSManaged public var cachedAuthors: String?
    /// When this reference was added to the folder
    @NSManaged public var dateAdded: Date
    /// Sort order within the folder
    @NSManaged public var sortOrder: Int16

    // FAIR attribution (ADR-0014 D54). All optional. Informational only —
    // `embargoUntil` does not gate any action.
    @NSManaged public var orcid: String?
    @NSManaged public var affiliation: String?
    @NSManaged public var funder: String?
    @NSManaged public var license: String?
    @NSManaged public var embargoUntil: Date?

    /// Typed semantics for the folder-membership relationship (ADR-0014 D56).
    /// Defaults to "Contains" on legacy rows via lightweight migration. Values
    /// mirror `crates/impress-core/src/reference.rs::EdgeType`; the small set
    /// applicable here is Contains / Cites / Supersedes / DerivedFrom.
    @NSManaged public var edgeType: String?

    // Relationships
    @NSManaged public var folder: CDFolder?
    @NSManaged public var workspace: CDWorkspace?
}

/// Edge types used by `CDDocumentReference.edgeType`. Mirrors a subset of the
/// Rust `EdgeType` enum (ADR-0014 D56) — only the variants meaningful for
/// a folder→document link are surfaced here.
public enum CDDocumentReferenceEdgeType: String, CaseIterable, Sendable {
    case contains   = "Contains"
    case cites      = "Cites"
    case supersedes = "Supersedes"
    case derivedFrom = "DerivedFrom"

    public static var defaultValue: CDDocumentReferenceEdgeType { .contains }
}

public extension CDDocumentReference {
    /// Validates an ORCID iD string of the form `0000-0000-0000-0000`
    /// (with optional `X` checksum digit in the last position).
    static func isValidORCID(_ candidate: String) -> Bool {
        candidate.range(
            of: #"^\d{4}-\d{4}-\d{4}-\d{3}[\dX]$"#,
            options: .regularExpression
        ) != nil
    }
}

public extension CDDocumentReference {
    /// Display title, falling back to "Untitled" if no cached title
    var displayTitle: String {
        if let title = cachedTitle, !title.isEmpty { return title }
        return "Untitled"
    }
}
