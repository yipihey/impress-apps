//
//  RenderTreeForwardCompatTests.swift
//  ImpressSurfaceTests
//
//  ADR-0033 Defaults: "unknown widget kinds degrade to a placeholder that
//  keeps the node, so a spec authored for a newer kit still renders its
//  rest." Before wave 7 that held only at the TAG level: a known kind with a
//  missing or mistyped field threw, the throw crossed `[RenderNode]`, and the
//  whole pane became "Surface Unavailable" (review SK-K17). These pin the
//  per-node rule, and decode every one of the 18 render kinds at least once
//  (SK-K20: the Rust golden carries only five of them).
//

import Foundation
import Testing

@testable import ImpressSurface

@Suite("RenderTree forward compatibility")
struct RenderTreeForwardCompatTests {

    private func decode(_ json: String) throws -> RenderTree {
        try RenderTree.decode(json)
    }

    @Test("a known kind with a bad shape becomes a placeholder and its siblings still render")
    func malformedKnownKindKeepsSiblings() throws {
        let tree = try decode(
            """
            {"focus_order": ["b"], "root": {"id": "root", "node": {"kind": "column", "items": [
              {"id": "t", "node": {"kind": "text", "text": "before"}},
              {"id": "g", "node": {"kind": "grid", "columns": "three", "items": []}},
              {"id": "tb", "node": {"kind": "table", "rows": []}},
              {"id": "b", "node": {"kind": "button", "label": "Go"}}
            ]}}}
            """)
        guard case .column(let items) = tree.root.node else {
            Issue.record("root should still be a column"); return
        }
        #expect(items.count == 4)
        guard case .text(let text) = items[0].node else {
            Issue.record("the text sibling should survive"); return
        }
        #expect(text == "before")

        guard case .placeholder(let gridKind, let gridReason) = items[1].node else {
            Issue.record("a grid whose columns is a string should be a placeholder"); return
        }
        #expect(gridKind == "grid")
        #expect(gridReason?.contains("undecodable grid") == true)

        guard case .placeholder(let tableKind, let tableReason) = items[2].node else {
            Issue.record("a table with no columns should be a placeholder"); return
        }
        #expect(tableKind == "table")
        #expect(tableReason?.contains("missing 'columns'") == true)
        // The node keeps its id, so focus order and events still line up.
        #expect(items[2].id == "tb")

        guard case .button(let label) = items[3].node else {
            Issue.record("the button after the bad nodes should survive"); return
        }
        #expect(label == "Go")
    }

    @Test("a child that is not even a node is replaced in place, not dropped")
    func childWithoutAnIdIsReplacedInPlace() throws {
        let tree = try decode(
            """
            {"focus_order": [], "root": {"id": "root", "node": {"kind": "row", "items": [
              {"node": {"kind": "text", "text": "no id"}},
              {"id": "ok", "node": {"kind": "divider"}}
            ]}}}
            """)
        guard case .row(let items) = tree.root.node else {
            Issue.record("root should still be a row"); return
        }
        #expect(items.count == 2)
        guard case .placeholder = items[0].node else {
            Issue.record("the id-less child should be a placeholder"); return
        }
        #expect(items[0].id == "items.0")
        guard case .divider = items[1].node else {
            Issue.record("the next child should survive"); return
        }
    }

    @Test("fields that are optional by nature default instead of failing")
    func optionalByNatureFieldsDefault() throws {
        let tree = try decode(
            """
            {"focus_order": [], "root": {"id": "root", "node": {"kind": "column", "items": [
              {"id": "s", "node": {"kind": "section", "title": "S",
                "body": {"id": "sb", "node": {"kind": "spacer"}}}},
              {"id": "g", "node": {"kind": "grid", "items": []}},
              {"id": "f", "node": {"kind": "field", "field": {"text": {}}}}
            ]}}}
            """)
        guard case .column(let items) = tree.root.node else {
            Issue.record("root should be a column"); return
        }
        guard case .section(_, let collapsed, _) = items[0].node else {
            Issue.record("a section without `collapsed` should still be a section"); return
        }
        #expect(collapsed == false)
        guard case .grid(let columns, _) = items[1].node else {
            Issue.record("a grid without `columns` should still be a grid"); return
        }
        #expect(columns == 1)
        guard case .field(_, _, let value) = items[2].node else {
            Issue.record("a field without `value` should still be a field"); return
        }
        #expect(value.isNull)
    }

    /// Every `RenderKind` Rust can produce, once — `resolve.rs`'s enum,
    /// spelled the way serde writes it (`tag = "kind"`, snake_case).
    @Test("all 18 render kinds decode to their own case")
    func everyRenderKindDecodes() throws {
        let tree = try decode(
            """
            {"focus_order": ["f", "b", "tb", "l", "tabs"], "root": {"id": "root", "node": {
              "kind": "column", "items": [
                {"id": "row", "node": {"kind": "row", "items": []}},
                {"id": "grid", "node": {"kind": "grid", "columns": 2, "items": []}},
                {"id": "sec", "node": {"kind": "section", "title": "T", "collapsed": true,
                  "body": {"id": "sb", "node": {"kind": "divider"}}}},
                {"id": "tabs", "node": {"kind": "tabs", "tabs": [
                  {"title": "A", "body": {"id": "ta", "node": {"kind": "spacer"}}}]}},
                {"id": "txt", "node": {"kind": "text", "text": "hello"}},
                {"id": "tb", "node": {"kind": "table", "rows": [{"id": "r1", "a": 1}], "columns": ["a"]}},
                {"id": "l", "node": {"kind": "list", "rows": [{"id": "r1", "title": "x"}]}},
                {"id": "p", "node": {"kind": "plot", "spec": {"kind": "plot-spec@1.0.0"}}},
                {"id": "img", "node": {"kind": "image", "url": "https://example.org/x.png"}},
                {"id": "f", "node": {"kind": "field", "field": {"date": {}}, "bind": "state.d",
                  "value": "2026-09-25"}, "label": "When"},
                {"id": "b", "node": {"kind": "button", "label": "Go"}},
                {"id": "st", "node": {"kind": "status", "level": "warning", "message": "careful"}},
                {"id": "lg", "node": {"kind": "log", "lines": ["a", "b"]}},
                {"id": "kv", "node": {"kind": "kv", "pairs": {"k": "v"}}},
                {"id": "dv", "node": {"kind": "divider"}},
                {"id": "sp", "node": {"kind": "spacer"}},
                {"id": "ph", "node": {"kind": "placeholder", "unknown_kind": "future", "reason": "newer kit"}}
              ]}}}
            """)
        guard case .column(let items) = tree.root.node else {
            Issue.record("root should be a column"); return
        }
        // 17 children plus the column itself = 18 kinds.
        #expect(items.count == 17)
        let names = items.map { Self.caseName($0.node) }
        #expect(
            names == [
                "row", "grid", "section", "tabs", "text", "table", "list", "plot", "image",
                "field", "button", "status", "log", "kv", "divider", "spacer", "placeholder",
            ])
        #expect(Self.caseName(tree.root.node) == "column")
        #expect(items[9].label == "When")
        guard case .placeholder(let unknownKind, _) = items[16].node else { return }
        // A real Rust placeholder keeps ITS unknown kind; it is not re-wrapped.
        #expect(unknownKind == "future")
    }

    private static func caseName(_ kind: RenderKind) -> String {
        switch kind {
        case .column: return "column"
        case .row: return "row"
        case .grid: return "grid"
        case .section: return "section"
        case .tabs: return "tabs"
        case .text: return "text"
        case .table: return "table"
        case .list: return "list"
        case .plot: return "plot"
        case .image: return "image"
        case .field: return "field"
        case .button: return "button"
        case .status: return "status"
        case .log: return "log"
        case .kv: return "kv"
        case .divider: return "divider"
        case .spacer: return "spacer"
        case .placeholder: return "placeholder"
        }
    }
}
