#if os(macOS)
// Chassis file — macOS-only. ADR-0031 work package L6.
//
//  LayoutController+Automation.swift
//  PublicationManagerCore
//
//  The live tree, as the HTTP automation surface drives it.
//
//  `LayoutAutomationRoutes` (ImpressAutomation) owns the envelope — paths,
//  status codes, the 409 when no tree is rendering. This file owns the
//  VOCABULARY, and it is the only file that may: a verb spelling here is the
//  same `LayoutVerb`/`impress_layout::Verb` the keyboard grammar uses, so an
//  agent's split and a person's split are one code path with two actors.
//
//  THE TREE-SHAPED VERBS ARE NOT ENUMERATED. `applyLayoutVerb` forwards the
//  request body verbatim to `SharedLayout.apply(verbJson:actor:)`, which is
//  what `LayoutController.perform` does for every `LayoutVerb` that has a
//  `verbJSON`. A Swift mirror of the `Verb` enum here would be a third copy
//  (Rust, `LayoutVerb`, this) and the one most likely to rot: nothing in the
//  app calls it, so nothing would fail when Rust grew a case. What IS
//  enumerated is the short list of operations that are NOT `Verb` cases —
//  undo, redo, resize-share, save-layout, apply-layout, delete-layout —
//  because those go through typed FFI methods rather than the JSON door.
//
//  ACTOR. `LayoutAutomationRoutes.actor` ("agent"), never `guiActor`. The
//  undo rings are per-actor-visible in the log, and a script's arrangement
//  change that claimed to be the human's would be unreadable in exactly the
//  session where it matters.
//

import Foundation
import ImpressAutomation
import ImpressLogging
import ImpressRustCore

extension LayoutController: LayoutAutomationHost {

    public var layoutAppID: String { appID }

    // MARK: Reads

    public func layoutTreeJSON() -> [String: Any] {
        var payload: [String: Any] = ["version": version]
        if let focused { payload["focused"] = focused }
        if let error = lastError { payload["lastError"] = error }
        // The tree itself is Rust's JSON, decoded here only so the response is
        // one object rather than an object with a string of JSON inside it.
        if let snapshot = try? liveSnapshot() {
            payload["layout"] = snapshot
        } else {
            payload["layout"] = NSNull()
        }
        return payload
    }

    public func savedLayoutsJSON() -> [[String: Any]] {
        savedLayouts().map { row in
            var dict: [String: Any] = [
                "id": row.id,
                "ordinal": row.ordinal,
                "created": row.created,
                "modified": row.modified,
            ]
            if let name = row.name { dict["name"] = name }
            if let purpose = row.purpose { dict["purpose"] = purpose }
            return dict
        }
    }

    // MARK: Mutations

    public func applyLayoutVerb(_ verb: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: verb)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LayoutAutomationError.badVerb("verb body is not UTF-8")
        }
        return try applied(
            applyVerbJSON(json, actor: LayoutAutomationRoutes.actor),
            describing: "verb \(verb["verb"] as? String ?? "?")")
    }

    public func applyLayoutOperation(
        _ operation: String, body: [String: Any]
    ) throws -> [String: Any] {
        let verb: LayoutVerb
        switch operation {
        case "undo", "redo":
            // The stack is explicit and has no default: "undo" that silently
            // means "the window's shape" would eventually undo an arrangement
            // an agent thought it was undoing a selection on (ADR-0031 D7).
            guard let raw = body["stack"] as? String,
                let stack = LayoutUndoStack(rawValue: raw)
            else {
                throw LayoutAutomationError.badVerb(
                    "\(operation) needs {\"stack\": \"arrangement\"|\"exploration\"}")
            }
            let pane = (body["pane"] as? NSNumber).map { UInt64(truncating: $0) }
            verb = operation == "undo" ? .undo(stack: stack, pane: pane) : .redo(stack: stack, pane: pane)

        case "resize-share":
            guard let pane = (body["pane"] as? NSNumber).map({ UInt64(truncating: $0) }),
                let share = body["share"] as? Double
            else {
                throw LayoutAutomationError.badVerb(
                    "resize-share needs {\"pane\": <tile id>, \"share\": <0…1>}")
            }
            verb = .resizeShare(pane: pane, share: share)

        case "save-layout":
            guard let name = body["name"] as? String, !name.isEmpty else {
                throw LayoutAutomationError.badVerb("save-layout needs {\"name\": ...}")
            }
            verb = .saveLayout(name: name, purpose: body["purpose"] as? String)

        case "apply-layout":
            // `name` or `ordinal` — the ⌃⌘1–9 chords name layouts by position.
            let target: String?
            if let name = body["name"] as? String, !name.isEmpty {
                target = name
            } else if let ordinal = body["ordinal"] as? NSNumber {
                target = "\(ordinal.intValue)"
            } else {
                target = nil
            }
            guard let nameOrOrdinal = target else {
                throw LayoutAutomationError.badVerb(
                    "apply-layout needs {\"name\": ...} or {\"ordinal\": 1…9}")
            }
            verb = .applyLayout(nameOrOrdinal: nameOrOrdinal)

        case "delete-layout":
            guard let nameOrId = body["name"] as? String, !nameOrId.isEmpty else {
                throw LayoutAutomationError.badVerb("delete-layout needs {\"name\": ...}")
            }
            verb = .deleteLayout(nameOrId: nameOrId)

        default:
            throw LayoutAutomationError.badVerb("unknown layout operation '\(operation)'")
        }

        return try applied(
            performForAutomation(verb, actor: LayoutAutomationRoutes.actor),
            describing: verb.traceDescription)
    }

    // MARK: Shared shaping

    /// The same three-point trace `apply(_:)` writes, and the same adoption of
    /// what Rust handed back — so an HTTP verb is indistinguishable from a
    /// keystroke everywhere except the actor field.
    private func applied(
        _ result: SharedAppliedVerb, describing what: String
    ) throws -> [String: Any] {
        logInfo(
            "layout applied (agent): \(what) → version \(result.version), "
                + "\(result.affectedPanes.count) affected, \(result.changedTiles.count) changed",
            category: "layout")
        var payload: [String: Any] = [
            "version": result.version,
            "affectedPanes": result.affectedPanes,
            "changedTiles": result.changedTiles,
        ]
        if let focused = result.focused { payload["focused"] = focused }
        if let tree = try? JSONSerialization.jsonObject(
            with: Data(result.layoutJson.utf8)) as? [String: Any]
        {
            payload["layout"] = tree
        }
        return payload
    }
}

/// What this surface refuses before Rust ever sees it: a body that is not a
/// verb. Rust's own refusals come back as `SharedLayoutError` and are
/// reported with their own message.
public enum LayoutAutomationError: Error, CustomStringConvertible {
    case badVerb(String)

    public var description: String {
        switch self {
        case .badVerb(let message): return message
        }
    }
}
#endif
