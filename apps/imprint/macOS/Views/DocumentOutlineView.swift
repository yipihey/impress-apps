import SwiftUI

/// Document outline sidebar showing headings and structure.
/// Supports both Typst and LaTeX heading syntax.
struct DocumentOutlineView: View {
    let source: String
    var format: DocumentFormat = .typst

    @State private var outlineItems: [OutlineItem] = []

    var body: some View {
        List(outlineItems) { item in
            OutlineRow(item: item)
                .accessibilityIdentifier("outline.item.\(item.lineNumber)")
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("outline.container")
        .onAppear {
            parseOutline()
        }
        .onChange(of: source) { _, _ in
            parseOutline()
        }
    }

    private func parseOutline() {
        switch format {
        case .typst:
            parseTypstOutline()
        case .latex:
            parseLaTeXOutline()
        }
    }

    private func parseTypstOutline() {
        var items: [OutlineItem] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("=") {
                let level = trimmed.prefix(while: { $0 == "=" }).count
                let title = String(trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces))

                if !title.isEmpty {
                    items.append(OutlineItem(
                        id: UUID(),
                        title: title,
                        level: level,
                        lineNumber: index
                    ))
                }
            }
        }

        outlineItems = items
    }

    private func parseLaTeXOutline() {
        var items: [OutlineItem] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        // LaTeX sectioning commands → level mapping
        let sectionCommands: [(pattern: String, level: Int)] = [
            ("\\\\part\\{([^}]+)\\}", 0),
            ("\\\\chapter\\{([^}]+)\\}", 1),
            ("\\\\section\\{([^}]+)\\}", 1),
            ("\\\\subsection\\{([^}]+)\\}", 2),
            ("\\\\subsubsection\\{([^}]+)\\}", 3),
        ]

        for (index, line) in lines.enumerated() {
            let lineStr = String(line)

            // Skip commented lines
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%") { continue }

            for (pattern, level) in sectionCommands {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: lineStr, range: NSRange(lineStr.startIndex..., in: lineStr)),
                      let titleRange = Range(match.range(at: 1), in: lineStr) else { continue }

                let title = String(lineStr[titleRange])
                items.append(OutlineItem(
                    id: UUID(),
                    title: title,
                    level: level,
                    lineNumber: index
                ))
                break
            }

            // Special entries
            if trimmed.hasPrefix("\\appendix") {
                items.append(OutlineItem(id: UUID(), title: "Appendix", level: 1, lineNumber: index))
            } else if trimmed.contains("\\begin{abstract}") {
                items.append(OutlineItem(id: UUID(), title: "Abstract", level: 1, lineNumber: index))
            } else if trimmed.contains("\\begin{thebibliography}") || trimmed.contains("\\printbibliography") {
                items.append(OutlineItem(id: UUID(), title: "Bibliography", level: 1, lineNumber: index))
            }
        }

        outlineItems = items
    }
}

/// A single item in the document outline
struct OutlineItem: Identifiable {
    let id: UUID
    let title: String
    let level: Int
    let lineNumber: Int
}

/// Row view for an outline item
struct OutlineRow: View {
    let item: OutlineItem

    var body: some View {
        HStack {
            // Indentation based on heading level
            if item.level > 1 {
                Spacer()
                    .frame(width: CGFloat(item.level - 1) * 16)
            }

            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(item.title)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch item.level {
        case 1: return "doc.text"
        case 2: return "text.alignleft"
        case 3: return "text.justify"
        default: return "text.alignleft"
        }
    }
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
    """)
    .frame(width: 220, height: 400)
}
