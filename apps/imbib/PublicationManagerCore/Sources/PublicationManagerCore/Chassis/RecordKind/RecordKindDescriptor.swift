// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS).
//
// De-gated in the iOS foundation pass: this file is pure DATA (structs,
// enums, closures) and imports only SwiftUI. Its `#if os(macOS)` was a
// GUI-meld Phase-1 artefact, not a technical constraint — and keeping the
// contract macOS-only forced iOS to re-declare status strings, triage rules
// and open behaviour as literals. Declarative fixes have to be reachable
// from every platform or they are not declarative.
//
// Platform-specific VIEW code that consumes these descriptors stays gated
// (see StoreSearchSurface, the per-kind list wrappers, TriageNewTagPrompt).
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

/// One status value in a kind's lifecycle, WITH its presentation.
///
/// `statuses` used to be `[String]`, which declared *which* statuses a kind
/// has but not how to name or picture them — so the chassis carried a private
/// label/icon table (`RecordStatusPresentation.known`) that lived a folder
/// away from the declaration, and macOS's sidebar spelled the same four
/// labels a third time as literals. Presentation now travels WITH the
/// declaration: one place to add a status, one place to read it.
///
/// Deliberately NOT here: whether a status is the DISMISSAL or the ARCHIVE
/// status. `DismissalSemantics.statusChange(dismissed:restoreTo:)` and
/// `archiveStatus` already say that, and a second spelling of the same fact is
/// how the two drift apart. `RecordKindStatusSpecTests` cross-checks them
/// instead.
public struct StatusSpec: Sendable, Equatable, Hashable, Identifiable {
    /// The payload `status` value, exactly as the store holds it.
    public let rawValue: String
    /// Sidebar row / badge text.
    public let label: String
    /// SF Symbol for the sidebar row.
    public let systemImage: String
    /// A lifecycle END state — nothing leaves it without an explicit user
    /// verb. Drives `JournalManuscriptStatus.isActive`.
    public let isTerminal: Bool
    /// Not offered as a primary-section smart child. The dismissal status
    /// sets this: it owns the Dismissed SECTION, and listing it in both
    /// places would give the same rows two homes.
    public let hiddenByDefault: Bool
    /// Entering this status FREEZES the source record — a durable snapshot of
    /// the body is written and the status becomes a citable point in the
    /// record's history (ADR-0011 D5).
    ///
    /// Declared here because it is not derivable from any other facet, and the
    /// only two candidates are both wrong: `isTerminal` includes the dismissal
    /// status (dismissing is a user saying "not this one" — freezing a
    /// revision of rejected work, which outlives the restorable dismissal) and
    /// excludes `submitted`, which is deliberately non-terminal and is the
    /// PRIMARY freeze trigger. impel's `JournalPipeline.autoSnapshotStatuses`
    /// carried that set as a hand-written literal for exactly that reason;
    /// `JournalStatusPolicyParityTests` is the interlock, and this facet is
    /// what lets it check the literal against a DECLARATION instead of a
    /// second hand-written list.
    ///
    /// Defaulted `false`: a status that says nothing freezes nothing, so every
    /// existing declaration site is unchanged.
    public let freezesSource: Bool

    public var id: String { rawValue }

    public init(
        _ rawValue: String,
        label: String,
        systemImage: String,
        isTerminal: Bool = false,
        hiddenByDefault: Bool = false,
        freezesSource: Bool = false
    ) {
        self.rawValue = rawValue
        self.label = label
        self.systemImage = systemImage
        self.isTerminal = isTerminal
        self.hiddenByDefault = hiddenByDefault
        self.freezesSource = freezesSource
    }
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
    /// Status values this kind's lifecycle uses, with their presentation
    /// (parity-checked vs schema).
    public var statuses: [StatusSpec]

    public init(
        canStar: Bool = true,
        canFlag: Bool = true,
        canTag: Bool = true,
        dismissal: DismissalSemantics = .none,
        archiveStatus: String? = nil,
        deletion: DeletionSemantics = .none,
        statuses: [StatusSpec] = []
    ) {
        self.canStar = canStar
        self.canFlag = canFlag
        self.canTag = canTag
        self.dismissal = dismissal
        self.archiveStatus = archiveStatus
        self.deletion = deletion
        self.statuses = statuses
    }

    /// The raw `status` values, for store predicates and validation gates.
    public var statusValues: [String] { statuses.map(\.rawValue) }

    /// The raw values of the statuses that FREEZE the source record
    /// (`StatusSpec.freezesSource`) — the declared form of what impel's
    /// journal pipeline calls its auto-snapshot set. A `Set` because every
    /// consumer asks "is this status in it", never "what order are they in".
    public var freezingStatusValues: Set<String> {
        Set(statuses.filter(\.freezesSource).map(\.rawValue))
    }

    /// The spec for a raw status value, if this kind declares it.
    public func status(_ rawValue: String) -> StatusSpec? {
        statuses.first { $0.rawValue == rawValue }
    }

    /// The dismissal status value, when dismissal is a status change.
    public var dismissedStatus: String? {
        if case .statusChange(let dismissed, _) = dismissal { return dismissed }
        return nil
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

/// When a kind's containers offer the organise verbs (ADR-0022 C2, axis 2).
///
/// `canOrganize` answers "does this KIND organise at all"; this answers "does
/// THIS ROW", which is a different question the moment a kind has smart
/// (query-defined) containers. imbib is that kind: a smart publication
/// collection is defined by its query, so renaming it or nesting a manual
/// collection under it is meaningless, and its menu has only Delete.
///
/// The predicate is sourced from the KERNEL row (`CollectionKernelRow.isSmart`,
/// which is `collection_ops`' `smart_field` axis), never from a second Swift
/// read of a legacy row shape — that second read is what kept publication
/// collections off the generic path.
public enum CollectionOrganizePolicy: String, Sendable, Equatable {
    /// Every row offers rename / new sub-container / delete. Manuscript and
    /// figure folders: their schemas have no smart rows to exclude.
    case always
    /// Smart rows offer Delete ONLY; manual rows offer everything.
    case unlessSmart
}

/// A kind whose containers live INSIDE another container (ADR-0022 C2, axis 1).
///
/// imbib publication collections are per-LIBRARY: a collection node carries
/// (collectionID, libraryID), drop acceptance requires the same library, a
/// cross-library move is one `reparent_in` with a container argument, and
/// creation names the library up front. Manuscript and figure folders are
/// global and leave `container` nil, which is what makes every container-aware
/// site below a no-op for them.
public struct CollectionContainerSpec: Sendable, Equatable {
    /// What the kind calls its containers ("Library"), for menus and logs.
    public let noun: String
    /// Whether a drag may cross containers. imbib allows it (a collection can
    /// move between libraries, which is the two-write path the kernel now does
    /// atomically); a kind that said `false` would reject the drop outright.
    public let allowsCrossContainerMoves: Bool

    public init(noun: String, allowsCrossContainerMoves: Bool = true) {
        self.noun = noun
        self.allowsCrossContainerMoves = allowsCrossContainerMoves
    }
}

/// One TIER of a kind's containers (ADR-0022 C2, axis 4).
///
/// A tier is `(binding, container)` plus the presentation that container's
/// section gives it — same schema, same kernel binding, different owning
/// container and different affordances. imbib has three: the per-library
/// collections under Libraries, the Inbox library's collections, and the
/// Exploration library's collections.
///
/// Declared as DATA rather than discovered from node cases because the
/// differences are a short, closed list, and writing them down is what turns
/// three near-copy sidebar blocks into one table. `CollectionTierTests` pins
/// this table against the frozen matrix rows, so a tier cannot drift from the
/// behaviour it claims.
public struct CollectionTier: Sendable, Equatable, Identifiable {
    /// Stable tier key ("libraries", "inbox", "exploration").
    public let id: String
    /// May a row in this tier be renamed? Exploration collections cannot —
    /// they are named by the search that produced them.
    public let allowsRename: Bool
    /// May a row in this tier host sub-collections?
    public let allowsSubcontainers: Bool

    public init(id: String, allowsRename: Bool, allowsSubcontainers: Bool) {
        self.id = id
        self.allowsRename = allowsRename
        self.allowsSubcontainers = allowsSubcontainers
    }
}

/// The tier ids imbib's publication collections form. Named constants rather
/// than bare strings so the sidebar and the tier table cannot disagree by typo.
public enum CollectionTierID {
    /// Collections under a user library (the `libraryCollection` node).
    public static let libraries = "libraries"
    /// Collections of the Inbox library (the `inboxCollection` node).
    public static let inbox = "inbox"
    /// Collections of the Exploration library (the `explorationCollection`
    /// node) — Delete only, and selecting one sets
    /// `ExplorationService.currentExplorationCollectionID`.
    public static let exploration = "exploration"
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
    /// SF Symbol for this kind's folder rows. Declared rather than hardcoded
    /// in the sidebar builder so a kind whose containers are not "folders"
    /// (mail's server-mirrored mailboxes, a future smart collection) can say
    /// so without the builder growing a `switch`.
    public let folderSymbolName: String
    /// What this kind calls its containers, singular and capitalised. Drives
    /// the organise MENU TITLES ("New \(noun)", "New Sub\(noun)",
    /// "Delete \(noun)") which were three inline literals in
    /// `ImbibSidebarViewModel`'s AppKit menu builders. `mail-folder` rows are
    /// mailboxes, not folders, and that is the kind of thing a capability
    /// should be able to say without an app-side `if`.
    public let containerNoun: String
    /// When THIS ROW offers the organise verbs (ADR-0022 C2, axis 2).
    /// `.always` for every kind whose schema has no smart containers.
    public let organizePolicy: CollectionOrganizePolicy
    /// The OWNING CONTAINER this kind's collections live in (ADR-0022 C2,
    /// axis 1), or nil for a kind whose containers are global.
    public let container: CollectionContainerSpec?
    /// The TIERS this kind's containers form (ADR-0022 C2, axis 4). Empty for a
    /// kind with a single undifferentiated tree.
    public let tiers: [CollectionTier]
    /// Overrides the derived "Delete \(containerNoun)" menu title.
    ///
    /// Exists because imbib's frozen publication-collection menu says plain
    /// **"Delete"**, not "Delete Collection", and the whole point of routing
    /// that menu through the generic builder is that the labels do not change.
    /// A derivation that is wrong in the one place it is adopted has not
    /// earned its keep.
    public let deleteTitleOverride: String?

    public init(
        bindingID: String,
        canOrganize: Bool = true,
        dragUTTypeIdentifier: String? = nil,
        folderSymbolName: String = "folder",
        containerNoun: String = "Folder",
        organizePolicy: CollectionOrganizePolicy = .always,
        container: CollectionContainerSpec? = nil,
        tiers: [CollectionTier] = [],
        deleteTitleOverride: String? = nil
    ) {
        self.bindingID = bindingID
        self.canOrganize = canOrganize
        self.dragUTTypeIdentifier = dragUTTypeIdentifier
        self.folderSymbolName = folderSymbolName
        self.containerNoun = containerNoun
        self.organizePolicy = organizePolicy
        self.container = container
        self.tiers = tiers
        self.deleteTitleOverride = deleteTitleOverride
    }

    /// Menu title for creating a container at root ("New Folder").
    public var newContainerTitle: String { "New \(containerNoun)" }
    /// Menu title for creating a nested container ("New Subfolder").
    public var newSubContainerTitle: String { "New Sub\(containerNoun.lowercased())" }
    /// Menu title for deleting a container ("Delete Folder", or the override).
    public var deleteContainerTitle: String {
        deleteTitleOverride ?? "Delete \(containerNoun)"
    }

    /// The tier with this id, if declared.
    public func tier(_ id: String) -> CollectionTier? {
        tiers.first { $0.id == id }
    }

    /// Whether a row offers rename / new sub-container, given what the KERNEL
    /// says about it. The ONE place the per-row predicate is evaluated, so no
    /// caller can forget the smart case.
    ///
    /// - Parameters:
    ///   - isSmart: `CollectionKernelRow.isSmart` — the payload-sourced flag,
    ///     from `collection_ops`' `smart_field` axis.
    ///   - tier: the tier the row sits in, when the kind declares tiers. A tier
    ///     that permits neither rename nor sub-containers (Exploration) wins
    ///     over an otherwise-organisable row.
    public func allowsOrganize(isSmart: Bool, tier: CollectionTier? = nil) -> Bool {
        guard canOrganize else { return false }
        if let tier, !tier.allowsRename, !tier.allowsSubcontainers { return false }
        switch organizePolicy {
        case .always: return true
        case .unlessSmart: return !isSmart
        }
    }
}

/// A lifecycle a kind owns in a payload field OTHER than `status`, which the
/// chassis may READ but must never write.
///
/// impel's tasks are the case that forced this to be declared rather than
/// hardcoded. Their states (`queued`, `running`, `waiting_review`, …) live in
/// payload `state`, and `TaskStoreApi.transition` is the sole legal mutation
/// (ADR-0015 D1) — so they cannot go in `TriageCapabilities.statuses`, whose
/// whole contract is "values the chassis's generic status writer may set".
/// Declaring them separately keeps that distinction honest while still moving
/// their labels and icons out of `AgentStoreReader`'s `switch`.
public struct RecordLifecycleSpec: Sendable, Equatable {
    /// The payload field holding the state (`"state"` for impel's kernel).
    public let payloadField: String
    /// The states, in canonical pipeline order.
    public let states: [StatusSpec]
    /// `true` = a kernel service owns every transition; the chassis renders
    /// these and offers no verb that writes them.
    public let isKernelOwned: Bool

    public init(payloadField: String, states: [StatusSpec], isKernelOwned: Bool = true) {
        self.payloadField = payloadField
        self.states = states
        self.isKernelOwned = isKernelOwned
    }

    public var stateValues: [String] { states.map(\.rawValue) }

    public func state(_ rawValue: String) -> StatusSpec? {
        states.first { $0.rawValue == rawValue }
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
    /// Plural of `displayName`, for "All Publications"-style rows. Declared
    /// because English pluralization is not `displayName + "s"` in general
    /// ("Analysis", "Entry", "Series"), and the sidebar builder used to do
    /// exactly that concatenation — a latent wrong label for the first kind
    /// whose name does not take a bare `s`.
    public let pluralDisplayName: String
    /// SF Symbol for records of this kind. Lives on the descriptor so
    /// mixed-kind surfaces (grouped search, Related items) resolve an icon
    /// from the DECLARATION instead of a central `switch` that has to be
    /// edited for every new kind — the one edit ADR-0021's litmus called out
    /// as the last per-kind chassis change.
    public let symbolName: String
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
    /// A kernel-owned lifecycle in a payload field other than `status`
    /// (impel's tasks). Nil for every kind whose lifecycle is `status`, or
    /// which has none.
    public let lifecycle: RecordLifecycleSpec?

    public init(
        id: RecordKindID,
        schemaRefs: [String],
        displayName: String,
        pluralDisplayName: String? = nil,
        symbolName: String = RecordKindDescriptor.unknownSymbolName,
        detailTabs: [DetailTabSpec],
        fallbackTab: @escaping @Sendable (DetailTab, RecordTabContext) -> DetailTab = { _, _ in .info },
        triage: TriageCapabilities,
        creation: [CreationAffordance] = [],
        defaultOpenBehavior: OpenBehavior = .detailPane,
        collection: CollectionCapability? = nil,
        lifecycle: RecordLifecycleSpec? = nil
    ) {
        // A kind with no schema ref resolves for zero rows, forever, silently
        // — the exact failure mode schema-refs.json exists to prevent. Trap at
        // construction (descriptors are compile-time constants, so this fires
        // on the first launch after the mistake, not in a user's store).
        precondition(
            !schemaRefs.isEmpty,
            "RecordKindDescriptor '\(id.rawValue)' declares no schemaRefs")
        self.id = id
        self.schemaRefs = schemaRefs
        self.displayName = displayName
        self.pluralDisplayName = pluralDisplayName ?? "\(displayName)s"
        self.symbolName = symbolName
        self.detailTabs = detailTabs
        self.fallbackTab = fallbackTab
        self.triage = triage
        self.creation = creation
        self.defaultOpenBehavior = defaultOpenBehavior
        self.collection = collection
        self.lifecycle = lifecycle
    }

    /// The ref this kind's own readers query. Non-optional by construction
    /// (`schemaRefs` is asserted non-empty), so a reader does not need a
    /// `?? "literal"` fallback that re-states the ref the descriptor already
    /// declares — which is how a reader and its writer drift apart.
    ///
    /// Kinds that span SEVERAL refs (a message is `email-message` OR
    /// `chat-message`) must iterate `schemaRefs` instead; this is the
    /// single-ref convenience, not a claim that one ref is enough.
    public var primarySchemaRef: String { schemaRefs[0] }

    /// Shown for a schema no descriptor claims — honest about not knowing,
    /// rather than mislabelling the row as some other kind. Also the default
    /// for a descriptor that forgets to declare one.
    public static let unknownSymbolName = "questionmark.square.dashed"

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
