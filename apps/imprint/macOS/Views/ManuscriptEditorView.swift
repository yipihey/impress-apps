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
import PublicationManagerCore
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

    /// Snapshot of the manuscript at open time + on every store mutation.
    /// Drives the import-banner heuristic and the header (title/status/export).
    @State private var manuscript: ManuscriptModel?

    /// One-shot banner for newly-imported manuscripts. Hides itself
    /// after `bannerDisplayDuration`.
    @State private var showImportedBanner: Bool = false

    /// Detail tab for the hosted chassis pane; manuscripts land in the editor.
    @State private var selectedTab: DetailTab = .source
    /// This window's editor session (registry-owned). Resolved here and passed
    /// into the chassis pane, which holds no session state of its own.
    @State private var session: ManuscriptEditorSession?

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
            // GUI-meld Phase 7: this standalone editor window now hosts the
            // SAME chassis detail pane as the main window (tabbed Info/Source/
            // Preview, the shared editor, outline/comments/preview + the AI/
            // Throughline/Veusz/Paper inspector). The manuscript-store↔editor
            // bridge and the 1,582-line legacy ContentView it drove are retired
            // — the chassis loads/saves the manuscript itself via its session.
            ManuscriptDetailPane(
                manuscriptID: manuscriptID, session: session, selectedTab: $selectedTab)
        }
        .frame(minWidth: 700, minHeight: 400)
        .focusedSceneValue(\.focusedManuscriptID, manuscriptID)
        .task(id: manuscriptID) {
            session = ManuscriptSessionRegistry.shared.session(for: manuscriptID)
        }
        .task(id: manuscriptID) { await loadMetadata() }
        .onChange(of: adapter.dataVersion) { _, _ in
            if let updated = adapter.manuscript(id: manuscriptID) {
                manuscript = updated
            }
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
                            .fill(badgeColor(m.format).opacity(0.18))
                    )
                    .foregroundStyle(badgeColor(m.format))
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

    // MARK: - Load

    /// Fetch the manuscript snapshot for the header + import banner. The
    /// hosted chassis pane loads and saves the body itself (via its editor
    /// session's compare-and-set), so there is no bridge/debounced-save here.
    private func loadMetadata() async {
        guard let m = adapter.manuscript(id: manuscriptID) else {
            Logger.sharedStore.warningCapture(
                "ManuscriptEditorView: manuscript \(manuscriptID) not found in store",
                category: "manuscript-editor"
            )
            return
        }
        manuscript = m

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

    private func badgeColor(_ format: ManuscriptFormat) -> Color {
        switch format {
        case .typst: return .blue
        case .latex: return .orange
        case .markdown: return .green
        case .plaintext: return .gray
        }
    }

    // MARK: - Export

    private func exportAsBundle() {
        ManuscriptExportActions.exportAsBundle(manuscriptID: manuscriptID)
    }

    private func exportAsProject() {
        ManuscriptExportActions.exportAsProject(manuscriptID: manuscriptID)
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
