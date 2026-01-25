//
//  AnnotationListView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import SwiftUI
import CoreData

// MARK: - Annotation List View

/// Displays a list of annotations for a PDF file
public struct AnnotationListView: View {
    let linkedFile: CDLinkedFile
    let onSelect: ((CDAnnotation, Int) -> Void)?  // (annotation, pageIndex) -> navigate to page

    @Environment(\.managedObjectContext) private var viewContext

    @State private var selectedAnnotation: CDAnnotation?
    @State private var showDeleteConfirmation = false
    @State private var annotationToDelete: CDAnnotation?

    public init(
        linkedFile: CDLinkedFile,
        onSelect: ((CDAnnotation, Int) -> Void)? = nil
    ) {
        self.linkedFile = linkedFile
        self.onSelect = onSelect
    }

    public var body: some View {
        Group {
            if linkedFile.hasAnnotations {
                List(linkedFile.sortedAnnotations, selection: $selectedAnnotation) { annotation in
                    AnnotationRow(annotation: annotation)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedAnnotation = annotation
                            onSelect?(annotation, Int(annotation.pageNumber))
                        }
                        .contextMenu {
                            Button {
                                onSelect?(annotation, Int(annotation.pageNumber))
                            } label: {
                                Label("Go to Page", systemImage: "arrow.right.circle")
                            }

                            if annotation.hasContent {
                                Button {
                                    copyAnnotationText(annotation)
                                } label: {
                                    Label("Copy Text", systemImage: "doc.on.doc")
                                }
                            }

                            Divider()

                            Button(role: .destructive) {
                                annotationToDelete = annotation
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.plain)
            } else {
                ContentUnavailableView(
                    "No Annotations",
                    systemImage: "highlighter",
                    description: Text("Highlight text in the PDF to add annotations")
                )
            }
        }
        .confirmationDialog(
            "Delete Annotation?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let annotation = annotationToDelete {
                    deleteAnnotation(annotation)
                }
            }
            Button("Cancel", role: .cancel) {
                annotationToDelete = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private func copyAnnotationText(_ annotation: CDAnnotation) {
        let text = annotation.contents ?? annotation.selectedText ?? ""
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func deleteAnnotation(_ annotation: CDAnnotation) {
        Task { @MainActor in
            try? AnnotationPersistence.shared.delete(annotation)
            annotationToDelete = nil
        }
    }
}

// MARK: - Annotation Row

struct AnnotationRow: View {
    @ObservedObject var annotation: CDAnnotation

    var body: some View {
        HStack(spacing: 12) {
            // Type icon with color
            annotationIcon
                .font(.title3)
                .foregroundStyle(annotationColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                // Preview text
                Text(annotation.previewText)
                    .font(.subheadline)
                    .lineLimit(2)

                // Metadata
                HStack(spacing: 8) {
                    Text("Page \(annotation.pageNumber + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let author = annotation.author {
                        Text("by \(author)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Date
            Text(annotation.dateCreated, style: .date)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var annotationIcon: some View {
        if let type = annotation.typeEnum {
            Image(systemName: type.icon)
        } else {
            Image(systemName: "highlighter")
        }
    }

    private var annotationColor: Color {
        if let hexColor = annotation.color {
            return Color(hex: hexColor) ?? .yellow
        }
        return .yellow
    }
}

// MARK: - Annotation Summary

/// Shows annotation count and types summary
public struct AnnotationSummary: View {
    let linkedFile: CDLinkedFile

    public init(linkedFile: CDLinkedFile) {
        self.linkedFile = linkedFile
    }

    public var body: some View {
        if linkedFile.hasAnnotations {
            HStack(spacing: 8) {
                Image(systemName: "highlighter")
                    .foregroundStyle(.yellow)

                Text("\(linkedFile.annotationCount) annotation\(linkedFile.annotationCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Annotation Badge

/// Small badge showing annotation count
public struct AnnotationBadge: View {
    let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.yellow)
                .clipShape(Capsule())
        }
    }
}

// Note: Uses Color.init(hex:) from Theme/Color+Hex.swift

// MARK: - Searchable Annotations

/// Search through annotations
public struct AnnotationSearchView: View {
    let linkedFile: CDLinkedFile
    let onSelect: ((CDAnnotation, Int) -> Void)?

    @State private var searchText = ""

    public init(
        linkedFile: CDLinkedFile,
        onSelect: ((CDAnnotation, Int) -> Void)? = nil
    ) {
        self.linkedFile = linkedFile
        self.onSelect = onSelect
    }

    private var filteredAnnotations: [CDAnnotation] {
        if searchText.isEmpty {
            return linkedFile.sortedAnnotations
        }

        let query = searchText.lowercased()
        return linkedFile.sortedAnnotations.filter { annotation in
            (annotation.contents?.lowercased().contains(query) ?? false) ||
            (annotation.selectedText?.lowercased().contains(query) ?? false)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search annotations", text: $searchText)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))

            Divider()

            // Results
            if filteredAnnotations.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No annotations match \"\(searchText)\"")
                )
            } else {
                List(filteredAnnotations) { annotation in
                    AnnotationRow(annotation: annotation)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect?(annotation, Int(annotation.pageNumber))
                        }
                }
                .listStyle(.plain)
            }
        }
    }
}
