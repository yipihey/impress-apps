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
//      `passesFacetGate`), which KINDS this host can present at all
//      (`presentableKinds`), and which auxiliary routes it carries.
//    * `RecordKindDescriptor` — whether the kind has a status lifecycle
//      (`triage.statuses`, each carrying its own label + symbol), a dismissal
//      status, flags, a plural name, and a folder tree (`collection`, carrying
//      its own folder glyph).
//    * `RecordSidebarDataSource` — the app's store, behind closures, because
//      this folder must not import store types (ADR-0021 D3).
//
//  Nothing here is conditioned on an app id or a record kind. Passing
//  `.imprint` yields imprint's sidebar; passing `.imbib` yields imbib's;
//  passing `.impress` yields every section at once.
//

import Foundation
import ImpressFTUI

// MARK: - Host-resolved section content

/// What a HOST contributes to one section, on top of what the section's role
/// derives from the declarations.
///
/// The four roles (`primary`/`flagged`/`dismissed`/`opaque`) cover every
/// section whose rows are a slice of ONE record kind. imbib is the shell that
/// showed where that stops:
///
///   * `.opaque` yields exactly one row titled after the section. imbib's
///     Search section is NINE rows (the search forms), SciX Libraries is one
///     row per remote shelf, and Cited in Manuscripts' single row is titled
///     "All Cited Papers", not "Cited in Manuscripts".
///   * `.primary` yields "All <plural>" + status children + the kind's folder
///     tree. imbib's Inbox is Recent + feeds + inbox collections, and its
///     Libraries section is a tree of LIBRARIES each owning its own
///     collections — the publication kind deliberately declares no
///     `CollectionCapability`, because "the folder tree of publications" is
///     not a thing that exists once collections are per-library.
///
/// The alternative was a second sidebar view, which is the drift ADR-0021
/// exists to prevent, or app-id/section-name literals inside the builder,
/// which is the drift ADR-0022 exists to prevent. So the SHAPE stays
/// declarative — which sections exist, in what order, with what title, icon
/// and gates, all from the preset — and the ROWS of a section the host
/// resolves come from the host, through the same closure seam its folders and
/// counts already do.
///
/// Every field is optional-shaped: returning `RecordSidebarSectionContent()`
/// changes nothing.
public struct RecordSidebarSectionContent: Sendable {

    /// Rows for the section. nil = keep the role-derived rows (imbib returns
    /// nil for Flagged and Dismissed, which the declarations already get right).
    public var nodes: [RecordSidebarNode]?

    /// Make the section HEADER a selectable destination (see
    /// `RecordSidebarSectionModel.headerScope`).
    public var headerScope: RecordSidebarScope?

    /// Override the descriptor-derived organise gate. nil = the kind's
    /// `CollectionCapability.canOrganize`.
    ///
    /// A host that resolves its own folder rows also owns the answer to
    /// "are these organisable", because the kind may declare no collection
    /// binding at all (imbib's publications) and still have real folders.
    public var canOrganizeFolders: Bool?

    /// Whether the header offers root-folder creation. nil = follow
    /// `canOrganizeFolders`.
    public var offersRootFolderCreation: Bool?

    public init(
        nodes: [RecordSidebarNode]? = nil,
        headerScope: RecordSidebarScope? = nil,
        canOrganizeFolders: Bool? = nil,
        offersRootFolderCreation: Bool? = nil
    ) {
        self.nodes = nodes
        self.headerScope = headerScope
        self.canOrganizeFolders = canOrganizeFolders
        self.offersRootFolderCreation = offersRootFolderCreation
    }
}

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

    /// The host's contribution to a section (rows it resolves itself, a
    /// selectable header, its own organise gate). nil = the section is fully
    /// derived from the declarations, which is what imprint returns for every
    /// section it shows.
    public var sectionContent: (SidebarSectionType, RecordKindID?) -> RecordSidebarSectionContent?

    public init(
        folders: @escaping (RecordKindID) -> [RecordFolder] = { _ in [] },
        folderCounts: @escaping (RecordKindID, [UUID]) -> [Int] = { _, ids in
            ids.map { _ in 0 }
        },
        count: @escaping (RecordSidebarScope) -> Int? = { _ in nil },
        sectionIsAvailable: @escaping (SidebarSectionType) -> Bool = { _ in true },
        sectionContent: @escaping (SidebarSectionType, RecordKindID?)
            -> RecordSidebarSectionContent? = { _, _ in nil }
    ) {
        self.folders = folders
        self.folderCounts = folderCounts
        self.count = count
        self.sectionIsAvailable = sectionIsAvailable
        self.sectionContent = sectionContent
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

    /// Build a COMPOSED sidebar: one group per app, each group built by running
    /// the call above against that app's own preset.
    ///
    /// This is the whole of impress's sidebar redesign, and the point is how
    /// little there is of it. There is no per-group logic below — no section
    /// list, no kind, no rule about what Flagged means in the imprint group.
    /// Every one of those is `sections(configuration:order:dataSource:)`
    /// answering the same question it answers for the shipping imprint app,
    /// because it is handed the same value.
    ///
    /// The one thing the composed call adds is the HOST intersection: the
    /// sibling presets say `presentableKinds == nil` (true of their own apps),
    /// and a composed host is a different build. `SidebarAppGroup
    /// .configuration(inHost:)` applies it once per group.
    ///
    /// EMPTY GROUPS ARE KEPT. A group whose every section gates away still
    /// returns a model with `sections == []`, and the renderer still draws its
    /// header. "Collate each of their sidebars" means the five sidebars are
    /// present; an app with nothing in it right now is a fact about the store,
    /// not about whether that app is part of impress. Within a group, a section
    /// that resolves to no rows keeps the existing DROP behaviour — the
    /// distinction being that a missing section is the host saying "I cannot
    /// serve this", which is exactly what the flat sidebar's negative-space
    /// contract already means.
    @MainActor
    public static func groups(
        composition: SidebarComposition,
        host: AppShellConfiguration,
        order: [SidebarSectionType]? = nil,
        dataSource: RecordSidebarDataSource
    ) -> [RecordSidebarGroupModel] {
        composition.groups.map { group in
            RecordSidebarGroupModel(
                group: group,
                sections: sections(
                    configuration: group.configuration(inHost: host),
                    order: order,
                    dataSource: dataSource))
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

        // The host's KIND capability. A shell whose build has no surface for
        // this kind drops the section entirely — the declarative replacement
        // for imprint-iOS's former `section != .citedInManuscripts` literal.
        // Unbound sections fall through: they have no kind to be incapable of.
        if let kindID, !configuration.canPresent(kindID) { return nil }

        // What the HOST resolves for this section, if anything.
        let hostContent = dataSource.sectionContent(section, kindID)

        guard let kindID, let descriptor else {
            // Unbound section (imbib's Review Queue: its rows have no
            // descriptor by design). One opaque row, host-rendered.
            let nodes = hostContent?.nodes ?? [
                RecordSidebarNode(
                    scope: .section(section, nil),
                    title: section.displayName,
                    systemImage: section.icon)
            ]
            guard !nodes.isEmpty || hostContent?.headerScope != nil else { return nil }
            return RecordSidebarSectionModel(
                section: section,
                kind: nil,
                role: .opaque,
                nodes: nodes,
                canOrganizeFolders: hostContent?.canOrganizeFolders ?? false,
                headerScope: hostContent?.headerScope,
                offersRootFolderCreation: hostContent?.offersRootFolderCreation)
        }

        // Host rows WIN over the role-derived ones when supplied: the role
        // still decides the section's chrome and semantics, the host only
        // answers "which rows", which is the half a preset cannot know.
        if let nodes = hostContent?.nodes {
            guard !nodes.isEmpty || hostContent?.headerScope != nil else { return nil }
            return RecordSidebarSectionModel(
                section: section,
                kind: kindID,
                role: role,
                nodes: nodes,
                canOrganizeFolders: hostContent?.canOrganizeFolders
                    ?? (descriptor.collection?.canOrganize ?? false),
                headerScope: hostContent?.headerScope,
                offersRootFolderCreation: hostContent?.offersRootFolderCreation)
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

        guard !nodes.isEmpty || hostContent?.headerScope != nil else { return nil }
        return RecordSidebarSectionModel(
            section: section,
            kind: kindID,
            role: role,
            nodes: nodes,
            canOrganizeFolders: hostContent?.canOrganizeFolders
                ?? (descriptor.collection?.canOrganize ?? false),
            headerScope: hostContent?.headerScope,
            offersRootFolderCreation: hostContent?.offersRootFolderCreation)
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
                // DECLARED plural, not `displayName + "s"`: the concatenation
                // was a latent wrong label for the first kind whose name does
                // not take a bare `s`.
                title: "All \(descriptor.pluralDisplayName)",
                systemImage: section.icon,
                count: dataSource.count(.all(kind)))
        ]

        // Status smart-children. `hiddenByDefault` is the declaration that
        // keeps a status out of here; the dismissal status sets it, because it
        // owns the `.dismissed` SECTION and listing it twice would give the
        // same rows two homes. The dismissal semantics are ALSO consulted, so
        // the two statements of that fact cannot silently disagree —
        // `RecordKindStatusSpecTests` asserts they never do.
        let dismissedStatus = descriptor.triage.dismissedStatus
        for spec in descriptor.triage.statuses
        where !spec.hiddenByDefault && spec.rawValue != dismissedStatus {
            let scope = RecordSidebarScope.status(kind, spec.rawValue)
            nodes.append(
                RecordSidebarNode(
                    scope: scope,
                    title: spec.label,
                    systemImage: spec.systemImage,
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
        guard let collection = descriptor.collection else { return [] }
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
                // The kind's DECLARED folder glyph — a kind whose containers
                // are not "folders" (mail's server mailboxes) says so in its
                // `CollectionCapability` instead of this line growing a check.
                systemImage: collection.folderSymbolName,
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
