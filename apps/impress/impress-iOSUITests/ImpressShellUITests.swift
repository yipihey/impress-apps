//
//  ImpressShellUITests.swift
//  impress-iOSUITests
//
//  The regression oracle for impress-iOS.
//
//  I3 CHANGED WHAT THIS SUITE IS ABOUT. The sidebar is no longer one flat list
//  built from `AppShellConfiguration.impress`; it is a `SidebarComposition` —
//  five collapsible GROUPS, one per sibling app, each rendering that app's own
//  preset (`.imbib`, `.imprint`, `.implore`, `.impel`, `.impart`) narrowed by
//  `presenting([.message, .figure, .task, .publication, .manuscript])`.
//
//  The user's report is the specification:
//
//    "It's quite hit and miss with impress. Libraries and collections and the
//     Inbox is for imbib. Imprint has its own collections for manuscripts.
//     Impart has its own for messages and all have flagged pubs, manuscripts or
//     messages."
//
//  Three of those clauses are `testTheSidebarCollatesEachAppsOwnSidebar`. The
//  fourth — "ALL have flagged pubs, manuscripts or messages" — is
//  `testFlaggedIsPerGroupAndListsThatGroupsOwnKind`, and it is the one the flat
//  sidebar could not have passed: `sectionBindings` maps a section to ONE kind,
//  so a union of five presets has a single Flagged bound to `.publication` and
//  flagged manuscripts have no row at all.
//
//  PORTRAIT on iPhone (I2's finding, and I3 made it matter more): a lazy `List`
//  only instantiates what fits, and the composed sidebar is roughly half again
//  as tall as the flat one. Landscape's 402-point list would leave most of the
//  contract unreachable.
//
//  GROUP COLLAPSE IS ALSO A TEST INSTRUMENT. `focusGroup(_:)` closes the other
//  four before walking one app's rows, which is both far faster than sweeping
//  a 45-row sidebar per assertion and an exercise of the affordance in every
//  test. It is safe to leave state behind because the seed clears
//  `sidebarCompositionCollapsed` on every seeded launch — see
//  `ImpressIOSUITestSeed`.
//

import XCTest

final class ImpressShellUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = IOSTestApp.launchSeeded()
    }

    override func tearDown() {
        app?.terminate()
        app = nil
    }

    // MARK: - The composition: each app's sidebar, under that app's name

    func testTheSidebarCollatesEachAppsOwnSidebar() {
        // ONE pass over the whole sidebar, collecting every identifier it
        // renders. A SwiftUI `List` releases off-screen rows, so `exists` on a
        // row below the fold is false for a reason that has nothing to do with
        // the contract under test, and a per-identifier scroll would leave the
        // list at the bottom before the next check. Collecting once and
        // asserting against the SET is the only form of this test that cannot
        // pass or fail for a scroll-position reason.
        let sidebar = allSidebarIdentifiers()
        capture("sidebar")

        // 1. FIVE GROUPS, all present. This is "collate each of their
        //    sidebars" in its most literal form.
        for group in ImpressA11y.allGroups {
            XCTAssertTrue(
                sidebar.contains(group),
                "\(group) must be present: a composition is the five sidebars, and an app "
                    + "with nothing in it today is a fact about the store, not a reason to "
                    + "hide the app")
        }

        // 2. Each app's own rows, under that app. Asserted on the selectable
        //    NODE rather than the section header: a node is what a user can
        //    actually reach, and a 20-point header can park behind the
        //    navigation bar between two steps of a sweep (I2's finding).
        for present in [
            // "Libraries and collections and the Inbox is for imbib"
            ImpressA11y.inboxNode,
            ImpressA11y.redFlaggedPapersNode,
            ImpressA11y.dismissedNode,
            // "Imprint has its own collections for manuscripts"
            ImpressA11y.allManuscriptsNode,
            ImpressA11y.redFlaggedManuscriptsNode,
            ImpressA11y.dismissedManuscriptsNode,
            // "Impart has its own for messages"
            ImpressA11y.allMessagesNode,
            // implore and impel round out the five
            ImpressA11y.allFiguresNode,
            ImpressA11y.allTasksNode,
        ] {
            XCTAssertTrue(
                sidebar.contains(present),
                "\(present) is declared by its group's preset, its kind is presentable and "
                    + "this host has rows for it")
        }

        // 3. The LIBRARY row is host-supplied and lives in the imbib group —
        //    libraries sit above the collection tree, which is the case
        //    `RecordSidebarSectionContent` exists for.
        XCTAssertTrue(
            sidebar.contains { $0.hasPrefix(ImpressA11y.libraryNodePrefix) },
            "the seeded library should render as a host node inside the imbib group")

        // 4. A section TWO apps declare renders in BOTH groups. Duplication is
        //    the design, not a leak: the user asked for each app's sidebar
        //    verbatim, and an imbib user looking for Cited in Manuscripts
        //    should find it under imbib.
        XCTAssertTrue(sidebar.contains(ImpressA11y.imbibCitedNode))
        XCTAssertTrue(sidebar.contains(ImpressA11y.imprintCitedNode))

        // 5. DECLARED ABSENT, not empty — and now attributed to the group whose
        //    preset declares them. Search is imbib's section, so its absence is
        //    a statement about impress-iOS's imbib group and nowhere else.
        for absent in ImpressA11y.declaredAbsentSections {
            XCTAssertFalse(
                sidebar.contains(absent),
                "\(absent) is gated off for this host and must be absent, never an empty "
                    + "section")
        }

        // 6. NO UNQUALIFIED row survives. If one did, the composition would be
        //    rendering a row outside any group — which is exactly the flat
        //    sidebar the user reported, hiding inside the grouped one.
        let ungrouped = sidebar.filter { id in
            guard let prefix = ["sidebar.node.", "sidebar.section.", "sidebar.sectionSelect."]
                .first(where: { id.hasPrefix($0) })
            else { return false }
            let rest = id.dropFirst(prefix.count)
            return !ImpressA11y.appIDs.contains { rest.hasPrefix("\($0).") }
        }
        XCTAssertTrue(
            ungrouped.isEmpty,
            "every row in a composed sidebar belongs to an app group; found \(ungrouped)")
    }

    // MARK: - THE regression: Flagged is per group, and scoped to that kind

    /// "all have flagged pubs, manuscripts or messages."
    ///
    /// Two rows, same section type, same colour, different owning app — and
    /// they must land on DIFFERENT lists of DIFFERENT records. This is the
    /// exact behaviour a single `sectionBindings[.flagged]` cannot express, and
    /// therefore the exact "hit and miss" the composition removes.
    func testFlaggedIsPerGroupAndListsThatGroupsOwnKind() {
        let any = app.descendants(matching: .any)

        // imprint's Flagged → MANUSCRIPTS. The seed red-flags exactly one
        // manuscript, so this is proven by content and not just by a list id.
        focusGroup(ImpressA11y.imprintGroup)
        let openedManuscripts = select(
            ImpressA11y.redFlaggedManuscriptsNode, expecting: ImpressA11y.manuscriptList)
        // Capture BEFORE asserting: `continueAfterFailure` is off, so on a
        // failure this screenshot is the only thing that says whether the row
        // routed to the wrong list or to an empty one (imbib's detail-tab
        // suite's rule).
        capture("flagged-imprint-manuscripts")
        XCTAssertTrue(
            openedManuscripts,
            "the imprint group's red flag row must open a MANUSCRIPT list — "
                + "`AppShellConfiguration.imprint` binds .flagged to .manuscript")
        XCTAssertTrue(
            app.staticTexts[ImpressSeed.manuscriptTitle].waitForExistence(timeout: 15),
            "the red-flagged manuscript should be its row")
        XCTAssertEqual(
            any.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "publicationRow.")).count, 0,
            "no publication may appear in the imprint group's Flagged list")

        // imbib's Flagged → PUBLICATIONS. Same gesture, same colour, other app.
        // imbib's header is the FIRST row of the sidebar, so re-opening it is
        // one tap at the top with nothing to scroll past.
        returnToSidebar(anchor: ImpressA11y.imbibGroup)
        toggleGroup(ImpressA11y.imbibGroup)
        XCTAssertTrue(
            select(ImpressA11y.redFlaggedPapersNode, expecting: ImpressA11y.publicationList),
            "the imbib group's red flag row must open a PUBLICATION list — "
                + "`AppShellConfiguration.imbib` binds .flagged to .publication")
        let papers = any.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "publicationRow."))
        XCTAssertGreaterThan(papers.count, 0, "the red-flagged paper should be its row")
        XCTAssertEqual(
            any.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "manuscriptRow.")).count, 0,
            "no manuscript may appear in the imbib group's Flagged list")
        capture("flagged-imbib-publications")
    }

    // MARK: - Groups collapse and expand

    func testCollapsingAGroupHidesItsSectionsAndExpandingRestoresThem() {
        let any = app.descendants(matching: .any)

        // imbib is the first group, so its rows are on screen at launch.
        let inbox = reveal(ImpressA11y.inboxNode)
        XCTAssertTrue(inbox.exists, "the imbib group starts EXPANDED")
        capture("groups-expanded")

        let header = reveal(ImpressA11y.imbibGroup)
        XCTAssertTrue(header.exists, "the imbib group header is the collapse target")
        XCTAssertEqual(
            header.value as? String, ImpressA11y.expanded,
            "a disclosure header must PUBLISH its state — VoiceOver announces it, and it is "
                + "the only read of open/closed that does not depend on scroll position")
        setDisclosure(header, to: ImpressA11y.collapsed, named: "the imbib group")

        // Its rows go; the other groups' rows stay. Collapsing is per group,
        // which is the affordance the user asked for ("collapsible sections").
        XCTAssertTrue(
            any[ImpressA11y.inboxNode].waitForNonExistence(timeout: 10),
            "collapsing imbib must hide imbib's rows")
        XCTAssertFalse(
            any[ImpressA11y.redFlaggedPapersNode].exists,
            "…including its Flagged rows")
        XCTAssertTrue(
            any[ImpressA11y.imprintGroup].exists,
            "the other four groups are untouched")
        XCTAssertEqual(
            any[ImpressA11y.imprintGroup].value as? String, ImpressA11y.expanded,
            "…including their disclosure state")
        XCTAssertTrue(
            reveal(ImpressA11y.redFlaggedManuscriptsNode, attempts: 6).exists,
            "imprint's OWN Flagged section must survive imbib's collapse — the two are "
                + "separately keyed (`SidebarCompositionKey.section(group:section:)`), which "
                + "is why the same section type in two groups does not collapse together")
        capture("groups-imbib-collapsed")

        // And back.
        setDisclosure(
            reveal(ImpressA11y.imbibGroup), to: ImpressA11y.expanded,
            named: "the imbib group")
        XCTAssertTrue(
            reveal(ImpressA11y.inboxNode, attempts: 6).exists,
            "expanding restores the group's rows")
    }

    /// Drive a disclosure header to `target`, using its PUBLISHED state as the
    /// oracle.
    ///
    /// The retry WAITS before deciding the tap missed, and that ordering is the
    /// whole point. `XCUIElement.value` is read from a snapshot, so immediately
    /// after a tap it can still report the old state while the collapse
    /// animation runs — a retry that fires on that reading taps a second time
    /// and puts the header back where it started, which is exactly how the
    /// first version of this helper turned a passing collapse into
    /// "expanded ≠ collapsed". So: tap once, wait for the state to become
    /// `target`, and only tap again if the wait genuinely timed out.
    @discardableResult
    private func setDisclosure(
        _ header: XCUIElement, to target: String, named name: String
    ) -> Bool {
        if header.value as? String == target { return true }
        header.tap()
        if waitForValue(header, target) { return true }
        header.tap()
        let settled = waitForValue(header, target)
        XCTAssertTrue(settled, "\(name) should report itself \(target) after the tap")
        return settled
    }

    private func waitForValue(
        _ element: XCUIElement, _ value: String, timeout: TimeInterval = 8
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// The two groups' Flagged sections are SEPARATE sections, separately
    /// keyed and separately addressable — the structural half of "all have
    /// flagged pubs, manuscripts or messages".
    ///
    /// Collapse is exercised at the GROUP level (the test above) rather than at
    /// the section level, and that is a scoping decision with a reason.
    /// Tapping a `List` section HEADER to collapse it is an affordance the
    /// chassis sidebar has always offered and that NO suite in this repo covers
    /// — not imbib-iOS's, not imprint-iOS's, not impart-iOS's. On this OS it
    /// does not take effect from a synthesized tap (the event reaches the
    /// button; the rows stay), in the composed sidebar and in the flat one
    /// alike. That is a pre-existing chassis gap recorded in
    /// docs/chassis-capability-matrix.md, not something the composition
    /// introduced, and asserting it here would pin a behaviour I3 neither
    /// changed nor fixed. What I3 DID introduce — that the two Flagged sections
    /// are distinct, per-app, and independently keyed — is what this asserts.
    func testTheTwoGroupsFlaggedSectionsAreSeparateAndSeparatelyAddressable() {
        let sidebar = allSidebarIdentifiers()

        // Two headers, one per app, each namespaced by its group.
        XCTAssertTrue(
            sidebar.contains(ImpressA11y.imbibFlaggedSection),
            "imbib declares Flagged, so the imbib group has one")
        XCTAssertTrue(
            sidebar.contains(ImpressA11y.imprintFlaggedSection),
            "imprint declares Flagged too, so the imprint group has its own")

        // Two Dismissed sections likewise — and theirs differ in SEMANTICS as
        // well as kind (library move vs status change), which is visible in the
        // scope each one's row carries.
        XCTAssertTrue(sidebar.contains(ImpressA11y.imbibDismissedSection))
        XCTAssertTrue(sidebar.contains(ImpressA11y.imprintDismissedSection))
        XCTAssertTrue(sidebar.contains(ImpressA11y.dismissedNode))
        XCTAssertTrue(sidebar.contains(ImpressA11y.dismissedManuscriptsNode))

        // Collapsing the imbib GROUP takes imbib's Flagged with it and leaves
        // imprint's — the independence claim, exercised through the affordance
        // that works.
        // Back to the TOP first. `allSidebarIdentifiers()` above sweeps to the
        // bottom, and `reveal` only ever swipes UP (a downward swipe at the top
        // is pull-to-refresh), so imbib's header — the FIRST row — is otherwise
        // unreachable from here. Same trap `focusGroup` documents.
        scrollSidebarToTop()
        let imbibGroup = reveal(ImpressA11y.imbibGroup)
        imbibGroup.tap()
        // SETTLE before resolving anything: the collapse animates the whole
        // list, and `XCTNSPredicateExpectation` polling an element's `value`
        // through that raises "Failed to get matching snapshot" for a row that
        // moved between the snapshot and the read — the real-store suite hit
        // the same thing mid-scroll and solves it the same way. `tap` +
        // settle + `waitForNonExistence` needs no snapshot of a moving row.
        Thread.sleep(forTimeInterval: 1.0)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(
            any[ImpressA11y.imbibFlaggedSection].waitForNonExistence(timeout: 10),
            "imbib's Flagged section goes with imbib")
        XCTAssertTrue(
            reveal(ImpressA11y.imprintFlaggedSection, attempts: 8).exists,
            "imprint's Flagged section is a different section under a different app "
                + "and must be untouched")
        capture("section-independence-across-groups")
    }

    // MARK: - Mail: list + the shared chassis detail pane

    func testSelectingAMailMessageShowsTheChassisDetailPane() {
        let any = app.descendants(matching: .any)
        focusGroup(ImpressA11y.impartGroup)
        XCTAssertTrue(
            select(ImpressA11y.allMessagesNode, expecting: ImpressA11y.messageList),
            "RecordListHost should render the mail list")
        let rows = any.matching(NSPredicate(format: "identifier BEGINSWITH %@", "messageRow."))
        XCTAssertGreaterThan(rows.count, 0, "seeded inbox messages should render as rows")
        capture("mail-list")

        let starred = app.staticTexts[ImpressSeed.starredSubject]
        XCTAssertTrue(starred.waitForExistence(timeout: 15))
        starred.tap()

        XCTAssertTrue(
            any[ImpressA11y.messageDetail].waitForExistence(timeout: 20),
            "MessageDetailPane — the SHARED pane, unchanged — should fill the detail column")
        // The Info tab's rows come from the descriptor's declared tabs.
        XCTAssertTrue(app.staticTexts["From"].waitForExistence(timeout: 15))
        capture("mail-detail")
    }

    // MARK: - The mixed-kind claim: three kinds, one shell

    func testFiguresAndTasksRenderThroughTheirNewlyCrossPlatformChassisPanes() {
        let any = app.descendants(matching: .any)

        focusGroup(ImpressA11y.imploreGroup)
        XCTAssertTrue(
            select(ImpressA11y.allFiguresNode, expecting: ImpressA11y.figureList),
            "the implore group's Figures list should render")
        capture("figure-list")
        let figure = app.staticTexts[ImpressSeed.figureTitle]
        XCTAssertTrue(figure.waitForExistence(timeout: 15))
        figure.tap()
        XCTAssertTrue(
            any[ImpressA11y.figureDetail].waitForExistence(timeout: 20),
            "FigureDetailPane was macOS-only until D9 un-gated it; this is the proof it runs")
        capture("figure-detail")

        // Back to the sidebar before the next kind. On a phone the split view
        // is a STACK: tapping a row PUSHED the figure detail, so the sidebar is
        // two pops away and its rows are not in the accessibility tree until
        // they are back on screen.
        returnToSidebar(anchor: ImpressA11y.imploreGroup)
        // implore is still the only open group, so impel's header sits just
        // below implore's rows — one tap re-opens it.
        toggleGroup(ImpressA11y.impelGroup)
        XCTAssertTrue(
            select(ImpressA11y.allTasksNode, expecting: ImpressA11y.taskList),
            "the impel group's Agents (Tasks) list should render")
        let task = app.staticTexts[ImpressSeed.taskTitle]
        XCTAssertTrue(task.waitForExistence(timeout: 15))
        task.tap()
        XCTAssertTrue(
            any[ImpressA11y.taskDetail].waitForExistence(timeout: 20),
            "AgentRecordDetailPane, likewise")
        capture("task-detail")
    }

    // MARK: - Publications: the LIFTED pane (I2 gap 1), now in the imbib group

    /// The user's earlier report, as a test: "none of the ones we have multiple
    /// entries like publications and manuscripts". This walks the imbib group →
    /// a library → a paper → every tab the publication descriptor declares.
    func testSelectingAPaperShowsTheLiftedChassisDetailPaneWithEveryDescriptorTab() {
        let any = app.descendants(matching: .any)
        focusGroup(ImpressA11y.imbibGroup)
        let library = revealLibraryNode()
        XCTAssertTrue(library.exists, "the seeded library row, inside the imbib group")
        library.tap()
        if !any[ImpressA11y.publicationList].waitForExistence(timeout: 15) {
            library.tap()
        }
        let openedPapers = any[ImpressA11y.publicationList].waitForExistence(timeout: 15)
        capture("publication-list-open")
        XCTAssertTrue(
            openedPapers,
            "IOSPublicationListPane — RecordListHost over PublicationListCore")
        let rows = any.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "publicationRow."))
        XCTAssertGreaterThan(rows.count, 0, "the two imported BibTeX entries should be rows")
        capture("publication-list")

        let paper = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", ImpressSeed.publicationTitleFragment)
        ).firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 15))
        paper.tap()

        XCTAssertTrue(
            any[ImpressA11y.publicationDetail].waitForExistence(timeout: 20),
            "IOSPublicationDetailPane should fill the detail column")

        // Info / PDF / Notes / BibTeX — the tab set comes from
        // `PublicationRecordKind.descriptor`, so this asserts the DECLARATION
        // renders, not four hardcoded tabs.
        XCTAssertTrue(
            any[ImpressA11y.DetailTabs.info].waitForExistence(timeout: 15),
            "the Info tab pane should render")
        capture("publication-info")

        selectTab("PDF")
        XCTAssertTrue(
            any[ImpressA11y.DetailTabs.pdf].waitForExistence(timeout: 15),
            "the PDF tab should render its honest offline state, not a blank pane")
        capture("publication-pdf")

        // BibTeX is PMC's `BibTeXTab` — the very same view macOS renders. It is
        // asserted by CONTENT rather than by the tab identifier: the tab wraps a
        // syntax-highlighted editor that publishes its own accessibility
        // container, so the wrapper's identifier is not reliably queryable
        // (imbib's detail-tab suite anchors on the entry text for the same
        // reason). The `@` and the Copy button are what a user sees.
        selectTab("BibTeX")
        // Capture BEFORE asserting: when this fails, the screenshot is the only
        // thing that says whether the pane rendered the wrong state or nothing
        // (imbib's detail-tab suite's rule, and `continueAfterFailure` is off).
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "@"))
            .firstMatch.waitForExistence(timeout: 15)
        capture("publication-bibtex")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "@"))
                .firstMatch.exists
                || app.buttons["Copy"].exists
                || app.buttons["Edit"].exists,
            "the shared BibTeXTab should show the imported entry")

        // Notes binds the shared `PublicationNotesDocument`'s freeform half
        // through `IOSNotesEditorView`, a UITextView wrapper.
        selectTab("Notes")
        XCTAssertTrue(
            app.textViews.firstMatch.waitForExistence(timeout: 15),
            "the Notes tab should show an editor")
        capture("publication-notes")

        // The Explore row is gated on a `LibraryManager` this shell does not
        // inject — DECLARED absent, and the assertion is what keeps it declared
        // rather than accidentally working against imbib's exploration library.
        selectTab("Info")
        XCTAssertFalse(
            app.staticTexts["Explore"].exists,
            "impress injects no LibraryManager, so the Explore row must not render")
    }

    // MARK: - Manuscripts: the read-only pane (I2 gap 2), now in the imprint group

    func testSelectingAManuscriptShowsTheReadOnlyChassisPane() {
        let any = app.descendants(matching: .any)
        focusGroup(ImpressA11y.imprintGroup)
        XCTAssertTrue(
            select(ImpressA11y.allManuscriptsNode, expecting: ImpressA11y.manuscriptList),
            "the imprint group's Manuscripts list should render over ManuscriptRowData")
        let rows = any.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "manuscriptRow."))
        XCTAssertGreaterThan(rows.count, 0, "the seeded manuscript should render as a row")
        capture("manuscript-list")

        let manuscript = app.staticTexts[ImpressSeed.manuscriptTitle]
        XCTAssertTrue(manuscript.waitForExistence(timeout: 15))
        manuscript.tap()

        XCTAssertTrue(
            any[ImpressA11y.manuscriptDetail].waitForExistence(timeout: 20),
            "IOSManuscriptReadOnlyPane should fill the detail column")
        XCTAssertTrue(
            any[ImpressA11y.DetailTabs.info].waitForExistence(timeout: 15),
            "the Info tab should render title/status/authors")
        capture("manuscript-info")

        // The Source tab is READ-ONLY — a selectable monospaced body, and no
        // text view to type into. `textViews` is what an editor exposes; its
        // absence is the assertion.
        selectTab("Source")
        XCTAssertTrue(
            any[ImpressA11y.DetailTabs.source].waitForExistence(timeout: 15),
            "the Source tab should render the body")
        XCTAssertEqual(
            app.textViews.count, 0,
            "the read-only pane must expose no editor: that is imprint's job")
        capture("manuscript-source")

        // The seed's manuscript is MARKDOWN, whose preview is free (no compile
        // step) — so the Preview tab renders rather than handing off.
        selectTab("Preview")
        XCTAssertTrue(
            any[ImpressA11y.DetailTabs.pdf].waitForExistence(timeout: 15),
            "markdown renders through MarkdownSourcePreview with no compiler")
        capture("manuscript-preview")

        // The handoff affordance, which is what a typst manuscript would get
        // INSTEAD of a preview.
        XCTAssertTrue(
            any[ImpressA11y.openInImprintButton].exists,
            "the pane offers the imprint handoff rather than pretending to compile")
    }

    // MARK: - Settings

    /// The gear is the ONE thing impress keeps outside the groups. It is window
    /// chrome rather than a place records live, so a "settings group" would be
    /// the flat-sidebar mistake in miniature.
    func testSettingsRendersTheAvailabilityFilteredPreset() {
        let gear = app.buttons[ImpressA11y.settingsButton]
        XCTAssertTrue(gear.waitForExistence(timeout: 30))
        gear.tap()

        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 15),
            "IOSSettingsScreen should present over `AppSettingsConfiguration.impress`")

        let any = app.descendants(matching: .any)
        XCTAssertTrue(any[ImpressA11y.settingsAppearanceRow].exists,
                      "Appearance is `.everywhere` and comes from the chassis builtin")

        // Asserted BEFORE any scrolling: a lazy List releases off-screen rows,
        // so a negative after a scroll would pass for the wrong reason.
        for macOnly in ImpressA11y.settingsMacOnlyRows {
            XCTAssertFalse(
                any[macOnly].exists,
                "\(macOnly) requires a capability iOS never grants")
        }
        capture("settings")

        any[ImpressA11y.settingsAppearanceRow].tap()
        XCTAssertTrue(
            app.navigationBars.element.waitForExistence(timeout: 15))
        capture("settings-appearance")
    }

    // MARK: - Group focus

    /// Collapse every group but one.
    ///
    /// The composed sidebar is roughly 45 rows tall on this fixture, and a walk
    /// that scrolls to a row in the fifth group re-scrolls past the first four
    /// for every assertion. Collapsing the others is what a person does, is one
    /// tap per group, and leaves the target group's rows near the top.
    ///
    /// Collapses in declaration order, which matters: each collapse shortens
    /// what is above the next header, so the fifth group's header is on screen
    /// by the time its turn comes.
    private func focusGroup(_ keep: String) {
        for group in ImpressA11y.allGroups where group != keep {
            let header = reveal(group, attempts: 12)
            guard header.exists, header.isHittable else { continue }
            header.tap()
        }
        // BACK TO THE TOP, and this is load-bearing rather than tidy. Finding
        // the fifth group's header scrolls to the BOTTOM of the sidebar, and
        // `reveal` only ever swipes UP (a downward swipe at the top of a list
        // is pull-to-refresh, not scrolling) — so a row above the current offset
        // is unreachable afterwards. It can still resolve as `exists` from a
        // stale snapshot while being off-screen, and `tap()` on an off-screen
        // row lands somewhere else: that is how the first run of this suite
        // "found" the library row and opened nothing.
        scrollSidebarToTop()
    }

    /// Return the sidebar to its first row.
    ///
    /// Swiping DOWN at the top is pull-to-refresh, which is why every search
    /// helper here refuses to do it — but returning to a known offset is
    /// exactly the case where the refresh is harmless (`refresh()` re-reads the
    /// store and re-seeds nothing) and the alternative is unreachable rows.
    private func scrollSidebarToTop() {
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 {
            if list.exists { list.swipeDown(velocity: .fast) } else { app.swipeDown(velocity: .fast) }
        }
    }

    /// Flip one group. Callers know which state they left it in — every seeded
    /// launch starts with EVERY group expanded (`ImpressIOSUITestSeed` clears
    /// the persisted collapse set), so the state is a function of the taps this
    /// test has made and nothing else.
    private func toggleGroup(_ group: String) {
        let header = reveal(group, attempts: 12)
        guard header.exists, header.isHittable else {
            return XCTFail("\(group) header should be reachable")
        }
        header.tap()
    }

    // MARK: - Revealing a sidebar row

    /// Wait for `identifier`, scrolling the sidebar DOWN until it appears.
    ///
    /// `swipeUp` and never `swipeDown`: a downward swipe at the top of the list
    /// is PULL-TO-REFRESH, not scrolling, and a bidirectional search fires a
    /// refresh per attempt (imbib's list suite's finding). The sidebar is the
    /// leading column, so the swipe is aimed at the app rather than a column
    /// query — on a compact-width device the split view is a stack and the
    /// sidebar IS the screen.
    @discardableResult
    private func reveal(_ identifier: String, attempts: Int = 12) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        if element.waitForExistence(timeout: 30) { return element }
        for _ in 0..<attempts {
            scrollSidebarDown()
            if element.exists { return element }
        }
        return element
    }

    /// Scroll the sidebar list one screen down.
    ///
    /// Aimed at the LIST, not at the application element: a swipe on the app
    /// starts at the window's centre, and on this shell that point can sit on a
    /// row whose leading/trailing swipe actions consume the gesture. Always
    /// `swipeUp` — a downward swipe at the top of the list is PULL-TO-REFRESH,
    /// not scrolling, and a bidirectional search fires one refresh per attempt
    /// (imbib's list suite's finding).
    private func scrollSidebarDown(velocity: XCUIGestureVelocity = .default) {
        let list = app.collectionViews.firstMatch
        if list.exists {
            list.swipeUp(velocity: velocity)
        } else {
            app.swipeUp(velocity: velocity)
        }
    }

    /// The seeded library's row, whose UUID `createLibrary` chooses.
    @discardableResult
    private func revealLibraryNode(attempts: Int = 12) -> XCUIElement {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", ImpressA11y.libraryNodePrefix))
        if query.firstMatch.waitForExistence(timeout: 30) { return query.firstMatch }
        for _ in 0..<attempts {
            scrollSidebarDown()
            if query.count > 0 { return query.firstMatch }
        }
        return query.firstMatch
    }

    /// Every `sidebar.*` identifier the sidebar renders, collected in one
    /// downward sweep. "Not on screen" is not "not present", and a lazy list
    /// makes the two look identical — so both the positive and the negative
    /// assertions read this SET rather than asking `exists` at whatever scroll
    /// offset they inherit.
    ///
    /// `.slow` and thirty steps rather than ten full-page swipes: a page-sized
    /// jump can carry a header from below the fold to above the navigation bar
    /// between two collections, and the row is then never seen even though it
    /// rendered. Thirty rather than I2's twenty because the composed sidebar is
    /// half again as tall — the same reasoning, applied to the new height.
    private func allSidebarIdentifiers(attempts: Int = 30) -> Set<String> {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sidebar."))
        _ = query.firstMatch.waitForExistence(timeout: 30)
        var seen = Set<String>()
        for step in 0...attempts {
            seen.formUnion(query.allElementsBoundByIndex.compactMap {
                $0.exists ? $0.identifier : nil
            })
            if step < attempts { scrollSidebarDown(velocity: .slow) }
        }
        return seen
    }

    /// Pop back to the sidebar column.
    ///
    /// Compact width collapses `NavigationSplitView` into a stack, so a test
    /// that walks two groups has to unwind the pushes between them. `anchor` is
    /// a row the caller knows is on screen once the sidebar is back — it cannot
    /// be a fixed one any more, because with four groups collapsed the row that
    /// proves "we are on the sidebar" differs per test.
    private func returnToSidebar(anchor: String, maxPops: Int = 3) {
        for _ in 0..<maxPops {
            if app.descendants(matching: .any)[anchor].exists { return }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists, back.isHittable else { return }
            back.tap()
        }
    }

    // MARK: - Selection

    /// Tap a tab-bar button by its label.
    ///
    /// The tab BAR is tried first: a SwiftUI `TabView` with
    /// `.tabBarMinimizeBehavior` puts more than one element with the tab's
    /// label in the tree, so `app.buttons[label]` raises "Multiple matching
    /// elements found" instead of tapping (imbib's detail-tab suite's finding).
    private func selectTab(_ label: String) {
        let barButton = app.tabBars.buttons[label].firstMatch
        if barButton.waitForExistence(timeout: 5), barButton.isHittable {
            barButton.tap()
            return
        }
        let fallback = app.buttons.matching(
            NSPredicate(format: "label == %@", label)
        ).allElementsBoundByIndex.first { $0.isHittable }
        fallback?.tap()
    }

    /// Tap a sidebar node and wait for its list.
    ///
    /// Retries the tap ONCE: the seed posts a structural store mutation, which
    /// bumps `dataVersion` and makes `RecordSidebarView` rebuild its rows, and a
    /// tap landing during that rebuild can hit a row that is being replaced.
    private func select(_ nodeID: String, expecting listID: String) -> Bool {
        let any = app.descendants(matching: .any)
        let node = reveal(nodeID)
        guard node.exists else { return false }
        node.tap()
        if any[listID].waitForExistence(timeout: 15) { return true }
        node.tap()
        return any[listID].waitForExistence(timeout: 15)
    }

    // MARK: - Screenshots

    /// Attach to the result bundle AND write a PNG to the runner's temp dir, so
    /// evidence can be opened without unpacking an `.xcresult`. `.keepAlways`
    /// because the default discards attachments from PASSING tests.
    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "impress-ios-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("impress-ios-\(name).png")
        try? shot.pngRepresentation.write(to: url)
        return shot
    }
}
