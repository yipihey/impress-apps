//
//  ImprintSidebarSections.swift
//  imprint
//
//  Sidebar section definitions, persistence, UTTypes, and Transferable drag items.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ImpressSidebar

// MARK: - Section Enum

public enum ImprintSidebarSection: String, CaseIterable, Hashable, Codable, Sendable, SidebarSection {
    case workspace = "workspace"
    case recentDocuments = "recentDocuments"

    public var displayName: String {
        switch self {
        case .workspace: return "Projects"
        case .recentDocuments: return "Recent Documents"
        }
    }

    public var icon: String {
        switch self {
        case .workspace: return "folder"
        case .recentDocuments: return "clock"
        }
    }
}

// MARK: - Section Stores

extension ImprintSidebarSection {
    /// Persisted section ordering
    static let orderStore = SidebarSectionOrderStore<ImprintSidebarSection>(
        key: "imprint.sidebar.sectionOrder",
        defaultOrder: ImprintSidebarSection.allCases
    )

    /// Persisted collapse state
    static let collapsedStore = SidebarCollapsedStateStore<ImprintSidebarSection>(
        key: "imprint.sidebar.collapsedSections"
    )
}

// MARK: - Custom UTTypes for Drag-and-Drop

extension UTType {
    /// UTType for dragging folder IDs within the sidebar
    static let imprintFolderID = UTType(exportedAs: "com.imbib.imprint.folder-id")

    /// UTType for dragging sidebar section headers
    static let imprintSidebarSectionID = UTType(exportedAs: "com.imbib.imprint.sidebar-section-id")
}

// MARK: - Folder Drag Item

struct FolderDragItem: Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .imprintFolderID) { item in
            item.id.uuidString.data(using: .utf8) ?? Data()
        } importing: { data in
            guard let string = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return FolderDragItem(id: uuid)
        }
    }
}

// MARK: - Section Drag Item

struct SectionDragItem: Transferable {
    let type: ImprintSidebarSection

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .imprintSidebarSectionID) { item in
            SectionDragReorder.encode(item.type)
        } importing: { data in
            guard let type = SectionDragReorder.decode(data, as: ImprintSidebarSection.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return SectionDragItem(type: type)
        }
    }
}
