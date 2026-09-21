#if os(macOS)
//
//  LayoutVerbEncodingTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0031 L6. `LayoutVerb` must serialize to EXACTLY the serde form of
//  `impress_layout::Verb`, because that string is the whole mutating surface
//  (`SharedLayout.apply(verbJson:actor:)`) and a misspelled tag does not fail
//  loudly: `apply` falls through to the "bare split" recogniser and then
//  returns a JSON error, i.e. a gesture that silently does nothing.
//
//  The expected strings below are written BY HAND from the Rust attributes,
//  not captured from the encoder — a golden taken from the code under test
//  proves only that it is self-consistent:
//
//    * `#[serde(tag = "verb", rename_all = "kebab-case")]` on `Verb` ⇒ the
//      VARIANT names are kebab-case (`move-tile`, `set-view-kind`) and the
//      tag key is `verb`;
//    * `rename_all` does NOT touch struct-variant FIELDS, so they keep Rust's
//      own spelling — `view_kind`, not `view-kind` and not `viewKind`;
//    * `#[serde(tag = "ref", rename_all = "kebab-case")]` on `PaneRef` ⇒
//      `{"ref":"id","tile":3}` / `{"ref":"focused"}`;
//    * `Placement::IntoTabs` ⇒ `"into-tabs"`.
//
//  Keys are sorted by the encoder, so these strings are stable.
//

import XCTest

@testable import PublicationManagerCore

final class LayoutVerbEncodingTests: XCTestCase {

    private func json(_ verb: LayoutVerb) throws -> String {
        try XCTUnwrap(verb.verbJSON).jsonString()
    }

    // MARK: - Tree verbs

    func testFocus() throws {
        XCTAssertEqual(
            try json(.focus(target: .id(2))),
            #"{"target":{"ref":"id","tile":2},"verb":"focus"}"#)
    }

    func testFocusByRoleAndByDirection() throws {
        XCTAssertEqual(
            try json(.focus(target: .role("detail"))),
            #"{"target":{"ref":"role","role":"detail"},"verb":"focus"}"#)
        XCTAssertEqual(
            try json(.focus(target: .direction(.prev))),
            #"{"target":{"direction":"prev","ref":"direction"},"verb":"focus"}"#)
        XCTAssertEqual(
            try json(.focus(target: .focused)),
            #"{"target":{"ref":"focused"},"verb":"focus"}"#)
    }

    func testSplit() throws {
        XCTAssertEqual(
            try json(.split(target: .id(1), dir: .vertical, after: true, new: nil)),
            #"{"after":true,"dir":"vertical","target":{"ref":"id","tile":1},"verb":"split"}"#)
    }

    /// A split that NAMES its new pane carries the whole spec under `new`.
    func testSplitWithANewSpec() throws {
        let spec = LayoutJSONValue.object([
            "view_kind": .string("info"),
            "channel": .object(["number": .int(1)]),
        ])
        XCTAssertEqual(
            try json(.split(target: .focused, dir: .horizontal, after: false, new: spec)),
            #"{"after":false,"dir":"horizontal","new":{"channel":{"number":1},"view_kind":"info"},"target":{"ref":"focused"},"verb":"split"}"#
        )
    }

    func testClose() throws {
        XCTAssertEqual(
            try json(.close(target: .id(3))),
            #"{"target":{"ref":"id","tile":3},"verb":"close"}"#)
    }

    func testMoveTile() throws {
        XCTAssertEqual(
            try json(.move(tile: .id(1), target: .id(2), placement: .intoTabs)),
            #"{"placement":"into-tabs","target":{"ref":"id","tile":2},"tile":{"ref":"id","tile":1},"verb":"move-tile"}"#
        )
        XCTAssertEqual(
            try json(.move(tile: .focused, target: .role("list"), placement: .below)),
            #"{"placement":"below","target":{"ref":"role","role":"list"},"tile":{"ref":"focused"},"verb":"move-tile"}"#
        )
    }

    func testMaximizeAndRestore() throws {
        XCTAssertEqual(
            try json(.maximize(target: .id(7))),
            #"{"target":{"ref":"id","tile":7},"verb":"maximize"}"#)
        XCTAssertEqual(try json(.restore), #"{"verb":"restore"}"#)
    }

    func testSetViewKindKeepsRustsFieldSpelling() throws {
        XCTAssertEqual(
            try json(.setViewKind(target: .id(3), viewKind: .pdf)),
            #"{"target":{"ref":"id","tile":3},"verb":"set-view-kind","view_kind":"pdf"}"#)
    }

    /// `role: None` is how a role is CLEARED, and `#[serde(default)]` on the
    /// field means an explicit `null` is the right wire form for it.
    func testSetRoleAndClearRole() throws {
        XCTAssertEqual(
            try json(.setRole(target: .id(1), role: "navigator")),
            #"{"role":"navigator","target":{"ref":"id","tile":1},"verb":"set-role"}"#)
        XCTAssertEqual(
            try json(.setRole(target: .id(1), role: nil)),
            #"{"role":null,"target":{"ref":"id","tile":1},"verb":"set-role"}"#)
    }

    // MARK: - The typed half

    /// These have their OWN FFI methods (`focus_direction`, `select`,
    /// `resize_share`, `undo`, `redo`, `save_layout`, `apply_layout`), and
    /// four of them are not `Verb` variants at all — they are service verbs
    /// that touch the store or a ring. A non-nil `verbJSON` here would mean
    /// the controller sends them down the wrong path.
    func testTypedVerbsCarryNoVerbJSON() {
        let typed: [LayoutVerb] = [
            .focusDirection(.left),
            .select(pane: 2, kind: "publication", ids: ["a"]),
            .resizeShare(pane: 1, share: 0.5),
            .undo(stack: .arrangement, pane: nil),
            .redo(stack: .exploration, pane: 2),
            .saveLayout(name: "Triage", purpose: nil),
            .applyLayout(nameOrOrdinal: "3"),
        ]
        for verb in typed {
            XCTAssertNil(verb.verbJSON, "\(verb.traceDescription) must use its typed FFI method")
        }
    }

    /// The stack names the FFI takes are the strings `layout-service` matches.
    func testUndoStackNames() {
        XCTAssertEqual(LayoutUndoStack.arrangement.rawValue, "arrangement")
        XCTAssertEqual(LayoutUndoStack.exploration.rawValue, "exploration")
    }

    /// `focus_direction(dir:)` takes these six strings and no others.
    func testFocusDirectionNames() {
        XCTAssertEqual(
            LayoutFocusDirection.allNames, ["left", "right", "up", "down", "next", "prev"])
    }
}

extension LayoutFocusDirection {
    /// Test-only helper so the six names are asserted as a SET rather than
    /// one at a time.
    static var allNames: [String] {
        [Self.left, .right, .up, .down, .next, .prev].map(\.rawValue)
    }
}
#endif
