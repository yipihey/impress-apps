//
//  BibTeXTab.swift
//  imbib
//
//  Extracted from DetailView.swift; un-gated in Stage 5b — this is the ONE
//  publication BibTeX tab, macOS and iOS.
//
//  ## One surface written twice (verdict: full collapse)
//
//  `IOSBibTeXTab` (126 lines) was this view with the same state machine
//  (`bibtexContent` / `isEditing` / `hasChanges`), the same `BibTeXEditor`
//  with line numbers, the same load (`RustStoreAdapter.exportBibTeX`) and the
//  same save-by-reparse. Two differences, both of which were bugs rather than
//  designs:
//
//  * **The save path.** macOS re-imports the parsed entry
//    (`LibraryViewModel.updateFromBibTeX`), so an edited cite key, entry type
//    or a DELETED field takes effect. iOS looped `updateField` over
//    `entry.fields`, which cannot express any of those three: renaming
//    `@article{foo` to `@article{bar` or deleting a `pages` line appeared to
//    save and silently did nothing. iOS now takes the macOS path.
//  * **The empty state.** iOS showed an editor over an empty buffer where
//    macOS shows `ContentUnavailableView`.
//
//  The one behavioural difference kept is `confirmsUnsavedDiscard`: iOS asks
//  before discarding an edit, macOS discards silently. macOS's Cancel is part
//  of the frozen detail pane, so the confirmation is opt-in rather than
//  applied to both.
//

import SwiftUI
import OSLog
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private let logger = Logger(subsystem: "com.imbib.app", category: "bibtextab")

public struct BibTeXTab: View {
    let paper: any PaperRepresentable
    let publicationID: UUID?
    let publicationIDs: [UUID]  // For multi-selection support

    /// Whether Cancel asks before throwing away an edit. iOS: true (it was the
    /// one thing the iOS copy did better). macOS: false — frozen behaviour.
    var confirmsUnsavedDiscard: Bool = false

    @Environment(LibraryViewModel.self) private var viewModel
    @Environment(\.themeColors) private var theme
    @State private var bibtexContent: String = ""
    @State private var isEditing = false
    @State private var hasChanges = false
    @State private var isLoading = false
    @State private var showDiscardAlert = false

    public init(
        paper: any PaperRepresentable,
        publicationID: UUID?,
        publicationIDs: [UUID],
        confirmsUnsavedDiscard: Bool = false
    ) {
        self.paper = paper
        self.publicationID = publicationID
        self.publicationIDs = publicationIDs
        self.confirmsUnsavedDiscard = confirmsUnsavedDiscard
    }

    /// Entry point for hosts that have only an id (imbib-iOS's detail pane).
    ///
    /// Returns nil when the publication is gone, the same shape
    /// `DetailView.init?(publicationID:…)` uses.
    public init?(publicationID: UUID, confirmsUnsavedDiscard: Bool = true) {
        guard let model = RustStoreAdapter.shared.getPublicationDetail(id: publicationID) else {
            return nil
        }
        self.paper = LocalPaper(from: model)
        self.publicationID = publicationID
        self.publicationIDs = [publicationID]
        self.confirmsUnsavedDiscard = confirmsUnsavedDiscard
    }

    /// Whether editing is enabled (only for single library paper)
    private var canEdit: Bool {
        publicationID != nil && publicationIDs.count <= 1
    }

    /// Whether multiple papers are selected
    private var isMultiSelection: Bool {
        publicationIDs.count > 1
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar (only show edit controls for library papers)
            if canEdit {
                editableToolbar
            }

            // Editor / Display
            if isLoading {
                ProgressView("Loading BibTeX...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if bibtexContent.isEmpty {
                ContentUnavailableView(
                    "No BibTeX",
                    systemImage: "doc.text",
                    description: Text("BibTeX is not available for this paper")
                )
            } else {
                BibTeXEditor(
                    text: $bibtexContent,
                    isEditable: isEditing,
                    showLineNumbers: true
                ) { _ in
                    saveBibTeX()
                }
                .onChange(of: bibtexContent) { _, _ in
                    if isEditing {
                        hasChanges = true
                    }
                }
            }
        }
        .background(theme.detailBackground)
        .scrollContentBackground(theme.detailBackground != nil ? .hidden : .automatic)
        .onChange(of: paper.id, initial: true) { _, _ in
            // Reset state and reload when paper changes
            bibtexContent = ""
            isEditing = false
            hasChanges = false
            loadBibTeX()
        }
        // Half-page scrolling support (macOS)
        .halfPageScrollable()
        .alert("Unsaved Changes", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) {
                cancelEditing(force: true)
            }
            Button("Save") {
                saveBibTeX()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have unsaved changes. Would you like to save them?")
        }
    }

    @ViewBuilder
    private var editableToolbar: some View {
        HStack {
            if isEditing {
                Button("Cancel") {
                    cancelEditing()
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Save") {
                    saveBibTeX()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges)
            } else {
                // Multi-selection indicator
                if isMultiSelection {
                    Text("\(publicationIDs.count) papers selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Copy button (always visible)
                Button {
                    copyToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy BibTeX to clipboard")

                // Edit button (only for single selection)
                if !isMultiSelection {
                    Button {
                        isEditing = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func copyToClipboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bibtexContent, forType: .string)
        #else
        UIPasteboard.general.string = bibtexContent
        #endif
    }

    /// Leave edit mode, restoring the stored entry.
    ///
    /// With `confirmsUnsavedDiscard` the dirty case raises the alert first
    /// (iOS); macOS discards, which is what its Cancel has always done.
    private func cancelEditing(force: Bool = false) {
        if confirmsUnsavedDiscard && hasChanges && !force {
            showDiscardAlert = true
            return
        }
        bibtexContent = generateBibTeX()
        isEditing = false
        hasChanges = false
    }

    private func loadBibTeX() {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            Logger.performance.info("loadBibTeX: \(elapsed, format: .fixed(precision: 1))ms")
        }

        isLoading = true
        bibtexContent = generateBibTeX()
        isLoading = false
    }

    private func generateBibTeX() -> String {
        // Multi-selection: export all selected publications
        if isMultiSelection {
            return RustStoreAdapter.shared.exportBibTeX(ids: publicationIDs)
        }
        // Single paper: export via RustStoreAdapter
        if let id = publicationID {
            return RustStoreAdapter.shared.exportBibTeX(ids: [id])
        }
        // Fallback for any edge cases (should not happen)
        let entry = BibTeXExporter.generateEntry(from: paper)
        return BibTeXExporter().export([entry])
    }

    private func saveBibTeX() {
        guard let id = publicationID else { return }

        Task {
            do {
                let items = try BibTeXParserFactory.createParser().parse(bibtexContent)
                guard let entry = items.compactMap({ item -> BibTeXEntry? in
                    if case .entry(let entry) = item { return entry }
                    return nil
                }).first else {
                    return
                }

                await viewModel.updateFromBibTeX(id: id, entry: entry)

                await MainActor.run {
                    isEditing = false
                    hasChanges = false
                }
            } catch {
                logger.error("Failed to parse BibTeX: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Multi-Selection BibTeX View

/// A simplified view shown when multiple papers are selected.
/// Only displays combined BibTeX with a Copy button.
struct MultiSelectionBibTeXView: View {
    let publicationIDs: [UUID]
    var onDownloadPDFs: (() -> Void)?

    /// Combined BibTeX content - exported via RustStoreAdapter
    private var bibtexContent: String {
        guard !publicationIDs.isEmpty else { return "" }
        return RustStoreAdapter.shared.exportBibTeX(ids: publicationIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with count and action buttons
            HStack {
                Text("\(publicationIDs.count) papers selected")
                    .font(.headline)

                Spacer()

                if let onDownloadPDFs = onDownloadPDFs {
                    Button {
                        onDownloadPDFs()
                    } label: {
                        Label("Download PDFs", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    copyToClipboard()
                } label: {
                    Label("Copy All BibTeX", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(bibtexContent.isEmpty)
            }
            .padding()
            .background(.bar)

            Divider()

            // BibTeX content
            if bibtexContent.isEmpty {
                ContentUnavailableView(
                    "No BibTeX",
                    systemImage: "doc.text",
                    description: Text("Could not generate BibTeX for selected papers")
                )
            } else {
                ScrollView {
                    Text(bibtexContent)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
    }

    private func copyToClipboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bibtexContent, forType: .string)
        #else
        UIPasteboard.general.string = bibtexContent
        #endif
    }
}
