//
//  ManuscriptEditorView.swift
//
//  Phase 2 of the unified-store pivot
//  (/Users/tabel/.claude/plans/one-store-the-store-melodic-wreath.md).
//
//  The editor window for a manuscript that lives in the unified store.
//  Body content is loaded from `ManuscriptStoreAdapter.body(id:)` and
//  written back via `setBody(id:text:)` with a 200 ms idle debounce.
//
//  This is intentionally a minimal editor in Phase 2 — phase 4b folds
//  in the rich `ContentView` (syntax highlighting, citation insert,
//  plots panel, etc.) once `FileDocument` is retired. The Phase 2 goal
//  is to prove the body-in-SQLite + materialize-for-toolchain path
//  end-to-end without breaking the existing `DocumentGroup` editor.
//

import SwiftUI

/// Editor for a single manuscript opened by ID from the library.
/// Instantiated by `WindowGroup("manuscript-editor")` via
/// `openWindow(id: "manuscript-editor", value: manuscriptID)`.
struct ManuscriptEditorView: View {

    /// The ID passed in via `openWindow(value:)`. Constant for the
    /// lifetime of the window.
    let manuscriptID: UUID

    @Bindable private var adapter = ManuscriptStoreAdapter.shared

    /// The live editing buffer. Initialised from the store on first
    /// appearance; written back via the debouncer on every change.
    @State private var bodyBuffer: String = ""

    /// Snapshot of the manuscript at open time; used to render title /
    /// authors / format badge in the header. Reread from the adapter
    /// when `dataVersion` changes.
    @State private var manuscript: ManuscriptModel?

    /// One-shot banner for newly-imported manuscripts. Hides itself
    /// after `bannerDisplayDuration`. Reset by the view's task.
    @State private var showImportedBanner: Bool = false

    /// Debouncer state.
    @State private var debounceTask: Task<Void, Never>?
    private static let debounceInterval: Duration = .milliseconds(200)
    private static let bannerDisplayDuration: Duration = .seconds(10)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showImportedBanner, let source = manuscript?.importSource {
                ImportedBanner(source: source) {
                    showImportedBanner = false
                }
                Divider()
            }
            editor
        }
        .frame(minWidth: 600, minHeight: 400)
        .task { await loadOnAppear() }
        .onChange(of: adapter.dataVersion) { _, _ in
            // Re-read the metadata snapshot. We deliberately don't
            // overwrite the live body buffer: the editor is the source
            // of truth between debounces.
            if let updated = adapter.manuscript(id: manuscriptID) {
                manuscript = updated
            }
        }
        .onChange(of: bodyBuffer) { _, newValue in
            scheduleSave(text: newValue)
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Editor

    private var editor: some View {
        TextEditor(text: $bodyBuffer)
            .font(.system(.body, design: .monospaced))
            .lineSpacing(2)
            .padding(8)
            .scrollContentBackground(.hidden)
            .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Load + save

    private func loadOnAppear() async {
        guard let m = adapter.manuscript(id: manuscriptID) else {
            return
        }
        manuscript = m
        bodyBuffer = m.body
        // Show the import banner once if the manuscript was just imported
        // (heuristic: import_source present AND body_modified_at within
        // the last 30 seconds).
        if let source = m.importSource,
           let modified = m.bodyModifiedAt,
           Date().timeIntervalSince(modified) < 30,
           source.kind == .tex || source.kind == .imprint {
            showImportedBanner = true
            // Auto-hide after the display duration.
            Task {
                try? await Task.sleep(for: Self.bannerDisplayDuration)
                await MainActor.run { showImportedBanner = false }
            }
        }
    }

    /// Debounced save. Cancel any pending save when the user keeps typing;
    /// after 200 ms of inactivity, write back to the adapter.
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
                // Persistent failures should surface; for now we just log.
                // Phase 4a wires a proper error banner.
                print("ManuscriptEditorView: setBody failed: \(error)")
            }
        }
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
