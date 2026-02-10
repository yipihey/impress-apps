//
//  ImbibSidebarNode.swift
//  imbib
//
//  Unified node type for the NSOutlineView-based sidebar.
//  Uses value types (UUIDs, strings) rather than Core Data objects.
//

import Foundation
import SwiftUI
import ImpressSidebar
import ImpressFTUI
import PublicationManagerCore

// MARK: - Node Type

/// Discriminated union of all sidebar item types.
/// Uses value types only — no Core Data objects stored here.
enum ImbibSidebarNodeType: Hashable {
    case section(SidebarSectionType)
    case allInbox
    case inboxFeed(feedID: UUID)
    case inboxCollection(collectionID: UUID)
    case library(libraryID: UUID)
    case libraryCollection(collectionID: UUID, libraryID: UUID)
    case sharedLibrary(libraryID: UUID)
    case scixLibrary(libraryID: UUID)
    case searchForm(SearchFormType)
    case explorationSearch(searchID: UUID)
    case explorationCollection(collectionID: UUID)
    case anyFlag
    case flagColor(FlagColor)
    case allArtifacts
    case artifactType(String)   // ArtifactType.rawValue
    case dismissed
}

// MARK: - Sidebar Node

/// Unified node for the imbib sidebar NSOutlineView.
///
/// Conforms to `SidebarTreeNode` so it works with `SidebarOutlineView`.
/// Deterministic UUIDs for fixed items (sections, allInbox, flags, etc.)
/// ensure stable identity across rebuilds.
@MainActor
struct ImbibSidebarNode: SidebarTreeNode {
    let id: UUID
    let nodeType: ImbibSidebarNodeType
    let displayName: String
    let iconName: String
    var displayCount: Int?
    var iconColor: Color?
    var treeDepth: Int = 0
    var hasTreeChildren: Bool = false
    var parentID: UUID?
    var childIDs: [UUID] = []
    var ancestorIDs: [UUID] = []

    /// Whether this node is a section header (group item in NSOutlineView)
    var isGroup: Bool = false
}

// MARK: - Tab Mapping

extension ImbibSidebarNode {
    /// Maps this node to the corresponding ImbibTab for content routing.
    /// Returns nil for section headers (not selectable).
    var imbibTab: ImbibTab? {
        switch nodeType {
        case .section:
            return nil
        case .allInbox:
            return .inbox
        case .inboxFeed(let feedID):
            return .inboxFeed(feedID)
        case .inboxCollection(let collectionID):
            return .inboxCollection(collectionID)
        case .library(let libraryID):
            return .library(libraryID)
        case .libraryCollection(let collectionID, _):
            return .collection(collectionID)
        case .sharedLibrary(let libraryID):
            return .sharedLibrary(libraryID)
        case .scixLibrary(let libraryID):
            return .scixLibrary(libraryID)
        case .searchForm(let formType):
            return .searchForm(formType)
        case .explorationSearch(let searchID):
            return .exploration(searchID)
        case .explorationCollection(let collectionID):
            return .explorationCollection(collectionID)
        case .anyFlag:
            return .flagged(nil)
        case .flagColor(let color):
            return .flagged(color.rawValue)
        case .allArtifacts:
            return .allArtifacts
        case .artifactType(let rawValue):
            return .artifactType(rawValue)
        case .dismissed:
            return .dismissed
        }
    }
}

// MARK: - Deterministic UUIDs

/// Generates deterministic UUIDs from string identifiers.
/// This ensures section headers, fixed items (allInbox, anyFlag, etc.)
/// have stable IDs across rebuilds without storing state.
enum ImbibSidebarNodeID {

    /// Create a deterministic UUID from a stable string key.
    /// Uses Hasher (seeded per-process) so IDs are stable within a single app launch.
    static func stable(_ key: String) -> UUID {
        // Use UUID v5-style: hash the key and pack into UUID bytes
        var hasher = Hasher()
        hasher.combine("com.imbib.sidebar")
        hasher.combine(key)
        let hash = hasher.finalize()

        // Start from zeroed UUID — NOT UUID() which is random each call
        var uuidBytes: uuid_t = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        withUnsafeBytes(of: hash) { src in
            withUnsafeMutableBytes(of: &uuidBytes) { dst in
                for i in 0..<min(src.count, 8) {
                    dst[i] = src[i]
                }
            }
        }
        // Set version and variant bits for UUID v5 compatibility
        uuidBytes.6 = (uuidBytes.6 & 0x0F) | 0x50 // version 5
        uuidBytes.8 = (uuidBytes.8 & 0x3F) | 0x80 // variant 1

        return UUID(uuid: uuidBytes)
    }

    // Pre-computed stable IDs for fixed items
    static let allInbox = stable("allInbox")
    static let anyFlag = stable("anyFlag")
    static let dismissed = stable("dismissed")

    static func section(_ type: SidebarSectionType) -> UUID {
        stable("section.\(type.rawValue)")
    }

    static func searchForm(_ type: SearchFormType) -> UUID {
        stable("searchForm.\(type.rawValue)")
    }

    static func flagColor(_ color: FlagColor) -> UUID {
        stable("flagColor.\(color.rawValue)")
    }

    static let allArtifacts = stable("allArtifacts")

    static func artifactType(_ rawValue: String) -> UUID {
        stable("artifactType.\(rawValue)")
    }
}
