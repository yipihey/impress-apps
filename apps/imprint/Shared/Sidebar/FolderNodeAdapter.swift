//
//  FolderNodeAdapter.swift
//  imprint
//
//  Wraps CDFolder to conform to SidebarTreeNode for use with GenericTreeRow.
//

import Foundation
import SwiftUI
import ImpressSidebar

// MARK: - Folder Node Adapter

@MainActor
public struct FolderNodeAdapter: SidebarTreeNode {
    public let folder: CDFolder

    public init(folder: CDFolder) {
        self.folder = folder
    }

    public var id: UUID { folder.id }

    public var displayName: String { folder.name }

    public var iconName: String {
        folder.hasChildren ? "folder.fill" : "folder"
    }

    public var displayCount: Int? {
        let count = folder.recursiveDocumentCount
        return count > 0 ? count : nil
    }

    public var treeDepth: Int { folder.depth }

    public var hasTreeChildren: Bool { folder.hasChildren }

    public var parentID: UUID? { folder.parentFolder?.id }

    public var childIDs: [UUID] {
        folder.sortedChildren.map { $0.id }
    }

    public var ancestorIDs: [UUID] {
        folder.ancestors.map { $0.id }
    }

    public var iconColor: Color? { .accentColor }
}

// MARK: - Document Reference Node Adapter

/// Adapter for document references displayed as leaf nodes under folders.
@MainActor
public struct DocumentRefNodeAdapter: SidebarTreeNode {
    public let docRef: CDDocumentReference
    /// Depth = parent folder depth + 1
    public let parentDepth: Int

    public init(docRef: CDDocumentReference, parentDepth: Int) {
        self.docRef = docRef
        self.parentDepth = parentDepth
    }

    public var id: UUID { docRef.id }

    public var displayName: String { docRef.displayTitle }

    public var iconName: String { "doc.text" }

    public var displayCount: Int? { nil }

    public var treeDepth: Int { parentDepth + 1 }

    public var hasTreeChildren: Bool { false }

    public var parentID: UUID? { docRef.folder?.id }

    public var childIDs: [UUID] { [] }

    public var ancestorIDs: [UUID] {
        guard let folder = docRef.folder else { return [] }
        return folder.ancestors.map { $0.id } + [folder.id]
    }

    public var iconColor: Color? { nil }
}

// MARK: - Convenience Extensions

extension Array where Element == CDFolder {
    /// Convert to folder node adapters
    @MainActor
    func asFolderAdapters() -> [FolderNodeAdapter] {
        map { FolderNodeAdapter(folder: $0) }
    }
}
