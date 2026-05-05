//
//  InlineCitationPalette.swift
//  imprint
//
//  Floating citation palette that appears inline when the user types
//  `\cite{` (LaTeX) or `@` (Typst). Searches imbib directly via the shared
//  Rust store — no HTTP. Results ranked with already-cited papers first.
//

import AppKit
import ImbibRustCore
import SwiftUI

/// SwiftUI view for the inline citation palette — shown inside an NSPopover
/// anchored to the caret in the source editor. Reads its query from the
/// shared `CitationPaletteModel` which the controller updates as the user
/// types in the editor (the editor keeps focus the whole time).
struct InlineCitationPalette: View {
    /// Shared observable model — controller pushes query updates here.
    @Bindable var model: CitationPaletteModel
    /// Keys already cited in the current manuscript (used for ranking boost)
    let alreadyCitedKeys: Set<String>
    /// Called when the user picks a paper — receives the row.
    let onInsert: (BibliographyRow) -> Void
    /// Called when the user dismisses (Escape).
    let onCancel: () -> Void

    @State private var results: [BibliographyRow] = []
    @State private var selectedIndex: Int = 0
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Read-only query header — the editor has focus, not this view.
            // The user types in the editor and the controller pushes updates.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                if model.query.isEmpty {
                    Text("Type to search citations…")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(model.query)
                        .font(.system(size: 12, design: .monospaced))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if results.isEmpty {
                VStack(spacing: 4) {
                    if model.query.isEmpty {
                        Text("Type to search your imbib library")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                            PaletteRow(
                                row: row,
                                isSelected: index == selectedIndex,
                                isAlreadyCited: alreadyCitedKeys.contains(row.citeKey)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onInsert(row) }
                            .onHover { if $0 { selectedIndex = index } }
                            .id(index)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            if !results.isEmpty {
                Divider()
                HStack(spacing: 12) {
                    Text("Click to insert · keep typing to filter")
                    Spacer()
                    Text("\(results.count)")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
        .frame(width: 480)
        .background(.regularMaterial)
        .onAppear {
            runSearch(model.query)
        }
        .onChange(of: model.revision) { _, _ in
            runSearch(model.query)
        }
    }

    private func runSearch(_ q: String) {
        // Debounce + multi-term search via the shared store. `search()` splits
        // on whitespace and intersects results, matching imbib's multi-term UX.
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        searchTask = Task { @MainActor in
            // Short debounce to coalesce keystrokes
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }

            let rows = ImprintPublicationService.shared.search(trimmed, limit: 50)

            // Ranking boost: papers already cited in this manuscript first
            let (cited, others) = rows.reduce(into: ([BibliographyRow](), [BibliographyRow]())) { acc, row in
                if alreadyCitedKeys.contains(row.citeKey) {
                    acc.0.append(row)
                } else {
                    acc.1.append(row)
                }
            }
            results = cited + others
            if selectedIndex >= results.count {
                selectedIndex = max(0, results.count - 1)
            }
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let next = selectedIndex + delta
        selectedIndex = max(0, min(next, results.count - 1))
    }

    private func insertSelected() {
        guard !results.isEmpty, selectedIndex < results.count else { return }
        onInsert(results[selectedIndex])
    }
}

/// Single row in the palette — dense layout showing title, authors, year, cite key.
private struct PaletteRow: View {
    let row: BibliographyRow
    let isSelected: Bool
    let isAlreadyCited: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Small indicator for already-cited papers
            if isAlreadyCited {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else if row.hasDownloadedPdf {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.citeKey)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isSelected ? .white : .secondary)
                    if let y = row.year {
                        Text("(\(y))")
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.7))
                    }
                }
                Text(row.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                if !row.authorString.isEmpty {
                    Text(row.authorString)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if row.isStarred {
                Image(systemName: "star.fill")
                    .foregroundStyle(isSelected ? .white : .yellow)
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : .clear)
    }
}
