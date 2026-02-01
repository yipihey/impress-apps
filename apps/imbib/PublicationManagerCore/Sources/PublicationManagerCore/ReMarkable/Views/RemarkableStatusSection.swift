//
//  RemarkableStatusSection.swift
//  PublicationManagerCore
//
//  Shows reMarkable sync status in the publication detail view.
//  ADR-019: reMarkable Tablet Integration
//

import SwiftUI
import CoreData

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

    let publication: CDPublication

    @State private var remarkableDocument: CDRemarkableDocument?
    @State private var isLoading = false
    @State private var error: String?
    @State private var showingAnnotations = false

    private let syncManager = RemarkableSyncManager.shared
    private let settings = RemarkableSettingsStore.shared

    // MARK: - Body

    public init(publication: CDPublication) {
        self.publication = publication
    }

    public var body: some View {
        Section {
            if let doc = remarkableDocument {
                connectedView(doc)
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
            if let doc = remarkableDocument {
                RemarkableAnnotationsSheet(document: doc)
            }
        }
    }

    // MARK: - Connected State

    @ViewBuilder
    private func connectedView(_ doc: CDRemarkableDocument) -> some View {
        // Sync state
        LabeledContent("Status") {
            SyncStateBadge(state: doc.syncStateEnum)
        }

        // Last sync date
        if let lastSync = doc.lastSyncDate {
            LabeledContent("Last synced") {
                Text(lastSync, style: .relative)
                    .foregroundStyle(.secondary)
            }
        }

        // Annotation count
        if doc.annotationCount > 0 {
            Button {
                showingAnnotations = true
            } label: {
                LabeledContent("Annotations") {
                    HStack(spacing: 4) {
                        Text("\(doc.annotationCount)")
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
                Task { await syncAnnotations(doc) }
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isLoading)

            Spacer()

            Button(role: .destructive) {
                Task { await removeFromDevice(doc) }
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
        if publication.hasPDFAvailable {
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
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDRemarkableDocument>(entityName: "RemarkableDocument")
        request.predicate = NSPredicate(format: "publication == %@", publication)
        request.fetchLimit = 1

        remarkableDocument = try? context.fetch(request).first
    }

    private func pushToDevice() async {
        guard let linkedFile = publication.primaryPDF ?? publication.linkedFiles?.first(where: { $0.isPDF }) else {
            self.error = "No PDF available"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let doc = try await syncManager.uploadPublication(publication, linkedFile: linkedFile)
            remarkableDocument = doc
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func syncAnnotations(_ doc: CDRemarkableDocument) async {
        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await syncManager.importAnnotations(for: doc)
            await loadRemarkableDocument()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeFromDevice(_ doc: CDRemarkableDocument) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let backend = try RemarkableBackendManager.shared.requireActiveBackend()
            try await backend.deleteDocument(documentID: doc.remarkableDocumentID)

            let context = PersistenceController.shared.viewContext
            context.delete(doc)
            try context.save()

            remarkableDocument = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Sync State Badge

/// A badge showing the current sync state with appropriate color and icon.
struct SyncStateBadge: View {
    let state: CDRemarkableDocument.SyncState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.icon)
                .foregroundStyle(color)
            Text(displayText)
                .foregroundStyle(color)
        }
        .font(.caption)
    }

    private var color: Color {
        switch state {
        case .synced: return .green
        case .pending: return .orange
        case .conflict: return .red
        case .error: return .red
        }
    }

    private var displayText: String {
        switch state {
        case .synced: return "Synced"
        case .pending: return "Pending"
        case .conflict: return "Conflict"
        case .error: return "Error"
        }
    }
}

// MARK: - Annotations Sheet

/// Sheet view showing imported reMarkable annotations.
struct RemarkableAnnotationsSheet: View {
    let document: CDRemarkableDocument

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(document.sortedAnnotations, id: \.id) { annotation in
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
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 300)
        #endif
    }
}

// MARK: - Annotation Row

/// A single reMarkable annotation row in the list.
struct RemarkableAnnotationRow: View {
    let annotation: CDRemarkableAnnotation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Type icon
            Image(systemName: annotation.typeEnum.icon)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                // Type and page
                HStack {
                    Text(annotation.typeEnum.displayName)
                        .font(.headline)
                    Text("• Page \(annotation.pageNumber + 1)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // OCR text if available
                if let ocrText = annotation.ocrText, !ocrText.isEmpty {
                    Text(ocrText)
                        .font(.body)
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                }

                // Import date
                Text(annotation.dateImported, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconColor: Color {
        switch annotation.typeEnum {
        case .highlight: return .yellow
        case .ink: return .primary
        case .text: return .blue
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
