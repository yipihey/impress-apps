//
//  CitationDropDelegate.swift
//  imprint-iOS
//
//  Created by Claude on 2026-01-27.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Citation Drop Support

/// Enables drag-and-drop of citations from imbib into imprint.
///
/// Supported drop types:
/// - BibTeX entries (text/x-bibtex)
/// - Plain text cite keys
/// - URLs to imbib papers
///
/// When a citation is dropped:
/// 1. Parse the BibTeX or cite key
/// 2. Add to document bibliography if not present
/// 3. Insert citation reference at cursor position
struct CitationDropDelegate: DropDelegate {

    // MARK: - Properties

    /// Callback when a citation is dropped
    let onCitationDropped: (DroppedCitation) -> Void

    /// Current insertion point (cursor position)
    let insertionPoint: Int?

    // MARK: - DropDelegate

    func validateDrop(info: DropInfo) -> Bool {
        // Accept BibTeX, plain text, or URLs
        return info.hasItemsConforming(to: [.bibtex, .plainText, .url])
    }

    func dropEntered(info: DropInfo) {
        // Visual feedback handled by view
    }

    func dropExited(info: DropInfo) {
        // Visual feedback handled by view
    }

    func performDrop(info: DropInfo) -> Bool {
        // Try BibTeX first
        if let provider = info.itemProviders(for: [.bibtex]).first {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.bibtex.identifier) { data, error in
                guard let data = data,
                      let bibtex = String(data: data, encoding: .utf8) else {
                    return
                }

                DispatchQueue.main.async {
                    self.handleBibTeXDrop(bibtex)
                }
            }
            return true
        }

        // Try plain text (cite key)
        if let provider = info.itemProviders(for: [.plainText]).first {
            provider.loadObject(ofClass: String.self) { string, error in
                guard let citeKey = string as? String else { return }

                DispatchQueue.main.async {
                    self.handleCiteKeyDrop(citeKey)
                }
            }
            return true
        }

        // Try URL (imbib paper URL)
        if let provider = info.itemProviders(for: [.url]).first {
            provider.loadObject(ofClass: URL.self) { url, error in
                guard let url = url as? URL else { return }

                DispatchQueue.main.async {
                    self.handleURLDrop(url)
                }
            }
            return true
        }

        return false
    }

    // MARK: - Drop Handlers

    private func handleBibTeXDrop(_ bibtex: String) {
        // Parse cite key from BibTeX
        guard let citeKey = parseCiteKey(from: bibtex) else { return }

        let citation = DroppedCitation(
            citeKey: citeKey,
            bibtex: bibtex,
            source: .dragDrop
        )

        onCitationDropped(citation)
    }

    private func handleCiteKeyDrop(_ citeKey: String) {
        let trimmed = citeKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove @ prefix if present
        let key = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed

        let citation = DroppedCitation(
            citeKey: key,
            bibtex: nil,
            source: .dragDrop
        )

        onCitationDropped(citation)
    }

    private func handleURLDrop(_ url: URL) {
        // Parse imbib URL: imbib://paper/{citeKey}
        guard url.scheme == "imbib",
              url.host == "paper",
              let citeKey = url.pathComponents.dropFirst().first else {
            return
        }

        let citation = DroppedCitation(
            citeKey: citeKey,
            bibtex: nil,
            source: .imbibURL
        )

        onCitationDropped(citation)
    }

    // MARK: - BibTeX Parsing

    private func parseCiteKey(from bibtex: String) -> String? {
        // Pattern: @type{citeKey,
        let pattern = #"@\w+\{([^,]+),"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: bibtex,
                range: NSRange(bibtex.startIndex..., in: bibtex)
              ),
              let range = Range(match.range(at: 1), in: bibtex) else {
            return nil
        }

        return String(bibtex[range])
    }
}

// MARK: - Dropped Citation

/// Represents a citation that was dropped into the editor.
struct DroppedCitation: Identifiable {
    let id = UUID()
    let citeKey: String
    let bibtex: String?
    let source: Source

    enum Source {
        case dragDrop
        case imbibURL
        case clipboard
    }

    /// The Typst citation reference to insert
    var typstReference: String {
        "@\(citeKey)"
    }
}

// MARK: - UTType Extension

extension UTType {
    /// BibTeX file type
    static var bibtex: UTType {
        UTType(filenameExtension: "bib") ?? .plainText
    }
}

// MARK: - Citation Drop Modifier

/// A view modifier that enables citation drop on any view.
struct CitationDropModifier: ViewModifier {
    @Binding var isDropTargeted: Bool
    let onCitationDropped: (DroppedCitation) -> Void

    func body(content: Content) -> some View {
        content
            .onDrop(
                of: [.bibtex, .plainText, .url],
                delegate: CitationDropDelegate(
                    onCitationDropped: onCitationDropped,
                    insertionPoint: nil
                )
            )
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.1))
                }
            }
    }
}

extension View {
    /// Enables dropping citations onto this view.
    func citationDropTarget(
        isTargeted: Binding<Bool>,
        onDrop: @escaping (DroppedCitation) -> Void
    ) -> some View {
        modifier(CitationDropModifier(
            isDropTargeted: isTargeted,
            onCitationDropped: onDrop
        ))
    }
}

// MARK: - Citation Drag Source

/// A view that can be dragged as a citation.
struct CitationDragSource: View {
    let citeKey: String
    let bibtex: String?

    var body: some View {
        Label(citeKey, systemImage: "quote.bubble")
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .draggable(citeKey) {
                // Preview shown during drag
                Label(citeKey, systemImage: "quote.bubble")
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
    }
}

// MARK: - Citation Insertion Service

/// Service for inserting citations into the document.
@MainActor @Observable
class CitationInsertionService {

    var pendingCitation: DroppedCitation?
    var showingCitationSheet = false

    /// Handles a dropped citation.
    func handleDroppedCitation(_ citation: DroppedCitation, document: inout ImprintDocument, at position: Int) {
        // Add to bibliography if we have BibTeX
        if let bibtex = citation.bibtex {
            document.bibliography[citation.citeKey] = bibtex
        }

        // Insert citation reference at position
        let reference = citation.typstReference
        document.insertText(reference, at: position)
    }

    /// Shows UI for confirming/editing a dropped citation.
    func promptForCitation(_ citation: DroppedCitation) {
        pendingCitation = citation
        showingCitationSheet = true
    }
}

// MARK: - Preview

#Preview("Citation Drag Source") {
    VStack(spacing: 16) {
        CitationDragSource(citeKey: "Smith2024", bibtex: nil)
        CitationDragSource(citeKey: "Jones2023", bibtex: nil)
        CitationDragSource(citeKey: "Brown2022", bibtex: nil)
    }
    .padding()
}

#Preview("Drop Target") {
    struct PreviewContent: View {
        @State private var isTargeted = false
        @State private var droppedCitations: [DroppedCitation] = []

        var body: some View {
            VStack {
                Text("Drop citations here")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGray6))
                    .citationDropTarget(isTargeted: $isTargeted) { citation in
                        droppedCitations.append(citation)
                    }

                ForEach(droppedCitations) { citation in
                    Text(citation.citeKey)
                }
            }
        }
    }

    return PreviewContent()
        .padding()
}
