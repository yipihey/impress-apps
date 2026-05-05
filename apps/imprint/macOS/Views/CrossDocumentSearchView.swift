//
//  CrossDocumentSearchView.swift
//  imprint
//
//  A floating search window that searches across every stored manuscript
//  section via `ManuscriptSearchService`. Invoked with Cmd+Shift+F.
//
//  Unlike the inline citation palette (which searches imbib's
//  publications), this searches imprint's own manuscript corpus —
//  sections, their titles, and their bodies. It answers "where did I
//  write about halo bias last year?" in under 100ms for typical
//  corpus sizes.
//
//  Clicking a result posts `.openDocumentByID` so the project browser
//  can open the owning manuscript.
//

#if os(macOS)
import AppKit
import ImprintCore
import SwiftUI

struct CrossDocumentSearchView: View {
    let onClose: () -> Void

    @State private var query: String = ""
    @State private var results: [ManuscriptSearchHit] = []
    @State private var isSearching: Bool = false
    @State private var selectedIndex: Int = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var indexedCount: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            resultsList
            Divider()
            footer
        }
        .frame(width: 600, height: 480)
        .background(.regularMaterial)
        .task {
            // Pull the current index size on open for the footer.
            let count = await ManuscriptSearchService.shared.indexedSectionCount
            self.indexedCount = count
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search across your manuscripts…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit {
                    insertSelected()
                }
                .onChange(of: query) { _, newValue in
                    runSearch(newValue)
                }
            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            VStack(spacing: 6) {
                if query.isEmpty {
                    Text("Type to search your manuscript library")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("\(indexedCount) sections indexed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if !isSearching {
                    Text("No matches for '\(query)'")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, hit in
                            SearchResultRow(
                                hit: hit,
                                isSelected: index == selectedIndex
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { insert(hit) }
                            .onHover { if $0 { selectedIndex = index } }
                            .id(index)
                        }
                    }
                }
                .onChange(of: selectedIndex) { _, new in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if results.isEmpty {
                Text("⌘⇧F · Cross-document search")
            } else {
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                Spacer()
                Text("↩ to open · Esc to close")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Search

    private func runSearch(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
            let hits = await ManuscriptSearchService.shared.search(trimmed, limit: 50)
            if Task.isCancelled { return }
            self.results = hits
            self.isSearching = false
            if selectedIndex >= hits.count {
                selectedIndex = max(0, hits.count - 1)
            }
        }
    }

    private func insertSelected() {
        guard !results.isEmpty, selectedIndex < results.count else { return }
        insert(results[selectedIndex])
    }

    private func insert(_ hit: ManuscriptSearchHit) {
        if let docID = hit.documentID {
            NotificationCenter.default.post(
                name: .openDocumentByID,
                object: nil,
                userInfo: [
                    "documentID": docID.uuidString,
                    "sectionID": hit.sectionID.uuidString
                ]
            )
        }
        onClose()
    }
}

private struct SearchResultRow: View {
    let hit: ManuscriptSearchHit
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? .white : .primary)
                    if let type = hit.sectionType, !type.isEmpty {
                        Text(type)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.2))
                            .clipShape(Capsule())
                            .foregroundStyle(isSelected ? .white : .secondary)
                    }
                }
                if !hit.excerpt.isEmpty {
                    Text(hit.excerpt)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : .clear)
    }
}
#endif
