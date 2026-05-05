import ImpressLogging
import ImprintCore
import SwiftUI

/// Document outline sidebar showing headings and structure.
/// Supports both Typst and LaTeX heading syntax.
/// Clicking an item navigates the editor/preview to that location.
///
/// Dual mode:
/// - If the focused document has ≥2 stored sections in the shared
///   store, the view reads from `OutlineSnapshot.shared` — the same
///   source of truth that imbib, HTTP automation, and agents see.
/// - Otherwise (single-section documents, the current default), the
///   view falls back to parsing `source` with regex. This is what
///   imprint has always done and stays useful for long single-file
///   manuscripts whose outline comes from heading markers in the text.
struct DocumentOutlineView: View {
    let source: String
    var format: DocumentFormat = .typst
    /// Optional document id. When set, the view subscribes to
    /// `OutlineSnapshot.shared` and prefers its entries when the
    /// stored structure has ≥2 sections.
    var documentID: UUID?
    /// Called when the user clicks an outline item — parameter is the 1-based line number.
    var onNavigateToLine: ((Int) -> Void)?

    @State private var collapsedIDs: Set<String> = []
    @State private var isOutlineCollapsed = false
    /// Tracked singleton; `@Observable` reads in `flatItems` fire view
    /// updates automatically when the snapshot maintainer publishes.
    var outlineSnapshot: OutlineSnapshot = .shared

    /// Compute outline items, preferring the stored snapshot for
    /// multi-section documents and falling back to regex parsing for
    /// single-section ones.
    private var flatItems: [FlatOutlineItem] {
        if let documentID,
           outlineSnapshot.focusedDocumentID == documentID,
           outlineSnapshot.entries.count >= 2 {
            return outlineSnapshot.entries.enumerated().map { index, entry in
                FlatOutlineItem(
                    title: entry.title,
                    level: 1,
                    lineNumber: index,
                    depth: 0,
                    hasChildren: false
                )
            }
        }
        let fmt = effectiveFormat
        let items: [OutlineItem]
        switch fmt {
        case .typst: items = Self.parseTypstItems(source)
        case .latex: items = Self.parseLaTeXItems(source)
        }
        return Self.buildFlatTree(from: items)
    }

    var body: some View {
        Section(isExpanded: Binding(
            get: { !isOutlineCollapsed },
            set: { isOutlineCollapsed = !$0 }
        )) {
            if flatItems.isEmpty {
                Text("No headings found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(visibleItems) { item in
                    outlineRow(item)
                }
            }
        } header: {
            Label("Outline", systemImage: "list.bullet.indent")
        }
        .accessibilityIdentifier("outline.container")
    }

    // MARK: - Visible Items (respecting collapsed state)

    private var visibleItems: [FlatOutlineItem] {
        let items = flatItems
        var visible: [FlatOutlineItem] = []
        var hideBelow: Int? = nil

        for item in items {
            if let threshold = hideBelow {
                if item.level > threshold {
                    continue
                } else {
                    hideBelow = nil
                }
            }

            visible.append(item)

            if collapsedIDs.contains(item.id) && item.hasChildren {
                hideBelow = item.level
            }
        }
        return visible
    }

    // MARK: - Row

    @ViewBuilder
    private func outlineRow(_ item: FlatOutlineItem) -> some View {
        Button {
            onNavigateToLine?(item.lineNumber + 1) // 0-based → 1-based
        } label: {
            HStack(spacing: 4) {
                if item.depth > 0 {
                    Spacer().frame(width: CGFloat(item.depth) * 12)
                }

                if item.hasChildren {
                    Image(systemName: collapsedIDs.contains(item.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .onTapGesture {
                            if collapsedIDs.contains(item.id) {
                                collapsedIDs.remove(item.id)
                            } else {
                                collapsedIDs.insert(item.id)
                            }
                        }
                } else {
                    Spacer().frame(width: 12)
                }

                Image(systemName: iconName(for: item.level))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                Text(item.title)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("outline.item.\(item.lineNumber)")
    }

    private func iconName(for level: Int) -> String {
        switch level {
        case 0: return "book.closed"
        case 1: return "doc.text"
        case 2: return "text.alignleft"
        default: return "text.justify"
        }
    }

    // MARK: - Format Detection

    private var effectiveFormat: DocumentFormat {
        if format == .typst && (source.contains("\\documentclass") || source.contains("\\begin{document}")) {
            return .latex
        }
        return format
    }

    // MARK: - Parsing (static to avoid captures)

    private static func parseTypstItems(_ source: String) -> [OutlineItem] {
        var items: [OutlineItem] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("=") {
                let level = trimmed.prefix(while: { $0 == "=" }).count
                let title = String(trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces))
                if !title.isEmpty {
                    items.append(OutlineItem(title: title, level: level, lineNumber: index))
                }
            }
        }
        return items
    }

    private static func parseLaTeXItems(_ source: String) -> [OutlineItem] {
        var items: [OutlineItem] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        let sectionCommands: [(pattern: String, level: Int)] = [
            ("\\\\part\\{([^}]+)\\}", 0),
            ("\\\\chapter\\{([^}]+)\\}", 1),
            ("\\\\section\\*?\\{([^}]+)\\}", 1),
            ("\\\\subsection\\*?\\{([^}]+)\\}", 2),
            ("\\\\subsubsection\\*?\\{([^}]+)\\}", 3),
        ]

        for (index, line) in lines.enumerated() {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%") { continue }

            for (pattern, level) in sectionCommands {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: lineStr, range: NSRange(lineStr.startIndex..., in: lineStr)),
                      let titleRange = Range(match.range(at: 1), in: lineStr) else { continue }
                items.append(OutlineItem(title: String(lineStr[titleRange]), level: level, lineNumber: index))
                break
            }

            if trimmed.hasPrefix("\\appendix") {
                items.append(OutlineItem(title: "Appendix", level: 1, lineNumber: index))
            } else if trimmed.contains("\\begin{abstract}") {
                items.append(OutlineItem(title: "Abstract", level: 1, lineNumber: index))
            } else if trimmed.contains("\\begin{thebibliography}") || trimmed.contains("\\printbibliography") {
                items.append(OutlineItem(title: "Bibliography", level: 1, lineNumber: index))
            }
        }
        return items
    }

    private static func buildFlatTree(from items: [OutlineItem]) -> [FlatOutlineItem] {
        guard !items.isEmpty else { return [] }
        let baseLevel = items.first?.level ?? 1
        return items.enumerated().map { (i, item) in
            let hasChildren = i + 1 < items.count && items[i + 1].level > item.level
            return FlatOutlineItem(
                title: item.title,
                level: item.level,
                lineNumber: item.lineNumber,
                depth: max(0, item.level - baseLevel),
                hasChildren: hasChildren
            )
        }
    }
}

// MARK: - Data Types

struct FlatOutlineItem: Identifiable {
    var id: String { "\(lineNumber):\(title)" }
    let title: String
    let level: Int
    let lineNumber: Int
    let depth: Int
    let hasChildren: Bool
}

private struct OutlineItem {
    let title: String
    let level: Int
    let lineNumber: Int
}

#Preview {
    DocumentOutlineView(source: """
    = Introduction

    Some text here.

    == Background

    More text.

    == Methods

    === Data Collection

    === Analysis

    = Results

    = Discussion
    """, onNavigateToLine: { line in print("Navigate to line \(line)") })
    .frame(width: 220, height: 400)
}
