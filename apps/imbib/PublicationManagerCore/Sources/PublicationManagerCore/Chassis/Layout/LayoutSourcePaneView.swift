#if os(macOS)
// Chassis file — macOS-only. Plan wave 6, W4 pass B (ADR-0031 L8 leaf 6, D6).
//
//  LayoutSourcePaneView.swift
//  PublicationManagerCore
//
//  The `source` view kind: the manuscript Source tab, one per pane, over an
//  editor the PANE owns.
//
//  Map, not rewrite (ADR-0031 D11): the pane renders `ManuscriptSourceTab`
//  unchanged — editor, preview split, compile strip — fed the manuscript the
//  way the other detail panes resolve their item (`single_item`, else the
//  `item` binding). The text comes from `ManuscriptSessionRegistry` like the
//  detail pane's Source tab (one save path, one compile path). What differs
//  is the EDITOR: it is the pane session's `TypstEditorHost`, looked up by the
//  pane spec's `SessionId`, so the same `NSTextView` and its undo histories
//  follow the pane through every split, swap and preset change. There is no
//  `.id` here, and none may be added: view identity is not what keeps the
//  editor, the session is (ADR-0031 D6, ADR-0018 D4).
//
//  A manuscript whose payload carries `external_source` never gets an editor
//  session (ADR-0023 D4): the pane shows its snapshot read-only instead.
//

import ImpressLogging
import SwiftUI

@MainActor
struct LayoutSourcePaneView: View {

    let context: PaneContext

    @Environment(\.layoutToolbarBand) private var toolbarBand

    /// The pane's editor, from the registry by the spec's session id.
    @State private var paneSession: SourcePaneSession?
    /// The manuscript's text session, from `ManuscriptSessionRegistry`.
    @State private var editorSession: ManuscriptEditorSession?
    /// Set instead of `editorSession` for an external-source manuscript.
    @State private var readOnlySnapshot: String?
    /// The last resolve found no row for the manuscript — deleted, not yet
    /// synced, or created by another process a moment from now. Distinct
    /// from "still resolving", which is the brief first pass (PH-M4).
    @State private var notInStore = false

    private var sessionID: String? { context.spec?.session }

    private var rawItem: String? {
        context.singleItem ?? context.bindings["item"]
    }

    private var manuscriptID: UUID? {
        rawItem.flatMap(UUID.init(uuidString:))
    }

    private var isManuscriptPane: Bool {
        context.primaryKind == RecordKindID.manuscript.rawValue
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { resolve() }
            .onChange(of: manuscriptID) { _, _ in resolve() }
            .onChange(of: sessionID) { _, _ in resolve() }
            // With no live session (not in the store yet, or a read-only
            // snapshot), an event naming the manuscript re-resolves: a late
            // row appears and a snapshot is re-read (PH-M4).
            .manuscriptLiveness(editorSession, manuscriptID: manuscriptID) { resolve() }
    }

    @ViewBuilder
    private var content: some View {
        if !isManuscriptPane {
            ChassisEmptyState(
                id: "detail-unavailable",
                title: "Detail Unavailable",
                systemImage: RecordKindDescriptor.unknownSymbolName,
                message: "The \u{201C}source\u{201D} view edits manuscripts; this pane lists "
                    + "\u{201C}\(context.primaryKind ?? "item")\u{201D}."
            )
            .view
        } else if sessionID == nil {
            // Rust gives every `source` pane a session (`sessions.rs`); a pane
            // without one is a tree from a build that predates the rule and
            // has not been through a verb yet.
            ChassisEmptyState(
                id: "pane-unresolved",
                title: "Editor Unavailable",
                systemImage: "rectangle.dashed",
                message: "This source pane has no session yet."
            )
            .view
        } else if let snapshot = readOnlySnapshot {
            readOnly(snapshot)
                .padding(.top, toolbarBand)
        } else if let editorSession, let paneSession,
                  editorSession.manuscriptID == manuscriptID {
            ManuscriptSourceTab(session: editorSession, editorHost: paneSession.editor)
                .padding(.top, toolbarBand)
        } else if let raw = rawItem, manuscriptID == nil {
            ChassisEmptyState(
                id: "detail-unavailable",
                title: "Detail Unavailable",
                systemImage: RecordKindDescriptor.unknownSymbolName,
                message: "No manuscript \u{201C}\(raw)\u{201D}."
            )
            .view
        } else if let id = manuscriptID, notInStore {
            // Said, not blank (PH-M4): the pane followed a selection whose
            // row the store does not have — and it re-resolves on its own
            // when the row arrives.
            ChassisEmptyState(
                id: "manuscript-not-in-store",
                title: "Manuscript Not Found",
                systemImage: "doc.questionmark",
                message: "No manuscript \u{201C}\(id.uuidString)\u{201D} in the store. "
                    + "This pane will show it if it arrives."
            )
            .view
        } else if manuscriptID != nil {
            // Resolving: the first pass after a mount.
            Color.clear
        } else {
            ChassisEmptyState.noRowSelection(kind: .manuscript).view
        }
    }

    private func readOnly(_ snapshot: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(
                "This manuscript indexes a file you edit elsewhere. The store holds a "
                    + "snapshot of it, shown read-only; nothing here writes to the file.",
                systemImage: "lock.doc"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(10)
            Divider()
            ScrollView {
                Text(snapshot)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
    }

    private func resolve() {
        guard let sessionID else {
            paneSession = nil
            logWarning("pane \(context.tile) source: no session id in the spec", category: "layout")
            return
        }
        if paneSession?.sessionID != sessionID {
            paneSession = SourcePaneSession.forPane(sessionID)
        }
        guard let paneSession else { return }
        guard isManuscriptPane, let id = manuscriptID else {
            paneSession.show(nil)
            editorSession = nil
            readOnlySnapshot = nil
            notInStore = false
            if let raw = rawItem {
                // The same kind of line `info` writes for an item it cannot
                // show: the pane followed the selection, and said why there
                // is no editor.
                logInfo(
                    "pane \(context.tile) source: \(context.primaryKind ?? "item") \(raw) — "
                        + "not a manuscript, no editor",
                    category: "layout")
            }
            return
        }
        // ADR-0023 D4, at session CREATION: a file-backed manuscript never
        // gets a session, so there is no debounced save to land late.
        let detail = RustStoreAdapter.shared.getManuscriptDetail(id: id)
        guard detail != nil else {
            paneSession.show(nil)
            editorSession = nil
            readOnlySnapshot = nil
            if !notInStore {
                logInfo(
                    "pane \(context.tile) source: no manuscript \(id.uuidString) in the store — "
                        + "named state; re-resolves on a store event naming it",
                    category: "layout")
            }
            notInStore = true
            return
        }
        notInStore = false
        guard RustStoreAdapter.shared.manuscriptAllowsEditorSession(id: id) else {
            paneSession.show(nil)
            editorSession = nil
            readOnlySnapshot = detail?.bodyContent ?? ""
            logInfo(
                "pane \(context.tile) source: manuscript \(id.uuidString) has external_source — "
                    + "read-only, no editor session",
                category: "layout")
            return
        }
        readOnlySnapshot = nil
        let session = ManuscriptSessionRegistry.shared.session(for: id)
        editorSession = session
        paneSession.show(session)
        logInfo(
            "pane \(context.tile) source: session \(sessionID) manuscript \(id.uuidString) "
                + "editor \(paneSession.editor.viewIdentity) "
                + "(\(SourcePaneSession.registry.count) source sessions live)"
                + (session == nil ? " — not in the store" : ""),
            category: "layout")
    }
}
/// Keep a manuscript session current with writes made elsewhere (D6).
///
/// Two shapes arrive: an in-process write names the manuscript; a write from
/// ANOTHER process (the CLI, an agent) reaches this one only as the store's
/// cross-process signal, which names nothing (`noteExternalMutation` →
/// `.structural`, held for the first 90 s after launch). The detail pane's
/// Source tab hears only the first. `absorbExternalChange` compares hashes
/// and returns at once when this manuscript did not move, so answering every
/// structural event costs one row read.
///
/// When the row is GONE — deleted by another writer, which could not discard
/// this session first — the session is discarded without a flush and dropped
/// from every `source` pane's editor (review PH-M9). With no live session,
/// `reresolve` is called instead, so a pane waiting for a row or showing a
/// read-only snapshot picks up the change (PH-M4).
private struct ManuscriptLiveness: ViewModifier {
    let session: ManuscriptEditorSession?
    let manuscriptID: UUID?
    let reresolve: (@MainActor () -> Void)?

    /// Keyed on the SESSION too: the task captures `session` when it starts,
    /// and on a pane's first pass that is still nil.
    private struct Key: Hashable {
        let manuscriptID: UUID?
        let session: ObjectIdentifier?
    }

    func body(content: Content) -> some View {
        content.task(id: Key(manuscriptID: manuscriptID, session: session.map(ObjectIdentifier.init))) {
            guard let id = manuscriptID else { return }
            for await event in ImbibImpressStore.shared.events.subscribe() {
                switch event {
                case .itemsMutated(_, let ids) where ids.contains(id):
                    break
                case .structural:
                    break
                default:
                    continue
                }
                if let session {
                    if !session.absorbExternalChange() {
                        ManuscriptSessionRegistry.shared.manuscriptDeletedElsewhere(id: id)
                        reresolve?()
                    }
                } else {
                    reresolve?()
                }
            }
        }
    }
}

extension View {
    func manuscriptLiveness(
        _ session: ManuscriptEditorSession?, manuscriptID: UUID?,
        reresolve: (@MainActor () -> Void)? = nil
    ) -> some View {
        modifier(ManuscriptLiveness(session: session, manuscriptID: manuscriptID, reresolve: reresolve))
    }
}
#endif
