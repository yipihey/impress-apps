//
//  AnnotationTimelineView.swift
//  PublicationManagerCore
//
//  Chronological view of all annotations across sources (local + reMarkable).
//  ADR-019: reMarkable Tablet Integration
//

import SwiftUI
import CoreData

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Annotation Timeline View

/// A chronological view showing all annotations for a publication.
///
/// Combines annotations from multiple sources:
/// - Local PDF annotations (highlights, notes, underlines)
/// - reMarkable annotations (handwritten notes, highlights)
///
/// Provides filtering by source and type, and allows copying content.
public struct AnnotationTimelineView: View {

    // MARK: - Properties

    let publication: CDPublication

    @State private var annotations: [TimelineAnnotation] = []
    @State private var isLoading = true
    @State private var filterSource: SourceFilter = .all
    @State private var filterType: TypeFilter = .all

    // MARK: - Filter Types

    enum SourceFilter: String, CaseIterable {
        case all = "All Sources"
        case local = "Local"
        case remarkable = "reMarkable"
    }

    enum TypeFilter: String, CaseIterable {
        case all = "All Types"
        case highlight = "Highlights"
        case note = "Notes"
        case ink = "Handwritten"
    }

    // MARK: - Initialization

    public init(publication: CDPublication) {
        self.publication = publication
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            filterBar

            Divider()

            // Content
            if isLoading {
                ProgressView("Loading annotations...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredAnnotations.isEmpty {
                emptyState
            } else {
                annotationList
            }
        }
        .task {
            await loadAnnotations()
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $filterSource) {
                ForEach(SourceFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Picker("Type", selection: $filterType) {
                ForEach(TypeFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Spacer()

            Text("\(filteredAnnotations.count) annotation\(filteredAnnotations.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Annotation List

    private var annotationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(filteredAnnotations) { annotation in
                    AnnotationTimelineRow(annotation: annotation)
                }
            }
            .padding()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Annotations")
                .font(.headline)

            Text(filterSource == .all && filterType == .all
                 ? "This publication has no annotations yet."
                 : "No annotations match the selected filters.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filtered Annotations

    private var filteredAnnotations: [TimelineAnnotation] {
        annotations.filter { annotation in
            // Source filter
            let matchesSource: Bool
            switch filterSource {
            case .all: matchesSource = true
            case .local: matchesSource = annotation.source == .local
            case .remarkable: matchesSource = annotation.source == .remarkable
            }

            // Type filter
            let matchesType: Bool
            switch filterType {
            case .all: matchesType = true
            case .highlight: matchesType = annotation.type == "highlight"
            case .note: matchesType = annotation.type == "note" || annotation.type == "text" || annotation.type == "freeText"
            case .ink: matchesType = annotation.type == "ink"
            }

            return matchesSource && matchesType
        }
    }

    // MARK: - Load Annotations

    private func loadAnnotations() async {
        isLoading = true
        defer { isLoading = false }

        var timeline: [TimelineAnnotation] = []

        // Load local PDF annotations
        await MainActor.run {
            if let linkedFiles = publication.linkedFiles {
                for file in linkedFiles where file.isPDF {
                    if let cdAnnotations = file.annotations {
                        timeline += cdAnnotations.map { TimelineAnnotation(from: $0) }
                    }
                }
            }
        }

        // Load reMarkable annotations
        let context = await MainActor.run {
            PersistenceController.shared.viewContext
        }

        let request = NSFetchRequest<CDRemarkableDocument>(entityName: "RemarkableDocument")
        request.predicate = NSPredicate(format: "publication == %@", publication)

        do {
            let documents = try await MainActor.run {
                try context.fetch(request)
            }

            if let rmDoc = documents.first {
                let rmAnnotations = await MainActor.run {
                    rmDoc.sortedAnnotations
                }
                timeline += rmAnnotations.map { TimelineAnnotation(from: $0) }
            }
        } catch {
            // Log error but continue with whatever we have
            print("Failed to load reMarkable annotations: \(error)")
        }

        // Sort by date (newest first)
        annotations = timeline.sorted { $0.date > $1.date }
    }
}

// MARK: - Timeline Annotation

/// A unified annotation representation for the timeline view.
struct TimelineAnnotation: Identifiable {
    let id: UUID
    let type: String
    let text: String
    let pageNumber: Int
    let date: Date
    let source: Source
    let color: String?
    let hasStrokeData: Bool

    enum Source {
        case local
        case remarkable
    }

    /// Create from a local CDAnnotation.
    init(from cdAnnotation: CDAnnotation) {
        id = cdAnnotation.id
        type = cdAnnotation.annotationType
        text = cdAnnotation.selectedText ?? cdAnnotation.contents ?? ""
        pageNumber = Int(cdAnnotation.pageNumber)
        date = cdAnnotation.dateCreated
        source = .local
        color = cdAnnotation.color
        hasStrokeData = false
    }

    /// Create from a reMarkable annotation.
    init(from rmAnnotation: CDRemarkableAnnotation) {
        id = rmAnnotation.id
        type = rmAnnotation.annotationType
        text = rmAnnotation.ocrText ?? ""
        pageNumber = Int(rmAnnotation.pageNumber)
        date = rmAnnotation.dateImported
        source = .remarkable
        color = rmAnnotation.color
        hasStrokeData = rmAnnotation.strokeDataCompressed != nil
    }
}

// MARK: - Annotation Timeline Row

/// A single row in the annotation timeline.
struct AnnotationTimelineRow: View {
    let annotation: TimelineAnnotation

    @State private var isCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Source indicator
            sourceIcon

            VStack(alignment: .leading, spacing: 4) {
                // Type and page
                HStack {
                    Text(displayType)
                        .font(.caption.bold())
                        .foregroundStyle(typeColor)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text("Page \(annotation.pageNumber + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Content
                if !annotation.text.isEmpty {
                    Text(annotation.text)
                        .font(.callout)
                        .lineLimit(3)
                }

                // Ink indicator
                if annotation.hasStrokeData && annotation.text.isEmpty {
                    Label("Handwritten content", systemImage: "pencil.tip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Actions
                HStack {
                    if !annotation.text.isEmpty {
                        Button {
                            copyToClipboard()
                        } label: {
                            Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }

                    Spacer()

                    Text(annotation.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Source Icon

    private var sourceIcon: some View {
        Image(systemName: annotation.source == .remarkable ? "tablet.landscape" : "doc.text")
            .foregroundStyle(annotation.source == .remarkable ? .orange : .blue)
            .frame(width: 24)
    }

    // MARK: - Display Type

    private var displayType: String {
        switch annotation.type {
        case "highlight": return "Highlight"
        case "underline": return "Underline"
        case "strikethrough": return "Strikethrough"
        case "note", "freeText", "text": return "Note"
        case "ink": return "Handwritten"
        default: return annotation.type.capitalized
        }
    }

    // MARK: - Type Color

    private var typeColor: Color {
        if let colorHex = annotation.color {
            return Color(hex: colorHex) ?? .primary
        }

        switch annotation.type {
        case "highlight": return .yellow
        case "underline": return .blue
        case "strikethrough": return .red
        case "note", "freeText", "text": return .green
        case "ink": return .orange
        default: return .primary
        }
    }

    // MARK: - Copy

    private func copyToClipboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(annotation.text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = annotation.text
        #endif

        isCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            isCopied = false
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AnnotationTimelineView_Previews: PreviewProvider {
    static var previews: some View {
        Text("AnnotationTimelineView Preview")
            .padding()
    }
}
#endif
