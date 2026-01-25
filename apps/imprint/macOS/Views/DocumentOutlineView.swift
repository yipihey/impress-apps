import SwiftUI

/// Document outline sidebar showing headings and structure
struct DocumentOutlineView: View {
    let source: String

    @State private var outlineItems: [OutlineItem] = []

    var body: some View {
        List(outlineItems) { item in
            OutlineRow(item: item)
        }
        .listStyle(.sidebar)
        .onAppear {
            parseOutline()
        }
        .onChange(of: source) { _, _ in
            parseOutline()
        }
    }

    private func parseOutline() {
        var items: [OutlineItem] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Match Typst headings (= Heading, == Subheading, etc.)
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
                .foregroundColor(.secondary)
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
