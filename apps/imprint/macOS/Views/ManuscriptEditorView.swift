//
//  ManuscriptEditorView.swift
//
//  Phase 2 + 4b of the unified-store pivot
//  (/Users/tabel/.claude/plans/one-store-the-store-melodic-wreath.md).
//
//  The editor window for a manuscript that lives in the unified store.
//  Bridges to the existing rich `ContentView` so every editor feature
//  (syntax highlighting, citation insert, plots panel, AI assistant,
//  Veusz wiring) keeps working in the manuscript-keyed path. The
//  bridged `ImprintDocument` is the editor's local source of truth
//  during a session; body changes are debounced back into the store.
//
//  This keeps `ContentView` itself unchanged — the heavy refactor
//  (taking a `manuscriptID` directly) is deferred to a follow-up,
//  along with the actual deletion of `ImprintDocument: FileDocument`.
//  In the meantime, the bridge is enough to retire `DocumentGroup`
//  as the *user-visible* path: every new manuscript opens through
//  the library here.
//

import AppKit
import ImpressLogging
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Editor for a single manuscript opened by ID from the library.
/// Instantiated by `WindowGroup("manuscript-editor")` via
/// `openWindow(id: "manuscript-editor", value: manuscriptID)`.
struct ManuscriptEditorView: View {

    /// The ID passed in via `openWindow(value:)`. Constant for the
    /// lifetime of the window.
    let manuscriptID: UUID

    @Bindable private var adapter = ManuscriptStoreAdapter.shared

    /// Bridged `ImprintDocument` driving the legacy `ContentView`.
    /// Materialised in `loadFromStore()` once the manuscript snapshot
    /// is available. Until then, the loading placeholder is shown.
    @State private var bridge: ImprintDocument = ImprintDocument(format: .typst)

    /// True after the first `loadFromStore()` call. Gates whether the
    /// editor body is shown and whether the source-change watcher
    /// debounces writes back to the store (we don't want the initial
    /// load to round-trip as a "user edit").
    @State private var hasLoaded: Bool = false

    /// Snapshot of the manuscript at open time + on every store
    /// mutation. Drives the import-banner heuristic and gives the
    /// header view live `ManuscriptModel` state without forcing
    /// `ContentView` to know about manuscript-store types.
    @State private var manuscript: ManuscriptModel?

    /// One-shot banner for newly-imported manuscripts. Hides itself
    /// after `bannerDisplayDuration`.
    @State private var showImportedBanner: Bool = false

    /// Debouncer state.
    @State private var debounceTask: Task<Void, Never>?
    private static let debounceInterval: Duration = .milliseconds(200)
    private static let bannerDisplayDuration: Duration = .seconds(10)

    var body: some View {
        VStack(spacing: 0) {
            header
            if showImportedBanner, let source = manuscript?.importSource {
                Divider()
                ImportedBanner(source: source) {
                    showImportedBanner = false
                }
            }
            Divider()
            if hasLoaded {
                ContentView(document: $bridge)
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
        .frame(minWidth: 700, minHeight: 400)
        .task(id: manuscriptID) { await loadFromStore() }
        .onChange(of: adapter.dataVersion) { _, _ in
            // Refresh metadata snapshot. Body buffer is owned by the
            // editor between debounces — we don't overwrite it from the
            // store here, that would clobber in-flight edits.
            if let updated = adapter.manuscript(id: manuscriptID) {
                manuscript = updated
            }
        }
        .onChange(of: bridge.source) { _, newValue in
            guard hasLoaded else { return }
            scheduleSave(text: newValue)
        }
        // Mirror metadata edits (title, authors) made via ContentView's
        // metadata UI back into the store. Debounced through the same
        // path so quick consecutive edits coalesce.
        .onChange(of: bridge.title) { _, newTitle in
            guard hasLoaded else { return }
            try? adapter.updateMetadata(id: manuscriptID, title: newTitle)
        }
        .onChange(of: bridge.authors) { _, newAuthors in
            guard hasLoaded else { return }
            try? adapter.updateMetadata(id: manuscriptID, authors: newAuthors)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let m = manuscript {
            HStack(spacing: 8) {
                Text(m.title)
                    .font(.headline)
                Spacer()
                Text(m.format.rawValue.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(m.format == .typst ? Color.blue.opacity(0.18) : Color.orange.opacity(0.18))
                    )
                    .foregroundStyle(m.format == .typst ? Color.blue : Color.orange)
                Text(m.status.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu("Export") {
                    Button("As .imprint Bundle…") { exportAsBundle() }
                    Button("As Standalone Project…") { exportAsProject() }
                }
                .font(.caption)
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    // MARK: - Load + save

    private func loadFromStore() async {
        guard let m = adapter.manuscript(id: manuscriptID) else {
            Logger.sharedStore.warningCapture(
                "ManuscriptEditorView: manuscript \(manuscriptID) not found in store",
                category: "manuscript-editor"
            )
            return
        }
        manuscript = m

        // Synthesize the bridged ImprintDocument. Reuses the type's
        // init(format:) so default templates are applied, then layers
        // the manuscript snapshot's fields on top so the editor sees
        // the actual content rather than the boilerplate.
        let format: DocumentFormat = m.format == .latex ? .latex : .typst
        var doc = ImprintDocument(format: format)
        doc.id = manuscriptID
        doc.title = m.title
        doc.authors = m.authors
        doc.source = m.body
        doc.createdAt = m.createdAt
        doc.modifiedAt = m.bodyModifiedAt ?? Date()
        bridge = doc
        hasLoaded = true

        // Import banner: show for freshly-imported manuscripts only.
        if let source = m.importSource,
           let modified = m.bodyModifiedAt,
           Date().timeIntervalSince(modified) < 30,
           source.kind == .tex || source.kind == .imprint {
            showImportedBanner = true
            Task {
                try? await Task.sleep(for: Self.bannerDisplayDuration)
                await MainActor.run { showImportedBanner = false }
            }
        }
    }

    /// Debounced save. Replaces any pending save when the user keeps
    /// typing; after 200 ms of inactivity, writes back to the adapter.
    private func scheduleSave(text: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Self.debounceInterval)
                guard !Task.isCancelled else { return }
                try adapter.setBody(id: manuscriptID, text: text)
            } catch is CancellationError {
                // Normal — replaced by a newer keystroke.
            } catch {
                Logger.sharedStore.error(
                    "ManuscriptEditorView: setBody failed: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Export

    private func exportAsBundle() {
        let panel = NSSavePanel()
        panel.title = "Export as .imprint Bundle"
        panel.nameFieldStringValue = "\(manuscript?.title ?? "manuscript").imprint"
        panel.allowedContentTypes = [UTType(filenameExtension: "imprint") ?? .package]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try ManuscriptExporter.exportAsBundle(manuscriptID: manuscriptID, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            presentExportError(error)
        }
    }

    private func exportAsProject() {
        let panel = NSSavePanel()
        panel.title = "Export Standalone Project"
        panel.nameFieldStringValue = manuscript?.title ?? "manuscript"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try ManuscriptExporter.exportAsProject(manuscriptID: manuscriptID, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            presentExportError(error)
        }
    }

    private func presentExportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Imported banner

private struct ImportedBanner: View {
    let source: ImportSource
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Imported into the library")
                    .font(.subheadline.bold())
                if let path = source.originalPath {
                    Text("Original: \(path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("The original file is detached. Use File → Export to write a standalone copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss", action: onDismiss)
                .font(.caption)
        }
        .padding(10)
        .background(Color.blue.opacity(0.08))
    }
}
