//
//  SurfaceTreeLogic.swift
//  ImpressSurface
//
//  The pure half of the `tree` widget: which text stands for a row id, what
//  list a disclosure click sends, and the exact value of every event a tree
//  sends. Kept out of `SurfaceTreeView` so a test can pin them without a
//  view, and so the wire shapes live in one place, mirrored from koine's
//  `docs/outline.md` § 3 ("The events", the values `tests/outline.rs` sends):
//
//    select    ["c2"]                                  on_select
//    change    ["c1", "c2"]  (the whole expanded list)  writes `bind`
//    rename    {"id": "b", "label": "library"}          on_rename
//    delete    ["c"]                                    on_delete
//    activate  ["d"]                                    on_activate
//    move      {"ids": ["c"], "to": "a", "index": 1}    on_move
//    menu      {"id": "b", "action": "Delete"}          that entry's on_click
//
//  None of this decides whether a tree HAS a handler for an event: a tree
//  with none ignores it, in `impress_surface::reduce`, on the far side of
//  `SharedSurface.dispatch`.
//

import Foundation

public enum SurfaceTreeLogic {

    // MARK: Row keys

    /// The text a row is known by inside the view (a `List` selection is a
    /// `Set<String>`, a drag carries a string). Total and collision-free
    /// across the two id spellings a row can have: the string `"1"` and the
    /// number `1` are different rows to Rust (two ids are the same when their
    /// JSON is), so they get different keys. It is never parsed back; the
    /// view keeps a `[key: id]` table instead, so the id an event carries is
    /// the original JSON value, string or number.
    public static func key(for id: SurfaceJSONValue) -> String {
        switch id {
        case .string(let value): return "s:" + value
        case .int(let value): return "n:" + String(value)
        case .double(let value): return "n:" + String(value)
        case .bool(let value): return "b:" + String(value)
        case .null: return "z:"
        case .array, .object: return "j:" + ((try? id.jsonString()) ?? "")
        }
    }

    /// `key → id` for the visible nodes.
    public static func idsByKey(_ nodes: [SurfaceTreeNode]) -> [String: SurfaceJSONValue] {
        var table: [String: SurfaceJSONValue] = [:]
        for node in nodes { table[key(for: node.id)] = node.id }
        return table
    }

    /// The ids behind `keys`, in the order the nodes are drawn; a key that no
    /// visible node has (a row a re-render removed) is dropped.
    public static func orderedIDs(
        keys: Set<String>, in nodes: [SurfaceTreeNode]
    ) -> [SurfaceJSONValue] {
        nodes.filter { keys.contains(key(for: $0.id)) }.map(\.id)
    }

    // MARK: Disclosure

    /// The list a disclosure click sends: the WHOLE expanded list (the one
    /// `RenderKind.tree.expanded` carries, including branches a collapsed
    /// ancestor hides) with `id` removed when the node is open and added when
    /// it is closed. `currentlyExpanded` is the node's own flag; collapsing a
    /// branch therefore keeps its descendants' state for when it opens again.
    public static func toggled(
        _ expanded: [SurfaceJSONValue], id: SurfaceJSONValue, currentlyExpanded: Bool
    ) -> [SurfaceJSONValue] {
        if currentlyExpanded {
            return expanded.filter { $0 != id }
        }
        return expanded.contains(id) ? expanded : expanded + [id]
    }

    // MARK: Events

    public static func changeEvent(widget: String, expanded: [SurfaceJSONValue]) -> SurfaceEvent {
        SurfaceEvent(widget: widget, kind: .change, value: .array(expanded))
    }

    public static func selectEvent(widget: String, ids: [SurfaceJSONValue]) -> SurfaceEvent {
        SurfaceEvent(widget: widget, kind: .select, value: .array(ids))
    }

    public static func activateEvent(widget: String, id: SurfaceJSONValue) -> SurfaceEvent {
        SurfaceEvent(widget: widget, kind: .activate, value: .array([id]))
    }

    public static func deleteEvent(widget: String, ids: [SurfaceJSONValue]) -> SurfaceEvent {
        SurfaceEvent(widget: widget, kind: .delete, value: .array(ids))
    }

    public static func renameEvent(
        widget: String, id: SurfaceJSONValue, label: String
    ) -> SurfaceEvent {
        SurfaceEvent(
            widget: widget, kind: .rename,
            value: .object(["id": id, "label": .string(label)]))
    }

    /// `to` is the new parent's id (`nil` is the root, sent as JSON null);
    /// `index` the position among the new siblings. A drop ON a row is
    /// `index` 0 under it; this renderer has no between-rows drop.
    public static func moveEvent(
        widget: String, ids: [SurfaceJSONValue], to: SurfaceJSONValue?, index: Int
    ) -> SurfaceEvent {
        SurfaceEvent(
            widget: widget, kind: .move,
            value: .object([
                "ids": .array(ids),
                "to": to ?? .null,
                "index": .int(index),
            ]))
    }

    public static func menuEvent(
        widget: String, id: SurfaceJSONValue, action: String
    ) -> SurfaceEvent {
        SurfaceEvent(
            widget: widget, kind: .menu,
            value: .object(["id": id, "action": .string(action)]))
    }

    // MARK: Rename

    /// The text a rename commits, or nil when there is nothing to send: an
    /// unchanged label or an empty one is not a rename.
    public static func committedLabel(draft: String, original: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != original else { return nil }
        return trimmed
    }
}
