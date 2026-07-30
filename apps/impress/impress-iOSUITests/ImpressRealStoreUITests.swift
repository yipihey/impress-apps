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

import XCTest

final class ImpressRealStoreUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_realStore_sidebarRendersThePresentedSectionsOverLiveData() throws {
        let app = XCUIApplication()
        // Deliberately NO launch arguments: real store, real container.
        app.launch()

        // ONE downward sweep, for the reason the seeded suite documents: I2
        // took this sidebar from three sections to eight, and a lazy `List`
        // makes "below the fold" and "not present" look identical.
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sidebar."))
        XCTAssertTrue(
            query.firstMatch.waitForExistence(timeout: 20),
            "the sidebar must render over the real store")
        // Slow, twenty-step sweep: a page-sized jump can carry a header from
        // below the fold to behind the navigation bar between two collections,
        // and the section is then never seen even though it rendered.
        let list = app.collectionViews.firstMatch
        var sections = Set<String>()
        for step in 0...20 {
            sections.formUnion(query.allElementsBoundByIndex.map(\.identifier))
            if step < 20 {
                if list.exists { list.swipeUp(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
            }
        }

        // I2 widened this list. The ones added are the sections whose rows are
        // DERIVED from a descriptor and therefore exist whatever the store
        // holds: Manuscripts ("All Manuscripts" + the declared statuses),
        // Flagged (one row per `FlagColor`), Dismissed (the publication kind's
        // library-move row). On the reporter's own device the missing sections
        // were exactly the kinds with the most rows — "none of the ones we have
        // multiple entries like publications and manuscripts" — so their
        // presence over a REAL container is the assertion that closes it.
        // Asserted on each section's selectable NODE rather than its header:
        // a node is what a user can reach, and a 20-point header can sit behind
        // the navigation bar at every step of a sweep (the seeded suite's
        // finding, recorded there).
        for present in [
            ImpressA11y.allMessagesNode,
            ImpressA11y.allFiguresNode,
            ImpressA11y.allTasksNode,
            ImpressA11y.allManuscriptsNode,
            ImpressA11y.redFlaggedPapersNode,
            ImpressA11y.dismissedNode,
        ] {
            XCTAssertTrue(
                sections.contains(present),
                "\(present) must render over the real store")
        }

        // Inbox and Libraries are deliberately NOT asserted: their rows are the
        // HOST's (an inbox library, the user's libraries), so a container with
        // no imbib data legitimately has neither — `RecordSidebarBuilder` drops
        // a section whose node list is empty. Asserting them here would make
        // this suite pass or fail on whether a developer happens to have run
        // imbib on the device, which is the opposite of a structural contract.
        // The SEEDED suite pins them instead.

        // Declared-absent sections stay absent on the real store too — the
        // presentableKinds and content gates are data-independent.
        for absent in ImpressA11y.declaredAbsentSections {
            XCTAssertFalse(
                sections.contains(absent),
                "\(absent) is declared absent and must not appear over a real store")
        }

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "real-store-sidebar"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
