//
//  LitmusNoteRecordKind.swift
//  PublicationManagerCoreTests
//
//  THE CI LITMUS RECORD KIND.
//
//  ADR-0021 D4 claims that adding a record kind is ADDITIVE — that the
//  chassis's generic machinery (sidebar section building, routing, the viewer
//  registry, tab availability, the status lifecycle) serves a kind it has never
//  heard of, and that "editing an existing chassis `switch` for a new kind is a
//  review-blocking smell". Its litmus re-run walks an imagined
//  `audio-recording` kind through that path in PROSE.
//
//  Prose is not a gate. This file is the gate: a record kind that exists ONLY
//  in the test target, declared here in full, which `LitmusRecordKindTests`
//  drives through the generic machinery. If a future chassis change reintroduces
//  a per-kind `switch`, an exhaustive enum or a hardcoded registry lookup on any
//  of those paths, this kind stops working and CI says so — in the same `swift
//  test` run the PMC lane already performs.
//
//  Nothing in `Sources/PublicationManagerCore` knows this kind exists, and
//  `LitmusChassisPurityTests` is the structural half that keeps it that way.
//
//  WHAT THE MINIMAL REGISTRATION SET ACTUALLY IS
//  ---------------------------------------------
//  Verified against the code (not the ADR's prose) as of 2026-07-30. To be a
//  first-class record kind in the chassis, a kind owes exactly five things, all
//  of which live in THIS file:
//
//    1. A `RecordKindID`. String-backed, so this is a `static let`, not an enum
//       case (`RecordKindDescriptor.swift`).
//    2. A `RecordKindDescriptor` — pure DATA: schema refs, names, symbol, tab
//       specs + availability, `TriageCapabilities` (incl. the status lifecycle),
//       creation affordances, open behaviour, optional `CollectionCapability`.
//    3. A row struct conforming to `MailStyleItem` (ADR-0018 D3 keeps these
//       per-kind on purpose).
//    4. A list scope conforming to `RecordRouteScope` — the hinge between the
//       ONE generic `RecordRoute` and the kind's own parallel scope.
//    5. A `RecordViewerFactory` registered in a `RecordViewerRegistry`, plus a
//       thin wrapper view for it to build.
//
//  Plus, on the HOST side and not intrinsic to the kind: a `sectionBindings`
//  line in whatever shell preset wants to show it.
//
//  THE TWO WALLS (see LitmusRecordKindTests for the executable form)
//  ----------------------------------------------------------------
//  a) `SidebarSectionType` (Files/SidebarSectionOrderStore.swift:14) is a closed
//     `String`-backed enum whose raw values back persisted sidebar order and
//     collapse state. A kind that wants a section of its OWN name needs a case
//     there. ADR-0021 step 6 says this is deliberate and correct, and this file
//     agrees with it: the litmus kind binds an EXISTING section
//     (`.artifacts`, whose role is `.primary`) in its own test shell preset, and
//     the sidebar builds it entirely from the descriptor. The wall is over
//     naming, not over behaviour.
//  b) Two DISPLAY resolvers reach the global `BuiltinRecordKinds.registry`
//     rather than taking a registry parameter:
//     `RecordKindIconography.symbolName(for:)` and
//     `RecordStatusPresentation.spec(for:)`. A production kind closes this with
//     the one-line append to `BuiltinRecordKinds.all` that ADR-0021 step 3
//     already prescribes; a TEST-ONLY kind cannot, and must not, so those two
//     paths return their honest fallbacks for it. That is asserted rather than
//     worked around — see `testGlobalDisplayResolversFallBackHonestly`.
//

import Foundation
import SwiftUI
import ImpressFTUI
import ImpressMailStyle

@testable import PublicationManagerCore

// MARK: - 1. Identity

extension RecordKindID {
    /// The litmus kind. No chassis edit: `RecordKindID` is string-backed
    /// precisely so kinds are additive (ADR-0021 D3).
    static let litmusNote = RecordKindID("litmus-note")
}

// MARK: - 2. Descriptor

/// The whole chassis contract for the litmus kind, as DATA.
///
/// Deliberately exercises the AWKWARD corners rather than the easy path:
///  * a conditional detail tab (so tab availability + coercion are live),
///  * a status lifecycle with a terminal state, an archive state, a
///    `hiddenByDefault` dismissal state and a `freezesSource` state,
///  * a plural that is NOT `displayName + "s"` (the sidebar used to concatenate),
///  * a `CollectionCapability` on the GENERIC kernel binding with a non-default
///    container noun and folder glyph,
///  * a creation affordance (so the `n` key / empty-state path has something).
enum LitmusNoteRecordKind {
    static let descriptor = RecordKindDescriptor(
        id: .litmusNote,
        // A ref no Rust schema registers — this kind never touches a store.
        // Non-empty because `RecordKindDescriptor.init` traps otherwise, which
        // is itself part of the contract.
        schemaRefs: ["impress/litmus-note"],
        displayName: "Litmus Analysis",
        // NOT "Litmus Analysiss". The sidebar's "All <plural>" row used to be a
        // bare `+ "s"`; this is the kind that would have caught it.
        pluralDisplayName: "Litmus Analyses",
        symbolName: "testtube.2",
        detailTabs: [
            DetailTabSpec(.info),
            DetailTabSpec(.source),
            // Conditional, in the FigureRecordKind idiom: present only when the
            // host reports a rendered state.
            DetailTabSpec(.pdf, isAvailable: {
                ($0.previewKind ?? DocumentFormat.PreviewKind.none) != .none
            }),
        ],
        // A publication's text tab lands on this kind's text tab.
        fallbackTab: { tab, _ in tab == .bibtex ? .source : .info },
        triage: TriageCapabilities(
            canStar: true,
            canFlag: true,
            canTag: true,
            dismissal: .statusChange(dismissed: "dismissed", restoreTo: "open"),
            archiveStatus: "archived",
            deletion: .confirmHard,
            statuses: [
                StatusSpec("open", label: "Open", systemImage: "circle"),
                StatusSpec(
                    "running", label: "Running", systemImage: "hourglass"),
                StatusSpec(
                    "verified", label: "Verified", systemImage: "checkmark.seal",
                    isTerminal: true, freezesSource: true),
                StatusSpec(
                    "archived", label: "Archive", systemImage: "archivebox",
                    isTerminal: true, freezesSource: true),
                // Owns the Dismissed SECTION, so it is not also a smart child.
                StatusSpec(
                    "dismissed", label: "Dismissed", systemImage: "xmark.circle",
                    isTerminal: true, hiddenByDefault: true),
            ]),
        creation: [CreationAffordance(label: "New Litmus Analysis")],
        defaultOpenBehavior: .detailPane,
        collection: CollectionCapability(
            bindingID: CollectionBindingID.generic,
            canOrganize: true,
            dragUTTypeIdentifier: "com.impress.litmus-note-id",
            folderSymbolName: "tray.2",
            containerNoun: "Batch")
    )
}

// MARK: - 3. Row struct

/// The per-kind row snapshot (ADR-0018 D3 / ADR-0021 D2 keep these per kind).
struct LitmusNoteRowData: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let status: String
    let summary: String?
    let dateModified: Date
    let starred: Bool
    let flagColor: FlagColor?
    let tagPaths: [String]

    init(
        id: UUID = UUID(),
        title: String,
        status: String = "open",
        summary: String? = nil,
        dateModified: Date = Date(timeIntervalSince1970: 1_700_000_000),
        starred: Bool = false,
        flagColor: FlagColor? = nil,
        tagPaths: [String] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.dateModified = dateModified
        self.starred = starred
        self.flagColor = flagColor
        self.tagPaths = tagPaths
    }
}

extension LitmusNoteRowData: MailStyleItem {
    /// Resolved through the kind's OWN declaration, never the global table —
    /// which is the discipline `TriageCapabilities.status(_:)` exists to
    /// support (see wall (b) in the file header).
    var headerText: String {
        LitmusNoteRecordKind.descriptor.triage.status(status)?.label
            ?? RecordStatusPresentation.titleCased(status)
    }
    var titleText: String { title }
    var date: Date { dateModified }
    var isRead: Bool { true }
    var isStarred: Bool { starred }
    var previewText: String? { summary }
    var flag: PublicationFlag? { flagColor.map { PublicationFlag(color: $0) } }
    var tagDisplays: [TagDisplayData] {
        tagPaths.map { path in
            TagDisplayData(
                id: UUID(),
                path: path,
                leaf: path.components(separatedBy: "/").last ?? path)
        }
    }
}

extension KindTaggedRow {
    /// The mixed-kind projection, in the `KindTaggedRow+RowData.swift` idiom.
    @MainActor
    init(litmusNote row: LitmusNoteRowData) {
        self.init(
            id: row.id,
            kind: .litmusNote,
            headerText: row.headerText,
            titleText: row.titleText,
            previewText: row.previewText,
            date: row.date,
            isRead: row.isRead,
            isStarred: row.isStarred,
            flag: row.flag,
            tagDisplays: row.tagDisplays)
    }
}

// MARK: - 4. List scope + RecordRouteScope

/// What subset of litmus notes the list shows — the kind's own PARALLEL scope
/// (ADR-0021 D2), not a chassis type.
enum LitmusNoteListScope: Hashable, Sendable {
    case all
    case status(String)
    case folder(UUID)
    case flagged(FlagColor?)
    /// A subset the chassis vocabulary has no word for, riding
    /// `RecordSidebarScope.host` — the declared escape hatch, with the key
    /// spelled ONCE (the `FigureListScope.unfiled` precedent).
    case unreviewed
}

extension LitmusNoteListScope: RecordScopeKey {
    var scopeKey: String {
        switch self {
        case .all: return "litmus-notes-all"
        case .status(let raw): return "litmus-notes-status-\(raw)"
        case .folder(let id): return "litmus-notes-folder-\(id.uuidString)"
        case .flagged(let color): return "litmus-notes-flagged-\(color?.rawValue ?? "any")"
        case .unreviewed: return "litmus-notes-unreviewed"
        }
    }

    var stableViewID: UUID { UUID.deterministic(from: scopeKey) }
}

extension LitmusNoteListScope {
    /// Chassis spelling of the "Unreviewed" row. Single-sourced here so no call
    /// site spells the host key.
    static let unreviewedRouteScope = RecordSidebarScope.host(
        .litmusNote, key: "litmus-notes.unreviewed")
}

extension LitmusNoteListScope: RecordRouteScope {
    init?(routeScope: RecordSidebarScope) {
        switch routeScope {
        case .all(.litmusNote):
            self = .all
        case Self.unreviewedRouteScope:
            self = .unreviewed
        case .status(.litmusNote, let raw):
            // The sidebar only builds these from declared StatusSpecs, so an
            // undeclared value is an honest nil (empty state), never a silent
            // `.all` — the ManuscriptListScope rule.
            guard LitmusNoteRecordKind.descriptor.triage.status(raw) != nil else { return nil }
            self = .status(raw)
        case .folder(.litmusNote, let id):
            self = .folder(id)
        case .flagged(.litmusNote, let raw):
            self = .flagged(raw.flatMap { FlagColor(rawValue: $0) })
        default:
            return nil
        }
    }
}

// MARK: - 5. Thin wrapper + viewer factory

/// The kind's list|detail section — the per-kind view code ADR-0018 D3
/// deliberately keeps. Thin on purpose: the shared `MailStyleRow` chrome drops
/// in with no adaptation, which is half of what the litmus is measuring.
struct LitmusNoteSectionView: View {
    let scope: LitmusNoteListScope
    let rows: [LitmusNoteRowData]

    init(scope: LitmusNoteListScope, rows: [LitmusNoteRowData] = []) {
        self.scope = scope
        self.rows = rows
    }

    var body: some View {
        HStack(spacing: 0) {
            List(rows) { row in
                MailStyleRow(item: row)
            }
            .frame(minWidth: 200)
            Text(scope.scopeKey)
                .frame(minWidth: 200)
        }
    }
}

extension RecordViewerFactory {
    /// The one registration line ADR-0021 step 5 says a new kind owes.
    static let litmusNote = RecordViewerFactory(
        kind: .litmusNote,
        makeSectionView: { context in
            guard let scope = context.scope(as: LitmusNoteListScope.self) else {
                return AnyView(ChassisEmptyState.viewerUnavailable(kind: .litmusNote).view)
            }
            return AnyView(LitmusNoteSectionView(scope: scope).id(scope))
        })
}

// MARK: - Host side: a test shell preset

extension AppShellConfiguration {

    /// A shell that shows the litmus kind, built the way a real adopter would.
    ///
    /// `.artifacts` is reused as the litmus kind's primary section because
    /// `SidebarSectionType` is a closed enum whose raw values back persisted
    /// sidebar state — wall (a) in this file's header, and the one cost
    /// ADR-0021 step 6 says should stay hand-written. Everything the section
    /// CONTAINS still comes from the descriptor, which is the claim under test.
    ///
    /// `visibleSections` is explicit (`nil` is retired suite-wide except for
    /// test shells, and being explicit is the better example anyway).
    static let litmusTestShell = AppShellConfiguration(
        appID: "litmus-test-shell",
        visibleSections: [.artifacts, .flagged, .dismissed],
        defaultSection: .artifacts,
        defaultDetailTab: .info,
        recordKinds: RecordKindRegistry(
            BuiltinRecordKinds.all + [LitmusNoteRecordKind.descriptor]),
        sectionBindings: [
            .artifacts: .litmusNote,
            .flagged: .litmusNote,
            .dismissed: .litmusNote,
        ],
        auxiliaryRoutes: [],
        openOverrides: [:])

    /// The same shell, minus the litmus kind's viewer — used to assert the
    /// unregistered-kind fallback is clean rather than blank.
    static let litmusTestShellWithoutTheKind = AppShellConfiguration(
        appID: "litmus-test-shell-bare",
        visibleSections: [.artifacts],
        defaultSection: .artifacts,
        defaultDetailTab: .info,
        recordKinds: BuiltinRecordKinds.registry,
        sectionBindings: [.artifacts: .litmusNote])
}
