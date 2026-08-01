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
    /// Records carrying one tag path ("reading/queue").
    ///
    /// Admitted to the closed vocabulary by the SAME test `.flagged` passes and
    /// `.unfiled` fails: it is a subset EVERY kind can be sliced by, and the
    /// store guarantees it rather than any one app — `item_tags` joins any item
    /// id and `items.flag_color` is a column on every row, so no kind has to
    /// opt in and none can be structurally incapable. "Every artifact should be
    /// flaggable and taggable" (2026-08-01); this case is the browse half of
    /// that, the shared `TriageMenu` having long been the apply half.
    ///
    /// The path is hierarchical and slash-separated, matching the store's tag
    /// vocabulary, and matching is DESCENDANT-INCLUSIVE: `.tag(kind, "reading")`
    /// returns rows tagged `reading` AND `reading/queue`. See `TagPathMatch`,
    /// which is the single authority for the rule.
    ///
    /// The alternative (exact match) makes the tree decorative — selecting a
    /// parent would show nothing while its children showed rows, so every
    /// interior row would read as empty. The hierarchy is only worth rendering
    /// if it is also worth selecting.
    case tag(RecordKindID, String)
    /// A section with no finer semantics in this shell (Cited in Manuscripts,
    /// Review Queue, a custom surface): the host decides what to show.
    case section(SidebarSectionType, RecordKindID?)
    /// A row whose MEANING only the host knows, named in the host's own route
    /// vocabulary.
    ///
    /// The five cases above are the chassis's closed vocabulary: they are the
    /// scopes any kind's records can be sliced by. imbib's sidebar proved they
    /// are not the whole sidebar. Half of its rows are neither a status, a
    /// folder of the kind's collection binding, nor a whole section:
    ///
    ///   * LIBRARIES — containers of publications that sit ABOVE the folder
    ///     tree (each library owns its own collections), so `.folder` is the
    ///     wrong word and the organise verbs must not attach to them;
    ///   * SAVED SEARCHES / FEEDS — a stored query, not a stored membership;
    ///   * REMOTE SHELVES (SciX libraries) — someone else's container, synced;
    ///   * SEARCH FORMS — not a record scope at all, but a UI route the
    ///     Search section offers (the row-level twin of `AuxiliaryRoute`).
    ///
    /// Enumerating those four here would be inventing imbib's taxonomy inside
    /// the chassis, and the next adopter's would differ again (mail accounts,
    /// agent runs, a plotting workspace). So the chassis declares the SHAPE —
    /// "this row selects something host-defined, of this kind, identified by
    /// this key" — and the host owns the key space. `scopeKey`/`stableViewID`
    /// already reduce every scope to a string for view identity, so this adds
    /// no new mechanism, only an honest name for the gap.
    ///
    /// Hosts should build these keys through ONE typed route enum on their
    /// side (imbib: `ImbibSidebarRoute`), never by spelling literals at call
    /// sites — that enum is what keeps the round trip (selection → row and
    /// notification → selection) single-sourced.
    case host(RecordKindID?, key: String)

    public var kind: RecordKindID? {
        switch self {
        case .all(let k), .status(let k, _), .folder(let k, _), .flagged(let k, _),
            .tag(let k, _):
            return k
        case .section(_, let k), .host(let k, _): return k
        }
    }

    /// The tag path this scope filters on, if it is a tag scope.
    public var tagPath: String? {
        if case .tag(_, let path) = self { return path }
        return nil
    }

    /// The host route key this scope carries, if it is a host row.
    public var hostKey: String? {
        if case .host(_, let key) = self { return key }
        return nil
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

// MARK: - Tag path matching

/// The ONE definition of "does this record satisfy that tag scope".
///
/// Every reader that filters by tag calls this — `FigureListWrapper`,
/// `MailStoreReader`, `AgentRecordListWrapper`, the manuscript and publication
/// lists — because a matching rule spelled per call site is a rule that can
/// disagree with itself, and this one has a subtlety worth not re-deriving:
/// the boundary is the SEPARATOR, not the character count. `reading` must match
/// `reading/queue` and must NOT match `reading-list`, so the prefix test has to
/// include the slash.
public enum TagPathMatch {

    /// Does one tag a record carries satisfy a `.tag(_, scopePath)` scope?
    public static func matches(recordTag: String, scopePath: String) -> Bool {
        recordTag == scopePath || recordTag.hasPrefix(scopePath + "/")
    }

    /// Does ANY of a record's tags satisfy the scope?
    public static func anyMatches(_ recordTags: [String], scopePath: String) -> Bool {
        recordTags.contains { matches(recordTag: $0, scopePath: scopePath) }
    }
}

extension RecordSidebarScope: RecordScopeKey {
    public var scopeKey: String {
        switch self {
        case .all(let k): return "\(k.rawValue).all"
        case .status(let k, let s): return "\(k.rawValue).status.\(s)"
        case .folder(let k, let id): return "\(k.rawValue).folder.\(id.uuidString.lowercased())"
        case .flagged(let k, let c): return "\(k.rawValue).flagged.\(c ?? "any")"
        case .tag(let k, let path): return "\(k.rawValue).tag.\(path)"
        case .section(let section, let k):
            return "section.\(section.rawValue).\(k?.rawValue ?? "none")"
        case .host(let k, let key):
            return "host.\(k?.rawValue ?? "none").\(key)"
        }
    }

    public var stableViewID: UUID { .deterministic(from: scopeKey) }
}

// MARK: - Status presentation

/// Label + icon for a raw `status` value, RESOLVED FROM THE DECLARATIONS.
///
/// This used to hold a private `[String: (label, systemImage)]` table — the
/// honest limitation the previous version of this comment admitted to:
/// `TriageCapabilities.statuses` was `[String]`, so a status declared no
/// presentation and the chassis kept one here, a folder away from the
/// declaration, while macOS's sidebar spelled four of the same labels a third
/// time as literals. `statuses` is now `[StatusSpec]`, so this is a LOOKUP
/// over the shipped descriptors rather than a second truth table.
///
/// The generic fallback stays and still matters: a status value that no
/// descriptor declares (a hand-edited row, a kind from a newer build, an
/// impel state read through the wrong lens) renders as a title-cased spelling
/// of the raw value with a neutral glyph — sanely, if generically, rather than
/// blank.
public enum RecordStatusPresentation {

    /// The spec for a raw value, searched across every shipped kind. The
    /// reserved lifecycle values (docs/status-lifecycle.md) are chassis-wide,
    /// so a caller holding only a string does not need to know the kind; a
    /// caller that DOES know it should prefer `triage.status(_:)`.
    public static func spec(for status: String) -> StatusSpec? {
        for descriptor in BuiltinRecordKinds.all {
            if let match = descriptor.triage.status(status) { return match }
        }
        return nil
    }

    public static func label(for status: String) -> String {
        if let declared = spec(for: status)?.label { return declared }
        return titleCased(status)
    }

    public static func systemImage(for status: String) -> String {
        spec(for: status)?.systemImage ?? "circle"
    }

    /// `"peer-review"` → `"Peer Review"`. The honest generic rendering of an
    /// undeclared status.
    static func titleCased(_ status: String) -> String {
        status
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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
    /// The kind's tag vocabulary, as a tree.
    ///
    /// Sibling of `.flagged` on purpose: both browse a mark the user put on the
    /// record rather than a property the record has. The difference is only
    /// that flags are a closed set the chassis knows and tags are an open one
    /// the store reports, which is why this role needs a data-source call and
    /// `.flagged` does not.
    case tags
    /// The kind's dismissed status.
    case dismissed
    /// One opaque selectable row (the host owns what it shows).
    case opaque

    /// The role a section plays. Declared BY the section
    /// (`SidebarSectionType.role`) rather than switched on here: a new section
    /// used to compile only after this switch grew an arm, which is the
    /// case-addition tax ADR-0022's follow-up register calls out. The property
    /// lives next to `displayName` and `icon`, so one place answers
    /// "what is this section" in all three respects.
    public static func role(for section: SidebarSectionType) -> RecordSidebarSectionRole {
        section.role
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

    /// Selecting the section HEADER selects this scope. nil = the header only
    /// collapses (the imprint case).
    ///
    /// macOS has had this since before ADR-0021: `resolveSelectedTab` maps the
    /// Inbox *section node* straight to `.inbox`, because "Inbox" names a real
    /// destination (the inbox library) and not just a group of rows, and
    /// imbib-iOS's hand-written sidebar copied it with an `.onTapGesture` on
    /// the header. The same is true of Flagged → any flag. Modelling it as a
    /// synthetic first row instead would have ADDED a row neither shell shows.
    public let headerScope: RecordSidebarScope?

    /// Whether the header offers "new root folder" (`folder.badge.plus`).
    ///
    /// Split from `canOrganizeFolders` by the second adopter: a kind whose
    /// folder tree has ONE root (imprint's manuscript collections) wants both,
    /// but imbib's collections are rooted PER LIBRARY, so "create at the root
    /// of the section" has no answer — the create verb belongs on the library
    /// row, which is host chrome. The section still organises its folders.
    public let offersRootFolderCreation: Bool

    public var id: String { section.rawValue }
    public var title: String { section.displayName }
    public var systemImage: String { section.icon }

    public init(
        section: SidebarSectionType,
        kind: RecordKindID?,
        role: RecordSidebarSectionRole,
        nodes: [RecordSidebarNode],
        canOrganizeFolders: Bool,
        headerScope: RecordSidebarScope? = nil,
        offersRootFolderCreation: Bool? = nil
    ) {
        self.section = section
        self.kind = kind
        self.role = role
        self.nodes = nodes
        self.canOrganizeFolders = canOrganizeFolders
        self.headerScope = headerScope
        self.offersRootFolderCreation = offersRootFolderCreation ?? canOrganizeFolders
    }
}

// MARK: - Groups

/// One app's sections, under that app's name — the rendered form of a
/// `SidebarAppGroup`.
///
/// `sections` may be EMPTY and the group is still returned: see the note on
/// `RecordSidebarBuilder.groups(composition:host:order:dataSource:)`.
public struct RecordSidebarGroupModel: Identifiable, Sendable {
    public let group: SidebarAppGroup
    public let sections: [RecordSidebarSectionModel]

    public var id: String { group.id }
    public var title: String { group.title }
    public var systemImage: String { group.systemImage }

    public init(group: SidebarAppGroup, sections: [RecordSidebarSectionModel]) {
        self.group = group
        self.sections = sections
    }

    /// The section serving `section` in THIS group, if it renders here.
    /// The per-group lookup tests and hosts reach for — the flat sidebar's
    /// `first { $0.section == x }` is ambiguous once two groups declare `x`.
    public func section(_ section: SidebarSectionType) -> RecordSidebarSectionModel? {
        sections.first { $0.section == section }
    }
}

public extension Array where Element == RecordSidebarGroupModel {
    subscript(groupID groupID: String) -> RecordSidebarGroupModel? {
        first { $0.id == groupID }
    }
}
