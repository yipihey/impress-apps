//
//  CitationSuggestionPanel.swift
//  imprint
//
//  Non-modal panel showing AI-extracted claims and the ranked imbib papers that
//  could support each. The author ticks the citations to insert — nothing is
//  auto-inserted (citation false positives are the main risk).
//

import SwiftUI

struct CitationSuggestionPanel: View {
    let suggestions: [CitationSuggestionService.ClaimSuggestion]
    let isLoading: Bool
    let onInsert: ([CitationResult]) -> Void
    let onDismiss: () -> Void

    @State private var selectedKeys: Set<String> = []

    private var selectedCandidates: [CitationResult] {
        var seen = Set<String>()
        return suggestions.flatMap(\.candidates).filter {
            selectedKeys.contains($0.citeKey) && seen.insert($0.citeKey).inserted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 460)
        .frame(maxHeight: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(radius: 16, y: 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "quote.opening").foregroundStyle(.tint)
            Text("Suggest citations").font(.headline)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Finding claims and searching your library…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else if suggestions.isEmpty {
            Text("No citation-worthy claims found in this passage.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 100)
                .padding()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(suggestions) { s in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(s.claim).font(.callout.weight(.medium))
                            Text("search: \(s.query)").font(.caption).foregroundStyle(.secondary)
                            if s.candidates.isEmpty {
                                Text("No matching papers in your imbib library.")
                                    .font(.caption).foregroundStyle(.secondary).italic()
                            } else {
                                ForEach(s.candidates, id: \.citeKey) { c in
                                    candidateRow(c)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func candidateRow(_ c: CitationResult) -> some View {
        let checked = selectedKeys.contains(c.citeKey)
        return Button {
            if checked { selectedKeys.remove(c.citeKey) } else { selectedKeys.insert(c.citeKey) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.title).font(.callout).lineLimit(2)
                    Text("\(c.authors) · \(c.year > 0 ? String(c.year) : "—") · \\cite{\(c.citeKey)}\(c.hasPDF ? " · PDF" : "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Button("Dismiss", role: .cancel, action: onDismiss)
                .keyboardShortcut(.escape, modifiers: [])
            Spacer()
            Button("Insert \(selectedCandidates.count) citation\(selectedCandidates.count == 1 ? "" : "s")") {
                onInsert(selectedCandidates)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedCandidates.isEmpty)
        }
        .padding(12)
    }
}
