//
//  BibTeXTab.swift
//  imbib
//
//  Extracted from DetailView.swift
//

import SwiftUI
import PublicationManagerCore
import OSLog
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private let logger = Logger(subsystem: "com.imbib.app", category: "bibtextab")

struct BibTeXTab: View {
    let paper: any PaperRepresentable
    let publication: CDPublication?
    let publications: [CDPublication]  // For multi-selection support

    @Environment(LibraryViewModel.self) private var viewModel
    @Environment(\.themeColors) private var theme
    @State private var bibtexContent: String = ""
    @State private var isEditing = false
    @State private var hasChanges = false
    @State private var isLoading = false

    /// Whether editing is enabled (only for single library paper)
    private var canEdit: Bool {
        publication != nil && publications.count <= 1
    }

    /// Whether multiple papers are selected
    private var isMultiSelection: Bool {
        publications.count > 1
    }

    var body: some View {
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
        // Keyboard navigation: h/l for pane cycling (j/k handled centrally by ContentView)
        .focusable()
        .onKeyPress { press in
            let store = KeyboardShortcutsStore.shared
            // Cycle pane focus left (default: h)
            if store.matches(press, action: "cycleFocusLeft") {
                NotificationCenter.default.post(name: .cycleFocusLeft, object: nil)
                return .handled
            }
            // Cycle pane focus right (default: l)
            if store.matches(press, action: "cycleFocusRight") {
                NotificationCenter.default.post(name: .cycleFocusRight, object: nil)
                return .handled
            }
            return .ignored
        }
    }

    @ViewBuilder
    private var editableToolbar: some View {
        HStack {
            if isEditing {
                Button("Cancel") {
                    bibtexContent = generateBibTeX()
                    isEditing = false
                    hasChanges = false
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
                    Text("\(publications.count) papers selected")
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
            let entries = publications.map { $0.toBibTeXEntry() }
            return BibTeXExporter().export(entries)
        }
        // Single paper: ADR-016: All papers are now CDPublication
        if let pub = publication {
            let entry = pub.toBibTeXEntry()
            return BibTeXExporter().export([entry])
        }
        // Fallback for any edge cases (should not happen)
        let entry = BibTeXExporter.generateEntry(from: paper)
        return BibTeXExporter().export([entry])
    }

    private func saveBibTeX() {
        guard let pub = publication else { return }

        Task {
            do {
                let items = try BibTeXParserFactory.createParser().parse(bibtexContent)
                guard let entry = items.compactMap({ item -> BibTeXEntry? in
                    if case .entry(let entry) = item { return entry }
                    return nil
                }).first else {
                    return
                }

                await viewModel.updateFromBibTeX(id: pub.id, entry: entry)

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
    let publications: [CDPublication]
    var onDownloadPDFs: (() -> Void)?

    /// Combined BibTeX content - computed directly from publications
    private var bibtexContent: String {
        guard !publications.isEmpty else { return "" }
        let entries = publications.compactMap { pub -> BibTeXEntry? in
            guard !pub.isDeleted, pub.managedObjectContext != nil else { return nil }
            return pub.toBibTeXEntry()
        }
        guard !entries.isEmpty else { return "" }
        return BibTeXExporter().export(entries)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with count and action buttons
            HStack {
                Text("\(publications.count) papers selected")
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
