//
//  IOSManuscriptEditorHost.swift
//  imprint-iOS
//
//  GUI-meld Phase 8. The iOS analogue of macOS `ManuscriptEditorView`:
//  loads a manuscript out of the unified store, bridges it into an in-memory
//  `ImprintDocument`, drives the existing rich `IOSContentView` editor
//  (outline / citation / sketch / compile), and debounces body + metadata
//  edits back into the store. This is what puts a store-backed manuscript
//  *behind* the editor so imprint-iOS is a manuscripts app, not a
//  single-document editor.
//

import SwiftUI
import OSLog
import ImpressLogging
import ImprintCore

/// Editor host for a single store-backed manuscript, opened by ID from the
/// library list. Reuses `IOSContentView` unchanged — the bridge is the only
/// new surface.
struct IOSManuscriptEditorHost: View {

    /// The manuscript to edit. Constant for the lifetime of this view.
    let manuscriptID: UUID

    @Bindable private var adapter = ManuscriptStoreAdapter.shared

    /// Bridged document driving `IOSContentView`. Materialised on load.
    @State private var bridge = ImprintDocument(format: .typst)

    /// Gate: true after the first `loadFromStore()`. Prevents the initial
    /// load from round-tripping as a "user edit", and hides the editor until
    /// the real content is in place.
    @State private var hasLoaded = false

    /// Metadata snapshot for the navigation title.
    @State private var manuscript: ManuscriptModel?

    /// Debouncer for body writes.
    @State private var debounceTask: Task<Void, Never>?
    private static let debounceInterval: Duration = .milliseconds(300)

    /// Document heads last seen — the base each commit is diffed against
    /// (ADR-0027 D6). Pinned at load and after every commit.
    @State private var savedHeads: [String] = []

    /// ADR-0023 D4 — the no-write-back gate.
    ///
    /// This host has its OWN 300 ms debounce into `setBody`, so it carries its
    /// own copy of the risk the chassis session carries: a save landing after
    /// (or against) an external edit. For a manuscript whose file is
    /// authoritative the editor is never mounted at all, which is the only
    /// version of this guard that cannot be defeated by a race — there is no
    /// buffer, so `scheduleSave` is never scheduled and `onDisappear`'s flush
    /// has nothing to flush. See `WatchedManuscriptGuard`.
    private var isExternal: Bool { !WatchedManuscriptGuard.allowsEditorSession(manuscript) }

    var body: some View {
        Group {
            if hasLoaded, isExternal, let manuscript {
                IOSExternalManuscriptPane(manuscript: manuscript)
            } else if hasLoaded {
                IOSContentView(document: $bridge)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading manuscript…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(manuscript?.title ?? "Manuscript")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: manuscriptID) { await loadFromStore() }
        .onChange(of: adapter.dataVersion) { _, _ in
            // Refresh the metadata snapshot only. The body buffer is owned by
            // the editor between debounces — overwriting it here would clobber
            // in-flight keystrokes (CLAUDE.md: don't fight the editor buffer).
            if let updated = adapter.manuscript(id: manuscriptID) {
                manuscript = updated
            }
        }
        .onChange(of: bridge.source) { _, newValue in
            guard hasLoaded else { return }
            scheduleSave(text: newValue)
        }
        .onChange(of: bridge.title) { _, newTitle in
            guard hasLoaded else { return }
            try? adapter.updateMetadata(id: manuscriptID, title: newTitle)
        }
        .onChange(of: bridge.authors) { _, newAuthors in
            guard hasLoaded else { return }
            try? adapter.updateMetadata(id: manuscriptID, authors: newAuthors)
        }
        .onDisappear {
            // Flush any pending edit immediately so navigating back never
            // drops the last keystrokes.
            debounceTask?.cancel()
            // `!isExternal` is belt and braces — an external manuscript never
            // mounted the editor, so `bridge.source` is the snapshot as loaded
            // — but writing it back would be a store write claiming an edit
            // nobody made, and the D4 rule is worth spelling at the one site
            // that writes unconditionally.
            if hasLoaded, !isExternal {
                _ = try? adapter.commitBody(
                    id: manuscriptID, text: bridge.source, baseHeads: savedHeads)
            }
        }
    }

    // MARK: - Store bridge

    private func loadFromStore() async {
        guard let m = adapter.manuscript(id: manuscriptID) else {
            Logger.sharedStore.warningCapture(
                "IOSManuscriptEditorHost: manuscript \(manuscriptID) not found in store",
                category: "manuscript-editor"
            )
            return
        }
        manuscript = m

        let format: DocumentFormat = m.format == .latex ? .latex : .typst
        var doc = ImprintDocument(format: format)
        doc.id = manuscriptID
        doc.title = m.title
        doc.authors = m.authors
        doc.source = m.body
        doc.createdAt = m.createdAt
        doc.modifiedAt = m.bodyModifiedAt ?? Date()
        // Hydrate the throughline sidecars from the store (C1). There is no
        // `.imprint` file bundle behind a store-backed manuscript, so the pane
        // would open on "No throughline yet" for a document that HAS one —
        // exactly what `PanelManuscriptBridge` does for the macOS side panel,
        // and the reason `ImprintStoreAdapter.loadThroughline` exists.
        //
        // Absence is not an error: a manuscript without a throughline hydrates
        // to nil and the pane offers its create affordance (ADR-0016 D1, opt-in).
        if let tl = ImprintStoreAdapter.shared.loadThroughline(
            documentID: manuscriptID.uuidString) {
            doc.throughlineSource = tl.source
            doc.throughlineAnchorsJSON =
                tl.anchorMapJSON.isEmpty ? nil : tl.anchorMapJSON
            Logger.sharedStore.infoCapture(
                "IOSManuscriptEditorHost: hydrated throughline for \(manuscriptID) "
                    + "(\(tl.source.count) bytes)",
                category: "throughline"
            )
        }
        bridge = doc
        savedHeads = adapter.collabHeads(id: manuscriptID)
        hasLoaded = true

        Logger.sharedStore.infoCapture(
            "IOSManuscriptEditorHost: loaded \(manuscriptID) (\(m.format.rawValue), \(m.body.count) bytes)",
            category: "manuscript-editor"
        )
    }

    private func scheduleSave(text: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Self.debounceInterval)
                guard !Task.isCancelled else { return }
                // ADR-0027: commit from our base; the document merges edits
                // made elsewhere with ours and returns the merged text, which
                // the buffer adopts (only if it still equals what we sent —
                // otherwise the next debounce folds it in from the new base).
                let outcome = try adapter.commitBody(
                    id: manuscriptID, text: text, baseHeads: savedHeads)
                savedHeads = outcome.heads
                if outcome.mergedExternal, bridge.source == text {
                    bridge.source = outcome.body
                    Logger.sharedStore.infoCapture(
                        "IOSManuscriptEditorHost: merged external edits into \(manuscriptID)",
                        category: "manuscript-editor")
                }
            } catch is CancellationError {
                // Normal — superseded by a newer keystroke.
            } catch {
                Logger.sharedStore.error(
                    "IOSManuscriptEditorHost: setBody failed: \(error.localizedDescription)"
                )
            }
        }
    }
}
