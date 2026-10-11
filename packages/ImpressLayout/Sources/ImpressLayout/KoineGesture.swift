#if os(macOS)
// Kit file (ImpressLayout) — macOS-only.
//
//  KoineGesture.swift
//  ImpressLayout
//
//  The chassis half of `koine::gesture`. A click, a drag, and a direction
//  key are one value, and `layoutVerb` is the layout verb that value already
//  determines — the same function as `koine::gesture::layout_verb`. A button
//  that is not a known view kind stays a surface event. A menu click stays
//  a menu. The committed cases are `crates/koine/tests/fixtures/gesture-verbs.json`.

import Foundation

/// The element a gesture names. A surface widget and a layout tile are both
/// addresses. `focused` is the element the cursor is on.
public enum KoineElement: Equatable, Sendable {
    case widget(String)
    case tile(UInt64)
    case focused
}

/// One edge of a frame.
public enum KoineEdge: String, Equatable, Sendable {
    case left, right, top, bottom
}

/// What a person did, as `koine::gesture::Gesture` serializes it.
public enum KoineGesture: Equatable, Sendable {
    case focus(KoineElement)
    case activate(KoineElement)
    case secondary(KoineElement)
    case move(LayoutFocusDirection)
    case drag(element: KoineElement, target: KoineElement, placement: LayoutPlacement)
    case resize(element: KoineElement, edge: KoineEdge)

    /// The layout verb this gesture determines.
    ///
    /// `pane` is the tile the pointer landed in. A tab click that names a
    /// known view kind shows that kind on the pane. A drag of a tile onto
    /// itself is nil; the host asks `tabSplitTarget` for the sibling and
    /// calls this again. A resize is nil; the host measures the two sides
    /// and calls `resizeVerbJSON`.
    public func layoutVerb(pane: UInt64? = nil) -> LayoutVerb? {
        switch self {
        case .focus(.tile(let id)):
            return .focus(target: .id(id))
        case .focus(.focused):
            return .focus(target: .focused)
        case .activate(.widget(let id)):
            guard let pane, ViewKindID.vocabulary.contains(ViewKindID(id)) else { return nil }
            return .setViewKind(target: .id(pane), viewKind: ViewKindID(id))
        case .move(let direction):
            return .focusDirection(direction)
        case .drag(.tile(let tile), .tile(let target), let placement) where tile != target:
            return .move(tile: .id(tile), target: .id(target), placement: placement)
        case .focus, .activate, .secondary, .drag, .resize:
            return nil
        }
    }

    /// The serde document of `verb`, including `focus-direction`, which the
    /// live host applies through its typed method and so has no `verbJSON`.
    public static func document(for verb: LayoutVerb) -> LayoutJSONValue? {
        if case .focusDirection(let direction) = verb {
            return .object([
                "verb": .string("focus-direction"),
                "direction": .string(direction.rawValue),
            ])
        }
        return verb.verbJSON
    }
}

extension KoineGesture {
    /// Where a spawned pane is inserted. `intoTabs` is a split to the right:
    /// a pane that does not exist yet cannot join a tab strip.
    public static func splitAxes(_ placement: LayoutPlacement) -> (LayoutLinearDirection, Bool) {
        switch placement {
        case .left:
            return (.horizontal, false)
        case .right, .intoTabs:
            return (.horizontal, true)
        case .above:
            return (.vertical, false)
        case .below:
            return (.vertical, true)
        }
    }

    /// The sibling a drop on one's own edge splits beside. Left and above
    /// prefer the previous tab; right and below prefer the next.
    public static func tabSplitTarget(
        children: [UInt64], index: Int, placement: LayoutPlacement
    ) -> UInt64? {
        guard children.count >= 2, children.indices.contains(index), placement != .intoTabs
        else { return nil }
        let neighbour: Int
        switch placement {
        case .left, .above:
            neighbour = index > 0 ? index - 1 : index + 1
        case .right, .below:
            neighbour = index + 1 < children.count ? index + 1 : index - 1
        case .intoTabs:
            return nil
        }
        return children[neighbour]
    }

    /// `set-tab-order` after moving `tabs[from]` to the drop index `to`.
    /// `to` is an index in the list before the removal. A drop that leaves
    /// the order unchanged returns nil.
    public static func tabOrderVerb(
        pane: UInt64, tabs: [String], from: Int, to: Int
    ) -> LayoutVerb? {
        guard let next = reorder(tabs, from: from, to: to) else { return nil }
        return .setTabOrder(target: .id(pane), tabs: next)
    }

    /// Move `items[from]` so that it lands at the drop index `to`.
    public static func reorder<T>(_ items: [T], from: Int, to: Int) -> [T]? {
        guard items.indices.contains(from), to >= 0, to <= items.count else { return nil }
        var dest = to
        if from < dest { dest -= 1 }
        guard from != dest else { return nil }
        var out = items
        let item = out.remove(at: from)
        out.insert(item, at: min(dest, out.count))
        return out
    }

    /// The child before the divider `edge` of child `index` names.
    public static func dividerIndex(childCount: Int, index: Int, edge: KoineEdge) -> Int? {
        guard childCount >= 2, index >= 0, index < childCount else { return nil }
        switch edge {
        case .right, .bottom:
            return index + 1 < childCount ? index : nil
        case .left, .top:
            return index > 0 ? index - 1 : nil
        }
    }

    /// The share of the child before a divider, after the pointer moved.
    /// `before` and `after` are the on-screen lengths of that child and the
    /// neighbour that gave up the space.
    public static func shareBeside(neighbour: Double, before: Double, after: Double) -> Double? {
        guard neighbour.isFinite, neighbour > 0,
              before.isFinite, before > 0,
              after.isFinite, after > 0
        else { return nil }
        let share = neighbour * before / after
        guard share.isFinite, share > 0 else { return nil }
        return share
    }

    /// The `resize` document after the divider following child `index` moved.
    public static func resizeVerbJSON(
        container: UInt64, shares: [Double], index: Int, before: Double, after: Double
    ) -> LayoutJSONValue? {
        guard shares.indices.contains(index + 1),
              let share = shareBeside(neighbour: shares[index + 1], before: before, after: after)
        else { return nil }
        var next = shares
        next[index] = share
        return .object([
            "verb": .string("resize"),
            "container": .int(Int(container)),
            "shares": .array(next.map { .double($0) }),
        ])
    }
}
#endif
