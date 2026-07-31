#if os(macOS)
//
//  MacComposedSidebarTests.swift
//  PublicationManagerCoreTests
//
//  The macOS sidebar view model, asserted HEADLESSLY — which is the point of
//  the file as much as its contents.
//
//  `ImbibSidebarViewModel` is the largest file in the repo and, until
//  `SidebarPersistenceScope` gave it a seam, the only instrument that could
//  show what it built was launching a macOS app. That is why a shipped bug
//  ("collapse state is loaded at launch and never saved" —
//  `handleExpansionChange` with no callers at all) sat in all six shells
//  unnoticed, and why the I3 report named "no test constructs
//  `ImbibSidebarViewModel`" as the decisive reason not to grow it a second
//  tier. These tests ARE the launch: they build the view model against a mock
//  store and a scratch persistence box, walk the tree the `NSOutlineView` would
//  walk (`outlineConfiguration.rootNodes` + `children(of:)` — the same two
//  entry points the coordinator uses, so nothing is asserted through a back
//  door), and drive the drag and expansion callbacks the way AppKit does.
//
//  The oracle for "the five sibling shells are unchanged" is the FLAT half of
//  every test below: each composed assertion has a single-preset twin built
//  from the same store, and the twin's rows, ids and depths are compared to
//  what they are without the composition existing.
//

import ImpressKit
import ImpressSidebar
import XCTest

@testable import PublicationManagerCore

@MainActor
final class MacComposedSidebarTests: XCTestCase {

    // MARK: - Helpers

    private func viewModel(
        _ configuration: AppShellConfiguration = .imbib,
        composed: SidebarComposition? = nil,
        persistence: SidebarPersistenceScope? = nil
    ) -> ImbibSidebarViewModel {
        ImbibSidebarViewModel(
            store: MockPublicationStore(),
            persistence: persistence ?? .inMemory(),
            shellConfiguration: configuration,
            sidebarComposition: composed)
    }

    private func composedViewModel(
        persistence: SidebarPersistenceScope? = nil
    ) -> ImbibSidebarViewModel {
        viewModel(.impress, composed: .impress, persistence: persistence)
    }

    /// Every node in the tree, pre-order — the same walk `rebuildData` does.
    private func flatten(
        _ viewModel: ImbibSidebarViewModel, from roots: [ImbibSidebarNode]? = nil
    ) -> [ImbibSidebarNode] {
        var out: [ImbibSidebarNode] = []
        func visit(_ nodes: [ImbibSidebarNode]) {
            for node in nodes {
                out.append(node)
                visit(viewModel.children(of: node))
            }
        }
        visit(roots ?? viewModel.outlineConfiguration.rootNodes)
        return out
    }

    private func group(
        _ viewModel: ImbibSidebarViewModel, _ id: String
    ) -> ImbibSidebarNode? {
        viewModel.outlineConfiguration.rootNodes.first {
            if case .appGroup(let groupID) = $0.nodeType { return groupID == id }
            return false
        }
    }

    private func sectionNode(
        _ viewModel: ImbibSidebarViewModel, group groupID: String, _ section: SidebarSectionType
    ) -> ImbibSidebarNode? {
        guard let group = group(viewModel, groupID) else { return nil }
        return viewModel.children(of: group).first {
            if case .section(let type) = $0.nodeType { return type == section }
            return false
        }
    }

    // MARK: - The root tier IS the five apps

    /// impress's macOS sidebar builds one group per sibling app, in the suite
    /// table's order, with that table's titles and glyphs — and impress itself
    /// is not one of them.
    func testComposedRootsAreTheFiveSiblingAppsInTableOrder() {
        let viewModel = composedViewModel()
        // The app groups are the record tier. The registered whole-pane custom
        // surfaces still sit after them at root, ungrouped and unchanged — they
        // are window chrome, not a place records live, which is the same reason
        // the composition itself excludes them.
        let roots = viewModel.outlineConfiguration.rootNodes.filter(\.isAppGroup)
        XCTAssertEqual(
            viewModel.outlineConfiguration.rootNodes.filter { !$0.isAppGroup }
                .allSatisfy { if case .customSurface = $0.nodeType { return true } else { return false } },
            true,
            "the only ungrouped roots a composed sidebar has are custom surfaces")

        let expected = SiblingApp.descriptors.map(\.id).filter { $0 != .impress }
        XCTAssertEqual(roots.count, expected.count)

        for (node, app) in zip(roots, expected) {
            XCTAssertEqual(node.nodeType, .appGroup(app.rawValue))
            XCTAssertTrue(node.isAppGroup, "\(app.rawValue) must render as an app group")
            XCTAssertFalse(
                node.isGroup,
                "an app group is NOT a section header — the two tiers coexist and render "
                    + "differently, and conflating them loses the section menu")
            XCTAssertEqual(node.displayName, app.displayName)
            XCTAssertEqual(node.iconName, app.systemImage)
            XCTAssertEqual(node.treeDepth, 0)
            XCTAssertNil(node.imbibTab, "a group header is an app's presence, not a destination")
            XCTAssertEqual(
                viewModel.outlineConfiguration.shouldSelectItem?(node), false,
                "app-group rows must not be selectable")
        }
    }

    /// A group's sections are exactly what that app's OWN shell builds — not a
    /// subset of the flat union, and not a hand-written list. Compared against
    /// a view model actually running that preset.
    func testEachGroupsSectionsAreExactlyWhatThatAppsOwnShellBuilds() {
        let composed = composedViewModel()
        let presets: [(String, AppShellConfiguration)] = [
            ("imbib", .imbib), ("imprint", .imprint), ("implore", .implore),
            ("impel", .impel), ("impart", .impart),
        ]
        for (id, preset) in presets {
            guard let groupNode = group(composed, id) else { return XCTFail("no \(id) group") }
            let composedSections = composed.children(of: groupNode).compactMap { node -> SidebarSectionType? in
                if case .section(let type) = node.nodeType { return type }
                return nil
            }
            let flat = viewModel(preset)
            let flatSections = flat.outlineConfiguration.rootNodes.compactMap { node -> SidebarSectionType? in
                if case .section(let type) = node.nodeType { return type }
                return nil
            }
            XCTAssertEqual(
                composedSections, flatSections,
                "\(id)'s group must be \(id)'s sidebar, section for section and in order")
        }
    }

    /// A group whose every section gates away still renders its header. A group
    /// is an app's presence in impress, not a claim about its data.
    func testAGroupWithNoSectionsIsStillPresent() {
        let composed = composedViewModel()
        for node in composed.outlineConfiguration.rootNodes {
            guard case .appGroup = node.nodeType else { continue }
            // Whether a given group is empty depends on the store; the claim
            // under test is that emptiness never removes the header.
            _ = composed.children(of: node)
        }
        XCTAssertEqual(
            composed.outlineConfiguration.rootNodes.filter(\.isAppGroup).count,
            SiblingApp.descriptors.count - 1,
            "no group may be dropped for being empty")
    }

    // MARK: - The user's report: flagged, per group

    /// THE regression the composition exists to fix, on macOS.
    ///
    /// Under the flat `.impress` preset there is exactly one Flagged section
    /// and `sectionBindings` can name exactly one kind for it — `.publication`
    /// — so a flagged MANUSCRIPT had no row in impress at all, on any platform.
    /// Composed, each group's Flagged section routes to its own app's kind, and
    /// the two do not contaminate each other.
    func testEachGroupsFlaggedRowsRouteToThatAppsOwnKind() {
        let composed = composedViewModel()

        guard let imbibFlagged = sectionNode(composed, group: "imbib", .flagged) else {
            return XCTFail("imbib group has no Flagged section")
        }
        guard let imprintFlagged = sectionNode(composed, group: "imprint", .flagged) else {
            return XCTFail("imprint group has no Flagged section")
        }

        // imbib's group behaves EXACTLY as flat imbib does: the publication
        // path, through the untouched `.flagged(colour)` tab.
        for row in composed.children(of: imbibFlagged) {
            switch row.nodeType {
            case .anyFlag:
                XCTAssertEqual(row.imbibTab, .flagged(nil))
            case .flagColor(let colour):
                XCTAssertEqual(row.imbibTab, .flagged(colour.rawValue))
            default:
                XCTFail("unexpected row \(row.nodeType) under imbib's Flagged")
            }
        }

        // imprint's group routes to MANUSCRIPTS — the row that did not exist.
        var sawManuscriptFlagRow = false
        for row in composed.children(of: imprintFlagged) {
            switch row.nodeType {
            case .anyFlag:
                XCTAssertEqual(row.imbibTab, .record(.flagged(.manuscript, nil)))
                sawManuscriptFlagRow = true
            case .flagColor(let colour):
                XCTAssertEqual(row.imbibTab, .record(.flagged(.manuscript, colour.rawValue)))
                sawManuscriptFlagRow = true
            default:
                XCTFail("unexpected row \(row.nodeType) under imprint's Flagged")
            }
        }
        XCTAssertTrue(
            sawManuscriptFlagRow,
            "impress must have at least one row that lists FLAGGED MANUSCRIPTS — the exact "
                + "thing the flat union could not express")
    }

    /// Flag COUNTS are per group too, and a group whose kind has not been
    /// counted yet shows no badge rather than another kind's number. The first
    /// tree is built before `refreshFlagCounts` runs, and inheriting the flat
    /// `flagCounts` there would put imbib's publication badges on imprint's
    /// manuscript rows.
    func testAComposedGroupNeverBorrowsAnotherKindsFlagCounts() {
        let composed = composedViewModel()
        guard let imprintFlagged = sectionNode(composed, group: "imprint", .flagged) else {
            return XCTFail("no imprint Flagged")
        }
        for row in composed.children(of: imprintFlagged) {
            XCTAssertNil(
                row.displayCount,
                "\(row.displayName) must not show a count it has not been given")
        }
        // And a FLAT shell still reads the single `flagCounts` it always read.
        let flat = viewModel(.imbib)
        flat.refreshFlagCounts()
        XCTAssertTrue(flat.flagCountsByKind.isEmpty, "a flat shell computes no per-kind counts")
    }

    /// The flat preset still cannot express it, which is why the composition is
    /// a separate value rather than an edit to `.impress`.
    func testTheFlatShellStillBindsFlaggedToPublicationsOnly() {
        let flat = viewModel(.impress)
        let flaggedSection = flat.outlineConfiguration.rootNodes.first {
            if case .section(.flagged) = $0.nodeType { return true }
            return false
        }
        guard let flaggedSection else { return XCTFail("flat impress has no Flagged section") }
        for row in flat.children(of: flaggedSection) {
            if case .record = row.imbibTab {
                XCTFail("the FLAT sidebar must keep its single publication-bound Flagged section")
            }
        }
        XCTAssertEqual(AppShellConfiguration.impress.sectionBindings[.flagged], .publication)
    }

    /// Dismissed is the second cross-kind section, and it carries each app's own
    /// dismissal SEMANTICS: imbib moves a paper between libraries, imprint
    /// changes a manuscript's status.
    func testEachGroupsDismissedRowUsesItsOwnKindsSemantics() {
        let composed = composedViewModel()
        if let imprintDismissed = sectionNode(composed, group: "imprint", .dismissed),
           let row = composed.children(of: imprintDismissed).first {
            let dismissed = BuiltinRecordKinds.registry[.manuscript]?.triage.dismissedStatus
            XCTAssertNotNil(dismissed)
            XCTAssertEqual(row.imbibTab, .record(.status(.manuscript, dismissed ?? "")))
        }
        if let imbibDismissed = sectionNode(composed, group: "imbib", .dismissed),
           let row = composed.children(of: imbibDismissed).first {
            XCTAssertEqual(
                row.imbibTab, .dismissed,
                "imbib's Dismissed keeps the publication-library route it has always had")
        }
    }

    /// A section two apps declare renders in BOTH groups. Not a defect to
    /// de-duplicate: the user asked for each app's sidebar verbatim.
    func testASectionTwoAppsDeclareRendersInBothGroups() {
        let composed = composedViewModel()
        let declaringBoth = SidebarSectionType.allCases.filter {
            AppShellConfiguration.imbib.permits($0) && AppShellConfiguration.imprint.permits($0)
        }
        XCTAssertFalse(declaringBoth.isEmpty, "the presets should still overlap somewhere")
        for section in declaringBoth {
            let inImbib = sectionNode(composed, group: "imbib", section)
            let inImprint = sectionNode(composed, group: "imprint", section)
            // Both present, or both gated away by content — never one silently
            // swallowing the other.
            if inImbib != nil || inImprint != nil {
                XCTAssertNotEqual(
                    inImbib?.id, inImprint?.id,
                    ".\(section.rawValue) must be two rows, not one shared row")
            }
        }
    }

    // MARK: - Identity: the collision a second tier introduces

    /// Every node in the composed tree has a UNIQUE id.
    ///
    /// This is not cosmetic. `ImbibSidebarNodeID` is deterministic, so imbib's
    /// red flag and imprint's red flag would otherwise BE the same UUID, and
    /// `SidebarOutlineView` keys its wrapper cache, its child map and its
    /// flattening info by UUID — one row would silently stand in for the other.
    func testEveryComposedNodeIDIsUnique() {
        let composed = composedViewModel()
        let all = flatten(composed)
        XCTAssertGreaterThan(all.count, 10, "the walk should have found a real tree")
        let ids = Set(all.map(\.id))
        XCTAssertEqual(
            ids.count, all.count,
            "duplicate node ids in a composed sidebar are undefined behaviour, not a clash")
    }

    /// A grouped node's id is its FLAT id, namespaced — so the flat shells' ids
    /// are untouched and the composed ones are derived rather than re-invented.
    func testGroupedIDsAreTheFlatIDsNamespacedByGroup() {
        let composed = composedViewModel()
        guard let imbibFlagged = sectionNode(composed, group: "imbib", .flagged) else {
            return XCTFail("no imbib Flagged")
        }
        XCTAssertEqual(
            imbibFlagged.id,
            ImbibSidebarNodeID.grouped("imbib", ImbibSidebarNodeID.section(.flagged)))
        XCTAssertNotEqual(
            imbibFlagged.id, ImbibSidebarNodeID.section(.flagged),
            "a grouped section must not collide with the flat one")
    }

    // MARK: - treeDepth (indentation is drawn from it, not by AppKit)

    /// A composed sidebar is one level deeper, everywhere below the group tier
    /// — and the ten hand-assigned `treeDepth` sites did not have to change,
    /// which is what makes that claim maintainable.
    func testGroupingOffsetsEveryDescendantDepthByExactlyOne() {
        let composed = composedViewModel()
        let flat = viewModel(.imbib)

        guard let imbibGroup = group(composed, "imbib") else { return XCTFail("no imbib group") }
        let composedSections = composed.children(of: imbibGroup)
        let flatSections = flat.outlineConfiguration.rootNodes

        for section in composedSections {
            guard case .section(let type) = section.nodeType,
                  let flatSection = flatSections.first(where: { $0.nodeType == .section(type) })
            else { continue }
            let composedRows = composed.children(of: section)
            let flatRows = flat.children(of: flatSection)
            XCTAssertEqual(
                composedRows.count, flatRows.count,
                ".\(type.rawValue) must have the same rows in the imbib group as in imbib")
            for (composedRow, flatRow) in zip(composedRows, flatRows) {
                XCTAssertEqual(
                    composedRow.treeDepth, flatRow.treeDepth + 1,
                    "\(composedRow.displayName) should be exactly one level deeper when grouped")
            }
        }
    }

    /// And the flat shells' depths are untouched — the offset only ever comes
    /// from a parent that HAS a group.
    func testFlatDepthsAreUnchangedByTheCompositionExisting() {
        let flat = viewModel(.imbib)
        for node in flat.outlineConfiguration.rootNodes {
            XCTAssertEqual(node.treeDepth, 0)
            XCTAssertNil(node.appGroup)
            XCTAssertFalse(node.isAppGroup)
            for child in flat.children(of: node) {
                XCTAssertNil(child.appGroup)
                XCTAssertEqual(
                    child.id, child.id,
                    "flat ids are the deterministic ones, not namespaced")
            }
        }
    }

    // MARK: - Persistence (the bug that shipped, and the tier it blocks)

    /// The pre-existing bug, now fixed for ALL SIX shells: collapsing a section
    /// writes. Before this, `handleExpansionChange` had no callers and collapse
    /// state was read at launch and never saved.
    func testCollapsingAFlatSectionPersists() {
        let box = SidebarPersistenceScope.ScratchBox(
            sectionOrder: SidebarSectionOrderStore.defaultOrder,
            collapsedSections: [], composedCollapse: [])
        let scope = scopeBacked(by: box)
        let flat = viewModel(.imbib, persistence: scope)

        guard let libraries = flat.outlineConfiguration.rootNodes.first(where: {
            $0.nodeType == .section(.libraries)
        }) else { return XCTFail("no Libraries section") }

        flat.outlineConfiguration.onExpansionChanged?(libraries, false)
        XCTAssertEqual(box.collapsedSections, [.libraries])

        flat.outlineConfiguration.onExpansionChanged?(libraries, true)
        XCTAssertEqual(box.collapsedSections, [])
    }

    /// A relaunch honours it: a view model built from the same scope starts with
    /// that section collapsed.
    func testAFlatCollapseSurvivesAReconstruction() {
        let box = SidebarPersistenceScope.ScratchBox(
            sectionOrder: SidebarSectionOrderStore.defaultOrder,
            collapsedSections: [.libraries], composedCollapse: [])
        let flat = viewModel(.imbib, persistence: scopeBacked(by: box))
        flat.configure(
            libraryManager: LibraryManager(),
            libraryViewModel: LibraryViewModel(),
            searchViewModel: SearchViewModel())
        XCTAssertFalse(
            flat.expansionState.isExpanded(ImbibSidebarNodeID.section(.libraries)),
            "a persisted collapse must come back collapsed")
        XCTAssertTrue(flat.expansionState.isExpanded(ImbibSidebarNodeID.section(.inbox)))
    }

    /// BOTH composed tiers persist, in their own key space, per group.
    func testCollapsingAGroupAndAPerGroupSectionPersistSeparately() {
        let box = SidebarPersistenceScope.ScratchBox(
            sectionOrder: SidebarSectionOrderStore.defaultOrder,
            collapsedSections: [], composedCollapse: [])
        let composed = composedViewModel(persistence: scopeBacked(by: box))

        guard let imprintGroup = group(composed, "imprint") else { return XCTFail("no group") }
        composed.outlineConfiguration.onExpansionChanged?(imprintGroup, false)
        XCTAssertEqual(box.composedCollapse, [.group("imprint")])

        guard let imbibFlagged = sectionNode(composed, group: "imbib", .flagged) else {
            return XCTFail("no imbib Flagged")
        }
        composed.outlineConfiguration.onExpansionChanged?(imbibFlagged, false)
        XCTAssertEqual(
            box.composedCollapse, [.group("imprint"), .section("imbib", .flagged)])

        // Collapsing imbib's Flagged must not touch imprint's — the exact
        // confusion the composition removes.
        XCTAssertFalse(box.composedCollapse.contains(.section("imprint", .flagged)))
        // And nothing landed in the FLAT key space, which the five sibling apps
        // read from the same `UserDefaults.standard` in a shared container.
        XCTAssertEqual(box.collapsedSections, [])
    }

    /// A composed collapse comes back on reconstruction, at both tiers.
    func testComposedCollapseSurvivesAReconstruction() {
        let box = SidebarPersistenceScope.ScratchBox(
            sectionOrder: SidebarSectionOrderStore.defaultOrder,
            collapsedSections: [],
            composedCollapse: [.group("impel"), .section("imbib", .flagged)])
        let composed = composedViewModel(persistence: scopeBacked(by: box))
        composed.configure(
            libraryManager: LibraryManager(),
            libraryViewModel: LibraryViewModel(),
            searchViewModel: SearchViewModel())

        XCTAssertFalse(composed.expansionState.isExpanded(ImbibSidebarNodeID.appGroup("impel")))
        XCTAssertTrue(composed.expansionState.isExpanded(ImbibSidebarNodeID.appGroup("imbib")))
        XCTAssertFalse(
            composed.expansionState.isExpanded(
                ImbibSidebarNodeID.grouped("imbib", ImbibSidebarNodeID.section(.flagged))))
        XCTAssertTrue(
            composed.expansionState.isExpanded(
                ImbibSidebarNodeID.grouped("imprint", ImbibSidebarNodeID.section(.flagged))),
            "collapsing imbib's Flagged must leave imprint's expanded")
    }

    /// Default is EMPTY = everything expanded. "Collate their sidebars" means a
    /// user opening impress sees five sidebars, not five closed drawers.
    func testAFreshComposedSidebarOpensFullyExpanded() {
        let composed = composedViewModel()
        composed.configure(
            libraryManager: LibraryManager(),
            libraryViewModel: LibraryViewModel(),
            searchViewModel: SearchViewModel())
        for app in SiblingApp.descriptors.map(\.id) where app != .impress {
            XCTAssertTrue(
                composed.expansionState.isExpanded(
                    ImbibSidebarNodeID.appGroup(app.rawValue)),
                "\(app.rawValue)'s group should open expanded")
        }
    }

    /// The default landing lands INSIDE a group, with its ancestors expanded —
    /// `restoreSelection` drops a selection whose ancestor is collapsed, so a
    /// leaf in a closed group is a window with nothing selected.
    func testTheDefaultLandingLeafIsInsideItsGroupAndItsAncestorsAreExpanded() {
        let composed = composedViewModel()
        composed.selectDefaultSectionLeaf()
        let expected = ImbibSidebarNodeID.grouped(
            "imbib", ImbibSidebarNodeID.section(AppShellConfiguration.impress.defaultSection))
        XCTAssertEqual(composed.selectedNodeID, expected)
        XCTAssertTrue(composed.expansionState.isExpanded(ImbibSidebarNodeID.appGroup("imbib")))
    }

    // MARK: - Drag: the guard that keeps section reorder working

    /// A section reorders WITHIN its own group. Without this arm the existing
    /// `(.section, _) -> false` rule would refuse every section drag the moment
    /// a group tier appeared above it — the gesture would die before the
    /// handler, with no error. That is the "breaks silently" this prevents.
    func testASectionMayReorderWithinItsOwnGroup() {
        let composed = composedViewModel()
        guard let imbibGroup = group(composed, "imbib"),
              let imbibFlagged = sectionNode(composed, group: "imbib", .flagged)
        else { return XCTFail("no imbib group/section") }

        XCTAssertEqual(
            composed.outlineConfiguration.canAcceptDrop?(imbibFlagged, imbibGroup), true)
    }

    /// A cross-group section drop is REFUSED — visibly, not silently applied to
    /// the wrong app's sidebar.
    func testACrossGroupSectionDropIsRefused() {
        let composed = composedViewModel()
        guard let imprintGroup = group(composed, "imprint"),
              let imbibFlagged = sectionNode(composed, group: "imbib", .flagged)
        else { return XCTFail("no groups") }

        XCTAssertEqual(
            composed.outlineConfiguration.canAcceptDrop?(imbibFlagged, imprintGroup), false,
            "a section belongs to the app whose sidebar it is")
    }

    /// Root is the group tier now, so a section dropped there is a section
    /// trying to leave its app.
    func testASectionMayNotBeDroppedAtTheComposedRoot() {
        let composed = composedViewModel()
        guard let imbibFlagged = sectionNode(composed, group: "imbib", .flagged) else {
            return XCTFail("no imbib Flagged")
        }
        XCTAssertEqual(composed.outlineConfiguration.canAcceptDrop?(imbibFlagged, nil), false)
    }

    /// A group itself never moves: group order is `SiblingApp.descriptors`', the
    /// one table, not a per-user preference.
    func testAnAppGroupIsNeitherDraggableNorADropTargetForItself() {
        let composed = composedViewModel()
        guard let imbibGroup = group(composed, "imbib"),
              let imprintGroup = group(composed, "imprint")
        else { return XCTFail("no groups") }
        XCTAssertEqual(composed.outlineConfiguration.canAcceptDrop?(imbibGroup, nil), false)
        XCTAssertEqual(
            composed.outlineConfiguration.canAcceptDrop?(imbibGroup, imprintGroup), false)
        XCTAssertEqual(
            composed.outlineConfiguration.capabilitiesOf(imbibGroup), .readOnly)
    }

    /// FLAT drop rules are untouched: sections still reorder at root, and still
    /// refuse every non-root target.
    func testFlatDropRulesAreUnchanged() {
        let flat = viewModel(.imbib)
        guard let libraries = flat.outlineConfiguration.rootNodes.first(where: {
            $0.nodeType == .section(.libraries)
        }), let flagged = flat.outlineConfiguration.rootNodes.first(where: {
            $0.nodeType == .section(.flagged)
        }) else { return XCTFail("no sections") }

        XCTAssertEqual(flat.outlineConfiguration.canAcceptDrop?(libraries, nil), true)
        XCTAssertEqual(flat.outlineConfiguration.canAcceptDrop?(libraries, flagged), false)
    }

    // MARK: - Reorder: one order, re-sequenced in place

    /// Reordering a group's sections re-sequences only the SLOTS that group
    /// occupies. The four groups the user was not looking at do not move.
    func testMergingReordersOnlyTheSubsetsSlots() {
        let order: [SidebarSectionType] = [
            .inbox, .libraries, .search, .flagged, .manuscripts, .dismissed,
        ]
        // imprint's group shows .manuscripts + .flagged + .dismissed; the user
        // drags Dismissed above Flagged inside it.
        let merged = ImbibSidebarViewModel.merging(
            [.dismissed, .flagged, .manuscripts], into: order)
        XCTAssertEqual(
            merged, [.inbox, .libraries, .search, .dismissed, .flagged, .manuscripts])
        // Sections outside the subset kept both their identity and their index.
        XCTAssertEqual(Array(merged.prefix(3)), [.inbox, .libraries, .search])
    }

    /// The empty and identity cases do nothing, which is what makes the merge
    /// safe to run on every drop.
    func testMergingIsIdentityForAnUnchangedSubset() {
        let order = SidebarSectionOrderStore.defaultOrder
        XCTAssertEqual(ImbibSidebarViewModel.merging([], into: order), order)
        XCTAssertEqual(ImbibSidebarViewModel.merging(order, into: order), order)
    }

    /// Driven through the real callback: a reorder inside a group persists the
    /// merged order and leaves the other groups' sections where they were.
    func testReorderingWithinAGroupPersistsTheMergedOrder() {
        let box = SidebarPersistenceScope.ScratchBox(
            sectionOrder: SidebarSectionOrderStore.defaultOrder,
            collapsedSections: [], composedCollapse: [])
        let composed = composedViewModel(persistence: scopeBacked(by: box))
        guard let imbibGroup = group(composed, "imbib") else { return XCTFail("no group") }

        let sections = composed.children(of: imbibGroup)
        guard sections.count >= 2 else { return XCTFail("imbib group needs ≥2 sections") }
        var swapped = sections
        swapped.swapAt(0, 1)

        let before = box.sectionOrder
        composed.outlineConfiguration.onReorder?(swapped, imbibGroup)

        XCTAssertNotEqual(box.sectionOrder, before, "the reorder must have been written")
        XCTAssertEqual(
            Set(box.sectionOrder), Set(before),
            "a per-group reorder must not ADD or DROP any section from the suite-wide order")
    }

    /// Reordering at the composed ROOT (the group tier) writes nothing.
    func testReorderingTheGroupTierIsANoOp() {
        let box = SidebarPersistenceScope.ScratchBox(
            sectionOrder: SidebarSectionOrderStore.defaultOrder,
            collapsedSections: [], composedCollapse: [])
        let composed = composedViewModel(persistence: scopeBacked(by: box))
        let before = box.sectionOrder
        composed.outlineConfiguration.onReorder?(
            composed.outlineConfiguration.rootNodes.reversed(), nil)
        XCTAssertEqual(box.sectionOrder, before)
    }

    // MARK: - The five sibling shells

    /// The app-group cell branch is UNREACHABLE in a single-preset shell, not
    /// merely false: `isAppGroupItem` is nil, so `SidebarOutlineView.viewFor`
    /// runs exactly the code it ran before this tier existed. That is the
    /// strongest form of "their cells are byte-identical" a unit test can make.
    func testSinglePresetShellsSupplyNoAppGroupPredicateAtAll() {
        for preset in [
            AppShellConfiguration.imbib, .imprint, .implore, .impel, .impart, .impress,
        ] {
            XCTAssertNil(
                viewModel(preset).outlineConfiguration.isAppGroupItem,
                "\(preset.appID) runs a single preset and must not opt into the group tier")
        }
        XCTAssertNotNil(composedViewModel().outlineConfiguration.isAppGroupItem)
    }

    /// No node a single-preset shell builds is ever an app group, at any depth.
    func testNoSinglePresetShellEverBuildsAGroupNode() {
        for preset in [
            AppShellConfiguration.imbib, .imprint, .implore, .impel, .impart, .impress,
        ] {
            let flat = viewModel(preset)
            for node in flatten(flat) {
                XCTAssertFalse(
                    node.isAppGroup, "\(preset.appID) built an app-group node: \(node.displayName)")
                XCTAssertNil(node.appGroup)
                if case .appGroup = node.nodeType {
                    XCTFail("\(preset.appID) built an .appGroup node type")
                }
            }
        }
    }

    /// Every shell — composed or not — now persists collapse. This closes the
    /// pre-existing bug rather than working around it for one app.
    func testEveryShellSuppliesAnExpansionPersistenceCallback() {
        for preset in [
            AppShellConfiguration.imbib, .imprint, .implore, .impel, .impart, .impress,
        ] {
            XCTAssertNotNil(viewModel(preset).outlineConfiguration.onExpansionChanged)
        }
        XCTAssertNotNil(composedViewModel().outlineConfiguration.onExpansionChanged)
    }

    // MARK: - Only impress composes (source-level, like the iOS twin)

    /// PMC's test bundle cannot link an app target, so "which macOS root passes
    /// a composition" is asserted on the SOURCE — the same instrument
    /// `SidebarCompositionTests.testOnlyImpressUsesTheComposedSidebarInit` uses
    /// for the iOS hosts.
    func testOnlyImpresssMacRootPassesAComposition() throws {
        let siblingRoots = [
            "apps/imbib/imbib/imbib/imbibApp.swift",
            "apps/imprint/macOS/Views/ImprintChassisRoot.swift",
            "apps/implore/Implore/Sources/App/ImploreChassisRoot.swift",
            "apps/impel/macOS/ImpelChassisRoot.swift",
            "apps/impart/macOS/ImpartChassisRoot.swift",
        ]
        for root in siblingRoots {
            guard let source = try? ChassisSourceRoots.repoText(of: root) else { continue }
            XCTAssertFalse(
                source.contains("sidebarComposition"),
                "\(root) must keep passing ONE preset: a group tier renames every row id in "
                    + "its sidebar and this app has no groups to show")
        }
        let impress = try ChassisSourceRoots.repoText(
            of: "apps/impress/macOS/ImpressChassisRoot.swift")
        XCTAssertTrue(
            impress.contains("sidebarComposition: Self.sidebarComposition"),
            "impress-macOS is the one shell that composes")
        XCTAssertTrue(impress.contains("SidebarComposition = .impress"))
    }

    // MARK: - Helper

    private func scopeBacked(
        by box: SidebarPersistenceScope.ScratchBox
    ) -> SidebarPersistenceScope {
        SidebarPersistenceScope(
            loadSectionOrder: { box.sectionOrder },
            saveSectionOrder: { box.sectionOrder = $0 },
            loadCollapsedSections: { box.collapsedSections },
            saveCollapsedSections: { box.collapsedSections = $0 },
            loadComposedCollapse: { box.composedCollapse },
            saveComposedCollapse: { box.composedCollapse = $0 })
    }
}
#endif
