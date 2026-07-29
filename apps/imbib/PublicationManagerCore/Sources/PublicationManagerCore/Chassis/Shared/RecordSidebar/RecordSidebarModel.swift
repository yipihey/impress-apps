// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS).
//
//  RecordSidebarModel.swift
//  PublicationManagerCore
//
//  The sidebar, as DATA (ADR-0021 continued onto iOS).
//
//  macOS renders its sidebar through `ImbibSidebarViewModel` +
//  `SidebarOutlineView` (AppKit, NSOutlineView). iOS cannot use either, and
//  the temptation is therefore to hand-write an iOS sidebar with its own
//  literal list of sections, statuses and folder rules — a second truth table
//  that drifts from the presets the moment either side changes. That is
//  exactly the failure ADR-0021 exists to prevent.
//
//  So the SHAPE of a sidebar is expressed here as platform-free values:
//  a `[RecordSidebarSectionModel]` built from an `AppShellConfiguration`
//  (which sections, which record kind each serves) plus each kind's
//  `RecordKindDescriptor` (which statuses it has, whether it has folders).
//  `RecordSidebarBuilder` is the only place those rules live; the iOS view
//  (`RecordSidebarView`) is a dumb renderer of the result, and this file is
//  unit-testable on macOS in `swift test`.
//
//  Adding an app = passing its preset. Nothing here names "manuscript",
//  "imprint" or "imbib".
//

import Foundation
// Re-exported: `RecordSidebarNode.flagColor` is `FlagColor`, so the flag
// vocabulary is part of the chassis's PUBLIC surface — an adopter that renders
// a sidebar node has to be able to name it (and reach the one shared
// `FlagColor.displayColor` mapping) from `import PublicationManagerCore`
// alone, exactly like `ImpressSidebar` and `ImpressStoreKit` above.
@_exported import ImpressFTUI

// MARK: - Folders

/// One collection/folder row, binding-agnostic — the projection every kind's
/// folder tree collapses to for sidebar purposes (imprint's
/// `ManuscriptCollection`, imbib's `CollectionModel`, PMC's
/// `CollectionKernelRow` all map onto this).
///
/// `parentID` is the TREE parent (payload `parent_collection_ref` /
/// `parent_id`), NEVER the envelope parent — see the c902a22f postmortem in
/// apps/imbib/CLAUDE.md.
public struct RecordFolder: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let parentID: UUID?
    public let sortOrder: Int64

    public init(id: UUID, name: String, parentID: UUID? = nil, sortOrder: Int64 = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortOrder = sortOrder
    }
}

public extension Array where Element == RecordFolder {

    /// Direct children of `parentID` (nil = roots), ordered by sortOrder then
    /// name — the same ordering the macOS folder nodes use.
    func children(of parentID: UUID?) -> [RecordFolder] {
        filter { $0.parentID == parentID }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    /// `id` plus every descendant — the set a reparent must never target
    /// (a folder cannot become its own descendant). The Rust kernel enforces
    /// this too; this is the pre-check that keeps the menu honest.
    func subtreeIDs(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var frontier = [id]
        while let current = frontier.popLast() {
            for child in self where child.parentID == current && !result.contains(child.id) {
                result.insert(child.id)
                frontier.append(child.id)
            }
        }
        return result
    }

    /// Pre-order (parent before children) with depth, for a flat List render.
    func preOrder() -> [(folder: RecordFolder, depth: Int)] {
        var out: [(RecordFolder, Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for folder in children(of: parent) {
                out.append((folder, depth))
                walk(folder.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }
}

// MARK: - Scope

/// What a sidebar node selects, in RECORD-KIND terms.
///
/// Deliberately NOT an app's store scope: each app translates this into its
/// own (imprint → `ManuscriptStoreScope`, imbib → `PublicationSource`), which
/// keeps the per-kind scope parallelism ADR-0018 invariant 3 requires while
/// still letting ONE sidebar produce selections for all of them.
public enum RecordSidebarScope: Hashable, Sendable {
    /// Every record of the kind (the kind's dismissal rule still applies).
    case all(RecordKindID)
    /// A payload `status` value declared by the kind's descriptor.
    case status(RecordKindID, String)
    /// Members of one folder of the kind's collection binding.
    case folder(RecordKindID, UUID)
    /// Flagged records; nil colour = any flag.
    case flagged(RecordKindID, String?)
    /// A section with no finer semantics in this shell (Cited in Manuscripts,
    /// Review Queue, a custom surface): the host decides what to show.
    case section(SidebarSectionType, RecordKindID?)

    public var kind: RecordKindID? {
        switch self {
        case .all(let k), .status(let k, _), .folder(let k, _), .flagged(let k, _): return k
        case .section(_, let k): return k
        }
    }

    /// The folder this scope is confined to, when it is a folder scope. Hosts
    /// use it to offer "Remove from Folder" only where that makes sense.
    public var folderID: UUID? {
        if case .folder(_, let id) = self { return id }
        return nil
    }

    /// The status this scope explicitly names, if any. Mirrors
    /// `ManuscriptStoreScope.explicitStatus` — the dismissed-exclusion rule
    /// keys off it, so a scope that names `dismissed` is the only one that
    /// sees dismissed rows.
    public var explicitStatus: String? {
        if case .status(_, let s) = self { return s }
        return nil
    }
}

extension RecordSidebarScope: RecordScopeKey {
    public var scopeKey: String {
        switch self {
        case .all(let k): return "\(k.rawValue).all"
        case .status(let k, let s): return "\(k.rawValue).status.\(s)"
        case .folder(let k, let id): return "\(k.rawValue).folder.\(id.uuidString.lowercased())"
        case .flagged(let k, let c): return "\(k.rawValue).flagged.\(c ?? "any")"
        case .section(let section, let k):
            return "section.\(section.rawValue).\(k?.rawValue ?? "none")"
        }
    }

    public var stableViewID: UUID { .deterministic(from: scopeKey) }
}

// MARK: - Status presentation

/// Label + icon for a raw `status` value.
///
/// HONEST LIMITATION: `TriageCapabilities.statuses` is `[String]`, so the
/// descriptor declares WHICH statuses a kind has but not how to name or
/// picture them. The table below is the chassis's shared presentation for the
/// reserved lifecycle values (docs/status-lifecycle.md) and everything else
/// falls back to a title-cased spelling of the raw value — so a kind that
/// invents a status still renders sanely, it just renders generically. The
/// principled fix is to widen `statuses` into `[StatusSpec]` carrying
/// label/icon; that is a contract change with parity tests attached, tracked
/// as follow-up rather than smuggled in here.
public enum RecordStatusPresentation {

    private static let known: [String: (label: String, systemImage: String)] = [
        "draft": ("Drafts", "pencil"),
        "internal-review": ("Internal Review", "person.2"),
        "submitted": ("Submitted", "paperplane"),
        "in-revision": ("In Revision", "arrow.triangle.2.circlepath"),
        "published": ("Published", "checkmark.seal"),
        "archived": ("Archive", "archivebox"),
        "dismissed": ("Dismissed", "xmark.circle"),
    ]

    public static func label(for status: String) -> String {
        if let known = known[status]?.label { return known }
        return status
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    public static func systemImage(for status: String) -> String {
        known[status]?.systemImage ?? "circle"
    }
}

// MARK: - Nodes

/// One selectable row in the sidebar.
public struct RecordSidebarNode: Identifiable, Hashable, Sendable {
    public let scope: RecordSidebarScope
    public let title: String
    public let systemImage: String
    /// Badge count, or nil for "don't show one".
    public var count: Int?
    /// Sub-rows (folder children). Empty for leaf nodes.
    public var children: [RecordSidebarNode]
    /// Whether this row is a user folder — drives the organise affordances
    /// (rename / new subfolder / move / delete), which are additionally gated
    /// on the kind's `CollectionCapability.canOrganize`.
    public var isFolder: Bool
    /// The flag this row stands for, when it is a flag row.
    ///
    /// Carried as the flag ENUM, not a `Color`: this file is the sidebar as
    /// platform-free data, and the enum is the key into the one cross-platform
    /// mapping (`FlagColor.displayColor`, ImpressFTUI). Renderers ask for the
    /// colour — macOS's `ImbibSidebarNode.iconColor` and iOS's
    /// `RecordSidebarView` icon tint both resolve through the same property,
    /// so a flag cannot be red in one shell and grey in the other.
    public var flagColor: FlagColor?

    public var id: UUID { scope.stableViewID }

    public init(
        scope: RecordSidebarScope,
        title: String,
        systemImage: String,
        count: Int? = nil,
        children: [RecordSidebarNode] = [],
        isFolder: Bool = false,
        flagColor: FlagColor? = nil
    ) {
        self.scope = scope
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.children = children
        self.isFolder = isFolder
        self.flagColor = flagColor
    }
}

public extension Array where Element == RecordSidebarNode {

    /// Pre-order flattening that stops descending at collapsed rows — the
    /// shape a SwiftUI `List` renders with a depth indent.
    func flattened(expanded: Set<UUID>) -> [(node: RecordSidebarNode, depth: Int)] {
        var out: [(RecordSidebarNode, Int)] = []
        func walk(_ nodes: [RecordSidebarNode], _ depth: Int) {
            for node in nodes {
                out.append((node, depth))
                if !node.children.isEmpty, expanded.contains(node.id) {
                    walk(node.children, depth + 1)
                }
            }
        }
        walk(self, 0)
        return out
    }
}

// MARK: - Sections

/// How a section presents the kind it is bound to. Derived from the SECTION
/// (chassis semantics), not from the app — `.flagged` means the same thing in
/// every shell, which is why the presets only have to say which KIND it serves.
public enum RecordSidebarSectionRole: Sendable, Equatable {
    /// The kind's home section: All + status smart-children + folder tree.
    case primary
    /// Per-flag-colour children.
    case flagged
    /// The kind's dismissed status.
    case dismissed
    /// One opaque selectable row (the host owns what it shows).
    case opaque

    public static func role(for section: SidebarSectionType) -> RecordSidebarSectionRole {
        switch section {
        case .flagged: return .flagged
        case .dismissed: return .dismissed
        case .citedInManuscripts, .reviewQueue, .search, .sharedWithMe, .scixLibraries:
            return .opaque
        case .inbox, .libraries, .exploration, .artifacts, .manuscripts,
             .figures, .mail, .agents:
            return .primary
        }
    }
}

/// One rendered sidebar section: its chrome, the kind it serves here, and its
/// rows.
public struct RecordSidebarSectionModel: Identifiable, Sendable {
    public let section: SidebarSectionType
    public let kind: RecordKindID?
    public let role: RecordSidebarSectionRole
    public let nodes: [RecordSidebarNode]
    /// Whether this section may offer folder create/rename/reparent/delete —
    /// the kind's `CollectionCapability.canOrganize`, resolved once here so no
    /// view has to re-derive it.
    public let canOrganizeFolders: Bool

    public var id: String { section.rawValue }
    public var title: String { section.displayName }
    public var systemImage: String { section.icon }

    public init(
        section: SidebarSectionType,
        kind: RecordKindID?,
        role: RecordSidebarSectionRole,
        nodes: [RecordSidebarNode],
        canOrganizeFolders: Bool
    ) {
        self.section = section
        self.kind = kind
        self.role = role
        self.nodes = nodes
        self.canOrganizeFolders = canOrganizeFolders
    }
}
