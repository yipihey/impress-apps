#if os(macOS)
// Chassis file — macOS-only. Plan wave 7, T4 (review PH-M6, PH-M10).
//
//  LayoutPaneViewState.swift
//  PublicationManagerCore
//
//  Writing a pane's `view_state`, and finding a pane by what it shows.
//
//  `PaneSpec.view_state` is opaque to the tree and owned by the view kind
//  (ADR-0031 D1): the console keeps its scope there, a scoped legacy pane its
//  route. State a pane must keep across a re-layout — the `info` pane's
//  detail tab — belongs there too, not in view `@State`, which a split
//  rebuilds by structure. Writing it is an ordinary `set-pane` verb: attributed,
//  undoable on the pane's exploration ring, visible at `/api/layout/tree`, and
//  replayable by an agent that sends the same verb.
//
//  The spec sent back is the one Rust just returned for the pane
//  (`SharedLayout.pane`), with only `view_state` changed — this file decides
//  nothing about the rest of it.
//

import Foundation
import ImpressLayout
import ImpressLogging

@MainActor
enum LayoutPaneViewState {

    /// Merge `fields` into `tile`'s `view_state` and apply it as `set-pane`.
    ///
    /// A write that changes nothing is not sent: it would be an undo entry
    /// for no change. Returns whether the pane now carries `fields`.
    @discardableResult
    static func merge(
        _ fields: [String: LayoutJSONValue], into tile: UInt64,
        controller: LayoutController, why: String
    ) -> Bool {
        guard let pane = controller.pane(tile) else {
            logWarning("pane \(tile) view_state: no such pane — \(why) not written", category: "layout")
            return false
        }
        guard var spec = (try? LayoutJSONValue.decode(pane.specJson))?.objectValue else {
            logWarning(
                "pane \(tile) view_state: its spec did not decode — \(why) not written", category: "layout")
            return false
        }
        var state = spec["view_state"]?.objectValue ?? [:]
        let before = state
        for (key, value) in fields { state[key] = value }
        if state == before { return true }
        spec["view_state"] = .object(state)
        let verb = LayoutJSONValue.object([
            "verb": .string("set-pane"),
            "target": LayoutPaneRef.id(tile).json,
            "spec": .object(spec),
        ])
        // 1. MUTATION
        let summary = fields.keys.sorted().map { "\($0)=\(fields[$0].map(describe) ?? "?")" }
            .joined(separator: ", ")
        logInfo("pane \(tile) view_state: \(summary) — \(why)", category: "layout")
        do {
            let applied = try controller.applyVerbJSON(verb.jsonString(), actor: LayoutController.guiActor)
            // 2. SAVE
            logInfo(
                "pane \(tile) view_state applied → version \(applied.version)", category: "layout")
            return true
        } catch {
            logWarning("pane \(tile) view_state refused: \(error) — \(why)", category: "layout")
            return false
        }
    }

    /// The pane showing `viewKind` on the same channel as `tile` (never
    /// `tile` itself), lowest tile id first so the answer is stable.
    ///
    /// "Same channel" is the tree's rule for "follows the same selection"
    /// (ADR-0031 D3): a `pdf` pane on another channel shows another paper.
    static func pane(
        showing viewKind: ViewKindID, onChannelOf tile: UInt64, in tree: LayoutTree
    ) -> UInt64? {
        guard let spec = tree.pane(tile) else { return nil }
        let channel = channelNumber(of: tile, spec: spec, in: tree)
        return tree.tiles.keys.sorted().first { id in
            guard id != tile, let other = tree.pane(id), other.viewKind == viewKind.rawValue
            else { return false }
            return channelNumber(of: id, spec: other, in: tree) == channel
        }
    }

    private static func channelNumber(of tile: UInt64, spec: LayoutPaneSpec, in tree: LayoutTree) -> UInt8 {
        spec.channel.resolved(windowDefault: tree.window(containing: tile)?.defaultChannel ?? .number(1))
    }

    private static func describe(_ value: LayoutJSONValue) -> String {
        value.stringValue ?? ((try? value.jsonString()) ?? "?")
    }
}
#endif
