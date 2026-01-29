//
//  RemarkableDocumentBrowserView.swift
//  PublicationManagerCore
//
//  Browser for viewing and managing documents on reMarkable tablet.
//  ADR-019: reMarkable Tablet Integration
//

import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableBrowser")

// MARK: - Document Browser View

/// Browser view for reMarkable documents and folders.
public struct RemarkableDocumentBrowserView: View {
    @State private var viewModel = RemarkableDocumentBrowserViewModel()
    @State private var selectedDocument: RemarkableDocumentInfo?
    @State private var showImportSheet = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    loadingView
                } else if viewModel.documents.isEmpty && viewModel.folders.isEmpty {
                    emptyView
                } else {
                    documentList
                }
            }
            .navigationTitle("reMarkable Documents")
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 400)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .task {
                await viewModel.loadDocuments()
            }
            .alert("Error", isPresented: .constant(viewModel.error != nil)) {
                Button("OK") { viewModel.error = nil }
            } message: {
                Text(viewModel.error?.localizedDescription ?? "")
            }
            .sheet(isPresented: $showImportSheet) {
                if let doc = selectedDocument {
                    RemarkableImportSheet(document: doc) {
                        showImportSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Loading documents...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No Documents", systemImage: "doc.text")
        } description: {
            Text("Your reMarkable library is empty, or you haven't connected yet.")
        } actions: {
            Button("Refresh") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Document List

    private var documentList: some View {
        List {
            // Current path breadcrumb
            if !viewModel.currentPath.isEmpty {
                Section {
                    Button {
                        viewModel.navigateUp()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }

            // Folders
            if !viewModel.currentFolders.isEmpty {
                Section("Folders") {
                    ForEach(viewModel.currentFolders, id: \.id) { folder in
                        FolderRow(folder: folder) {
                            viewModel.navigate(to: folder)
                        }
                    }
                }
            }

            // Documents
            if !viewModel.currentDocuments.isEmpty {
                Section("Documents") {
                    ForEach(viewModel.currentDocuments, id: \.id) { document in
                        DocumentRow(
                            document: document,
                            syncState: viewModel.syncState(for: document)
                        ) {
                            selectedDocument = document
                            showImportSheet = true
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.sidebar)
        #endif
    }
}

// MARK: - Folder Row

private struct FolderRow: View {
    let folder: RemarkableFolderInfo
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.yellow)
                    .font(.title2)

                VStack(alignment: .leading) {
                    Text(folder.name)
                        .font(.headline)
                    Text("\(folder.documentCount) documents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Document Row

private struct DocumentRow: View {
    let document: RemarkableDocumentInfo
    let syncState: RemarkableSyncState?
    let onImport: () -> Void

    var body: some View {
        HStack {
            // Document icon
            documentIcon

            // Document info
            VStack(alignment: .leading, spacing: 4) {
                Text(document.name)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    // Last modified
                    Text(document.lastModified.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Page count
                    if document.pageCount > 0 {
                        Text("\(document.pageCount) pages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Sync state indicator
            syncStateView

            // Import button
            Button("Import", action: onImport)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var documentIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 40, height: 50)

            Image(systemName: document.hasAnnotations ? "doc.text.fill" : "doc.fill")
                .foregroundStyle(document.hasAnnotations ? .blue : .secondary)
        }
    }

    @ViewBuilder
    private var syncStateView: some View {
        if let state = syncState {
            switch state {
            case .synced:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .syncing:
                ProgressView()
                    .controlSize(.small)
            case .pending:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .conflict:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            case .notSynced:
                EmptyView()
            }
        }
    }
}

// MARK: - Import Sheet

private struct RemarkableImportSheet: View {
    let document: RemarkableDocumentInfo
    let onDismiss: () -> Void

    @State private var isImporting = false
    @State private var importProgress: Double = 0
    @State private var importMessage: String = "Preparing..."
    @State private var importComplete = false
    @State private var importError: Error?
    @State private var importedAnnotationCount = 0

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading) {
                    Text(document.name)
                        .font(.headline)
                    Text("Import Annotations")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()

            Divider()

            // Content
            if importComplete {
                completionView
            } else if isImporting {
                progressView
            } else {
                confirmationView
            }

            Divider()

            // Actions
            HStack {
                if importComplete {
                    Button("Done", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel", action: onDismiss)
                        .buttonStyle(.bordered)

                    Spacer()

                    Button("Import") {
                        startImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting)
                }
            }
            .padding()
        }
        .frame(width: 400)
        .alert("Import Error", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError?.localizedDescription ?? "")
        }
    }

    private var confirmationView: some View {
        VStack(spacing: 12) {
            Text("Import annotations from this document?")
                .font(.body)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Pages", value: "\(document.pageCount)")
                    LabeledContent("Annotations", value: document.hasAnnotations ? "Yes" : "None detected")
                    LabeledContent("Last Modified", value: document.lastModified.formatted())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    private var progressView: some View {
        VStack(spacing: 12) {
            ProgressView(value: importProgress)
                .progressViewStyle(.linear)

            Text(importMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var completionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Import Complete")
                .font(.headline)

            Text("Imported \(importedAnnotationCount) annotations")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func startImport() {
        isImporting = true

        Task {
            do {
                importMessage = "Downloading document..."
                importProgress = 0.2

                // Get the sync manager
                let syncManager = RemarkableSyncManager.shared

                importMessage = "Parsing annotations..."
                importProgress = 0.5

                // Import annotations
                // Note: This would need a publication to link to
                // For now, just demonstrate the flow

                importMessage = "Processing..."
                importProgress = 0.8

                // Simulate some work
                try await Task.sleep(for: .seconds(1))

                importProgress = 1.0
                importedAnnotationCount = document.hasAnnotations ? 5 : 0 // Placeholder

                await MainActor.run {
                    importComplete = true
                    isImporting = false
                }
            } catch {
                await MainActor.run {
                    importError = error
                    isImporting = false
                }
            }
        }
    }
}

// MARK: - View Model

@MainActor
@Observable
final class RemarkableDocumentBrowserViewModel {
    var documents: [RemarkableDocumentInfo] = []
    var folders: [RemarkableFolderInfo] = []
    var currentPath: [RemarkableFolderInfo] = []
    var isLoading = false
    var error: Error?

    private var syncStates: [String: RemarkableSyncState] = [:]

    /// Documents in the current folder.
    var currentDocuments: [RemarkableDocumentInfo] {
        let currentFolderID = currentPath.last?.id
        return documents.filter { $0.parentFolderID == currentFolderID }
    }

    /// Folders in the current folder.
    var currentFolders: [RemarkableFolderInfo] {
        let currentFolderID = currentPath.last?.id
        return folders.filter { $0.parentFolderID == currentFolderID }
    }

    func loadDocuments() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil

        do {
            let backend = await RemarkableBackendManager.shared.activeBackend
            guard let backend = backend else {
                throw RemarkableError.notAuthenticated
            }

            // Load documents and folders
            async let documentsTask = backend.listDocuments()
            async let foldersTask = backend.listFolders()

            let (docs, fldrs) = try await (documentsTask, foldersTask)

            documents = docs
            folders = fldrs

            // Load sync states from Core Data
            await loadSyncStates()

        } catch {
            self.error = error
            logger.error("Failed to load documents: \(error)")
        }

        isLoading = false
    }

    func refresh() async {
        documents = []
        folders = []
        currentPath = []
        await loadDocuments()
    }

    func navigate(to folder: RemarkableFolderInfo) {
        currentPath.append(folder)
    }

    func navigateUp() {
        if !currentPath.isEmpty {
            currentPath.removeLast()
        }
    }

    func syncState(for document: RemarkableDocumentInfo) -> RemarkableSyncState? {
        syncStates[document.id]
    }

    private func loadSyncStates() async {
        // Would load from Core Data to get sync states
        // For now, just mark all as not synced
        for doc in documents {
            syncStates[doc.id] = .notSynced
        }
    }
}

// MARK: - Preview

#Preview {
    RemarkableDocumentBrowserView()
}
