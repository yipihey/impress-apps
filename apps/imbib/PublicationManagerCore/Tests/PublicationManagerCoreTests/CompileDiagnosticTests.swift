//
//  CompileDiagnosticTests.swift
//  PublicationManagerCoreTests
//
//  The diagnostics-click contract: a compiler diagnostic's byte range (UTF-8,
//  from Rust) must land the editor caret on the right UTF-16 offset, including
//  across multi-byte characters, and clamp instead of crash when the compile
//  source carried an appended virtual-bibliography line the editor never shows.
//

import XCTest
@testable import PublicationManagerCore

final class CompileDiagnosticTests: XCTestCase {

    func testByteOffsetMapsToUTF16Offset() {
        let source = "= Title\n\n#undefined_variable\n"
        let byteStart = source.utf8.distance(
            from: source.utf8.startIndex,
            to: source.range(of: "#undefined_variable")!.lowerBound.samePosition(in: source.utf8)!)
        let diag = CompileDiagnostic(
            severity: .error, message: "unknown variable",
            line: 3, column: 2,
            byteStart: byteStart, byteEnd: byteStart + "#undefined_variable".utf8.count)

        let offset = diag.editorOffset(in: source)
        XCTAssertEqual(offset, 9, "ASCII source: UTF-16 offset equals byte offset")
        let range = diag.editorRange(in: source)
        XCTAssertEqual(range, NSRange(location: 9, length: 19))
    }

    func testMultiByteCharactersShiftUTF16Offset() {
        // "é✓" is 4 UTF-8 bytes (2+3... é=2, ✓=3 → 5 bytes) but 2 UTF-16 units.
        let source = "é✓\n#bad\n"
        let byteStart = 6  // after "é✓\n" (2+3+1 bytes)
        let diag = CompileDiagnostic(
            severity: .error, message: "x", line: 2, column: 1,
            byteStart: byteStart, byteEnd: byteStart + 4)
        XCTAssertEqual(diag.editorOffset(in: source), 3,
                       "é(1) + ✓(1) + newline(1) = UTF-16 offset 3")
        XCTAssertEqual(diag.editorRange(in: source), NSRange(location: 3, length: 4))
    }

    func testOffsetBeyondSourceClamps() {
        // The compile source had an appended #bibliography line; the editor
        // source is shorter. The jump must clamp to the end, not crash.
        let editorSource = "= T\n"
        let diag = CompileDiagnostic(
            severity: .error, message: "x", line: 9, column: 1,
            byteStart: 400, byteEnd: 410)
        XCTAssertEqual(diag.editorOffset(in: editorSource), editorSource.utf16.count)
        XCTAssertNil(diag.editorRange(in: editorSource),
                     "a clamped range collapses to nil rather than lying")
    }

    func testLineColumnFallbackWhenNoByteRange() {
        let source = "one\ntwo\nthree three\n"
        let diag = CompileDiagnostic(
            severity: .warning, message: "x", line: 3, column: 7)
        XCTAssertEqual(diag.editorOffset(in: source), 14,
                       "line 3 starts at 8; column 7 adds 6")
    }

    func testDisplayLine() {
        XCTAssertEqual(
            CompileDiagnostic(severity: .error, message: "boom", line: 12).displayLine,
            "line 12: boom")
        XCTAssertEqual(
            CompileDiagnostic(severity: .error, message: "boom").displayLine, "boom")
    }
}
