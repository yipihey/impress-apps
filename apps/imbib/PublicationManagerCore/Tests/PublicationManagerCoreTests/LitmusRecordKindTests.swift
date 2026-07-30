//
//  LitmusRecordKindTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0021's "adding a record kind = zero chassis edits" claim, as a TEST.
//
//  The kind under test (`litmus-note`, declared in full in
//  `LitmusNoteRecordKind.swift`) exists only in this target. No production or
//  chassis source file mentions it, and `LitmusChassisPurityTests` below is the
//  structural half that enforces that. So every assertion here is necessarily
//  about GENERIC machinery: if any of it passes, it passed for a kind the
//  chassis has never been taught.
//
//  Read the two suites together. The behavioural one proves the machinery is
//  generic TODAY; the structural one proves it stays that way, because a future
//  change that "fixes" a failure here by adding a `litmus` special case would
//  make the whole exercise circular.
//

import SwiftUI
import XCTest

@testable import PublicationManagerCore

// MARK: - Behavioural

@MainActor
final class LitmusRecordKindTests: XCTestCase {

    private var descriptor: RecordKindDescriptor { LitmusNoteRecordKind.descriptor }
    private var triage: TriageCapabilities { descriptor.triage }

    // MARK: - Registration resolves at all

    /// The registry is a value over the descriptors it is HANDED, so a kind it
    /// was never compiled with resolves the moment it is passed one. If this
    /// ever fails, registration has become compile-time and the ADR's D3 trade
    /// ("string-backed so kinds are additive") has been reversed.
    func testTheRegistryResolvesAKindItWasNeverCompiledWith() {
        let registry = AppShellConfiguration.litmusTestShell.recordKinds
        XCTAssertEqual(registry[.litmusNote]?.id, .litmusNote)
        XCTAssertEqual(registry[.litmusNote]?.displayName, "Litmus Analysis")
        XCTAssertEqual(
            registry.descriptor(forSchemaRef: "impress/litmus-note")?.id, .litmusNote)
        XCTAssertEqual(
            registry.descriptor(forCollectionBinding: CollectionBindingID.generic)?.id,
            .litmusNote,
            "the generic kernel binding resolves back to whichever kind claims it")
    }

    /// The tolerant display lookup (ADR-0022 D8 / step 8) is generic over the
    /// registry it is called on: both spellings of the ref resolve, and a
    /// `*-collection` sibling must NOT.
    func testSchemaRefLookupIsToleranceWithoutAMappingTable() {
        let registry = AppShellConfiguration.litmusTestShell.recordKinds
        XCTAssertEqual(registry.kind(forStoreSchemaRef: "impress/litmus-note"), .litmusNote)
        XCTAssertEqual(
            registry.kind(forStoreSchemaRef: "impress/litmus-note@1.0.0"), .litmusNote,
            "version tolerance is base-name equality on both sides")
        XCTAssertNil(
            registry.kind(forStoreSchemaRef: "impress/litmus-note-collection"),
            "base-name equality, never hasPrefix")
    }

    // MARK: - A sidebar section is BUILT for it

    /// The load-bearing sidebar assertion: `RecordSidebarBuilder` produces the
    /// litmus kind's whole primary section — the "All <plural>" row, one smart
    /// child per declared non-hidden status, and the folder tree — from nothing
    /// but the preset binding and the descriptor.
    func testSidebarBuildsTheKindsPrimarySectionFromTheDescriptorAlone() {
        let folders = [
            RecordFolder(id: .deterministic(from: "litmus.batch.a"), name: "Batch A", sortOrder: 0),
            RecordFolder(id: .deterministic(from: "litmus.batch.b"), name: "Batch B", sortOrder: 1),
            RecordFolder(
                id: .deterministic(from: "litmus.batch.a1"), name: "Nested",
                parentID: .deterministic(from: "litmus.batch.a"), sortOrder: 0),
        ]
        let sections = RecordSidebarBuilder.sections(
            configuration: .litmusTestShell,
            dataSource: RecordSidebarDataSource(
                folders: { $0 == .litmusNote ? folders : [] },
                folderCounts: { _, ids in ids.map { _ in 7 } },
                count: { _ in 4 }))

        guard let primary = sections.first(where: { $0.section == .artifacts }) else {
            return XCTFail("no section was built for the litmus kind")
        }
        XCTAssertEqual(primary.kind, .litmusNote)
        XCTAssertEqual(primary.role, .primary)
        XCTAssertTrue(
            primary.canOrganizeFolders,
            "the kind's CollectionCapability declares canOrganize — the whole folder "
                + "verb set (create/rename/reparent/reorder/delete + undo) is live with "
                + "no sidebar edit (ADR-0022 G2/D3)")

        // The DECLARED plural, not `displayName + "s"`.
        XCTAssertEqual(primary.nodes.first?.scope, .all(.litmusNote))
        XCTAssertEqual(primary.nodes.first?.title, "All Litmus Analyses")

        // Status smart children ARE the descriptor's lifecycle, minus the
        // hiddenByDefault dismissal status (which owns the Dismissed section).
        let statusChildren = primary.nodes.compactMap(\.scope.explicitStatus)
        XCTAssertEqual(
            statusChildren, ["open", "running", "verified", "archived"],
            "declaration order IS sidebar row order, and `dismissed` is excluded")
        XCTAssertEqual(
            primary.nodes.compactMap { node -> String? in
                node.scope.explicitStatus == nil ? nil : node.title
            },
            ["Open", "Running", "Verified", "Archive"],
            "row labels come from the StatusSpecs, not from a chassis table")
        XCTAssertEqual(
            primary.nodes.first { $0.scope.explicitStatus == "verified" }?.systemImage,
            "checkmark.seal")

        // The folder tree, nested, with the DECLARED folder glyph.
        let folderNodes = primary.nodes.filter(\.isFolder)
        XCTAssertEqual(folderNodes.map(\.title), ["Batch A", "Batch B"])
        XCTAssertEqual(folderNodes.first?.children.map(\.title), ["Nested"])
        XCTAssertEqual(
            folderNodes.first?.systemImage, "tray.2",
            "a kind whose containers are not 'folders' says so in its capability")
        XCTAssertEqual(folderNodes.first?.count, 7)
    }

    /// The two cross-kind sections serve whichever kind the PRESET binds them
    /// to, with no `== .manuscript`-style comparison left in the builder.
    func testFlaggedAndDismissedSectionsServeTheKindThePresetBinds() {
        let sections = RecordSidebarBuilder.sections(
            configuration: .litmusTestShell,
            dataSource: RecordSidebarDataSource(count: { _ in 2 }))

        guard let flagged = sections.first(where: { $0.section == .flagged }) else {
            return XCTFail("no Flagged section")
        }
        XCTAssertEqual(flagged.kind, .litmusNote)
        XCTAssertEqual(flagged.role, .flagged)
        XCTAssertEqual(
            Set(flagged.nodes.compactMap(\.scope.kind)), [.litmusNote],
            "every flag row must be scoped to the bound kind")
        XCTAssertFalse(flagged.nodes.isEmpty, "the kind declares canFlag")

        guard let dismissed = sections.first(where: { $0.section == .dismissed }) else {
            return XCTFail("no Dismissed section")
        }
        XCTAssertEqual(
            dismissed.nodes.map(\.scope), [.status(.litmusNote, "dismissed")],
            "the kind's OWN dismissal status, read off DismissalSemantics — the "
                + "chassis never names it")
    }

    /// A kind that declares no flags / no dismissal gets no rows — same builder,
    /// different DATA. Proves the section content is descriptor-driven rather
    /// than section-driven.
    func testDeclarationsSuppressSectionsTheKindDoesNotWant() {
        let bare = TriageCapabilities(
            canStar: true, canFlag: false, canTag: true,
            dismissal: .none, archiveStatus: nil, deletion: .none, statuses: [])
        let mute = RecordKindDescriptor(
            id: .litmusNote,
            schemaRefs: ["impress/litmus-note"],
            displayName: "Litmus Analysis",
            pluralDisplayName: "Litmus Analyses",
            detailTabs: [DetailTabSpec(.info)],
            triage: bare)
        let shell = AppShellConfiguration(
            appID: "litmus-mute-shell",
            visibleSections: [.artifacts, .flagged, .dismissed],
            defaultSection: .artifacts,
            defaultDetailTab: .info,
            recordKinds: RecordKindRegistry([mute]),
            sectionBindings: [
                .artifacts: .litmusNote, .flagged: .litmusNote, .dismissed: .litmusNote,
            ])

        let sections = RecordSidebarBuilder.sections(
            configuration: shell, dataSource: RecordSidebarDataSource())
        XCTAssertFalse(
            sections.contains { $0.section == .flagged },
            "canFlag: false must drop the Flagged section, not render empty rows")
        XCTAssertFalse(
            sections.contains { $0.section == .dismissed },
            "dismissal: .none must drop the Dismissed section")
        let primary = sections.first { $0.section == .artifacts }
        XCTAssertEqual(
            primary?.nodes.map(\.title), ["All Litmus Analyses"],
            "no statuses declared -> no smart children; no collection -> no folders")
        XCTAssertEqual(primary?.canOrganizeFolders, false)
    }

    /// `presentableKinds` is the host CAPABILITY gate: a build with no litmus
    /// pane drops every litmus-bound section, whatever it is called.
    func testHostThatCannotPresentTheKindDropsItsSections() {
        let sections = RecordSidebarBuilder.sections(
            configuration: AppShellConfiguration.litmusTestShell.presenting([.publication]),
            dataSource: RecordSidebarDataSource())
        XCTAssertTrue(
            sections.isEmpty,
            "all three sections in this shell are litmus-bound; a host that cannot "
                + "present the kind shows none of them")
    }

    // MARK: - Its route resolves

    /// The Stage-3 hinge: kind + chassis scope out to ONE `RecordRoute` and back
    /// into the kind's OWN parallel list scope. If this loses information a
    /// sidebar row silently shows the wrong records.
    func testRouteRoundTripsThroughTheKindsOwnScope() {
        let folderID = UUID()
        XCTAssertEqual(
            LitmusNoteListScope(routeScope: RecordRoute.all(.litmusNote).scope), .all)
        XCTAssertEqual(
            LitmusNoteListScope(routeScope: RecordRoute.status(.litmusNote, "verified").scope),
            .status("verified"))
        XCTAssertEqual(
            LitmusNoteListScope(routeScope: RecordRoute.folder(.litmusNote, folderID).scope),
            .folder(folderID))
        XCTAssertEqual(
            LitmusNoteListScope(routeScope: RecordRoute.flagged(.litmusNote, "red").scope),
            .flagged(.red))
        XCTAssertEqual(
            LitmusNoteListScope(routeScope: RecordRoute.flagged(.litmusNote, nil).scope),
            .flagged(nil))
        XCTAssertEqual(
            LitmusNoteListScope(routeScope: RecordRoute.flagged(.litmusNote, "chartreuse").scope),
            .flagged(nil),
            "an unknown flag colour degrades to 'any flag', never to no rows")
        // The host escape hatch, round-tripped through its single-sourced key.
        XCTAssertEqual(
            LitmusNoteListScope(routeScope: LitmusNoteListScope.unreviewedRouteScope),
            .unreviewed)
        // An undeclared status is honest nil (empty state), not a silent `.all`.
        XCTAssertNil(
            LitmusNoteListScope(routeScope: RecordRoute.status(.litmusNote, "nonesuch").scope))
    }

    /// The guard that keeps one kind's viewer from rendering another's rows,
    /// in both directions.
    func testScopesOfOtherKindsDoNotTranslateAndViceVersa() {
        XCTAssertNil(LitmusNoteListScope(routeScope: RecordRoute.all(.figure).scope))
        XCTAssertNil(LitmusNoteListScope(routeScope: RecordRoute.all(.message).scope))
        XCTAssertNil(LitmusNoteListScope(routeScope: .section(.artifacts, .litmusNote)))
        XCTAssertNil(FigureListScope(routeScope: RecordRoute.all(.litmusNote).scope))
        XCTAssertNil(MessageListScope(routeScope: RecordRoute.all(.litmusNote).scope))
        XCTAssertNil(ManuscriptListScope(routeScope: RecordRoute.all(.litmusNote).scope))
        XCTAssertNil(AgentListScope(routeScope: RecordRoute.all(.litmusNote).scope))
    }

    /// Routes are selection STATE (they key `tabToNodeID`), and the tab enum
    /// carries them without gaining a case.
    func testRoutesAreValueSemanticsAndUsableAsTabKeys() {
        XCTAssertEqual(RecordRoute.all(.litmusNote).stableID, "litmus-note.all")
        XCTAssertNotEqual(RecordRoute.all(.litmusNote), RecordRoute.all(.figure))
        XCTAssertNotEqual(
            RecordRoute.status(.litmusNote, "open"), RecordRoute.status(.litmusNote, "running"))

        let ids = [
            RecordRoute.all(.litmusNote),
            .status(.litmusNote, "open"),
            .status(.litmusNote, "verified"),
            .flagged(.litmusNote, nil),
            .flagged(.litmusNote, "red"),
            RecordRoute(kind: .litmusNote, scope: LitmusNoteListScope.unreviewedRouteScope),
        ].map(\.stableID)
        XCTAssertEqual(Set(ids).count, ids.count, "stableID must separate every route")

        var tabToNode: [ImbibTab: Int] = [:]
        tabToNode[.record(.all(.litmusNote))] = 1
        tabToNode[.record(.all(.litmusNote))] = 2
        XCTAssertEqual(tabToNode.count, 1)
        XCTAssertEqual(tabToNode[.record(.all(.litmusNote))], 2)
    }

    /// Two different routes must never share a SwiftUI identity — the `.id()`
    /// rule the whole scope protocol exists for.
    func testScopeIdentityIsStableAndDistinct() {
        let scope = LitmusNoteListScope.status("verified")
        XCTAssertEqual(scope.stableViewID, LitmusNoteListScope.status("verified").stableViewID)
        XCTAssertNotEqual(scope.stableViewID, LitmusNoteListScope.status("archived").stableViewID)
        XCTAssertNotEqual(
            RecordRoute.all(.litmusNote).scope.stableViewID,
            RecordRoute.all(.figure).scope.stableViewID)
    }

    // MARK: - The viewer registry answers for it (and falls back cleanly)

    /// `RecordViewerRegistry` is a RUNTIME registry with a `register(_:)` verb,
    /// so a kind can be given a viewer without a chassis edit. That is the
    /// architecture's answer to "who renders this kind" and it is what makes
    /// test-only registration possible at all.
    func testViewerRegistryAnswersForTheKindOnceRegistered() {
        let registry = RecordViewerRegistry()
        XCTAssertNil(registry[.litmusNote])

        registry.register(.litmusNote)
        XCTAssertEqual(registry[.litmusNote]?.kind, .litmusNote)
        XCTAssertTrue(registry.registeredKinds.contains(.litmusNote))

        // Registering twice replaces, never duplicates.
        registry.register(.litmusNote)
        XCTAssertEqual(registry.registeredKinds.count, 1)

        // And the factory really builds a view for the kind's own scope.
        let section = registry[.litmusNote]?.makeSectionView(
            RecordSectionContext(scope: .all(.litmusNote)))
        XCTAssertNotNil(section)
    }

    /// Registering the litmus kind must not disturb the builtins — the registry
    /// is keyed by kind, so a new kind is purely additive.
    func testRegisteringTheKindLeavesTheBuiltinsAlone() {
        let registry = RecordViewerRegistry(
            [.litmusNote] + RecordViewerRegistry.builtin.registeredKinds.sorted {
                $0.rawValue < $1.rawValue
            }.compactMap { RecordViewerRegistry.builtin[$0] })
        XCTAssertTrue(registry.registeredKinds.contains(.litmusNote))
        XCTAssertTrue(
            RecordViewerRegistry.builtin.registeredKinds.isSubset(of: registry.registeredKinds))
        XCTAssertNil(
            RecordViewerRegistry.builtin[.litmusNote],
            "the SHIPPED registry must never learn about a test-only kind — if this "
                + "fails, litmus registration has leaked into chassis source")
    }

    /// The architecture's specified behaviour for a kind with NO factory is a
    /// clean, named empty state — `SectionContentView.recordSection` ends in
    /// `ChassisEmptyState.viewerUnavailable(kind:)`, not in a blank pane and not
    /// in a trap. This pins that contract (including the message text, so the
    /// failure is diagnosable in a screenshot).
    func testUnregisteredKindFallsBackToTheNamedViewerUnavailableState() {
        XCTAssertNil(RecordViewerRegistry()[.litmusNote])

        let state = ChassisEmptyState.viewerUnavailable(kind: .litmusNote)
        XCTAssertEqual(state.id, "viewer-unavailable")
        XCTAssertEqual(state.title, "Viewer Unavailable")
        XCTAssertEqual(state.message, "No registered viewer for \u{201C}litmus-note\u{201D}.")
        XCTAssertEqual(
            state.systemImage, RecordKindDescriptor.unknownSymbolName,
            "the honest 'unknown kind' glyph, never a wrong one")
    }

    /// A factory handed someone else's scope degrades to nil rather than
    /// rendering the wrong rows — the half of `scope(as:)` that carries weight.
    func testSectionContextRejectsForeignScopes() {
        XCTAssertEqual(
            RecordSectionContext(scope: .all(.litmusNote)).scope(as: LitmusNoteListScope.self),
            .all)
        XCTAssertNil(
            RecordSectionContext(scope: .all(.figure)).scope(as: LitmusNoteListScope.self))
        XCTAssertNil(
            RecordSectionContext(scope: .all(.litmusNote)).scope(as: FigureListScope.self))
    }

    /// Mixed-kind surfaces (grouped search, Related items) bucket the kind's
    /// rows the moment a row struct exists — no mapping table, and the shared
    /// mail-style chrome is the default row factory.
    func testMixedKindProjectionAndDefaultRowChrome() {
        let row = LitmusNoteRowData(
            title: "Chassis purity sweep", status: "verified",
            summary: "4 sections, 0 edits", starred: true, flagColor: .red,
            tagPaths: ["ci/litmus"])
        let tagged = KindTaggedRow(litmusNote: row)
        XCTAssertEqual(tagged.kind, .litmusNote)
        XCTAssertEqual(tagged.titleText, "Chassis purity sweep")
        XCTAssertEqual(
            tagged.headerText, "Verified",
            "the row's header reads the kind's OWN StatusSpec label")
        XCTAssertTrue(tagged.isStarred)
        XCTAssertEqual(tagged.flag?.color, .red)
        XCTAssertEqual(tagged.tagDisplays.map(\.leaf), ["litmus"])

        // A kind with no `makeListRow` override renders MailStyleRow — the
        // default on `RecordViewerFactory.init`.
        let registry = RecordViewerRegistry([.litmusNote])
        XCTAssertNotNil(registry[.litmusNote]?.makeListRow(tagged))
        XCTAssertEqual(
            AnyRecordListWrapper.primaryRow(in: [tagged.id], of: [tagged])?.kind, .litmusNote)
    }

    // MARK: - Its declared statuses and tabs are honored

    /// Tab availability and coercion are the descriptor's, evaluated against a
    /// `RecordTabContext` the host supplies — no `switch` over kinds anywhere.
    func testDeclaredTabsAndCoercionAreHonored() {
        // Default context: the conditional Preview tab is absent.
        XCTAssertEqual(descriptor.availableTabs(for: RecordTabContext()), [.info, .source])
        // With a rendered state, it appears.
        let rendered = RecordTabContext(previewKind: .compiledPDF)
        XCTAssertEqual(descriptor.availableTabs(for: rendered), [.info, .source, .pdf])
        XCTAssertEqual(
            descriptor.availableTabs(
                for: RecordTabContext(previewKind: DocumentFormat.PreviewKind.none)),
            [.info, .source])

        // Coercion: a valid tab is kept.
        XCTAssertEqual(descriptor.coercedTab(.source, for: RecordTabContext()), .source)
        // The declared fallback maps the "other" text tab onto this kind's.
        XCTAssertEqual(descriptor.coercedTab(.bibtex, for: RecordTabContext()), .source)
        // An unavailable tab with no usable fallback lands on the first valid one.
        XCTAssertEqual(descriptor.coercedTab(.pdf, for: RecordTabContext()), .info)
        XCTAssertEqual(descriptor.coercedTab(.pdf, for: rendered), .pdf)
        XCTAssertEqual(descriptor.coercedTab(.notes, for: RecordTabContext()), .info)
    }

    /// The status lifecycle, and the two facts `StatusSpec` deliberately does
    /// NOT restate (which status is the dismissal, which is the archive) being
    /// consistent with the semantics that do say so.
    func testDeclaredStatusLifecycleIsHonoredAndSelfConsistent() {
        XCTAssertEqual(
            triage.statusValues, ["open", "running", "verified", "archived", "dismissed"])
        XCTAssertEqual(triage.dismissedStatus, "dismissed")
        XCTAssertEqual(triage.archiveStatus, "archived")

        // Every semantics-named status is declared (the RecordKindStatusSpecTests
        // cross-check, applied to a kind those loops never see).
        for value in [triage.dismissedStatus, triage.archiveStatus].compactMap({ $0 }) {
            XCTAssertNotNil(triage.status(value), "'\(value)' is named but not declared")
            XCTAssertTrue(triage.status(value)?.isTerminal == true, "'\(value)' ends the lifecycle")
        }
        XCTAssertTrue(
            triage.status("dismissed")?.hiddenByDefault == true,
            "the dismissal status owns the Dismissed section, so it must not also be "
                + "a primary smart child")
        XCTAssertNil(triage.status("nonesuch"))

        // The freezesSource facet (added with this wave) is read off the
        // declaration like every other one.
        XCTAssertEqual(triage.freezingStatusValues, ["verified", "archived"])
        XCTAssertEqual(triage.status("open")?.freezesSource, false)
    }

    /// Triage capabilities and creation affordances drive the keyboard grammar
    /// and the `n` key generically — the descriptor is the only input.
    func testTriageCapabilitiesAndCreationAffordanceAreDeclared() {
        XCTAssertTrue(triage.canStar)
        XCTAssertTrue(triage.canFlag)
        XCTAssertTrue(triage.canTag)
        XCTAssertEqual(triage.deletion, .confirmHard)
        XCTAssertEqual(descriptor.creation.map(\.label), ["New Litmus Analysis"])
        XCTAssertEqual(
            AppShellConfiguration.litmusTestShell.openBehavior(for: .litmusNote), .detailPane)
        // A preset override wins over the descriptor default, with no edit to
        // either.
        let overridden = AppShellConfiguration(
            appID: "litmus-override",
            visibleSections: [.artifacts],
            defaultSection: .artifacts,
            defaultDetailTab: .info,
            recordKinds: RecordKindRegistry([descriptor]),
            openOverrides: [.litmusNote: .window(id: "litmus-window")])
        XCTAssertEqual(
            overridden.openBehavior(for: .litmusNote), .window(id: "litmus-window"))
    }

    /// The kind's folder verbs come from its `CollectionCapability`, including
    /// the MENU TITLES, which used to be inline literals in the sidebar.
    func testCollectionCapabilityDrivesTheOrganiseVocabulary() {
        guard let collection = descriptor.collection else {
            return XCTFail("the litmus kind declares a collection capability")
        }
        XCTAssertEqual(collection.bindingID, CollectionBindingID.generic)
        XCTAssertEqual(collection.newContainerTitle, "New Batch")
        XCTAssertEqual(collection.newSubContainerTitle, "New Subbatch")
        XCTAssertEqual(collection.deleteContainerTitle, "Delete Batch")
        XCTAssertEqual(collection.dragUTTypeIdentifier, "com.impress.litmus-note-id")
    }

    // MARK: - The honest boundary (wall (b))

    /// The two DISPLAY resolvers that reach the global `BuiltinRecordKinds`
    /// rather than a registry parameter. A production kind closes this with the
    /// one-line append to `BuiltinRecordKinds.all` that ADR-0021 step 3 already
    /// prescribes; a test-only kind cannot, and MUST NOT — so this asserts the
    /// fallbacks are honest rather than wrong.
    ///
    /// If either of these ever starts answering for `litmus-note`, the kind has
    /// been registered in chassis source and `LitmusChassisPurityTests` will
    /// have failed too.
    func testGlobalDisplayResolversFallBackHonestly() {
        XCTAssertNil(
            BuiltinRecordKinds.registry[.litmusNote],
            "the shipped registry must not contain a test-only kind")
        XCTAssertEqual(
            RecordKindIconography.symbolName(for: .litmusNote),
            RecordKindDescriptor.unknownSymbolName,
            "an unregistered kind shows the honest 'unknown kind' glyph, never a "
                + "wrong one — and never the litmus symbol, which only this target "
                + "declares")
        XCTAssertEqual(
            RecordKindIconography.symbolName(forStoreSchemaRef: "impress/litmus-note"),
            RecordKindDescriptor.unknownSymbolName)
        // Statuses this kind invents get the generic title-cased rendering.
        XCTAssertNil(RecordStatusPresentation.spec(for: "litmus-only-status"))
        XCTAssertEqual(
            RecordStatusPresentation.label(for: "litmus-only-status"), "Litmus Only Status")
        // But a status it shares with a shipped kind resolves to the SHIPPED
        // presentation, which is why a kind should read `triage.status(_:)`.
        XCTAssertEqual(RecordStatusPresentation.label(for: "archived"), "Archive")
        XCTAssertEqual(
            LitmusNoteRowData(title: "x", status: "running").headerText, "Running",
            "the row reads its own descriptor, so it is right even for a status the "
                + "global table has never heard of")
    }

    /// Wall (a), stated as an assertion so it cannot rot into a comment:
    /// `SidebarSectionType` is a closed enum, so the litmus kind rides an
    /// EXISTING section. ADR-0021 step 6 calls this deliberate (the raw values
    /// back persisted sidebar order/collapse state); this documents the shape of
    /// the remaining cost.
    func testSidebarSectionTypeIsStillClosedSoTheKindRidesAnExistingSection() {
        XCTAssertNil(
            SidebarSectionType(rawValue: "litmus-notes"),
            "a kind cannot name its own section without a SidebarSectionType case — "
                + "the one hand-written cost ADR-0021 step 6 keeps on purpose")
        XCTAssertEqual(
            AppShellConfiguration.litmusTestShell.effectiveRecordKind(for: .artifacts),
            .litmusNote,
            "so the kind binds an existing section, and everything IN it is still "
                + "descriptor-derived")
        XCTAssertEqual(SidebarSectionType.artifacts.role, .primary)
    }
}

// MARK: - Structural

/// The half that makes the behavioural suite mean something.
///
/// A test that a kind renders through generic machinery is worthless if the
/// machinery was taught about the kind. So: no CHASSIS SOURCE file may mention
/// the litmus kind, in any spelling.
///
/// SCOPE — "chassis source" is defined here exactly, and deliberately WIDER than
/// `Chassis/`: the whole of `Sources/PublicationManagerCore`, recursively, every
/// `.swift` file. The generic machinery this litmus exercises is not all under
/// `Chassis/` (`SidebarSectionType` lives in `Files/SidebarSectionOrderStore.swift`,
/// `DetailTab` in `SharedViews/DetailTab.swift`), and there is no honest line to
/// draw between "the chassis" and "the rest of PMC" for this purpose. Scanning
/// the whole production target is both simpler and stricter. The TEST target is
/// excluded — that is where the kind is supposed to live.
///
/// Precedent for scanning source text from a test:
/// `ChassisCrossPlatformContractTests` (which resolves
/// `Sources/PublicationManagerCore` from `#filePath` and asserts on file
/// contents) and `RecordRouteTests.chassisSource` (same trick, per file, for the
/// per-kind route enums). This mirrors both: `#filePath`-relative resolution so
/// the check travels with the package and does not depend on a working
/// directory.
///
/// TOKENS — the banned strings are the KIND's spellings, not the bare word
/// "litmus". Three chassis files legitimately reference ADR-0021's *litmus
/// section* in prose (`Chassis/RecordKind/RecordKindDescriptor.swift`,
/// `Chassis/TabSidebar/TabSidebarTypes.swift`,
/// `Chassis/Shared/SchemaRefKindLookup.swift`), and those references are the
/// chassis explaining WHY it is shaped this way — exactly what should stay. A
/// bare-word scan would have to allowlist them by path, which rots. Banning
/// every spelling of the identifier is the precise version of the same rule.
final class LitmusChassisPurityTests: XCTestCase {

    /// Spellings this target ACTUALLY uses. Both banned in production source and
    /// required to appear in the declaring test file — see the negative control
    /// in `testTheKindIsDeclaredEntirelyInTheTestTarget`, which keeps this list
    /// from going stale under a rename.
    private static let activeSpellings = [
        "litmus-note",   // the RecordKindID raw value, the schema ref, the UTType
        "litmusNote",    // the static let, the route scope key, the factory
        "LitmusNote",    // the types (LitmusNoteRecordKind, LitmusNoteRowData, …)
    ]

    /// Spellings nothing uses YET, banned defensively: the shapes a leak would
    /// most plausibly take if the kind ever grew a bridge (a Rust-style snake
    /// case ref, a constant, the display name as an identifier). Deliberately
    /// NOT part of the negative control — a token that matches nothing today is
    /// still worth banning tomorrow.
    private static let defensiveSpellings = [
        "litmus_note",
        "LITMUS_NOTE",
        "LitmusAnalysis",
    ]

    private static var bannedSpellings: [String] { activeSpellings + defensiveSpellings }

    /// Positive control for the scan itself.
    ///
    /// A "no file contains X" assertion passes just as happily when it reads no
    /// files, or reads them and finds nothing because the search is broken. This
    /// proves the enumerator reaches the tree AND that content matching works,
    /// by finding tokens that MUST be there.
    func testTheStructuralScanActuallyReadsChassisSource() throws {
        let files = Self.productionSwiftFiles()
        XCTAssertGreaterThan(
            files.count, 200,
            "the scan found suspiciously few files — if the source layout moved, fix "
                + "this test rather than letting it pass vacuously")

        let paths = files.map(Self.relativePath)
        for required in [
            "Sources/PublicationManagerCore/Chassis/RecordKind/RecordKindDescriptor.swift",
            "Sources/PublicationManagerCore/Chassis/RecordKind/BuiltinRecordKinds.swift",
            "Sources/PublicationManagerCore/Chassis/Shared/RecordSidebar/RecordSidebarBuilder.swift",
            "Sources/PublicationManagerCore/Chassis/TabSidebar/SectionContentView.swift",
            "Sources/PublicationManagerCore/Files/SidebarSectionOrderStore.swift",
        ] {
            XCTAssertTrue(
                paths.contains(required),
                "the scan must cover \(required) — it is generic machinery this litmus "
                    + "exercises")
        }

        // Content matching works: these tokens are in the tree by construction.
        let descriptorFile = Self.sourcesRoot
            .appendingPathComponent("Chassis/RecordKind/RecordKindDescriptor.swift")
        let text = try String(contentsOf: descriptorFile, encoding: .utf8)
        XCTAssertTrue(text.contains("struct RecordKindDescriptor"))
        XCTAssertTrue(
            text.contains("freezesSource"),
            "the facet added alongside this litmus must be readable by the same scan")
    }

    func testNoChassisSourceFileMentionsTheLitmusKind() throws {
        let files = Self.productionSwiftFiles()
        XCTAssertGreaterThan(files.count, 200)

        var offenders: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for banned in Self.bannedSpellings where text.contains(banned) {
                offenders.append("\(Self.relativePath(url)): contains \u{201C}\(banned)\u{201D}")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            The litmus record kind leaked into production source:

            \(offenders.joined(separator: "\n"))

            `litmus-note` is a TEST-ONLY record kind whose entire purpose is to \
            prove that ADR-0021's "adding a record kind = zero chassis edits" claim \
            holds. A chassis file that names it defeats the proof: the behavioural \
            assertions in LitmusRecordKindTests would then be testing a special \
            case, not the generic machinery.

            If a litmus assertion is failing and the fix looks like a chassis edit, \
            the correct move is either (a) a GENERIC, kind-agnostic seam — one that \
            does not mention this or any other kind — or (b) reporting the wall. \
            Never a `litmus` hook.
            """)
    }

    /// The complement, so the suite cannot pass because the kind quietly stopped
    /// existing: the test target really does declare it, in the file that owns it.
    func testTheKindIsDeclaredEntirelyInTheTestTarget() throws {
        let url = Self.testsRoot.appendingPathComponent("LitmusNoteRecordKind.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        for required in [
            "RecordKindID(\"litmus-note\")",
            "static let descriptor = RecordKindDescriptor(",
            ": MailStyleItem",
            ": RecordRouteScope",
            "RecordViewerFactory(",
        ] {
            XCTAssertTrue(
                text.contains(required),
                "the litmus kind's minimal registration set must stay in the test "
                    + "target: missing \u{201C}\(required)\u{201D}")
        }
        XCTAssertEqual(
            RecordKindID.litmusNote.rawValue, "litmus-note",
            "the id the structural scan bans must be the id the tests use")

        // Negative control for the token list: the banned spellings must
        // actually match real references to this kind. Run the SAME loop the
        // purity scan runs over the file that declares it — if this finds
        // nothing, the ban list has gone stale and the scan above is vacuous.
        let matched = Self.activeSpellings.filter { text.contains($0) }
        XCTAssertEqual(
            Set(matched), Set(Self.activeSpellings),
            """
            The purity scan's ban list no longer matches how the kind is spelled. \
            Unmatched: \(Set(Self.activeSpellings).subtracting(matched).sorted()). \
            The declaration was probably renamed — update `activeSpellings`, because \
            a token that matches nothing bans nothing and the scan above would pass \
            vacuously.
            """)
    }

    // MARK: - Helpers

    private static let packageRoot: URL = {
        URL(fileURLWithPath: #filePath)   // …/Tests/PublicationManagerCoreTests/<this>
            .deletingLastPathComponent()   // …/Tests/PublicationManagerCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/PublicationManagerCore
    }()

    private static let sourcesRoot = packageRoot.appendingPathComponent(
        "Sources/PublicationManagerCore")

    private static let testsRoot = packageRoot.appendingPathComponent(
        "Tests/PublicationManagerCoreTests")

    /// Every `.swift` file in the PRODUCTION target, recursively. Returns empty
    /// when the tree cannot be walked, which the caller's floor assertion
    /// reports as a failure rather than passing vacuously.
    private static func productionSwiftFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: nil)
        else { return [] }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    private static func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: packageRoot.path + "/", with: "")
    }
}
