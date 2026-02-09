//
//  RemarkableStatusSection.swift
//  PublicationManagerCore
//
//  Shows reMarkable sync status in the publication detail view.
//  ADR-019: reMarkable Tablet Integration
//

import SwiftUI

// MARK: - Status Section

/// A section view showing reMarkable sync status for a publication.
///
/// Displays:
/// - Connection status and device info
/// - "Send to reMarkable" button when PDF is available
/// - Sync state badge (synced/pending/conflict/error)
/// - Last sync date
/// - Annotation count with link to view them
/// - Sync Now / Remove buttons
public struct RemarkableStatusSection: View {

    // MARK: - Properties

    let publicationID: UUID

    @State private var remarkableDocID: String?
    @State private var remarkableSyncState: String?
    @State private var annotationCount: Int = 0
    @State private var lastSyncDate: Date?
    @State private var isLoading = false
    @State private var error: String?
    @State private var showingAnnotations = false
    @State private var hasPDF = false

    private let syncManager = RemarkableSyncManager.shared
    private let settings = RemarkableSettingsStore.shared
    private let store = RustStoreAdapter.shared

    // MARK: - Body

    public init(publicationID: UUID) {
        self.publicationID = publicationID
    }

    public var body: some View {
        Section {
            if remarkableDocID != nil {
                connectedView
            } else {
                disconnectedView
            }
        } header: {
            HStack {
                Label("reMarkable", systemImage: "tablet.landscape")
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .task {
            await loadRemarkableDocument()
        }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .sheet(isPresented: $showingAnnotations) {
            RemarkableAnnotationsSheet(publicationID: publicationID)
        }
    }

    // MARK: - Connected State

    @ViewBuilder
    private var connectedView: some View {
        // Sync state
        if let syncState = remarkableSyncState {
            LabeledContent("Status") {
                SyncStateBadge(state: syncState)
            }
        }

        // Last sync date
        if let lastSync = lastSyncDate {
            LabeledContent("Last synced") {
                Text(lastSync, style: .relative)
                    .foregroundStyle(.secondary)
            }
        }

        // Annotation count
        if annotationCount > 0 {
            Button {
                showingAnnotations = true
            } label: {
                LabeledContent("Annotations") {
                    HStack(spacing: 4) {
                        Text("\(annotationCount)")
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
        }

        // Actions
        HStack {
            Button {
                Task { await syncAnnotations() }
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isLoading)

            Spacer()

            Button(role: .destructive) {
                Task { await removeFromDevice() }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(isLoading)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Disconnected State

    @ViewBuilder
    private var disconnectedView: some View {
        if hasPDF {
            if settings.isAuthenticated {
                Button {
                    Task { await pushToDevice() }
                } label: {
                    Label("Send to reMarkable", systemImage: "arrow.up.doc")
                }
                .disabled(isLoading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect to reMarkable in Settings to sync this paper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    #if os(macOS)
                    Button("Open Settings...") {
                        // Post notification to open settings
                        NotificationCenter.default.post(
                            name: .init("openRemarkableSettings"),
                            object: nil
                        )
                    }
                    .buttonStyle(.link)
                    #endif
                }
            }
        } else {
            Text("Download PDF first to send to reMarkable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func loadRemarkableDocument() async {
        guard let detail = store.getPublicationDetail(id: publicationID) else { return }

        remarkableDocID = detail.fields["_remarkable_doc_id"]
        remarkableSyncState = detail.fields["_remarkable_sync_state"]
        annotationCount = Int(detail.fields["_remarkable_annotation_count"] ?? "0") ?? 0

        if let lastSyncStr = detail.fields["_remarkable_last_sync"] {
            lastSyncDate = ISO8601DateFormatter().date(from: lastSyncStr)
        }

        hasPDF = detail.linkedFiles.contains { $0.isPDF }
    }

    private func pushToDevice() async {
        let linkedFiles = store.listLinkedFiles(publicationId: publicationID)
        guard let pdfFile = linkedFiles.first(where: { $0.isPDF }) else {
            self.error = "No PDF available"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let docID = try await syncManager.uploadPublication(publicationID, linkedFile: pdfFile)
            remarkableDocID = docID
            remarkableSyncState = "synced"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func syncAnnotations() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let count = try await syncManager.importAnnotations(for: publicationID)
            annotationCount = count
            await loadRemarkableDocument()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeFromDevice() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let backend = try RemarkableBackendManager.shared.requireActiveBackend()
            if let docID = remarkableDocID {
                try await backend.deleteDocument(documentID: docID)
            }

            // Clear remarkable fields
            store.updateField(id: publicationID, field: "_remarkable_doc_id", value: nil)
            store.updateField(id: publicationID, field: "_remarkable_folder_id", value: nil)
            store.updateField(id: publicationID, field: "_remarkable_sync_state", value: nil)
            store.updateField(id: publicationID, field: "_remarkable_date_uploaded", value: nil)
            store.updateField(id: publicationID, field: "_remarkable_last_sync", value: nil)
            store.updateField(id: publicationID, field: "_remarkable_annotation_count", value: nil)

            remarkableDocID = nil
            remarkableSyncState = nil
            annotationCount = 0
            lastSyncDate = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Sync State Badge

/// A badge showing the current sync state with appropriate color and icon.
struct SyncStateBadge: View {
    let state: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(displayText)
                .foregroundStyle(color)
        }
        .font(.caption)
    }

    private var color: Color {
        switch state {
        case "synced": return .green
        case "pending": return .orange
        case "conflict": return .red
        case "error": return .red
        default: return .secondary
        }
    }

    private var displayText: String {
        switch state {
        case "synced": return "Synced"
        case "pending": return "Pending"
        case "conflict": return "Conflict"
        case "error": return "Error"
        default: return state.capitalized
        }
    }

    private var icon: String {
        switch state {
        case "synced": return "checkmark.circle.fill"
        case "pending": return "clock.fill"
        case "conflict": return "exclamationmark.triangle.fill"
        case "error": return "xmark.circle.fill"
        default: return "questionmark.circle"
        }
    }
}

// MARK: - Annotations Sheet

/// Sheet view showing imported reMarkable annotations.
struct RemarkableAnnotationsSheet: View {
    let publicationID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var annotations: [AnnotationModel] = []

    private let store = RustStoreAdapter.shared

    var body: some View {
        NavigationStack {
            List {
                ForEach(annotations, id: \.id) { annotation in
                    RemarkableAnnotationRow(annotation: annotation)
                }
            }
            .navigationTitle("reMarkable Annotations")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                loadAnnotations()
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 300)
        #endif
    }

    private func loadAnnotations() {
        let linkedFiles = store.listLinkedFiles(publicationId: publicationID)
        var allAnnotations: [AnnotationModel] = []
        for file in linkedFiles where file.isPDF {
            let fileAnnotations = store.listAnnotations(linkedFileId: file.id)
            // Filter to reMarkable annotations only
            allAnnotations += fileAnnotations.filter { $0.authorName == "reMarkable" }
        }
        annotations = allAnnotations.sorted { $0.pageNumber < $1.pageNumber }
    }
}

// MARK: - Annotation Row

/// A single reMarkable annotation row in the list.
struct RemarkableAnnotationRow: View {
    let annotation: AnnotationModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Type icon
            Image(systemName: iconForType)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                // Type and page
                HStack {
                    Text(displayName)
                        .font(.headline)
                    Text("Page \(annotation.pageNumber + 1)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Text content if available
                if let text = annotation.selectedText ?? annotation.contents, !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                }

                // Import date
                Text(annotation.dateCreated, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconForType: String {
        switch annotation.annotationType {
        case "highlight": return "highlighter"
        case "ink": return "pencil.tip"
        case "note", "text": return "text.bubble"
        default: return "pencil"
        }
    }

    private var displayName: String {
        switch annotation.annotationType {
        case "highlight": return "Highlight"
        case "ink": return "Handwritten"
        case "note", "text": return "Note"
        default: return annotation.annotationType.capitalized
        }
    }

    private var iconColor: Color {
        switch annotation.annotationType {
        case "highlight": return .yellow
        case "ink": return .primary
        case "note", "text": return .blue
        default: return .secondary
        }
    }
}

// MARK: - Preview

#if DEBUG
struct RemarkableStatusSection_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            // Preview would need a mock publication
            Text("RemarkableStatusSection Preview")
        }
    }
}
#endif
