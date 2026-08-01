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
    case tags
    case citedInManuscripts
    case artifacts
    /// The Manuscripts section (GUI-meld plan §5): one section absorbing the
    /// old Journal section — All Manuscripts, status smart-children,
    /// Submissions Inbox, and user folders (manuscript-collection items).
    /// Raw value stays "journal" so persisted section order/collapse state
    /// survives the rename.
    case manuscripts = "journal"
    /// The Figures section (Stage 2-B): implore's Library facet — All
    /// Figures, Unfiled, and figure-collection folders. Permits-gated to the
    /// implore shell (`shouldShowSection`).
    case figures
    /// The Mail section (Stage 2-A): impart's mail-browsing facet — All
    /// Inboxes, then per-account folder trees (mail-account/mail-folder
    /// items). Gated to the impart shell (`shouldShowSection`).
    case mail
    /// The Agents section (Stage 2-C): impel's task/run-browsing facet —
    /// Tasks (with per-state smart children) and Runs. Gated to the impel
    /// shell (`shouldShowSection`).
    case agents
    case reviewQueue
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
        case .tags: return "Tags"
        case .citedInManuscripts: return "Cited in Manuscripts"
        case .artifacts: return "Artifacts"
        case .manuscripts: return "Manuscripts"
        case .figures: return "Figures"
        case .mail: return "Mail"
        case .agents: return "Agents"
        case .reviewQueue: return "Review Queue"
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
        case .tags: return "tag.fill"
        case .citedInManuscripts: return "text.book.closed.fill"
        case .artifacts: return "archivebox"
        case .manuscripts: return "doc.text.image"
        case .figures: return "photo.on.rectangle.angled"
        case .mail: return "envelope"
        case .agents: return "brain"
        case .reviewQueue: return "checklist"
        case .dismissed: return "trash"
        }
    }

    /// How the shared sidebar builder presents this section — the third
    /// per-section fact, declared beside `displayName` and `icon` so adding a
    /// section is ONE edit here instead of one here plus an arm in a chassis
    /// switch (`RecordSidebarSectionRole.role(for:)`, which now just forwards).
    ///
    /// Role is a property of the SECTION, not of the app: `.flagged` means
    /// per-flag-colour rows in every shell, which is exactly why presets only
    /// have to name the KIND each section serves.
    public var role: RecordSidebarSectionRole {
        switch self {
        case .flagged:
            return .flagged
        case .tags:
            return .tags
        case .dismissed:
            return .dismissed
        // Sections whose rows the HOST resolves: they have no finer
        // record-kind semantics the builder could express.
        case .citedInManuscripts, .reviewQueue, .search, .sharedWithMe, .scixLibraries:
            return .opaque
        // A kind's home section: All + status smart-children + folder tree.
        case .inbox, .libraries, .exploration, .artifacts, .manuscripts,
             .figures, .mail, .agents:
            return .primary
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
        .citedInManuscripts,
        .artifacts,
        .manuscripts,
        .figures,
        .mail,
        .agents,
        .reviewQueue,
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
