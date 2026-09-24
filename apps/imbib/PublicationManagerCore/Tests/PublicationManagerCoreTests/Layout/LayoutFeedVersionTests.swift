#if os(macOS)
//
//  LayoutFeedVersionTests.swift
//  PublicationManagerCoreTests
//
//  The invalidation feed reloads the tree only for a version NEWER than the
//  one already on screen. Its reports hop to the main actor in their own
//  `Task`, so they arrive after the local `apply` that caused them; the old
//  equality test redrew the whole tree once per stale report — twice for
//  every outline click (2026-09-24).
//
//  FFI-free: `isNewer` is a pure function of two versions.
//

import XCTest
@testable import PublicationManagerCore

final class LayoutFeedVersionTests: XCTestCase {

    /// The outline click: two local verbs moved 101 → 103, then the feed
    /// delivered 101 and 102. Neither may reload.
    func testStaleReportsOfOurOwnVerbsDoNotReload() {
        XCTAssertFalse(LayoutController.isNewer(101, than: 103))
        XCTAssertFalse(LayoutController.isNewer(102, than: 103))
    }

    func testTheVersionAlreadyShownDoesNotReload() {
        XCTAssertFalse(LayoutController.isNewer(103, than: 103))
    }

    /// A change made elsewhere bumps the same monotonic counter, so it always
    /// arrives above what this process has adopted — and must reload.
    func testAChangeMadeElsewhereReloads() {
        XCTAssertTrue(LayoutController.isNewer(104, than: 103))
        XCTAssertTrue(LayoutController.isNewer(1, than: 0))
    }
}
#endif
