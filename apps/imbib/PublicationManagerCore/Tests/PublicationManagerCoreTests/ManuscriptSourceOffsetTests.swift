#if os(macOS)
//
//  ManuscriptSourceOffsetTests.swift
//  PublicationManagerCoreTests
//
//  Line/column → UTF-16 char offset conversion for LaTeX inverse-sync (SyncTeX
//  returns 1-indexed line + column; the editor's cursorPosition wants an offset).
//

import XCTest
@testable import PublicationManagerCore

final class ManuscriptSourceOffsetTests: XCTestCase {

    private let source = "line one\nsecond line\nthird"
    //                    0......... 9.......... 21...
    //  offsets: l=0..7, \n=8, s=9..19, \n=20, t=21..25

    func testFirstLineColumnZero() {
        XCTAssertEqual(ManuscriptSourceOffset.offset(in: source, line: 1, column: 0), 0)
    }

    func testSecondLineStart() {
        XCTAssertEqual(ManuscriptSourceOffset.offset(in: source, line: 2, column: 0), 9)
    }

    func testMidLineColumn() {
        // third line ("third") starts at 21; column 2 → 't','h' → offset 23.
        XCTAssertEqual(ManuscriptSourceOffset.offset(in: source, line: 3, column: 2), 23)
    }

    func testColumnPastLineEndClampsToLineEnd() {
        // "line one" is 8 chars; column 100 clamps to the end of line 1 (offset 8,
        // just before the newline).
        XCTAssertEqual(ManuscriptSourceOffset.offset(in: source, line: 1, column: 100), 8)
    }

    func testLineOutOfRangeReturnsNil() {
        XCTAssertNil(ManuscriptSourceOffset.offset(in: source, line: 4, column: 0))
        XCTAssertNil(ManuscriptSourceOffset.offset(in: source, line: 0, column: 0))
    }

    func testNoTrailingNewlineLastLine() {
        XCTAssertEqual(ManuscriptSourceOffset.offset(in: "abc", line: 1, column: 3), 3)
        XCTAssertNil(ManuscriptSourceOffset.offset(in: "abc", line: 2, column: 0))
    }

    func testEmptyTrailingLine() {
        // "a\n" → line 2 is the empty line at the end (offset 2).
        XCTAssertEqual(ManuscriptSourceOffset.offset(in: "a\n", line: 2, column: 0), 2)
    }

    func testNonASCIIUsesUTF16Units() {
        // "é" is 1 UTF-16 unit; "𝕏" (astral) is 2. Column counts UTF-16 units.
        let s = "é𝕏x"  // offsets: é=0, 𝕏=1..2, x=3
        XCTAssertEqual(ManuscriptSourceOffset.offset(in: s, line: 1, column: 1), 1)  // after é
        XCTAssertEqual(ManuscriptSourceOffset.offset(in: s, line: 1, column: 3), 3)  // after 𝕏
        XCTAssertEqual(s.utf16.count, 4)
    }
}
#endif
