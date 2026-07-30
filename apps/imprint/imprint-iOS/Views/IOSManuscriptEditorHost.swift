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

    var body: some View {
        Group {
            if hasLoaded {
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
            if hasLoaded {
                try? adapter.setBody(id: manuscriptID, text: bridge.source)
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
                try adapter.setBody(id: manuscriptID, text: text)
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
