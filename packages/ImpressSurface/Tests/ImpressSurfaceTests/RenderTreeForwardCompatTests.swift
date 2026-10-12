//
//  RenderTreeForwardCompatTests.swift
//  ImpressSurfaceTests
//
//  ADR-0033 Defaults: "unknown widget kinds degrade to a placeholder that
//  keeps the node, so a spec authored for a newer kit still renders its
//  rest." Before wave 7 that held only at the TAG level: a known kind with a
//  missing or mistyped field threw, the throw crossed `[RenderNode]`, and the
//  whole pane became "Surface Unavailable" (review SK-K17). These pin the
//  per-node rule, and decode every one of the 21 render kinds at least once
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

    /// The kinds koine 65c7321 added (`tree`, `graph`) and the fields it added
    /// to `table`, `list` and `code` — every one optional on the wire.
    @Test("tree and graph decode to their own cases; new table, list and code fields default")
    func treeGraphAndNewOptionalFields() throws {
        let tree = try decode(
            """
            {"focus_order": ["outline"], "root": {"id": "root", "node": {"kind": "column", "items": [
              {"id": "outline", "node": {"kind": "tree", "nodes": [
                {"id": "a", "label": "Library", "depth": 0, "has_children": true, "expanded": true,
                 "count": 3, "row": {"id": "a", "name": "Library"}},
                {"id": 2, "label": "Inbox", "depth": 1, "has_children": false, "expanded": false,
                 "row": {"id": 2}}],
                "bind": "state.open", "expanded": ["a"], "actions": ["Delete"], "movable": true}},
              {"id": "bare", "node": {"kind": "tree"}},
              {"id": "g", "node": {"kind": "graph", "spec": {"nodes": [{"id": "n"}], "edges": []},
                "svg": "<svg/>"}},
              {"id": "tb", "node": {"kind": "table", "rows": [], "columns": ["a"],
                "actions": ["Open"], "count_field": "n"}},
              {"id": "tb0", "node": {"kind": "table", "rows": [], "columns": ["a"]}},
              {"id": "l", "node": {"kind": "list", "rows": [], "actions": ["Open"], "count_field": "n"}},
              {"id": "c", "node": {"kind": "code", "language": "rust", "text": "fn a",
                "spans": [[["keyword", "fn"], ["", " a"]]]}},
              {"id": "c0", "node": {"kind": "code", "text": "plain"}}
            ]}}}
            """)
        guard case .column(let items) = tree.root.node else {
            Issue.record("root should be a column"); return
        }
        #expect(items.map { Self.caseName($0.node) }
            == ["tree", "tree", "graph", "table", "table", "list", "code", "code"])

        guard case .tree(let nodes, let bind, let expanded, let actions, let movable) = items[0].node
        else { Issue.record("expected a tree"); return }
        #expect(nodes.count == 2)
        #expect(nodes[0].id == .string("a"))
        #expect(nodes[0].label == "Library")
        #expect(nodes[0].depth == 0)
        #expect(nodes[0].hasChildren)
        #expect(nodes[0].expanded)
        #expect(nodes[0].count == SurfaceJSONValue.int(3))
        #expect(nodes[0].row["name"]?.stringValue == "Library")
        // A numeric id stays a number; an absent count stays nil.
        #expect(nodes[1].id == .int(2))
        #expect(nodes[1].depth == 1)
        #expect(nodes[1].count == nil)
        #expect(bind == "state.open")
        #expect(expanded == [.string("a")])
        #expect(actions == ["Delete"])
        #expect(movable)

        guard case .tree(let bareNodes, let bareBind, let bareExpanded, let bareActions, let bareMovable)
            = items[1].node
        else { Issue.record("a bare tree should still be a tree"); return }
        #expect(bareNodes.isEmpty && bareBind == nil && bareExpanded.isEmpty)
        #expect(bareActions.isEmpty && !bareMovable)

        guard case .graph(let spec, let svg) = items[2].node else {
            Issue.record("expected a graph"); return
        }
        #expect(spec["nodes"]?.arrayValue?.count == 1)
        #expect(svg == "<svg/>")

        guard case .table(_, _, _, let tableActions, let tableCount) = items[3].node else {
            Issue.record("expected a table"); return
        }
        #expect(tableActions == ["Open"] && tableCount == "n")
        guard case .table(_, _, _, let noActions, let noCount) = items[4].node else {
            Issue.record("expected a table"); return
        }
        #expect(noActions.isEmpty && noCount == nil)
        guard case .list(_, let listActions, let listCount) = items[5].node else {
            Issue.record("expected a list"); return
        }
        #expect(listActions == ["Open"] && listCount == "n")

        guard case .code(let language, _, let spans) = items[6].node else {
            Issue.record("expected code"); return
        }
        #expect(language == "rust")
        #expect(spans == [[
            SurfaceCodeSpan(styleClass: "keyword", text: "fn"),
            SurfaceCodeSpan(styleClass: "", text: " a"),
        ]])
        guard case .code(_, _, let plainSpans) = items[7].node else {
            Issue.record("expected code"); return
        }
        #expect(plainSpans.isEmpty)

        // The kinds survive an encode and a decode.
        let again = try RenderTree.decode(
            String(decoding: try JSONEncoder().encode(tree), as: UTF8.self))
        #expect(again == tree)
    }

    @Test("a tree whose node has no id becomes a placeholder, siblings intact")
    func malformedTreeNodeIsContained() throws {
        let tree = try decode(
            """
            {"focus_order": [], "root": {"id": "root", "node": {"kind": "column", "items": [
              {"id": "outline", "node": {"kind": "tree", "nodes": [{"label": "no id"}]}},
              {"id": "ok", "node": {"kind": "divider"}}
            ]}}}
            """)
        guard case .column(let items) = tree.root.node else {
            Issue.record("root should be a column"); return
        }
        guard case .placeholder(let kind, let reason) = items[0].node else {
            Issue.record("a tree with an id-less node should be a placeholder"); return
        }
        #expect(kind == "tree")
        #expect(reason?.contains("missing 'id'") == true)
        guard case .divider = items[1].node else {
            Issue.record("the sibling should survive"); return
        }
    }

    /// Every `RenderKind` Rust can produce, once — `resolve.rs`'s enum,
    /// spelled the way serde writes it (`tag = "kind"`, snake_case).
    @Test("all 21 render kinds decode to their own case")
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
                {"id": "tr", "node": {"kind": "tree", "nodes": [
                  {"id": "a", "label": "A", "depth": 0, "has_children": false, "expanded": false,
                   "row": {"id": "a"}}]}},
                {"id": "gr", "node": {"kind": "graph", "spec": {"nodes": [], "edges": []}, "svg": "<svg/>"}},
                {"id": "p", "node": {"kind": "plot", "spec": {"kind": "plot-spec@1.0.0"}}},
                {"id": "img", "node": {"kind": "image", "url": "https://example.org/x.png"}},
                {"id": "f", "node": {"kind": "field", "field": {"date": {}}, "bind": "state.d",
                  "value": "2026-09-25"}, "label": "When"},
                {"id": "b", "node": {"kind": "button", "label": "Go"}},
                {"id": "st", "node": {"kind": "status", "level": "warning", "message": "careful"}},
                {"id": "lg", "node": {"kind": "log", "lines": ["a", "b"]}},
                {"id": "kv", "node": {"kind": "kv", "pairs": {"k": "v"}}},
                {"id": "cd", "node": {"kind": "code", "language": "rust", "text": "fn a() {}"}},
                {"id": "dv", "node": {"kind": "divider"}},
                {"id": "sp", "node": {"kind": "spacer"}},
                {"id": "ph", "node": {"kind": "placeholder", "unknown_kind": "future", "reason": "newer kit"}}
              ]}}}
            """)
        guard case .column(let items) = tree.root.node else {
            Issue.record("root should be a column"); return
        }
        // 20 children plus the column itself = 21 kinds.
        #expect(items.count == 20)
        let names = items.map { Self.caseName($0.node) }
        #expect(
            names == [
                "row", "grid", "section", "tabs", "text", "table", "list", "tree", "graph", "plot",
                "image", "field", "button", "status", "log", "kv", "code", "divider", "spacer",
                "placeholder",
            ])
        #expect(Self.caseName(tree.root.node) == "column")
        #expect(items[11].label == "When")
        guard case .placeholder(let unknownKind, _) = items[19].node else { return }
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
        case .tree: return "tree"
        case .graph: return "graph"
        case .plot: return "plot"
        case .image: return "image"
        case .field: return "field"
        case .button: return "button"
        case .status: return "status"
        case .log: return "log"
        case .kv: return "kv"
        case .code: return "code"
        case .divider: return "divider"
        case .spacer: return "spacer"
        case .placeholder: return "placeholder"
        }
    }
}
