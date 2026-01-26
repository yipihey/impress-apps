import SwiftUI
import ImploreCore

/// Library section showing saved figures and folders
struct FigureLibrarySection: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @State private var showingNewFolderSheet = false
    @State private var newFolderName = ""

    var body: some View {
        List(selection: $libraryManager.selectedFigureId) {
            // Search field
            Section {
                TextField("Search figures...", text: $libraryManager.searchQuery)
                    .textFieldStyle(.roundedBorder)
            }

            // Folders
            Section("Folders") {
                ForEach(libraryManager.library.folders, id: \.id) { folder in
                    FolderRow(folder: folder)
                }

                Button(action: { showingNewFolderSheet = true }) {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Unfiled figures
            Section("Unfiled") {
                ForEach(libraryManager.unfiledFigures, id: \.id) { figure in
                    FigureRow(figure: figure)
                }

                if libraryManager.unfiledFigures.isEmpty {
                    Text("No figures")
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }

            // Linked documents
            if !libraryManager.library.figures.flatMap(\.imprintLinks).isEmpty {
                Section("Linked Documents") {
                    ForEach(linkedDocuments, id: \.id) { doc in
                        LinkedDocumentRow(
                            documentId: doc.id,
                            documentTitle: doc.title,
                            figureCount: doc.figureCount
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $showingNewFolderSheet) {
            NewFolderSheet(folderName: $newFolderName) {
                if !newFolderName.isEmpty {
                    _ = libraryManager.createFolder(name: newFolderName)
                    newFolderName = ""
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: { showingNewFolderSheet = true }) {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .accessibilityIdentifier("sidebar.librarySection")
    }

    private var linkedDocuments: [LinkedDocument] {
        var docs: [String: LinkedDocument] = [:]

        for figure in libraryManager.library.figures {
            for link in figure.imprintLinks {
                if var existing = docs[link.documentId] {
                    existing.figureCount += 1
                    docs[link.documentId] = existing
                } else {
                    docs[link.documentId] = LinkedDocument(
                        id: link.documentId,
                        title: link.documentTitle,
                        figureCount: 1
                    )
                }
            }
        }

        return Array(docs.values).sorted { $0.title < $1.title }
    }
}

/// Row for a folder with disclosure and figures
struct FolderRow: View {
    let folder: FigureFolder
    @EnvironmentObject var libraryManager: LibraryManager

    var body: some View {
        DisclosureGroup(isExpanded: .init(
            get: { !folder.collapsed },
            set: { _ in libraryManager.toggleFolderCollapsed(id: folder.id) }
        )) {
            ForEach(libraryManager.figures(inFolder: folder.id), id: \.id) { figure in
                FigureRow(figure: figure)
            }

            if libraryManager.figures(inFolder: folder.id).isEmpty {
                Text("Empty folder")
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        } label: {
            Label(folder.name, systemImage: "folder")
        }
        .contextMenu {
            Button("Rename...", action: {})
            Divider()
            Button("Delete", role: .destructive) {
                libraryManager.removeFolder(id: folder.id)
            }
        }
    }
}

/// Row for a single figure
struct FigureRow: View {
    let figure: LibraryFigure
    @EnvironmentObject var libraryManager: LibraryManager

    var body: some View {
        HStack(spacing: 8) {
            // Thumbnail
            if let thumbnailData = figure.thumbnail, let nsImage = NSImage(data: Data(thumbnailData)) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(figure.title)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if !figure.imprintLinks.isEmpty {
                        Image(systemName: "link")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }

                    if figure.imprintLinks.contains(where: { $0.autoUpdate }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }

                    if !figure.tags.isEmpty {
                        Text(figure.tags.first ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .tag(figure.id)
        .contextMenu {
            Button("Open", action: {})
            Button("Duplicate", action: {})
            Divider()

            Menu("Move to Folder") {
                Button("Unfiled") {
                    libraryManager.moveFigure(id: figure.id, toFolder: nil)
                }
                Divider()
                ForEach(libraryManager.library.folders, id: \.id) { folder in
                    Button(folder.name) {
                        libraryManager.moveFigure(id: figure.id, toFolder: folder.id)
                    }
                }
            }

            Divider()
            Button("Delete", role: .destructive) {
                libraryManager.removeFigure(id: figure.id)
            }
        }
        .accessibilityIdentifier("sidebar.figureRow.\(figure.id)")
    }
}

/// Row for a linked imprint document
struct LinkedDocumentRow: View {
    let documentId: String
    let documentTitle: String
    let figureCount: Int

    var body: some View {
        HStack {
            Image(systemName: "doc.text")
                .foregroundStyle(.blue)

            Text(documentTitle)
                .lineLimit(1)

            Spacer()

            Text("\(figureCount)")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }
}

/// Linked document summary
struct LinkedDocument: Identifiable {
    let id: String
    let title: String
    var figureCount: Int
}

/// Sheet for creating a new folder
struct NewFolderSheet: View {
    @Environment(\.dismiss) var dismiss
    @Binding var folderName: String
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Folder")
                .font(.headline)

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Create") {
                    onCreate()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(folderName.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

#Preview {
    FigureLibrarySection()
        .environmentObject(LibraryManager.shared)
        .frame(width: 280, height: 500)
}
