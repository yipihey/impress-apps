//
//  FolderNodeAdapter.swift
//  MessageManagerCore
//
//  Bridges CDFolder to ImpressSidebar's SidebarTreeNode protocol.
//

import SwiftUI
import ImpressSidebar

/// Adapts a CDFolder to SidebarTreeNode for use with GenericTreeRow.
@MainActor
public struct FolderNodeAdapter: SidebarTreeNode {
    private let folder: CDFolder

    public init(_ folder: CDFolder) {
        self.folder = folder
    }

    public var id: UUID { folder.id }
    public var displayName: String { folder.name }

    public var iconName: String {
        if folder.isVirtualFolder {
            return "folder.badge.gearshape"
        }
        switch folder.role {
        case .inbox:    return "tray"
        case .sent:     return "paperplane"
        case .drafts:   return "square.and.pencil"
        case .trash:    return "trash"
        case .archive:  return "archivebox"
        case .spam:     return "exclamationmark.shield"
        case .agents:   return "brain.head.profile"
        case .custom:   return "folder"
        }
    }

    public var iconColor: Color? {
        switch folder.role {
        case .inbox:        return .accentColor
        case .trash, .spam: return .red
        case .agents:       return .purple
        default:            return nil
        }
    }

    public var displayCount: Int? {
        folder.unreadCount > 0 ? Int(folder.unreadCount) : nil
    }

    public var treeDepth: Int { folder.depth }
    public var hasTreeChildren: Bool { folder.hasChildren }
    public var parentID: UUID? { folder.parentFolder?.id }

    public var childIDs: [UUID] {
        folder.sortedChildren.map(\.id)
    }

    public var ancestorIDs: [UUID] {
        folder.ancestors.map(\.id)
    }

    /// Access to the underlying CDFolder for domain-specific operations.
    public var underlyingFolder: CDFolder { folder }
}

// MARK: - Array Extension

public extension Array where Element == CDFolder {
    /// Convert an array of CDFolders to FolderNodeAdapters.
    @MainActor
    func asFolderAdapters() -> [FolderNodeAdapter] {
        map { FolderNodeAdapter($0) }
    }
}
