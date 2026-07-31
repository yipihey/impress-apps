//
//  ImpressRealStoreUITests.swift
//  impress-iOSUITests
//
//  The one suite that launches with NO arguments: the app opens the real
//  app-group `impress.sqlite` — on a developer device, the same container
//  imbib-iOS and imprint-iOS write. This is the "does impress see the whole
//  store?" check: the sidebar must render the presented sections over live
//  data (whatever the device actually holds, including zero rows), never
//  crash on a real container, and the screenshot attachment records the
//  actual counts for a human to read.
//
//  It asserts STRUCTURE, not contents: a fresh device legitimately has no
//  mail/figures/tasks. Contents are the screenshot's job.
//
//  I3: the structure is now a `SidebarComposition` — five app groups, each
//  rendering that app's own preset. So the structural contract gained a level:
//  every group must be present (a composition collates the five sidebars
//  unconditionally), and every DERIVED row must be present inside the group
//  whose preset declares it. The per-group Flagged pair is the sharpest of
//  those, because it is the row a real container is most likely to have data
//  for and the one the flat sidebar could not draw at all.
//
//  NO LAUNCH ARGUMENTS means no seed, which means this suite does NOT get the
//  seeded suite's collapse-state reset. Every group is therefore expanded here
//  only if nothing has collapsed it on this device — so this suite EXPANDS any
//  group it finds closed before asserting on that group's rows, rather than
//  assuming a launch state it has no way to establish.
//

import XCTest

final class ImpressRealStoreUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_realStore_sidebarComposesEveryAppsSidebarOverLiveData() throws {
        let app = XCUIApplication()
        // Deliberately NO launch arguments: real store, real container.
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)[ImpressA11y.imbibGroup]
                .waitForExistence(timeout: 20),
            "the composed sidebar must render over the real store")

        // Every group open before the sweep, so "not seen" can only mean "not
        // rendered" — this suite cannot know what a previous run collapsed.
        expandEveryGroup(app)

        let identifiers = sweep(app)

        // 1. FIVE GROUPS. Unconditional: a composition collates the five
        //    sidebars whatever the store holds.
        for group in ImpressA11y.allGroups {
            XCTAssertTrue(
                identifiers.contains(group),
                "\(group) must render over the real store — a group is an app's presence in "
                    + "impress, not a statement about its data")
        }

        // 2. Every DERIVED row, inside the group whose preset declares it.
        //    Derived means "from a descriptor", so these exist whatever the
        //    container holds: All Manuscripts + the declared statuses, one row
        //    per `FlagColor`, the kind's dismissal row.
        //
        //    On the reporter's own device the missing sections were exactly the
        //    kinds with the most rows, so their presence over a REAL container
        //    is what closes the report — and the two Flagged rows are the I3
        //    half of it: under the flat preset `sidebar.node.manuscript
        //    .flagged.red` did not exist in impress at all, in ANY container.
        for present in [
            ImpressA11y.allMessagesNode,
            ImpressA11y.allFiguresNode,
            ImpressA11y.allTasksNode,
            ImpressA11y.allManuscriptsNode,
            ImpressA11y.redFlaggedPapersNode,
            ImpressA11y.redFlaggedManuscriptsNode,
            ImpressA11y.dismissedNode,
            ImpressA11y.dismissedManuscriptsNode,
        ] {
            XCTAssertTrue(
                identifiers.contains(present),
                "\(present) must render over the real store")
        }

        // Inbox and Libraries are deliberately NOT asserted: their rows are the
        // HOST's (an inbox library, the user's libraries), so a container with
        // no imbib data legitimately has neither — `RecordSidebarBuilder` drops
        // a section whose node list is empty. Asserting them here would make
        // this suite pass or fail on whether a developer happens to have run
        // imbib on the device, which is the opposite of a structural contract.
        // The SEEDED suite pins them instead.

        // 3. Declared-absent sections stay absent on the real store too — the
        //    presentableKinds and content gates are data-independent.
        for absent in ImpressA11y.declaredAbsentSections {
            XCTAssertFalse(
                identifiers.contains(absent),
                "\(absent) is declared absent and must not appear over a real store")
        }

        // 4. Collapsing a group works over live data, and its neighbours do not
        //    move — the affordance the user asked for, on the container they
        //    actually have.
        let imbibHeader = app.descendants(matching: .any)[ImpressA11y.imbibGroup]
        if imbibHeader.exists, imbibHeader.isHittable {
            imbibHeader.tap()
            Thread.sleep(forTimeInterval: 0.6)
            XCTAssertFalse(
                app.descendants(matching: .any)[ImpressA11y.redFlaggedPapersNode].exists,
                "collapsing imbib hides imbib's rows")
            XCTAssertTrue(
                app.descendants(matching: .any)[ImpressA11y.imprintGroup].exists,
                "…and leaves the other groups standing")
            let collapsed = XCTAttachment(screenshot: app.screenshot())
            collapsed.name = "real-store-imbib-collapsed"
            collapsed.lifetime = .keepAlways
            add(collapsed)
            imbibHeader.tap()
        }

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "real-store-sidebar"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Helpers

    /// Open every group that is closed. Unlike the seeded suite this cannot
    /// assume a launch state, because it passes no arguments and therefore gets
    /// no collapse-state reset.
    ///
    /// The state comes from the header's ACCESSIBILITY VALUE
    /// (`ImpressA11y.collapsed` / `.expanded`), never from "does this group
    /// show any rows": a lazy list only publishes the rows on screen, so that
    /// question reads `false` for an EXPANDED group whose rows are below the
    /// fold — which is how the first run of this suite collapsed implore while
    /// meaning to open it.
    private func expandEveryGroup(_ app: XCUIApplication) {
        for group in ImpressA11y.allGroups {
            let header = app.descendants(matching: .any)[group]
            var attempts = 0
            while !header.exists, attempts < 25 {
                scroll(app)
                attempts += 1
            }
            guard header.exists, header.isHittable else { continue }
            if header.value as? String == ImpressA11y.collapsed {
                header.tap()
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        scrollToTop(app)
    }

    private func scrollToTop(_ app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        for _ in 0..<30 {
            if list.exists { list.swipeDown(velocity: .fast) } else { app.swipeDown(velocity: .fast) }
        }
    }

    /// One slow downward sweep, collecting every `sidebar.*` identifier.
    ///
    /// Thirty steps rather than I2's twenty: the composed sidebar is half again
    /// as tall. A page-sized jump can carry a header from below the fold to
    /// behind the navigation bar between two collections, and the row is then
    /// never seen even though it rendered.
    private func sweep(_ app: XCUIApplication, steps: Int = 30) -> Set<String> {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sidebar."))
        var seen = Set<String>()
        for step in 0...steps {
            // Let the scroll SETTLE before resolving the query: on a physical
            // device the list is still moving when the swipe returns, and
            // resolving element identifiers mid-scroll throws "Failed to get
            // matching snapshot" for an index that vanished between the
            // snapshot and the read.
            Thread.sleep(forTimeInterval: 0.6)
            seen.formUnion(query.allElementsBoundByIndex.compactMap {
                $0.exists ? $0.identifier : nil
            })
            if step < steps { scroll(app) }
        }
        return seen
    }

    private func scroll(_ app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        if list.exists { list.swipeUp(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
    }
}
