//
//  ProjectBrowserView.swift
//  imprint
//
//  Project browser window with folder tree sidebar and document list.
//  Documents open in their own windows via DocumentGroup.
//

#if os(macOS)
import SwiftUI
import AppKit

struct ProjectBrowserView: View {
    @State private var viewModel = ProjectSidebarViewModel()
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            ProjectSidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } detail: {
            documentListView
        }
        .navigationTitle(viewModel.selectedFolder?.name ?? "imprint")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    createNewDocument()
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .help("New Document")
            }
        }
        .searchable(text: $searchText, prompt: "Search documents...")
    }

    // MARK: - Document List

    @ViewBuilder
    private var documentListView: some View {
        if let folder = viewModel.selectedFolder {
            let refs = filteredDocRefs(in: folder)

            if refs.isEmpty {
                emptyFolderView(folder: folder)
            } else {
                List {
                    ForEach(refs, id: \.id) { ref in
                        DocumentRefRow(ref: ref, onOpen: {
                            openDocument(ref)
                        })
                        .contextMenu {
                            Button("Open") { openDocument(ref) }
                            Divider()
                            Button("Remove from Folder", role: .destructive) {
                                viewModel.removeDocumentReference(ref)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        } else {
            emptySelectionView
        }
    }

    @ViewBuilder
    private var emptySelectionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("Select a folder")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Choose a folder from the sidebar to see its documents.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func emptyFolderView(folder: CDFolder) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("No documents in \"\(folder.name)\"")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Create a new document or drag .imprint files here.")
                .font(.callout)
                .foregroundStyle(.tertiary)

            HStack(spacing: 16) {
                Button("New Document") {
                    createNewDocument()
                }
                .buttonStyle(.borderedProminent)

                Button("Add Existing...") {
                    addExistingDocument(to: folder)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers: providers, onto: folder)
        }
    }

    // MARK: - Actions

    private func createNewDocument() {
        NSDocumentController.shared.newDocument(nil)
    }

    private func openDocument(_ ref: CDDocumentReference) {
        guard let bookmark = ref.fileBookmark else {
            // No bookmark - try to open via document UUID or alert
            NSDocumentController.shared.newDocument(nil)
            return
        }

        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                // Refresh bookmark
                if let newBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    ref.fileBookmark = newBookmark
                    try? ref.managedObjectContext?.save()
                }
            }

            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error = error {
                    NSLog("[ProjectBrowser] Failed to open document: %@", error.localizedDescription)
                }
            }
        } catch {
            NSLog("[ProjectBrowser] Failed to resolve bookmark: %@", error.localizedDescription)
        }
    }

    private func addExistingDocument(to folder: CDFolder) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "imprint")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                viewModel.addDocumentToFolder(url: url, folder: folder)
            }
        }
    }

    private func filteredDocRefs(in folder: CDFolder) -> [CDDocumentReference] {
        let refs = viewModel.selectedFolderDocRefs
        guard !searchText.isEmpty else { return refs }
        return refs.filter { ref in
            ref.displayTitle.localizedCaseInsensitiveContains(searchText) ||
            (ref.cachedAuthors ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private func handleFileDrop(providers: [NSItemProvider], onto folder: CDFolder) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let urlData = data as? Data,
                      let url = URL(dataRepresentation: urlData, relativeTo: nil),
                      url.pathExtension == "imprint" else { return }
                Task { @MainActor in
                    viewModel.addDocumentToFolder(url: url, folder: folder)
                }
            }
            handled = true
        }
        return handled
    }
}

// MARK: - Document Reference Row

private struct DocumentRefRow: View {
    let ref: CDDocumentReference
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(ref.displayTitle)
                        .font(.body)
                        .lineLimit(1)

                    if let authors = ref.cachedAuthors, !authors.isEmpty {
                        Text(authors)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(ref.dateAdded, style: .date)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ProjectBrowserView()
        .frame(width: 700, height: 500)
}
#endif
