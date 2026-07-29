// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS).
//
//  RecordSidebarBuilder.swift
//  PublicationManagerCore
//
//  The ONE place the sidebar's shape is decided, for every impress app.
//
//  Inputs are entirely declarative:
//    * `AppShellConfiguration` — which sections exist in this shell, which
//      record kind each one serves (`visibleSections`, `sectionBindings`,
//      `passesFacetGate`), and which auxiliary routes it carries.
//    * `RecordKindDescriptor` — whether the kind has a status lifecycle
//      (`triage.statuses`), a dismissal status, flags, and a folder tree
//      (`collection`).
//    * `RecordSidebarDataSource` — the app's store, behind closures, because
//      this folder must not import store types (ADR-0021 D3).
//
//  Nothing here is conditioned on an app id or a record kind. Passing
//  `.imprint` yields imprint's sidebar; passing `.imbib` yields imbib's;
//  passing `.impress` yields every section at once.
//

import Foundation
import ImpressFTUI

// MARK: - Data source

/// The app's store, as closures. Every member has a defaulted no-op/empty
/// implementation so a host can adopt the sidebar incrementally (and so unit
/// tests can build one with a literal folder list).
@MainActor
public struct RecordSidebarDataSource {

    /// Folder rows for a kind, flat; the builder assembles the tree from
    /// `parentID`.
    public var folders: (RecordKindID) -> [RecordFolder]

    /// Member counts aligned index-for-index with the ids — a batch verb
    /// because the kernel offers one (`collectionMemberCounts`).
    public var folderCounts: (RecordKindID, [UUID]) -> [Int]

    /// Badge count for a non-folder scope, or nil for "no badge".
    public var count: (RecordSidebarScope) -> Int?

    /// The host's CONTENT gate, on top of the configuration's
    /// `permits`/`passesFacetGate` — visibility is the intersection of all
    /// three, exactly as on macOS (`ImbibSidebarViewModel.shouldShowSection`
    /// hides empty sections there). A host with no surface for a permitted
    /// section returns false here rather than the preset lying about it.
    public var sectionIsAvailable: (SidebarSectionType) -> Bool

    public init(
        folders: @escaping (RecordKindID) -> [RecordFolder] = { _ in [] },
        folderCounts: @escaping (RecordKindID, [UUID]) -> [Int] = { _, ids in
            ids.map { _ in 0 }
        },
        count: @escaping (RecordSidebarScope) -> Int? = { _ in nil },
        sectionIsAvailable: @escaping (SidebarSectionType) -> Bool = { _ in true }
    ) {
        self.folders = folders
        self.folderCounts = folderCounts
        self.count = count
        self.sectionIsAvailable = sectionIsAvailable
    }
}

// MARK: - Shell helpers

public extension AppShellConfiguration {

    /// The record kind a section serves in this shell, falling back to the
    /// CANONICAL section→kind table.
    ///
    /// Presets only spell out the bindings that differ from the obvious one
    /// (imprint binds `.flagged`/`.dismissed` to `.manuscript` and leaves
    /// `.manuscripts` unbound because the section's own name says it). The
    /// canonical table is not invented here: it is `impress`'s
    /// `sectionBindings`, the preset whose documented job is to name the kind
    /// EVERY section serves. Reading it keeps one table instead of two.
    ///
    /// Returns nil when the fallback kind is not registered in this shell.
    func effectiveRecordKind(for section: SidebarSectionType) -> RecordKindID? {
        let resolved = recordKind(for: section)
            ?? AppShellConfiguration.impress.sectionBindings[section]
        guard let resolved, recordKinds[resolved] != nil else { return nil }
        return resolved
    }

    /// Sections this shell may show, in the user's persisted order, after the
    /// preset's `permits` + facet gates. The content gate is the caller's.
    func orderedVisibleSections(order: [SidebarSectionType]) -> [SidebarSectionType] {
        order.filter { permits($0) && passesFacetGate($0) }
    }
}

// MARK: - Builder

public enum RecordSidebarBuilder {

    /// Build the whole sidebar for a shell.
    ///
    /// - Parameters:
    ///   - configuration: the shell preset (the app's declarative identity).
    ///   - order: section order (persisted per app); defaults to the suite
    ///     default order.
    ///   - dataSource: the app's store, behind closures.
    @MainActor
    public static func sections(
        configuration: AppShellConfiguration,
        order: [SidebarSectionType]? = nil,
        dataSource: RecordSidebarDataSource
    ) -> [RecordSidebarSectionModel] {
        let sectionOrder = order ?? SidebarSectionOrderStoreWrapper.defaultOrder
        return configuration.orderedVisibleSections(order: sectionOrder)
            .filter { dataSource.sectionIsAvailable($0) }
            .compactMap { section in
                self.section(section, configuration: configuration, dataSource: dataSource)
            }
    }

    @MainActor
    private static func section(
        _ section: SidebarSectionType,
        configuration: AppShellConfiguration,
        dataSource: RecordSidebarDataSource
    ) -> RecordSidebarSectionModel? {
        let role = RecordSidebarSectionRole.role(for: section)
        let kindID = configuration.effectiveRecordKind(for: section)
        let descriptor = kindID.flatMap { configuration.recordKinds[$0] }

        guard let kindID, let descriptor else {
            // Unbound section (imbib's Review Queue: its rows have no
            // descriptor by design). One opaque row, host-rendered.
            return RecordSidebarSectionModel(
                section: section,
                kind: nil,
                role: .opaque,
                nodes: [
                    RecordSidebarNode(
                        scope: .section(section, nil),
                        title: section.displayName,
                        systemImage: section.icon)
                ],
                canOrganizeFolders: false)
        }

        let nodes: [RecordSidebarNode]
        switch role {
        case .primary:
            nodes = primaryNodes(
                section: section,
                kind: kindID,
                descriptor: descriptor,
                dataSource: dataSource)
        case .flagged:
            nodes = descriptor.triage.canFlag
                ? flaggedNodes(kind: kindID, dataSource: dataSource)
                : []
        case .dismissed:
            nodes = dismissedNodes(kind: kindID, descriptor: descriptor, dataSource: dataSource)
        case .opaque:
            nodes = [
                RecordSidebarNode(
                    scope: .section(section, kindID),
                    title: section.displayName,
                    systemImage: section.icon,
                    count: dataSource.count(.section(section, kindID)))
            ]
        }

        guard !nodes.isEmpty else { return nil }
        return RecordSidebarSectionModel(
            section: section,
            kind: kindID,
            role: role,
            nodes: nodes,
            canOrganizeFolders: descriptor.collection?.canOrganize ?? false)
    }

    // MARK: Primary section

    /// All + status smart-children + folder tree. Every part is conditional
    /// on the DESCRIPTOR: a kind with no `statuses` gets no smart children, a
    /// kind with no `collection` gets no folders.
    @MainActor
    private static func primaryNodes(
        section: SidebarSectionType,
        kind: RecordKindID,
        descriptor: RecordKindDescriptor,
        dataSource: RecordSidebarDataSource
    ) -> [RecordSidebarNode] {
        var nodes: [RecordSidebarNode] = [
            RecordSidebarNode(
                scope: .all(kind),
                title: "All \(descriptor.displayName)s",
                systemImage: section.icon,
                count: dataSource.count(.all(kind)))
        ]

        // Status smart-children, minus the dismissed one: that status owns
        // the `.dismissed` SECTION, and listing it twice would give the same
        // rows two homes.
        let dismissedStatus: String? = {
            if case .statusChange(let dismissed, _) = descriptor.triage.dismissal {
                return dismissed
            }
            return nil
        }()
        for status in descriptor.triage.statuses where status != dismissedStatus {
            let scope = RecordSidebarScope.status(kind, status)
            nodes.append(
                RecordSidebarNode(
                    scope: scope,
                    title: RecordStatusPresentation.label(for: status),
                    systemImage: RecordStatusPresentation.systemImage(for: status),
                    count: dataSource.count(scope)))
        }

        nodes.append(contentsOf: folderNodes(kind: kind, descriptor: descriptor, dataSource: dataSource))
        return nodes
    }

    /// The kind's folder tree, nested (children carried on the node), with
    /// member counts. Empty when the kind declares no `CollectionCapability`.
    @MainActor
    public static func folderNodes(
        kind: RecordKindID,
        descriptor: RecordKindDescriptor,
        dataSource: RecordSidebarDataSource
    ) -> [RecordSidebarNode] {
        guard descriptor.collection != nil else { return [] }
        let folders = dataSource.folders(kind)
        guard !folders.isEmpty else { return [] }

        let ids = folders.map(\.id)
        let counts = dataSource.folderCounts(kind, ids)
        var countByID: [UUID: Int] = [:]
        if counts.count == ids.count {
            for (id, count) in zip(ids, counts) { countByID[id] = count }
        }

        func build(_ folder: RecordFolder) -> RecordSidebarNode {
            let count = countByID[folder.id] ?? 0
            return RecordSidebarNode(
                scope: .folder(kind, folder.id),
                title: folder.name,
                systemImage: "folder",
                count: count > 0 ? count : nil,
                children: folders.children(of: folder.id).map(build),
                isFolder: true)
        }
        return folders.children(of: nil).map(build)
    }

    // MARK: Flagged / Dismissed

    @MainActor
    private static func flaggedNodes(
        kind: RecordKindID,
        dataSource: RecordSidebarDataSource
    ) -> [RecordSidebarNode] {
        FlagColor.allCases.map { color in
            let scope = RecordSidebarScope.flagged(kind, color.rawValue)
            return RecordSidebarNode(
                scope: scope,
                title: color.displayName,
                systemImage: color.systemImage,
                count: dataSource.count(scope),
                // The row's colour travels WITH the row. Without it the
                // renderer has nothing to tint from and every flag reads grey.
                flagColor: color)
        }
    }

    @MainActor
    private static func dismissedNodes(
        kind: RecordKindID,
        descriptor: RecordKindDescriptor,
        dataSource: RecordSidebarDataSource
    ) -> [RecordSidebarNode] {
        switch descriptor.triage.dismissal {
        case .statusChange(let dismissed, _):
            let scope = RecordSidebarScope.status(kind, dismissed)
            return [
                RecordSidebarNode(
                    scope: scope,
                    title: SidebarSectionType.dismissed.displayName,
                    systemImage: SidebarSectionType.dismissed.icon,
                    count: dataSource.count(scope))
            ]
        case .libraryMove:
            // imbib: dismissal is a LIBRARY move, so the section is one
            // opaque row the host resolves to its Dismissed library.
            let scope = RecordSidebarScope.section(.dismissed, kind)
            return [
                RecordSidebarNode(
                    scope: scope,
                    title: SidebarSectionType.dismissed.displayName,
                    systemImage: SidebarSectionType.dismissed.icon,
                    count: dataSource.count(scope))
            ]
        case .none:
            return []
        }
    }
}
