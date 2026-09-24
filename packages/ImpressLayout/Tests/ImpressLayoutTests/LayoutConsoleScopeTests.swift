#if os(macOS)
//
//  LayoutConsoleScopeTests.swift
//  ImpressLayoutTests
//
//  The `console` view kind reads two keys of its pane's opaque `view_state`
//  — `search` and `levels`, the two controls `ConsoleView` already has — and
//  ignores everything else. These pin the reading (FFI-free: a
//  `LayoutJSONValue` in, a value out), including that a malformed
//  `view_state` degrades to the unscoped console rather than failing.
//

import ImpressLogging
import XCTest

@testable import ImpressLayout

final class LayoutConsoleScopeTests: XCTestCase {

    private func scope(_ json: String) throws -> LayoutConsoleScope {
        LayoutConsoleScope(viewState: try LayoutJSONValue.decode(json))
    }

    func testNoViewStateIsTheWholeLog() {
        let scope = LayoutConsoleScope(viewState: nil)
        XCTAssertEqual(scope, LayoutConsoleScope())
        XCTAssertEqual(scope.search, "")
        XCTAssertNil(scope.levels, "nil means every level, as the console window opens")
        XCTAssertEqual(scope.summary, "all")
        XCTAssertEqual(LayoutConsoleScope(viewState: .null), LayoutConsoleScope())
    }

    func testSearchAndLevelsAreRead() throws {
        let scope = try scope(#"{"search":"layout","levels":["warning","error"]}"#)
        XCTAssertEqual(scope.search, "layout")
        XCTAssertEqual(scope.levels, [.warning, .error])
        XCTAssertEqual(scope.summary, "search 'layout', levels warning,error")
    }

    /// The summary lists levels in the console's own order, not the JSON's,
    /// so the log line is stable whatever order an agent wrote.
    func testTheSummaryOrdersLevelsLikeTheToggles() throws {
        XCTAssertEqual(
            try scope(#"{"levels":["error","debug"]}"#).summary, "levels debug,error")
    }

    /// Unknown level names are dropped; if none is left the pane shows every
    /// level rather than none (an empty console would look like a dead app).
    func testUnknownLevelsAreIgnored() throws {
        XCTAssertEqual(try scope(#"{"levels":["info","verbose"]}"#).levels, [.info])
        XCTAssertNil(try scope(#"{"levels":["verbose"]}"#).levels)
        XCTAssertNil(try scope(#"{"levels":[]}"#).levels)
    }

    /// Wrong shapes are not errors: the pane is the whole console.
    func testMalformedViewStateDegradesToTheWholeLog() throws {
        XCTAssertEqual(try scope(#"{"search":7,"levels":"error"}"#), LayoutConsoleScope())
        XCTAssertEqual(try scope(#"["search","layout"]"#), LayoutConsoleScope())
        XCTAssertEqual(try scope(#""layout""#), LayoutConsoleScope())
    }

    /// Other keys belong to nobody yet and are left alone.
    func testOtherKeysAreIgnored() throws {
        XCTAssertEqual(
            try scope(#"{"search":"surface","colormap":"viridis"}"#),
            LayoutConsoleScope(search: "surface"))
    }
}
#endif
