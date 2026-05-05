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
import UniformTypeIdentifiers
import ImpressLogging
import OSLog

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
        let title = ref.displayTitle
        Logger.documents.infoCapture("Open requested for '\(title)' (id=\(ref.id.uuidString))", category: "documents")

        guard let bookmark = ref.fileBookmark else {
            Logger.documents.warningCapture(
                "Open '\(title)' failed: no fileBookmark stored on ref — creating a blank new document instead",
                category: "documents"
            )
            NSDocumentController.shared.newDocument(nil)
            return
        }

        let url: URL
        do {
            var isStale = false
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                Logger.documents.warningCapture(
                    "Bookmark stale for '\(title)' — refreshing",
                    category: "documents"
                )
                if let newBookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    ref.fileBookmark = newBookmark
                    try? ref.managedObjectContext?.save()
                }
            }
        } catch {
            Logger.documents.errorCapture(
                "Open '\(title)' failed to resolve bookmark: \(error.localizedDescription)",
                category: "documents"
            )
            return
        }

        Logger.documents.infoCapture(
            "Open '\(title)' resolved to \(url.path)",
            category: "documents"
        )

        // Security-scoped access must span the async openDocument call.
        // Using `defer` at the outer function scope would release the scope
        // before the completion handler runs, which makes NSDocument fail
        // with "you don't have permission". Release inside the completion.
        guard url.startAccessingSecurityScopedResource() else {
            Logger.documents.errorCapture(
                "Open '\(title)' failed: startAccessingSecurityScopedResource returned false for \(url.path)",
                category: "documents"
            )
            return
        }

        // Route every supported extension through NSDocumentController so
        // the file opens in an imprint editor window. imprint's
        // `ImprintDocument.readableContentTypes` claims `.imprintDocument`,
        // `.latexSource` (.tex), and `.plainText` — so .tex / .ltx / .md /
        // etc. all resolve to our NSDocument subclass, not the user's
        // default external editor.
        let ext = url.pathExtension.lowercased()
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
            defer { url.stopAccessingSecurityScopedResource() }
            if let error {
                Logger.documents.errorCapture(
                    "NSDocumentController.openDocument failed for '\(title)' (ext=\(ext)): \(error.localizedDescription)",
                    category: "documents"
                )
            } else {
                Logger.documents.infoCapture(
                    "Opened '\(title)' in imprint (ext=\(ext), windows=\(doc?.windowControllers.count ?? 0))",
                    category: "documents"
                )
            }
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
        // Button handles clicks. `.draggable(Transferable)` is applied to
        // the HStack INSIDE the Button's label — this way the button gets
        // mouse-up-without-movement (click), and the inner `.draggable`
        // handles the drag gesture. Crucially, `Transferable` via
        // `DataRepresentation` writes data EAGERLY to the pasteboard
        // (unlike `.onDrag { NSItemProvider }` which is lazy and can leave
        // drop consumers unable to read the payload).
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
            .draggable(DocRefDragItem(id: ref.id)) {
                // Pin into the drag session from the preview's .onAppear as a
                // backup — this still fires, but too late for fast drops.
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(ref.displayTitle).font(.body).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .onAppear {
                    DocRefDragSession.shared.begin(refID: ref.id)
                }
            }
        }
        .buttonStyle(.plain)
        // Prime the drag session on FIRST pointer movement, which happens
        // before SwiftUI renders the .draggable preview. Without this, fast
        // drops can complete before the preview's .onAppear fires, and the
        // session stays empty. `minimumDistance: 2` keeps pure clicks out of
        // this path. Button's click handler still wins for non-drag taps.
        .simultaneousGesture(
            DragGesture(minimumDistance: 2).onChanged { _ in
                if DocRefDragSession.shared.activeRefID != ref.id {
                    DocRefDragSession.shared.begin(refID: ref.id)
                    Logger.documents.infoCapture(
                        "Drag started for '\(ref.displayTitle)' (id=\(ref.id.uuidString))",
                        category: "drag"
                    )
                }
            }
        )
    }
}

// MARK: - Preview

#Preview {
    ProjectBrowserView()
        .frame(width: 700, height: 500)
}
#endif
