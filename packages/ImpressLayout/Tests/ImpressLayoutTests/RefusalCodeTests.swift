#if os(macOS)
//
//  RefusalCodeTests.swift
//  ImpressLayoutTests
//
//  Wave 7 T5 (review RL-L11): a verb Rust refuses reaches Swift with its
//  machine-readable `code`, the controller keeps it beside the prose, and
//  the HTTP status for it is Rust's one table — against a real in-memory
//  `SharedLayout`, not a fixture.
//

import ImpressRustCore
import XCTest

@testable import ImpressLayout

@MainActor
final class RefusalCodeTests: XCTestCase {

    func testARefusedVerbReachesSwiftWithItsCode() throws {
        let store = try SharedStore.openInMemory()
        let layout = SharedLayout.open(store: store, appId: "t5-swift", device: nil)
        let controller = LayoutController(
            layout: layout, appID: "t5-swift", store: store, startupGraceSecs: 0)
        defer { controller.stop() }

        XCTAssertThrowsError(
            try controller.applyVerbJSON(
                #"{"verb":"close","target":{"ref":"id","tile":4242}}"#, actor: "agent")
        ) { error in
            XCTAssertEqual(LayoutController.refusalCode(of: error), "unknown-tile")
            XCTAssertTrue(
                LayoutController.describe(error).hasPrefix("close "),
                LayoutController.describe(error))
        }
        XCTAssertEqual(controller.lastRefusalCode, "unknown-tile")
        XCTAssertEqual(refusalHttpStatus(code: "unknown-tile"), 422)
        XCTAssertEqual(refusalHttpStatus(code: "not-found"), 404)
        XCTAssertEqual(refusalHttpStatus(code: "store-error"), 500)
    }
}
#endif
