#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  RecordKindDescriptor.swift
//  PublicationManagerCore
//
//  Stage 1 of the GUI unification (ADR-0021): the chassis contract — tabs,
//  triage capabilities, creation, open behavior — declared as DATA per record
//  kind, so adding a kind is additive (a new descriptor + row struct + thin
//  wrapper) instead of editing switches across the chassis.
//
//  Deliberate boundaries (ADR-0018 D3 still governs):
//  - Per-kind row structs and list wrappers STAY; descriptors describe the
//    contract around them, they are not a runtime rendering engine.
//  - Descriptors are pure data + factory closures. This folder must not
//    import store types, so a future ImpressChassis package lift is a folder
//    move.
//  - Registration is compile-time (arrays in shell presets). Exhaustiveness
//    is enforced by RecordKindParityTests + the capability matrix, not the
//    compiler — the trade accepted in the Stage-1 plan.

import SwiftUI

/// Identity of a record kind. String-backed so kinds are additive; the known
/// kinds get statics for call-site clarity.
public struct RecordKindID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let publication = RecordKindID("publication")
    public static let manuscript = RecordKindID("manuscript")
    public static let artifact = RecordKindID("artifact")
    public static let figure = RecordKindID("figure")
    public static let message = RecordKindID("message")
    public static let task = RecordKindID("task")
    public static let agentRun = RecordKindID("agent-run")
}

/// Everything the detail-tab host needs to know about the selected record to
/// resolve tab availability (kept tiny on purpose).
public struct RecordTabContext: Sendable, Equatable {
    /// Publications: whether Notes is editable. nil when not applicable.
    public var isEditable: Bool?
    /// Manuscripts: how the non-source pane renders. nil when not applicable.
    public var previewKind: DocumentFormat.PreviewKind?

    public init(isEditable: Bool? = nil, previewKind: DocumentFormat.PreviewKind? = nil) {
        self.isEditable = isEditable
        self.previewKind = previewKind
    }
}

/// One detail tab plus its availability rule.
public struct DetailTabSpec: Sendable {
    public let tab: DetailTab
    public let isAvailable: @Sendable (RecordTabContext) -> Bool

    public init(_ tab: DetailTab, isAvailable: @escaping @Sendable (RecordTabContext) -> Bool = { _ in true }) {
        self.tab = tab
        self.isAvailable = isAvailable
    }
}

/// How dismissal behaves for a kind. imbib publications move to the Dismissed
/// LIBRARY (the filter_dismissed invariant); store-native kinds flip the
/// reserved `dismissed` status (docs/status-lifecycle.md).
public enum DismissalSemantics: Sendable, Equatable {
    case statusChange(dismissed: String, restoreTo: String)
    case libraryMove
    case none
}

/// How deletion behaves for a kind.
public enum DeletionSemantics: Sendable, Equatable {
    /// Confirmation alert, then hard delete (undoable); any live editor
    /// session must be discarded first (host-owned).
    case confirmHard
    /// Soft: delete = move to Dismissed; hard delete only from Dismissed.
    case softToDismissed
    case none
}

/// Triage surface of a record kind — drives keyboard grammar gating, swipe
/// builders, and menu builders.
public struct TriageCapabilities: Sendable, Equatable {
    public var canStar: Bool
    public var canFlag: Bool
    public var canTag: Bool
    public var dismissal: DismissalSemantics
    /// Status value for Archive, or nil when the kind has no archive.
    public var archiveStatus: String?
    public var deletion: DeletionSemantics
    /// Status values this kind's lifecycle uses (parity-checked vs schema).
    public var statuses: [String]

    public init(
        canStar: Bool = true,
        canFlag: Bool = true,
        canTag: Bool = true,
        dismissal: DismissalSemantics = .none,
        archiveStatus: String? = nil,
        deletion: DeletionSemantics = .none,
        statuses: [String] = []
    ) {
        self.canStar = canStar
        self.canFlag = canFlag
        self.canTag = canTag
        self.dismissal = dismissal
        self.archiveStatus = archiveStatus
        self.deletion = deletion
        self.statuses = statuses
    }
}

/// The collection-kernel bindings (ADR-0022 D1/D2), as plain strings.
///
/// Descriptors must not import store types (they are `Sendable` DATA — see
/// the file header and ADR-0021 D3), so the binding travels as an id and
/// `CollectionStoreAdapter` is the only place that maps it onto
/// `SharedCollectionBinding`. The raw values match the Rust enum variants.
public enum CollectionBindingID {
    /// imbib publication collections (`imbib/collection`).
    public static let publication = "publication"
    /// imprint manuscript folders (`manuscript-collection`).
    public static let manuscript = "manuscript"
    /// implore figure folders (`figure-collection`) — ENVELOPE nesting.
    public static let figure = "figure"
    /// The generic `collection@1.0.0` kernel schema.
    public static let generic = "generic"

    /// Every binding, in the Rust enum's declaration order.
    public static let all: [String] = [publication, manuscript, figure, generic]
}

/// How a record kind's sidebar folders behave (ADR-0022 D3).
///
/// This is the data that collapsed the per-kind folder blocks in
/// `ImbibSidebarViewModel` into one capability-driven implementation:
/// which kernel binding organises the kind, whether the sidebar exposes the
/// organise verbs at all, and which pasteboard type its list rows drag.
/// Kinds with no folder tree leave `collection` nil.
public struct CollectionCapability: Sendable, Equatable {
    /// Kernel binding id — one of `CollectionBindingID`.
    public let bindingID: String
    /// Whether the sidebar offers create / rename / reparent / reorder /
    /// delete for this kind's folders. `false` = read-only folder rows.
    public let canOrganize: Bool
    /// UTType identifier of the kind's list-row drag payload, or nil when
    /// records of this kind cannot be dropped into a folder.
    public let dragUTTypeIdentifier: String?

    public init(
        bindingID: String,
        canOrganize: Bool = true,
        dragUTTypeIdentifier: String? = nil
    ) {
        self.bindingID = bindingID
        self.canOrganize = canOrganize
        self.dragUTTypeIdentifier = dragUTTypeIdentifier
    }
}

/// A way to create a record of this kind (drives the `n` key and the
/// empty-state / File menus). `formatValue` is the payload `format` for kinds
/// that have one (manuscripts).
public struct CreationAffordance: Sendable, Identifiable, Equatable {
    public var id: String { label }
    public let label: String
    public let formatValue: String?

    public init(label: String, formatValue: String? = nil) {
        self.label = label
        self.formatValue = formatValue
    }
}

/// What "open" means for a record of this kind (double-click, `o`, context
/// menu). Shell presets override per app via `AppShellConfiguration`.
public enum OpenBehavior: Sendable, Equatable {
    /// Selection already shows it — no separate open surface.
    case detailPane
    /// Open an in-process window (SwiftUI WindowGroup id, value = record UUID).
    case window(id: String)
    /// Hand off to a sibling app (imbib → imprint).
    case appHandoff
}

/// The Stage-1 contract for one record kind.
public struct RecordKindDescriptor: Identifiable, Sendable {
    public let id: RecordKindID
    /// Store schema refs this kind covers (parity-checked against the Rust
    /// schema registry).
    public let schemaRefs: [String]
    public let displayName: String
    public let detailTabs: [DetailTabSpec]
    /// Today's text-tab coercion (source ↔ bibtex) generalized: where a
    /// persisted-but-unavailable tab should land.
    public let fallbackTab: @Sendable (DetailTab, RecordTabContext) -> DetailTab
    public let triage: TriageCapabilities
    public let creation: [CreationAffordance]
    /// Default open behavior; shells override via `openOverrides`.
    public let defaultOpenBehavior: OpenBehavior
    /// Sidebar folder behavior (ADR-0022 D3). Nil for kinds with no folder
    /// tree — message/task/agent-run/artifact folders are later work packages.
    public let collection: CollectionCapability?

    public init(
        id: RecordKindID,
        schemaRefs: [String],
        displayName: String,
        detailTabs: [DetailTabSpec],
        fallbackTab: @escaping @Sendable (DetailTab, RecordTabContext) -> DetailTab = { _, _ in .info },
        triage: TriageCapabilities,
        creation: [CreationAffordance] = [],
        defaultOpenBehavior: OpenBehavior = .detailPane,
        collection: CollectionCapability? = nil
    ) {
        self.id = id
        self.schemaRefs = schemaRefs
        self.displayName = displayName
        self.detailTabs = detailTabs
        self.fallbackTab = fallbackTab
        self.triage = triage
        self.creation = creation
        self.defaultOpenBehavior = defaultOpenBehavior
        self.collection = collection
    }

    /// Tabs available for a given record context, in display order.
    public func availableTabs(for context: RecordTabContext) -> [DetailTab] {
        detailTabs.filter { $0.isAvailable(context) }.map(\.tab)
    }

    /// Coerce a (possibly persisted) tab to one valid for `context`.
    public func coercedTab(_ tab: DetailTab, for context: RecordTabContext) -> DetailTab {
        let valid = availableTabs(for: context)
        if valid.contains(tab) { return tab }
        let fallback = fallbackTab(tab, context)
        return valid.contains(fallback) ? fallback : (valid.first ?? .info)
    }
}

/// Compile-time registry: the record kinds one app shell knows about.
public struct RecordKindRegistry: Sendable {
    public let descriptors: [RecordKindDescriptor]
    private let byID: [RecordKindID: RecordKindDescriptor]

    public init(_ descriptors: [RecordKindDescriptor]) {
        self.descriptors = descriptors
        self.byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    public subscript(id: RecordKindID) -> RecordKindDescriptor? { byID[id] }

    /// Descriptor owning a store schema ref, if any.
    public func descriptor(forSchemaRef schemaRef: String) -> RecordKindDescriptor? {
        descriptors.first { $0.schemaRefs.contains(schemaRef) }
    }

    /// Descriptor whose collection capability uses `bindingID`, if any.
    public func descriptor(forCollectionBinding bindingID: String) -> RecordKindDescriptor? {
        descriptors.first { $0.collection?.bindingID == bindingID }
    }
}
#endif
