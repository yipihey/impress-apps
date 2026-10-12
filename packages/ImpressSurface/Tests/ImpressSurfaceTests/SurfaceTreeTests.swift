//
//  SurfaceTreeTests.swift
//  ImpressSurfaceTests
//
//  The `tree` widget's pure half (`SurfaceTreeLogic`) and its wire shapes.
//  The event values are koine's `docs/outline.md` § 3 table, the same values
//  `crates/impress-surface/tests/outline.rs` sends, compared as the exact
//  JSON `SurfaceEvent.jsonString()` produces (sorted keys). The view itself
//  (`SurfaceTreeView`) holds no logic, so it has no test of its own.
//

import Foundation
import Testing

@testable import ImpressSurface

@Suite("Surface tree")
struct SurfaceTreeTests {

    // MARK: Decoding

    @Test("a tree render node decodes with every field")
    func decodesEveryField() throws {
        let tree = try RenderTree.decode(
            """
            {"focus_order": ["outline"], "root": {"id": "outline", "node": {"kind": "tree",
              "nodes": [
                {"id": "a", "label": "Library", "depth": 0, "has_children": true,
                 "expanded": true, "count": 0, "row": {"id": "a", "name": "Library"}},
                {"id": 7, "label": "Inbox", "depth": 1, "has_children": false,
                 "expanded": false, "row": {"id": 7}}],
              "bind": "state.open", "expanded": ["a", "z"], "actions": ["Delete", "New"],
              "movable": true}}}
            """)
        guard case .tree(let nodes, let bind, let expanded, let actions, let movable) = tree.root.node
        else { Issue.record("expected a tree"); return }
        #expect(nodes.count == 2)
        #expect(nodes[0].id == SurfaceJSONValue.string("a"))
        #expect(nodes[0].hasChildren && nodes[0].expanded)
        // Zero is a count: it is present, not absent.
        #expect(nodes[0].count == SurfaceJSONValue.int(0))
        #expect(nodes[1].id == SurfaceJSONValue.int(7))
        #expect(nodes[1].depth == 1)
        #expect(nodes[1].count == nil)
        #expect(bind == "state.open")
        // `expanded` is the whole list, including "z", which no visible node shows.
        #expect(expanded == [SurfaceJSONValue.string("a"), .string("z")])
        #expect(actions == ["Delete", "New"])
        #expect(movable)
    }

    // MARK: Row keys

    @Test("the string 1 and the number 1 are different rows")
    func keysSeparateStringsFromNumbers() {
        let string = SurfaceTreeLogic.key(for: .string("1"))
        let number = SurfaceTreeLogic.key(for: .int(1))
        #expect(string != number)
        #expect(SurfaceTreeLogic.key(for: .string("a")) == SurfaceTreeLogic.key(for: .string("a")))
    }

    @Test("selected keys come back as the original ids, in drawing order")
    func orderedIDsKeepJSONTypes() {
        let nodes = [
            SurfaceTreeNode(id: .string("a"), label: "A"),
            SurfaceTreeNode(id: .int(7), label: "B", depth: 1),
            SurfaceTreeNode(id: .string("c"), label: "C"),
        ]
        let keys: Set<String> = [
            SurfaceTreeLogic.key(for: .string("c")),
            SurfaceTreeLogic.key(for: .int(7)),
            "s:gone",
        ]
        #expect(
            SurfaceTreeLogic.orderedIDs(keys: keys, in: nodes) == [.int(7), .string("c")])
        #expect(SurfaceTreeLogic.idsByKey(nodes)[SurfaceTreeLogic.key(for: .int(7))] == SurfaceJSONValue.int(7))
    }

    // MARK: Disclosure

    @Test("a disclosure click sends the whole expanded list plus or minus one id")
    func toggledKeepsTheRest() {
        let list: [SurfaceJSONValue] = [.string("c1"), .string("hidden"), .int(3)]
        // Closing an open branch removes only it; "hidden" (under a collapsed
        // ancestor) keeps its state.
        #expect(
            SurfaceTreeLogic.toggled(list, id: .string("c1"), currentlyExpanded: true)
                == [.string("hidden"), .int(3)])
        // Opening a closed one appends it.
        #expect(
            SurfaceTreeLogic.toggled(list, id: .string("c2"), currentlyExpanded: false)
                == list + [.string("c2")])
        // Already listed: not twice.
        #expect(SurfaceTreeLogic.toggled(list, id: .int(3), currentlyExpanded: false) == list)
        // A node drawn open that the list does not name: removal is a no-op.
        #expect(SurfaceTreeLogic.toggled(list, id: .string("x"), currentlyExpanded: true) == list)
        #expect(SurfaceTreeLogic.toggled([], id: .string("a"), currentlyExpanded: false) == [.string("a")])
    }

    // MARK: Event values, byte for byte

    private func json(_ event: SurfaceEvent) throws -> String { try event.jsonString() }

    @Test("select, activate and delete carry a list of ids; change carries the expanded list")
    func listEvents() throws {
        #expect(
            try json(SurfaceTreeLogic.selectEvent(widget: "outline", ids: [.string("c2")]))
                == #"{"kind":"select","value":["c2"],"widget":"outline"}"#)
        #expect(
            try json(SurfaceTreeLogic.activateEvent(widget: "outline", id: .string("d")))
                == #"{"kind":"activate","value":["d"],"widget":"outline"}"#)
        #expect(
            try json(SurfaceTreeLogic.deleteEvent(widget: "outline", ids: [.string("c")]))
                == #"{"kind":"delete","value":["c"],"widget":"outline"}"#)
        #expect(
            try json(
                SurfaceTreeLogic.changeEvent(
                    widget: "outline", expanded: [.string("c1"), .string("c2")]))
                == #"{"kind":"change","value":["c1","c2"],"widget":"outline"}"#)
    }

    @Test("a numeric id is sent as a JSON number, not as text")
    func numericIDsStayNumbers() throws {
        #expect(
            try json(SurfaceTreeLogic.selectEvent(widget: "outline", ids: [.int(7)]))
                == #"{"kind":"select","value":[7],"widget":"outline"}"#)
        #expect(
            try json(SurfaceTreeLogic.menuEvent(widget: "outline", id: .int(7), action: "Delete"))
                == #"{"kind":"menu","value":{"action":"Delete","id":7},"widget":"outline"}"#)
    }

    @Test("rename, menu and move carry their objects")
    func objectEvents() throws {
        #expect(
            try json(
                SurfaceTreeLogic.renameEvent(widget: "outline", id: .string("b"), label: "library"))
                == #"{"kind":"rename","value":{"id":"b","label":"library"},"widget":"outline"}"#)
        #expect(
            try json(
                SurfaceTreeLogic.menuEvent(widget: "outline", id: .string("b"), action: "Delete"))
                == #"{"kind":"menu","value":{"action":"Delete","id":"b"},"widget":"outline"}"#)
        #expect(
            try json(
                SurfaceTreeLogic.moveEvent(
                    widget: "outline", ids: [.string("c"), .string("d")], to: .string("a"), index: 1))
                == #"{"kind":"move","value":{"ids":["c","d"],"index":1,"to":"a"},"widget":"outline"}"#)
        // To the root: `to` is JSON null.
        #expect(
            try json(SurfaceTreeLogic.moveEvent(widget: "outline", ids: [.string("c")], to: nil, index: 0))
                == #"{"kind":"move","value":{"ids":["c"],"index":0,"to":null},"widget":"outline"}"#)
    }

    // MARK: Rename

    @Test("an unchanged or empty label is not a rename")
    func committedLabel() {
        #expect(SurfaceTreeLogic.committedLabel(draft: "library", original: "Library") == "library")
        #expect(SurfaceTreeLogic.committedLabel(draft: "  library \n", original: "Library") == "library")
        #expect(SurfaceTreeLogic.committedLabel(draft: "Library", original: "Library") == nil)
        #expect(SurfaceTreeLogic.committedLabel(draft: "   ", original: "Library") == nil)
    }
}
