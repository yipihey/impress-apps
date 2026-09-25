#if os(macOS)
//
//  TypstEditorHost.swift
//  PublicationManagerCore
//
//  An editor that outlives the SwiftUI views showing it (ADR-0031 D6).
//
//  The Source tab builds its `NSTextView` in `TypstEditorRepresentable
//  .makeNSView` and loses it in `dismantleNSView`: its undo lives in the
//  window, and a remount is a new editor. A layout-tree `source` pane cannot
//  work that way — a split wraps the pane in a new container, so SwiftUI
//  rebuilds the pane's host by STRUCTURE, with or without `.id` — and D6 says
//  no layout mutation may tear an editor down.
//
//  So a pane's editor lives here, owned by its `SourcePaneSession` in a
//  `PaneSessionRegistry` keyed by the pane's `SessionId`. The representable
//  builds it ONCE (through the same `makeEditor` the Source tab uses) and
//  thereafter only moves it: into each new container on mount, out of an old
//  one on dismantle — never destroying it. One coordinator goes with it (it is
//  the text view's delegate), and one UndoManager PER MANUSCRIPT the editor
//  has shown, so a pane switching documents never mixes their histories and a
//  document coming back brings its own.
//
//  The TEXT is not here: it is the manuscript's `ManuscriptEditorSession`
//  (buffer, debounced commit, compile), bound through the representable's
//  `source` binding like the Source tab's. This type decides only what the
//  VIEW does when that text changes under it.
//

import AppKit
import ImpressHelixCore
import ImpressLogging

@MainActor
final class TypstEditorHost {

    /// For the log: which pane session this editor belongs to.
    let label: String

    /// The Helix state the editor's adaptor was built with. Held here, not in
    /// `SourceEditorView`'s `@State`, because the adaptor outlives that view.
    let helixState = HelixState()

    /// The text view's delegate, shared by every representable that mounts
    /// this editor (see `TypstEditorRepresentable.makeCoordinator`).
    var coordinator: TypstEditorRepresentable.Coordinator?

    private(set) var scrollView: NSScrollView?

    var textView: TypstTextView? { scrollView?.documentView as? TypstTextView }

    /// The manuscript the editor shows right now.
    private(set) var documentID: UUID?

    /// One history per manuscript this editor has shown.
    private var undoManagers: [UUID: UndoManager] = [:]

    /// The text each document had when the editor last left it. A document
    /// that comes back with other text (edited elsewhere meanwhile) cannot
    /// keep its history: every entry in it is a range into the old text.
    private var textWhenLeft: [UUID: String] = [:]

    /// Manuscripts deleted while this editor knew them. A SwiftUI pass still
    /// holding the old binding can ask to show one after the delete; it is
    /// ignored until a fresh session for it is shown (`remember`), which is
    /// what an Edit ▸ Undo of the delete produces.
    private var forgotten: Set<UUID> = []

    /// How many times the editor has been put into a pane container.
    private(set) var mounts = 0

    init(label: String) {
        self.label = label
    }

    /// The editor's identity, for the log and the proof: the same value
    /// across a split, a swap and a preset change is the whole claim.
    var viewIdentity: String {
        guard let textView else { return "none" }
        return String(describing: ObjectIdentifier(textView))
    }

    // MARK: - Mounting

    func adopt(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        logInfo("\(label): built editor \(viewIdentity)", category: "layout")
    }

    /// Move the editor into `container` — out of wherever it was.
    func mount(in container: NSView) {
        guard let scrollView else { return }
        let moved = scrollView.superview != nil
        scrollView.removeFromSuperview()
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        mounts += 1
        logInfo(
            "\(label): editor \(viewIdentity) mounted (mount \(mounts)"
                + (moved ? ", moved from another pane host)" : ")"),
            category: "layout")
    }

    /// The pane host `container` is going away. Take the editor out ONLY if
    /// it is still there — a split builds the new host before it dismantles
    /// the old one, and by then the editor already lives in the new one.
    /// Is the editor mounted in `container` right now? Only the
    /// representable whose container holds it may act on it — detach it, or
    /// repoint the shared coordinator at its bindings (review PH-L1).
    func holdsEditor(in container: NSView) -> Bool {
        scrollView?.superview === container
    }

    func detach(from container: NSView) {
        guard let scrollView, holdsEditor(in: container) else { return }
        scrollView.removeFromSuperview()
        coordinator?.resignCitationInsertion()
        logInfo("\(label): editor \(viewIdentity) detached (kept, not destroyed)", category: "layout")
    }

    // MARK: - Documents

    enum Presentation {
        /// Nothing to do.
        case unchanged
        /// Another manuscript: its text and its own history.
        case switched
        /// The same manuscript, changed by someone else (a merge, another
        /// process, a snippet insert) — applied in place.
        case external
    }

    /// Show `text` as document `id`, deciding whether that is a switch or an
    /// external change to the document already shown.
    func present(document id: UUID?, text: String, in textView: TypstTextView) -> Presentation {
        if let id, forgotten.contains(id) { return .unchanged }
        if id != documentID {
            if let previous = documentID {
                textWhenLeft[previous] = textView.string
            }
            textView.breakUndoCoalescing()
            if let id, let left = textWhenLeft[id], left != text, let history = undoManagers[id] {
                history.removeAllActions()
                logInfo(
                    "\(label): \(id.uuidString) changed while away — its undo history no longer "
                        + "matches the text and was cleared",
                    category: "layout")
            }
            documentID = id
            textView.documentUndoManager = id.map(history(for:))
            if textView.string != text {
                textView.string = text
            }
            logInfo(
                "\(label): editor \(viewIdentity) shows manuscript \(id?.uuidString ?? "none") "
                    + "(\((text as NSString).length) chars, undo "
                    + "\(textView.documentUndoManager?.canUndo == true ? "available" : "empty"))",
                category: "layout")
            return .switched
        }
        guard textView.string != text else { return .unchanged }
        applyExternal(text, to: textView)
        return .external
    }

    /// Replace only the span that differs, so the caret, the scroll position
    /// and the view itself stay put (D6 liveness: the pane shows the new text
    /// without a remount). The document's history is cleared: its entries are
    /// ranges into the text as it was, and replaying one against the new text
    /// would corrupt it.
    private func applyExternal(_ text: String, to textView: TypstTextView) {
        guard let storage = textView.textStorage else {
            textView.string = text
            return
        }
        let old = storage.string as NSString
        let new = text as NSString
        let limit = min(old.length, new.length)
        var prefix = 0
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < limit - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        let replaced = NSRange(location: prefix, length: old.length - prefix - suffix)
        let inserted = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        let delta = (inserted as NSString).length - replaced.length

        var selection = textView.selectedRange()
        storage.replaceCharacters(in: replaced, with: inserted)
        if selection.location >= NSMaxRange(replaced) {
            selection.location += delta
        } else if selection.location > replaced.location {
            selection = NSRange(location: replaced.location + (inserted as NSString).length, length: 0)
        }
        selection.location = min(max(0, selection.location), new.length)
        selection.length = min(selection.length, new.length - selection.location)
        textView.setSelectedRange(selection)

        textView.documentUndoManager?.removeAllActions()
        logInfo(
            "\(label): editor \(viewIdentity) took an external change to "
                + "\(documentID?.uuidString ?? "?") in place: \(replaced.length) chars at "
                + "\(replaced.location) replaced by \((inserted as NSString).length); undo history cleared",
            category: "layout")
    }

    /// The manuscript is being DELETED: drop its history and, if it is on
    /// screen, the text — without writing anything anywhere. Returns whether
    /// this editor had ever shown it.
    @discardableResult
    func forget(document id: UUID) -> Bool {
        let known = undoManagers.removeValue(forKey: id) != nil || documentID == id
        textWhenLeft[id] = nil
        forgotten.insert(id)
        guard documentID == id else { return known }
        documentID = nil
        textView?.documentUndoManager = nil
        textView?.string = ""
        return known
    }

    /// A live session for `id` is being shown again (the delete was undone):
    /// it may be presented, with a new, empty history.
    func remember(document id: UUID) {
        forgotten.remove(id)
    }

    private func history(for id: UUID) -> UndoManager {
        if let existing = undoManagers[id] { return existing }
        let created = UndoManager()
        undoManagers[id] = created
        return created
    }
}
#endif
