//
//  PublicationTagRemoval.swift
//  PublicationManagerCore
//
//  Remove Tag for a publication row — the verb behind the row menu's
//  "Remove Tag ›" (`PublicationRowContextMenu`, which the legacy list and the
//  layout tree's `list` pane share), the row's own tag chip menu, and the
//  legacy list's tag-delete mode.
//
//  All three were wired to an empty closure. `onRemoveTag` handed its handler
//  a tag UUID and the store keys tag membership by PATH, and the closure's
//  TODO said a lookup was missing — but the row data every caller holds
//  already carries the path (`TagDisplayData.path`), so the action now takes
//  the path and nothing needs a lookup.
//
//  The store verb is `RustStoreAdapter.removeTag` — the one `addTag` pairs
//  with, so both tag verbs go through imbib's operation log and
//  `UndoCoordinator`, and one ⌘Z / Edit ▸ Undo reverses either.
//

import Foundation
import ImpressFTUI
import ImpressLogging

@MainActor
public enum PublicationTagRemoval {

    /// Every tag the rows in `ids` carry, one entry per path, in path order —
    /// what "Remove Tag ›" offers.
    public static func removableTags(
        ids: Set<UUID>, row: (UUID) -> PublicationRowData?
    ) -> [TagDisplayData] {
        var byPath: [String: TagDisplayData] = [:]
        for id in ids {
            for tag in row(id)?.tagDisplays ?? [] where byPath[tag.path] == nil {
                byPath[tag.path] = tag
            }
        }
        return byPath.values.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    /// The rows among `ids` that carry `path` — the only ones a removal
    /// touches, so the undo entry names exactly what changed.
    public static func carriers(
        of path: String, in ids: Set<UUID>, row: (UUID) -> PublicationRowData?
    ) -> Set<UUID> {
        ids.filter { id in row(id)?.tagDisplays.contains { $0.path == path } ?? false }
    }

    /// Remove `path` from `ids`, undoably, with the three-point trace
    /// (mutation here, save here, display from whichever list re-reads its
    /// rows next — `reportDisplay`).
    public static func remove(_ path: String, from ids: Set<UUID>) {
        guard !ids.isEmpty else {
            logInfo("removeTag: '\(path)' — no row carries it, nothing to do", category: "tags")
            return
        }
        let adapter = RustStoreAdapter.shared
        logInfo("removeTag: removing '\(path)' from \(ids.count) pub(s)", category: "tags")
        adapter.removeTag(ids: Array(ids), tagPath: path)

        let stillTagged = ids.filter { id in
            adapter.getPublication(id: id)?.tagDisplays.contains { $0.path == path } ?? false
        }.count
        logInfo(
            "removeTag save: the store reads '\(path)' on \(stillTagged) of \(ids.count) pub(s)"
                + " (undo: \(UndoCoordinator.shared.undoManager?.canUndo == true ? "registered" : "NO undo manager"))",
            category: "tags")

        pending = Pending(path: path, ids: ids, until: Date().addingTimeInterval(120))
    }

    // MARK: - Display

    private struct Pending {
        let path: String
        let ids: Set<UUID>
        let until: Date
    }

    /// The last removal, for two minutes — long enough to see the rows
    /// re-read after it, and after an Undo or Redo of it.
    private static var pending: Pending?

    /// Called by a publication list after it re-reads its rows: logs how many
    /// of the rows the last removal touched are on screen and how many of
    /// those still SHOW the tag. Silent when none of them is in `rows`.
    public static func reportDisplay(
        surface: String, rows: [(id: UUID, tagPaths: [String])]
    ) {
        guard let pending else { return }
        guard pending.until > Date() else {
            self.pending = nil
            return
        }
        let shown = rows.filter { pending.ids.contains($0.id) }
        guard !shown.isEmpty else { return }
        let showing = shown.filter { $0.tagPaths.contains(pending.path) }.count
        logInfo(
            "removeTag display (\(surface)): \(showing) of \(shown.count) affected row(s) show '\(pending.path)'",
            category: "tags")
    }
}
