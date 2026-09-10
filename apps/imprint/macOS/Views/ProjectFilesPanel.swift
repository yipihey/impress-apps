//
//  ProjectFilesPanel.swift
//  imprint
//
//  The Files inspector (ADR-0030): a manuscript's project tree — every
//  `manuscript-file` row grouped by role, the entry marked, the derived
//  graph's verdict on each file (unreferenced, unresolved, stale) as
//  badges. Click a text file to edit it in its own editor (a session over
//  the file's Automerge document; compiles build the whole tree). Add files
//  from disk; delete or rename with the context menu. Every write goes
//  through `ManuscriptProjectModel`, which goes through the one Rust writer.
//

#if os(macOS)
import AppKit
import ImpressKit
import PublicationManagerCore
import SwiftUI
import UniformTypeIdentifiers

struct ProjectFilesSidePanel: ManuscriptSidePanel {
    let id = "files"
    let label = "Files"
    let systemImage = "folder"

    func makeView(_ context: ManuscriptPanelContext) -> AnyView {
        AnyView(ProjectFilesPanel(manuscriptID: context.manuscriptID, insertAtCursor: context.insertAtCursor))
    }
}

struct ProjectFilesPanel: View {
    let manuscriptID: UUID
    let insertAtCursor: (String) -> Void

    @State private var model: ManuscriptProjectModel
    @State private var editingPath: String?
    @State private var renaming: ManuscriptProjectFile?
    @State private var renameTo = ""
    @State private var addError: String?

    init(manuscriptID: UUID, insertAtCursor: @escaping (String) -> Void) {
        self.manuscriptID = manuscriptID
        self.insertAtCursor = insertAtCursor
        _model = State(initialValue: ManuscriptProjectModel.shared(for: manuscriptID))
    }

    private static let roleOrder: [(role: String, title: String)] = [
        ("main", "Entry"),
        ("chapter", "Chapters"),
        ("supplement", "Supplements"),
        ("bibliography", "Bibliographies"),
        ("figure", "Figures"),
        ("figure-source", "Figure sources"),
        ("data", "Data"),
        ("style", "Styles"),
        ("aux", "Other"),
        ("output", "Outputs"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.files.isEmpty {
                emptyState
            } else {
                list
            }
            if let error = model.lastError ?? addError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(8)
            }
        }
        .sheet(item: Binding(
            get: { editingPath.map(EditingFile.init) },
            set: { editingPath = $0?.path }
        )) { file in
            ManuscriptFileEditorSheet(manuscriptID: manuscriptID, path: file.path)
        }
        .alert("Rename file", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Path", text: $renameTo)
            Button("Rename") {
                if let file = renaming, !renameTo.isEmpty, renameTo != file.path {
                    model.move(from: file.path, to: renameTo)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Project-relative path, e.g. chapters/intro.typ")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isProject ? "\(model.files.count + 1) files" : "One-file manuscript")
                    .font(.headline)
                if model.graph.hasErrors {
                    Text("\(model.graph.diagnostics.filter { $0.severity == "error" }.count) unresolved")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !model.graph.unreferenced.isEmpty {
                    Text("\(model.graph.unreferenced.count) unreferenced")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button("Add files…") { addFiles() }
                Button("Import folder…") { importFolder() }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add files from disk, or import a whole folder, into this manuscript's project")
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Re-read the project")
        }
        .padding(8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("This manuscript is one file: \(model.entryPath).")
                .font(.callout)
            Text("Add chapters, figures, data or a second bibliography and imprint builds them together: `#include \"chapters/intro.typ\"`, `image(\"figures/f.png\")`, `\\input{chapters/intro}`.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Add files…") { addFiles() }
                Button("Import folder…") { importFolder() }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            Section("Entry") {
                HStack {
                    Image(systemName: "doc.text.fill").foregroundStyle(.blue)
                    Text(model.entryPath)
                    Spacer()
                    Text("main")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }
            ForEach(Self.roleOrder.dropFirst(), id: \.role) { group in
                let files = model.files.filter { $0.role == group.role }
                if !files.isEmpty {
                    Section(group.title) {
                        ForEach(files) { file in
                            row(file)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(_ file: ManuscriptProjectFile) -> some View {
        let problems = model.graph.diagnostics(for: file.path)
        let unreferenced = model.graph.unreferenced.contains(file.path)
        let stale = model.graph.staleSources.contains(file.path)
        HStack(spacing: 6) {
            Image(systemName: icon(for: file))
                .foregroundStyle(color(for: file))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1)
                if !file.directory.isEmpty {
                    Text(file.directory).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let first = problems.first(where: { $0.severity == "error" }) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(first.message)
            } else if stale {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
                    .help("Its outputs are older than this source")
            } else if unreferenced {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .help("Nothing in \(model.entryPath) references this file")
            }
            Text(sizeLabel(file.size))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if file.isText { editingPath = file.path }
        }
        .contextMenu {
            if file.isText {
                Button("Edit") { editingPath = file.path }
            }
            Button("Rename…") {
                renaming = file
                renameTo = file.path
            }
            Button("Insert reference at cursor") {
                insertReference(to: file)
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(path: file.path) }
        }
    }

    private func icon(for file: ManuscriptProjectFile) -> String {
        switch file.role {
        case "chapter", "supplement": return "doc.text"
        case "bibliography": return "books.vertical"
        case "figure", "output": return "photo"
        case "figure-source": return "function"
        case "data": return "tablecells"
        case "style": return "gearshape"
        default: return "doc"
        }
    }

    private func color(for file: ManuscriptProjectFile) -> Color {
        switch file.role {
        case "chapter", "supplement": return .blue
        case "bibliography": return .orange
        case "figure", "output": return .green
        case "figure-source": return .purple
        case "data": return .teal
        case "style": return .gray
        default: return .secondary
        }
    }

    private func sizeLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// A reference to `file` in the manuscript's grammar, at the caret.
    private func insertReference(to file: ManuscriptProjectFile) {
        let snippet: String
        switch (model.format, file.role) {
        case ("latex", "chapter"), ("latex", "supplement"):
            snippet = "\\input{\(file.path.replacingOccurrences(of: ".tex", with: ""))}"
        case ("latex", "figure"), ("latex", "output"):
            snippet = "\\includegraphics{\(file.path)}"
        case ("latex", "bibliography"):
            snippet = "\\bibliography{\(file.path.replacingOccurrences(of: ".bib", with: ""))}"
        case ("typst", "chapter"), ("typst", "supplement"):
            snippet = "#include \"\(file.path)\""
        case ("typst", "figure"), ("typst", "output"):
            snippet = "#figure(image(\"\(file.path)\"))"
        case ("typst", "bibliography"):
            snippet = "#bibliography(\"\(file.path)\")"
        case ("typst", "data"):
            snippet = "#let data = csv(\"\(file.path)\")"
        case ("markdown", "figure"), ("markdown", "output"):
            snippet = "![](\(file.path))"
        default:
            snippet = file.path
        }
        insertAtCursor(snippet)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Add files to this manuscript's project"
        guard panel.runModal() == .OK else { return }
        addError = nil
        for url in panel.urls {
            let path = suggestedPath(for: url)
            if model.importFile(at: url, as: path) == nil {
                addError = model.lastError ?? "could not add \(url.lastPathComponent)"
            }
        }
    }

    /// A whole directory into this manuscript (ADR-0030 P3): the plan is
    /// Rust's; a folder in another grammar is refused here and offered as a
    /// new manuscript by File ▸ Import Folder as Manuscript….
    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Import a folder's files into this manuscript"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addError = nil
        if model.importDirectory(at: url) == nil {
            addError = model.lastError ?? "could not import \(url.lastPathComponent)"
        }
    }

    /// Where an added file lands by extension: figures under `figures/`,
    /// data under `data/`, chapters at the root.
    private func suggestedPath(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        switch ext {
        case "png", "jpg", "jpeg", "pdf", "svg", "eps", "gif", "tif", "tiff", "webp":
            return "figures/\(name)"
        case "csv", "tsv", "json", "npz", "npy", "h5", "hdf5", "fits", "parquet", "dat":
            return "data/\(name)"
        case "vsz", "py", "jl", "r", "sh", "plot":
            return "figures/\(name)"
        default:
            return name
        }
    }
}

private struct EditingFile: Identifiable {
    let path: String
    var id: String { path }
}

#endif
