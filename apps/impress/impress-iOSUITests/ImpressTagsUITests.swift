//
//  ImpressTagsUITests.swift
//  impress-iOSUITests
//
//  The runtime proof for the Tags section — "every artifact should be
//  flaggable and taggable", browse half.
//
//  Three things here cannot be checked by a unit test, and all three have
//  already been wrong once:
//
//    1. THAT THE SECTION RENDERS AT ALL. `RecordSidebarBuilder` was producing
//       a correct Tags section, under six presets, with passing unit tests,
//       while `SidebarSectionOrderStore.defaultOrder` — which
//       `orderedVisibleSections` FILTERS by — did not list `.tags`. Nothing
//       drew a single row on either platform. A test that calls the builder
//       cannot see that; a test that looks at the app can.
//    2. THAT AN INTERIOR ROW SELECTS SOMETHING. `reading` is carried by no
//       record: it exists because the tree materialises ancestors, and it is
//       worth rendering only because `TagPathMatch` is descendant-inclusive.
//       Tapping it and finding BOTH papers is that decision, end to end.
//    3. THAT THE FILTER KEEPS PARENTS. Filtering a tree is not filtering a
//       list — typing "queue" must leave `reading` on screen or the match
//       under it is unreachable.
//
//  PORTRAIT, and the other four groups collapsed before each walk, for the
//  reasons `ImpressShellUITests` gives: a lazy `List` instantiates only what
//  fits, and the composed sidebar is five app groups tall.
//

import XCTest

final class ImpressTagsUITests: XCTestCase {

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

    // MARK: - The section renders, as a TREE

    func testTagsSectionRendersTheVocabularyAsATree() {
        focusGroup(ImpressA11y.imbibGroup)
        let sidebar = allSidebarIdentifiers()
        capture("tags-tree")

        XCTAssertTrue(
            sidebar.contains(ImpressA11y.imbibTagsSection),
            "the imbib group must show a Tags section: its preset permits `.tags`, the "
                + "publication kind declares `canTag`, and the seed put three paths in the "
                + "vocabulary. This is the assertion that would have failed for the whole "
                + "time `.tags` was missing from `defaultOrder`")

        for leaf in [ImpressA11y.readingQueueTagNode, ImpressA11y.readingDoneTagNode,
                     ImpressA11y.grantsTagNode] {
            XCTAssertTrue(sidebar.contains(leaf), "\(leaf) is a tag a seeded paper carries")
        }

        XCTAssertTrue(
            sidebar.contains(ImpressA11y.readingTagNode),
            "`reading` is carried by NO record — it must be materialised from its children, "
                + "or the hierarchy the user typed into their tags is not a hierarchy here")
    }

    /// The per-app binding, which Tags shares with Flagged: impart's section
    /// reads the MESSAGE vocabulary, so a publication tag must not appear in it
    /// and a message tag must.
    func testTagsAreBoundPerAppLikeFlagged() {
        focusGroup(ImpressA11y.impartGroup)
        let sidebar = allSidebarIdentifiers()

        XCTAssertTrue(
            sidebar.contains(ImpressA11y.impartTagsSection),
            "impart's group binds `.tags` to `.message` and the seed tagged a message")
        XCTAssertFalse(
            sidebar.contains(ImpressA11y.readingTagNode),
            "a PUBLICATION tag must not appear under impart: an empty `sectionBindings` "
                + "falls back to the canonical table, where `.tags` is `.publication`, and "
                + "this is the assertion that catches a preset that forgot to bind")
    }

    // MARK: - An interior row selects a real, non-empty set

    func testSelectingAnInteriorTagListsEveryDescendantsRecords() {
        focusGroup(ImpressA11y.imbibGroup)
        let parent = reveal(ImpressA11y.readingTagNode)
        XCTAssertTrue(parent.exists, "the interior tag row must be reachable")
        parent.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)[ImpressA11y.publicationList]
                .waitForExistence(timeout: 10),
            "selecting a tag row must open the publication list")
        capture("tags-interior-selection")

        // BOTH papers: one carries `reading/queue`, the other `reading/done`,
        // and NEITHER carries `reading`. Exact matching would show an empty
        // list here, which is what makes the tree decorative.
        for fragment in [ImpressSeed.publicationTitleFragment,
                         ImpressSeed.secondPublicationTitleFragment] {
            XCTAssertTrue(
                app.descendants(matching: .any).containing(
                    NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
                    .waitForExistence(timeout: 5),
                "\(fragment) is tagged under `reading/…`, so the `reading` row must list it — "
                    + "descendant-inclusive matching (`TagPathMatch`) is the whole reason an "
                    + "interior row is worth selecting")
        }
    }

    // MARK: - The filter

    func testFilteringTheTreeKeepsTheParentsOfMatchesAndDropsTheRest() {
        focusGroup(ImpressA11y.imbibGroup)
        let field = reveal(ImpressA11y.imbibTagFilterField)
        XCTAssertTrue(
            field.exists,
            "the Tags section must carry a filter field: imbib's real vocabulary is 23,916 "
                + "paths, so the tree without one is a list of everything")

        field.tap()
        field.typeText("queue")
        let filtered = allSidebarIdentifiers()
        capture("tags-filtered")

        XCTAssertTrue(
            filtered.contains(ImpressA11y.readingQueueTagNode),
            "the match itself must survive")
        XCTAssertTrue(
            filtered.contains(ImpressA11y.readingTagNode),
            "its PARENT must survive too — filtering a tree is not filtering a list, and "
                + "without the parent the match is unreachable")
        XCTAssertFalse(
            filtered.contains(ImpressA11y.readingDoneTagNode),
            "a sibling that does not match must go")
        XCTAssertFalse(
            filtered.contains(ImpressA11y.grantsTagNode),
            "an unrelated root must go")

        // And the section SURVIVES a filter that matches nothing, with its
        // field: everywhere else in this sidebar "no rows" drops the section,
        // which here would take the user's focus and text with it.
        field.tap()
        field.typeText("zzzz")
        let empty = allSidebarIdentifiers()
        XCTAssertTrue(
            empty.contains(ImpressA11y.imbibTagFilterField),
            "the field must outlive its own non-matching keystroke")
        XCTAssertFalse(empty.contains(ImpressA11y.readingTagNode))
    }

    // MARK: - Helpers
    //
    // Deliberately local rather than shared with `ImpressShellUITests`: that
    // suite's helpers are private to it, and a UI-test runner that links a
    // helper module has a build dependency this suite does not need.

    /// Every `sidebar.`-prefixed identifier the sidebar renders, collected in
    /// ONE downward pass.
    ///
    /// A SwiftUI `List` releases off-screen rows, so `exists` on a row below
    /// the fold is false for a reason that has nothing to do with the contract
    /// under test. Collecting once and asserting against the SET is the only
    /// form of these assertions that cannot pass or fail for a scroll reason.
    private func allSidebarIdentifiers(attempts: Int = 12) -> Set<String> {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sidebar."))
        _ = query.firstMatch.waitForExistence(timeout: 30)
        var seen = Set<String>()
        for step in 0...attempts {
            seen.formUnion(query.allElementsBoundByIndex.compactMap {
                $0.exists ? $0.identifier : nil
            })
            if step < attempts { scrollDown() }
        }
        scrollToTop()
        return seen
    }

    /// Scroll until `identifier` is on screen, and return it.
    private func reveal(_ identifier: String, attempts: Int = 14) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        _ = element.waitForExistence(timeout: 10)
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return element }
            scrollDown()
        }
        return element
    }

    /// Collapse every group but one. Both a speed-up over sweeping a 45-row
    /// sidebar and an exercise of the affordance; safe to leave behind because
    /// the seed clears `sidebarCompositionCollapsed` on every seeded launch.
    private func focusGroup(_ keep: String) {
        for group in ImpressA11y.allGroups where group != keep {
            let header = reveal(group)
            guard header.exists, header.isHittable else { continue }
            header.tap()
        }
        scrollToTop()
    }

    private func scrollDown() {
        let list = app.collectionViews.firstMatch
        if list.exists { list.swipeUp(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
    }

    private func scrollToTop() {
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 {
            if list.exists { list.swipeDown(velocity: .fast) } else { app.swipeDown(velocity: .fast) }
        }
    }

    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "impress-ios-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("impress-ios-\(name).png"))
        return shot
    }
}
