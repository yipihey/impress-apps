//
//  IOSDocumentOutlineView.swift
//  imprint-iOS
//
//  Document outline (headings / sections) for iOS/iPadOS.
//
//  The macOS `DocumentOutlineView` is macOS-only (it lives in the macOS
//  target and leans on `Section(isExpanded:)` sidebar chrome). Rather than
//  share that View, this file ports its proven regex parsers
//  (`parseTypstItems` / `parseLaTeXItems` / `buildFlatTree`) — the reliable
//  path that works for the single-file manuscripts iOS edits — and renders
//  them in a touch-friendly `List`.
//
//  Presentation is owned by `IOSContentView`:
//  - iPad (regular width): a persistent left column.
//  - iPhone (compact width): a sheet raised from a toolbar button.
//
//  Tapping a row calls `onNavigateToLine(1-based line)`, which drives the
//  editor's go-to-line binding.
//

import SwiftUI
import OSLog
import ImprintCore
import ImpressLogging

// MARK: - Outline View

struct IOSDocumentOutlineView: View {

    /// Live document source. Re-parsed whenever it changes.
    let source: String

    /// Document format (Typst vs LaTeX). Auto-corrected for LaTeX content
    /// mislabelled as Typst, mirroring the macOS view.
    var format: DocumentFormat = .typst

    /// Called with the 1-based line number of the tapped heading.
    var onNavigateToLine: ((Int) -> Void)?

    /// Optional dismiss handler — supplied when hosted in a sheet (iPhone).
    var onDismiss: (() -> Void)?

    private var flatItems: [IOSFlatOutlineItem] {
        let items: [IOSOutlineItem]
        switch effectiveFormat {
        case .typst: items = Self.parseTypstItems(source)
        case .latex: items = Self.parseLaTeXItems(source)
        case .markdown: items = Self.parseMarkdownItems(source)
        case .plaintext: items = []   // no heading grammar
        }
        return Self.buildFlatTree(from: items)
    }

    var body: some View {
        Group {
            if flatItems.isEmpty {
                ContentUnavailableView(
                    "No Headings",
                    systemImage: "list.bullet.indent",
                    description: Text("Add headings to your document to build an outline.")
                )
            } else {
                List(flatItems) { item in
                    Button {
                        Logger.editor.infoCapture(
                            "Outline navigate → line \(item.lineNumber + 1) (\(item.title))",
                            category: "outline"
                        )
                        onNavigateToLine?(item.lineNumber + 1) // 0-based → 1-based
                        onDismiss?()
                    } label: {
                        HStack(spacing: 6) {
                            if item.depth > 0 {
                                Spacer().frame(width: CGFloat(item.depth) * 14)
                            }
                            Image(systemName: iconName(for: item.level))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(item.title)
                                .lineLimit(1)
                                .font(item.depth == 0 ? .body.weight(.semibold) : .body)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("outline.item.\(item.lineNumber)")
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Outline")
        .accessibilityIdentifier("outline.container")
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

    // MARK: - Parsing (ported verbatim from macOS DocumentOutlineView)

    private static func parseTypstItems(_ source: String) -> [IOSOutlineItem] {
        var items: [IOSOutlineItem] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("=") {
                let level = trimmed.prefix(while: { $0 == "=" }).count
                let title = String(trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces))
                if !title.isEmpty {
                    items.append(IOSOutlineItem(title: title, level: level, lineNumber: index))
                }
            }
        }
        return items
    }

    /// ATX headings outside code fences — mirrors the macOS
    /// `DocumentOutlineView.parseMarkdownItems` grammar.
    private static func parseMarkdownItems(_ source: String) -> [IOSOutlineItem] {
        var items: [IOSOutlineItem] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var inFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, trimmed.hasPrefix("#") else { continue }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            guard level <= 6 else { continue }
            let title = String(trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces))
            if !title.isEmpty {
                items.append(IOSOutlineItem(title: title, level: level, lineNumber: index))
            }
        }
        return items
    }

    private static func parseLaTeXItems(_ source: String) -> [IOSOutlineItem] {
        var items: [IOSOutlineItem] = []
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
                items.append(IOSOutlineItem(title: String(lineStr[titleRange]), level: level, lineNumber: index))
                break
            }

            if trimmed.hasPrefix("\\appendix") {
                items.append(IOSOutlineItem(title: "Appendix", level: 1, lineNumber: index))
            } else if trimmed.contains("\\begin{abstract}") {
                items.append(IOSOutlineItem(title: "Abstract", level: 1, lineNumber: index))
            } else if trimmed.contains("\\begin{thebibliography}") || trimmed.contains("\\printbibliography") {
                items.append(IOSOutlineItem(title: "Bibliography", level: 1, lineNumber: index))
            }
        }
        return items
    }

    private static func buildFlatTree(from items: [IOSOutlineItem]) -> [IOSFlatOutlineItem] {
        guard !items.isEmpty else { return [] }
        let baseLevel = items.first?.level ?? 1
        return items.enumerated().map { (i, item) in
            let hasChildren = i + 1 < items.count && items[i + 1].level > item.level
            return IOSFlatOutlineItem(
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

struct IOSFlatOutlineItem: Identifiable {
    var id: String { "\(lineNumber):\(title)" }
    let title: String
    let level: Int
    let lineNumber: Int
    let depth: Int
    let hasChildren: Bool
}

private struct IOSOutlineItem {
    let title: String
    let level: Int
    let lineNumber: Int
}

// MARK: - Preview

#Preview {
    NavigationStack {
        IOSDocumentOutlineView(
            source: """
            = Introduction

            Some text here.

            == Background

            == Methods

            === Data Collection

            = Results

            = Discussion
            """,
            onNavigateToLine: { print("navigate to line \($0)") }
        )
    }
}
