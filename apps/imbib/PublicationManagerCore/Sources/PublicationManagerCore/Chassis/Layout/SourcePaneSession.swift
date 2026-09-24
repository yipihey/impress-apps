#if os(macOS)
// Chassis file — macOS-only. Plan wave 6, W4 pass B (ADR-0031 D6).
//
//  SourcePaneSession.swift
//  PublicationManagerCore
//
//  The session a `source` pane carries: its editor.
//
//  Keyed by the pane's `SessionId`, which Rust decides (`impress_layout`
//  `sessions.rs`): every `source` pane has one, a split's new pane gets a new
//  one, and no swap, move, close or preset change takes a pane's away. So
//  whichever SwiftUI view ends up showing that pane after a re-layout asks
//  `registry` for the session and gets the SAME `TypstEditorHost` — the same
//  `NSTextView`, the same undo histories — with no `.id` anywhere.
//
//  What a session holds, and what it does not:
//
//  * the EDITOR (`TypstEditorHost`): scroll view, text view, coordinator, one
//    UndoManager per manuscript it has shown;
//  * a reference to the manuscript it shows (`ManuscriptEditorSession`, from
//    `ManuscriptSessionRegistry` — the one save and compile path; this type
//    adds none).
//
//  Lifetime: a closed pane's session stays in the LRU until it is evicted
//  (D6 — "closing the pane releases the session through the registry's LRU,
//  not through view identity"); an on-screen session is never evicted
//  (`isPinned`). A manuscript being deleted is abandoned by every session
//  showing it BEFORE the row goes (`abandonEverywhere`), so no save fires
//  after the delete.
//

import Foundation
import ImpressLogging

@MainActor
public final class SourcePaneSession: PaneSession {

    /// Where every `source` pane's session lives. Capacity is the number of
    /// OFF-screen editors kept warm; on-screen ones never count against it.
    public static let registry = PaneSessionRegistry<SourcePaneSession>(capacity: 6, label: "source")

    public let sessionID: String

    let editor: TypstEditorHost

    /// The manuscript session the editor is bound to right now.
    private(set) var manuscript: ManuscriptEditorSession?

    init(sessionID: String) {
        self.sessionID = sessionID
        self.editor = TypstEditorHost(label: "source session \(sessionID.suffix(8))")
    }

    /// The session for a pane, made on first use.
    static func forPane(_ sessionID: String) -> SourcePaneSession? {
        registry.session(for: sessionID) { SourcePaneSession(sessionID: sessionID) }
    }

    /// Bind the editor to `session` (or to nothing).
    func show(_ session: ManuscriptEditorSession?) {
        guard session !== manuscript else { return }
        manuscript = session
        if let session {
            editor.remember(document: session.manuscriptID)
        }
    }

    // MARK: PaneSession

    /// Evicted from the LRU: commit what the buffer holds. The editor itself
    /// goes with the session.
    public func flush() {
        manuscript?.flush()
    }

    /// The manuscript is being deleted: cancel its pending save, keep
    /// nothing.
    public func abandon() {
        if let manuscript {
            abandon(manuscriptID: manuscript.manuscriptID)
        }
    }

    public var isPinned: Bool {
        editor.scrollView?.window != nil
    }

    // MARK: Deletion

    func abandon(manuscriptID: UUID) {
        let showing = manuscript?.manuscriptID == manuscriptID
        if showing {
            manuscript?.abandonPendingSave()
            manuscript = nil
        }
        guard editor.forget(document: manuscriptID) || showing else { return }
        logInfo(
            "source session \(sessionID): abandoned manuscript \(manuscriptID.uuidString) "
                + "(deleted) — \(showing ? "was on screen; " : "")pending save cancelled, "
                + "undo history dropped, nothing written",
            category: "layout")
    }

    /// Every `source` session drops `manuscriptID`. Call BEFORE the delete,
    /// beside `ManuscriptSessionRegistry.discard(id:)`.
    public static func abandonEverywhere(manuscriptID: UUID) {
        for session in registry.liveSessions {
            session.abandon(manuscriptID: manuscriptID)
        }
    }
}
#endif
