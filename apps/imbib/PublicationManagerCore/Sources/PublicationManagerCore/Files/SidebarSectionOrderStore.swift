//
//  SidebarSectionOrderStore.swift
//  PublicationManagerCore
//
//  Sidebar section types and persistence using ImpressSidebar generic stores.
//

import Foundation
import ImpressSidebar

// MARK: - Sidebar Section Type

/// Represents the reorderable and collapsible sections in the sidebar
public enum SidebarSectionType: String, CaseIterable, Codable, Identifiable, Equatable, Hashable, Sendable, SidebarSection {
    case inbox
    case libraries
    case sharedWithMe
    case scixLibraries
    case search
    case exploration
    case flagged
    case artifacts
    case dismissed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .inbox: return "Inbox"
        case .libraries: return "Libraries"
        case .sharedWithMe: return "Shared With Me"
        case .scixLibraries: return "SciX Libraries"
        case .search: return "Search"
        case .exploration: return "Exploration"
        case .flagged: return "Flagged"
        case .artifacts: return "Artifacts"
        case .dismissed: return "Dismissed"
        }
    }

    public var icon: String {
        switch self {
        case .inbox: return "building.columns"
        case .libraries: return "books.vertical"
        case .sharedWithMe: return "person.2.fill"
        case .scixLibraries: return "cloud"
        case .search: return "magnifyingglass"
        case .exploration: return "sparkle.magnifyingglass"
        case .flagged: return "flag.fill"
        case .artifacts: return "archivebox"
        case .dismissed: return "trash"
        }
    }
}

// MARK: - Sidebar Section Order Store

/// Persists the user's preferred order of sidebar sections.
///
/// Thin wrapper over ImpressSidebar's generic `SidebarSectionOrderStore`,
/// specialized for imbib's `SidebarSectionType`.
public final class SidebarSectionOrderStoreWrapper: Sendable {

    public static let shared = SidebarSectionOrderStoreWrapper()

    public static let defaultOrder: [SidebarSectionType] = [
        .inbox,
        .libraries,
        .sharedWithMe,
        .scixLibraries,
        .search,
        .exploration,
        .flagged,
        .artifacts,
        .dismissed
    ]

    private let store: ImpressSidebar.SidebarSectionOrderStore<SidebarSectionType>

    private init() {
        self.store = ImpressSidebar.SidebarSectionOrderStore<SidebarSectionType>(
            key: "sidebarSectionOrder",
            defaultOrder: Self.defaultOrder
        )
    }

    public func order() async -> [SidebarSectionType] {
        await store.order()
    }

    public func save(_ order: [SidebarSectionType]) async {
        await store.save(order)
    }

    public func reset() async {
        await store.reset()
    }

    public func loadOrderSync() -> [SidebarSectionType] {
        store.loadSync()
    }

    /// Static convenience for SwiftUI @State initialization.
    public static func loadOrderSync() -> [SidebarSectionType] {
        shared.loadOrderSync()
    }
}

// MARK: - Sidebar Collapsed State Store

/// Persists which sidebar sections are collapsed.
///
/// Thin wrapper over ImpressSidebar's generic `SidebarCollapsedStateStore`.
public final class SidebarCollapsedStateStoreWrapper: Sendable {

    public static let shared = SidebarCollapsedStateStoreWrapper()

    private let store: ImpressSidebar.SidebarCollapsedStateStore<SidebarSectionType>

    private init() {
        self.store = ImpressSidebar.SidebarCollapsedStateStore<SidebarSectionType>(
            key: "sidebarCollapsedSections"
        )
    }

    public func collapsedSections() async -> Set<SidebarSectionType> {
        await store.collapsedSections()
    }

    public func save(_ collapsed: Set<SidebarSectionType>) async {
        await store.save(collapsed)
    }

    public func toggle(_ section: SidebarSectionType) async -> Set<SidebarSectionType> {
        await store.toggle(section)
    }

    public func isCollapsed(_ section: SidebarSectionType) async -> Bool {
        await store.isCollapsed(section)
    }

    public func loadCollapsedSync() -> Set<SidebarSectionType> {
        store.loadSync()
    }

    /// Static convenience for SwiftUI @State initialization.
    public static func loadCollapsedSync() -> Set<SidebarSectionType> {
        shared.loadCollapsedSync()
    }
}

// MARK: - Backward Compatibility Typealiases

/// Backward compatibility: the old `SidebarSectionOrderStore` actor API
/// is now `SidebarSectionOrderStoreWrapper` (a final class wrapping the generic actor).
public typealias SidebarSectionOrderStore = SidebarSectionOrderStoreWrapper

/// Backward compatibility: the old `SidebarCollapsedStateStore` actor API
/// is now `SidebarCollapsedStateStoreWrapper`.
public typealias SidebarCollapsedStateStore = SidebarCollapsedStateStoreWrapper

// MARK: - Notification

public extension Notification.Name {
    static let sidebarSectionOrderDidChange = Notification.Name("sidebarSectionOrderDidChange")
    static let sidebarCollapsedStateDidChange = Notification.Name("sidebarCollapsedStateDidChange")
}
