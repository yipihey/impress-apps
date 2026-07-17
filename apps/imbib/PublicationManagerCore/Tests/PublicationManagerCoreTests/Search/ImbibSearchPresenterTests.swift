//
//  ImbibSearchPresenterTests.swift
//  PublicationManagerCoreTests
//

import XCTest
@testable import PublicationManagerCore

@MainActor
final class ImbibSearchPresenterTests: XCTestCase {

    func testLocalFindStoresContextAndPresentsOnlyLocalWorkflow() {
        let presenter = ImbibSearchPresenter()
        let paperID = UUID(uuidString: "00000000-0000-0000-0000-000000000555")!

        presenter.perform(.localFind(
            context: .publication(paperID, "Paper"),
            source: .keyboardShortcut
        ))

        XCTAssertEqual(presenter.presentedWorkflow, .localFind)
        XCTAssertTrue(presenter.isLocalFindPresented)
        XCTAssertFalse(presenter.isOnlineSourceSearchPresented)
        XCTAssertEqual(presenter.localFindContext, .publication(paperID, "Paper"))
    }

    func testOnlineSourceSearchReplacesLocalFind() {
        let presenter = ImbibSearchPresenter()
        let libraryID = UUID(uuidString: "00000000-0000-0000-0000-000000000666")!

        presenter.perform(.localFind(
            context: .library(libraryID, "Library"),
            source: .toolbarButton
        ))
        presenter.perform(.onlineSourceSearch(source: .menuCommand))

        XCTAssertEqual(presenter.presentedWorkflow, .onlineSourceSearch)
        XCTAssertFalse(presenter.isLocalFindPresented)
        XCTAssertTrue(presenter.isOnlineSourceSearchPresented)
        XCTAssertEqual(presenter.localFindContext, .library(libraryID, "Library"))
    }

    func testDismissIgnoresStaleWorkflowBindings() {
        let presenter = ImbibSearchPresenter()

        presenter.perform(.onlineSourceSearch(source: .keyboardShortcut))
        presenter.dismiss(.localFind)

        XCTAssertEqual(presenter.presentedWorkflow, .onlineSourceSearch)

        presenter.dismiss(.onlineSourceSearch)

        XCTAssertNil(presenter.presentedWorkflow)
    }
}
