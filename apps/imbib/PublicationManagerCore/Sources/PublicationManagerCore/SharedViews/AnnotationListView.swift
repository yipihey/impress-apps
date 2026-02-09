//
//  AnnotationListView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import SwiftUI

// MARK: - Annotation List View

/// Displays a list of annotations for a PDF file
public struct AnnotationListView: View {
    let linkedFileID: UUID
    let onSelect: ((AnnotationModel, Int) -> Void)?  // (annotation, pageIndex) -> navigate to page

    @State private var annotations: [AnnotationModel] = []
    @State private var selectedAnnotationID: UUID?
    @State private var showDeleteConfirmation = false
    @State private var annotationToDeleteID: UUID?

    private let store = RustStoreAdapter.shared

    public init(
        linkedFileID: UUID,
        onSelect: ((AnnotationModel, Int) -> Void)? = nil
    ) {
        self.linkedFileID = linkedFileID
        self.onSelect = onSelect
    }

    public var body: some View {
        Group {
            if !annotations.isEmpty {
                List(annotations, selection: $selectedAnnotationID) { annotation in
                    AnnotationRow(annotation: annotation)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedAnnotationID = annotation.id
                            onSelect?(annotation, annotation.pageNumber)
                        }
                        .contextMenu {
                            Button {
                                onSelect?(annotation, annotation.pageNumber)
                            } label: {
                                Label("Go to Page", systemImage: "arrow.right.circle")
                            }

                            if annotation.contents != nil || annotation.selectedText != nil {
                                Button {
                                    copyAnnotationText(annotation)
                                } label: {
                                    Label("Copy Text", systemImage: "doc.on.doc")
                                }
                            }

                            Divider()

                            Button(role: .destructive) {
                                annotationToDeleteID = annotation.id
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
        .onAppear {
            loadAnnotations()
        }
        .confirmationDialog(
            "Delete Annotation?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let annotationID = annotationToDeleteID {
                    deleteAnnotation(annotationID)
                }
            }
            Button("Cancel", role: .cancel) {
                annotationToDeleteID = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private func loadAnnotations() {
        annotations = store.listAnnotations(linkedFileId: linkedFileID)
            .sorted { $0.pageNumber < $1.pageNumber }
    }

    private func copyAnnotationText(_ annotation: AnnotationModel) {
        let text = annotation.contents ?? annotation.selectedText ?? ""
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func deleteAnnotation(_ annotationID: UUID) {
        store.deleteItem(id: annotationID)
        annotationToDeleteID = nil
        loadAnnotations()
    }
}

// MARK: - Annotation Row

struct AnnotationRow: View {
    let annotation: AnnotationModel

    var body: some View {
        HStack(spacing: 12) {
            // Type icon with color
            annotationIcon
                .font(.title3)
                .foregroundStyle(annotationColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                // Preview text
                Text(previewText)
                    .font(.subheadline)
                    .lineLimit(2)

                // Metadata
                HStack(spacing: 8) {
                    Text("Page \(annotation.pageNumber + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let author = annotation.authorName {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.blue.opacity(0.5))
                                .frame(width: 8, height: 8)
                            Text(author)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
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

    private var previewText: String {
        annotation.selectedText ?? annotation.contents ?? annotation.annotationType.capitalized
    }

    @ViewBuilder
    private var annotationIcon: some View {
        switch annotation.annotationType {
        case "highlight":
            Image(systemName: "highlighter")
        case "underline":
            Image(systemName: "underline")
        case "strikethrough":
            Image(systemName: "strikethrough")
        case "note", "freeText", "text":
            Image(systemName: "text.bubble")
        case "ink":
            Image(systemName: "pencil.tip")
        default:
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
    let linkedFileID: UUID
    @State private var annotationCount: Int = 0

    private let store = RustStoreAdapter.shared

    public init(linkedFileID: UUID) {
        self.linkedFileID = linkedFileID
    }

    public var body: some View {
        if annotationCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: "highlighter")
                    .foregroundStyle(.yellow)

                Text("\(annotationCount) annotation\(annotationCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                annotationCount = store.countAnnotations(linkedFileId: linkedFileID)
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
    let linkedFileID: UUID
    let onSelect: ((AnnotationModel, Int) -> Void)?

    @State private var searchText = ""
    @State private var annotations: [AnnotationModel] = []

    private let store = RustStoreAdapter.shared

    public init(
        linkedFileID: UUID,
        onSelect: ((AnnotationModel, Int) -> Void)? = nil
    ) {
        self.linkedFileID = linkedFileID
        self.onSelect = onSelect
    }

    private var filteredAnnotations: [AnnotationModel] {
        if searchText.isEmpty {
            return annotations
        }

        let query = searchText.lowercased()
        return annotations.filter { annotation in
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
                            onSelect?(annotation, annotation.pageNumber)
                        }
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            annotations = store.listAnnotations(linkedFileId: linkedFileID)
                .sorted { $0.pageNumber < $1.pageNumber }
        }
    }
}
