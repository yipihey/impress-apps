//
//  ManuscriptPlotsPanel.swift
//  PublicationManagerCore
//
//  ONE Plots inspector for every kind of figure a manuscript mixes
//  (ADR-0030 D13): Veusz documents, lilaq figures lilook edits, plain Typst
//  figures, implore and native plot specs, scripts — each a `figure-source`
//  row rendered by the runner its kind implies. The panel lists them with
//  their kind and staleness, previews the selected one through the Rust
//  engine, creates new ones from templates, renders (recording outputs as
//  rows), edits — a text session, the native-spec inspector, or the
//  external application the host installs (Veusz, lilook) over a working
//  copy that is checked back in on every save — and places a figure at the
//  caret in the manuscript's own grammar. Shared by imbib and imprint.
//

#if os(macOS)
import AppKit
import ImprintCore
import ImpressKit
import SwiftUI
import WebKit

/// The seam conformer both apps install.
public struct ManuscriptPlotsPanel: ManuscriptSidePanel {
    public init() {}
    public var id: String { "plots" }
    public var label: String { "Plots" }
    public var systemImage: String { "chart.xyaxis.line" }
    public func makeView(_ context: ManuscriptPanelContext) -> AnyView {
        AnyView(PlotsPanelView(context: context))
    }
}

/// A figure kind as the panel shows it.
struct FigureKindInfo {
    let id: String
    let label: String
    let symbol: String
    let externalEditor: String?

    static let all: [FigureKindInfo] = [
        FigureKindInfo(id: "lilaq", label: "lilaq figure (lilook)", symbol: "chart.line.uptrend.xyaxis", externalEditor: "lilook"),
        FigureKindInfo(id: "veusz", label: "Veusz document", symbol: "chart.bar.doc.horizontal", externalEditor: "Veusz"),
        FigureKindInfo(id: "impress-plot", label: "Native plot spec", symbol: "slider.horizontal.3", externalEditor: nil),
        FigureKindInfo(id: "implore", label: "implore plot spec", symbol: "chart.dots.scatter", externalEditor: nil),
        FigureKindInfo(id: "typst", label: "Typst figure", symbol: "function", externalEditor: nil),
        FigureKindInfo(id: "script", label: "Script (Python…)", symbol: "terminal", externalEditor: nil),
    ]

    static func info(for id: String?) -> FigureKindInfo {
        all.first { $0.id == id } ?? FigureKindInfo(id: id ?? "figure", label: id ?? "figure", symbol: "photo", externalEditor: nil)
    }
}

private struct PlotsPanelView: View {
    let context: ManuscriptPanelContext

    @State private var model: ManuscriptProjectModel
    @State private var selectedPath: String?
    @State private var preview: TreeFigureRender?
    @State private var previewTask: Task<Void, Never>?
    @State private var showNewSheet = false
    @State private var newKind = "lilaq"
    @State private var newName = ""
    @State private var editingTextPath: String?
    @State private var editingSpecPath: String?
    @State private var allowShell = false
    @State private var log = ""

    init(context: ManuscriptPanelContext) {
        self.context = context
        _model = State(initialValue: ManuscriptProjectModel.shared(for: context.manuscriptID))
    }

    private var selected: ManuscriptProjectFile? {
        selectedPath.flatMap { p in model.figures.first { $0.path == p } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.figures.isEmpty {
                emptyState
            } else {
                HSplitView {
                    figureList
                        .frame(minWidth: 180, idealWidth: 220)
                    detail
                        .frame(minWidth: 240)
                }
            }
            if let error = model.lastError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(8)
            }
        }
        .onAppear {
            if selectedPath == nil { selectedPath = model.figures.first?.path }
            schedulePreview()
        }
        .onChange(of: selectedPath) { schedulePreview() }
        .onChange(of: model.files.map(\.contentHash).joined()) { schedulePreview() }
        .sheet(isPresented: $showNewSheet) { newFigureSheet }
        .sheet(item: Binding(get: { editingTextPath.map(PathItem.init) }, set: { editingTextPath = $0?.path })) { item in
            ManuscriptFileEditorSheet(manuscriptID: context.manuscriptID, path: item.path)
        }
        .sheet(item: Binding(get: { editingSpecPath.map(PathItem.init) }, set: { editingSpecPath = $0?.path })) { item in
            NativePlotSpecEditorSheet(
                context: context,
                path: item.path,
                specJSON: model.files.first { $0.path == item.path }?.content ?? "",
                onSave: { json in
                    model.updateFigureSource(path: item.path, text: json)
                })
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.figures.isEmpty ? "No figures yet" : "\(model.figures.count) figure(s)")
                    .font(.headline)
                let stale = model.figures.filter { model.graph.staleSources.contains($0.path) }.count
                if stale > 0 {
                    Text("\(stale) to render").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if model.figures.contains(where: { model.graph.staleSources.contains($0.path) }) {
                Button {
                    Task { await renderAllStale() }
                } label: {
                    Label("Render all", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Render every figure whose outputs are older than its source")
            }
            Menu {
                ForEach(FigureKindInfo.all, id: \.id) { kind in
                    Button {
                        newKind = kind.id
                        newName = defaultName(for: kind.id)
                        showNewSheet = true
                    } label: {
                        Label(kind.label, systemImage: kind.symbol)
                    }
                }
            } label: {
                Label("New", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("A new figure: Veusz, lilaq (edit in lilook), a plot spec, a Typst figure, or a script")
        }
        .padding(8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.secondary)
            Text("Figures live in the project: a Veusz document, a lilaq figure, a plot spec or a script, each rendered into the image the text places.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New figure…") {
                newKind = "lilaq"
                newName = defaultName(for: newKind)
                showNewSheet = true
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var figureList: some View {
        List(selection: $selectedPath) {
            ForEach(model.figures) { figure in
                let kind = FigureKindInfo.info(for: model.figureKind(of: figure))
                let stale = model.graph.staleSources.contains(figure.path)
                let problems = model.graph.diagnostics(for: figure.path).filter { $0.severity == "error" }
                HStack(spacing: 6) {
                    Image(systemName: kind.symbol).foregroundStyle(.purple).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(figure.name).lineLimit(1)
                        Text(kind.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let first = problems.first {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).help(first.message)
                    } else if stale {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange).help("Outputs are older than the source")
                    } else if !model.outputs(of: figure).isEmpty {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green).help("Rendered")
                    }
                }
                .tag(figure.path)
                .contextMenu { figureMenu(figure) }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func figureMenu(_ figure: ManuscriptProjectFile) -> some View {
        Button("Render") { Task { await render(figure, force: true) } }
        Button("Insert at cursor") { insert(figure) }
        Divider()
        editButtons(figure)
        Divider()
        Button("Delete", role: .destructive) {
            model.endExternalEdit(path: figure.path)
            model.delete(path: figure.path)
            if selectedPath == figure.path { selectedPath = model.figures.first?.path }
        }
    }

    @ViewBuilder
    private func editButtons(_ figure: ManuscriptProjectFile) -> some View {
        let kindID = model.figureKind(of: figure)
        let kind = FigureKindInfo.info(for: kindID)
        if kindID == "impress-plot" {
            Button("Edit in the inspector…") { editingSpecPath = figure.path }
        }
        if figure.isText {
            Button("Edit source…") { editingTextPath = figure.path }
        }
        if let app = kind.externalEditor, ManuscriptEditorEnvironment.shared.figureEditorAvailable(kindID ?? "") {
            Button("Edit in \(app)…") { openExternally(figure, kind: kindID ?? "") }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let figure = selected {
            VStack(spacing: 0) {
                previewPane(figure)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        actionRow(figure)
                        outputsRow(figure)
                        if let preview, !preview.isSuccess {
                            Label(preview.message, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                        }
                        if !log.isEmpty {
                            DisclosureGroup("Log") {
                                Text(log).font(.caption2.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text("Select a figure").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewPane(_ figure: ManuscriptProjectFile) -> some View {
        ZStack {
            if let svg = preview?.svg {
                FigureSVGView(svg: svg)
            } else if let output = model.outputs(of: figure).first(where: { $0.path.hasSuffix(".svg") }),
                      let data = model.bytes(of: output.path), let svg = String(data: data, encoding: .utf8) {
                FigureSVGView(svg: svg)
            } else {
                Text(preview == nil ? "Rendering…" : "No preview")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.renderingFigure == figure.path {
                ProgressView().controlSize(.small)
            }
        }
        .frame(minHeight: 180)
        .frame(maxWidth: .infinity)
    }

    private func actionRow(_ figure: ManuscriptProjectFile) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await render(figure, force: true) }
            } label: {
                Label("Render", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.renderingFigure != nil)
            .help("Render this figure and record its outputs as project files")
            Button {
                insert(figure)
            } label: {
                Label("Insert", systemImage: "text.insert")
            }
            .help("Place the figure at the caret in this manuscript's grammar")
            Menu {
                editButtons(figure)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            if model.figureKind(of: figure) == "script" {
                Toggle("allow shell", isOn: $allowShell).toggleStyle(.checkbox).font(.caption)
                    .help("Scripts run only when allowed")
            }
        }
    }

    @ViewBuilder
    private func outputsRow(_ figure: ManuscriptProjectFile) -> some View {
        let outputs = model.outputs(of: figure)
        if outputs.isEmpty {
            Text("Not rendered yet — Render writes \(declaredOutputs(figure).joined(separator: ", ")).")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Outputs").font(.caption).foregroundStyle(.secondary)
                ForEach(outputs) { out in
                    HStack {
                        Text(out.path).font(.caption2.monospaced())
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(out.size), countStyle: .file))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func declaredOutputs(_ figure: ManuscriptProjectFile) -> [String] {
        guard let json = figure.buildJSON, let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return (raw["outputs"] as? [String]) ?? []
    }

    // MARK: - New figure

    private var newFigureSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New figure").font(.headline)
            Picker("Kind", selection: $newKind) {
                ForEach(FigureKindInfo.all, id: \.id) { Text($0.label).tag($0.id) }
            }
            TextField("Path (project-relative)", text: $newName)
                .textFieldStyle(.roundedBorder)
            Text("A starter of that kind is created as a project file with the build spec that renders it to an SVG beside it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showNewSheet = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    if let row = model.newFigure(kind: newKind, path: newName) {
                        selectedPath = row.path
                        showNewSheet = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .impressResizableSheet(minWidth: 420, minHeight: 200)
    }

    private func defaultName(for kind: String) -> String {
        let base = "figures/\(kind == "impress-plot" ? "plot" : kind)"
        var n = 1
        var candidate = "\(base)-\(n)"
        while model.figures.contains(where: { $0.path.hasPrefix(candidate + ".") || $0.path == candidate }) {
            n += 1
            candidate = "\(base)-\(n)"
        }
        return candidate
    }

    // MARK: - Actions

    private func schedulePreview() {
        previewTask?.cancel()
        guard let figure = selected else {
            preview = nil
            return
        }
        let path = figure.path
        let shell = allowShell
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let r = await model.renderFigure(path: path, force: true, allowShell: shell, record: false)
            if Task.isCancelled { return }
            preview = r
            if let r, !r.log.isEmpty { log = r.log }
        }
    }

    private func render(_ figure: ManuscriptProjectFile, force: Bool) async {
        let r = await model.renderFigure(path: figure.path, force: force, allowShell: allowShell, record: true)
        preview = r
        if let r { log = r.log }
    }

    private func renderAllStale() async {
        for figure in model.figures where model.graph.staleSources.contains(figure.path) {
            _ = await model.renderFigure(path: figure.path, force: false, allowShell: allowShell, record: true)
        }
        schedulePreview()
    }

    private func insert(_ figure: ManuscriptProjectFile) {
        guard let snippet = model.placementSnippet(for: figure) else {
            model.lastErrorHint("\(figure.name) has no output to place; render it first")
            return
        }
        context.insertAtCursor(snippet)
    }

    private func openExternally(_ figure: ManuscriptProjectFile, kind: String) {
        guard let url = model.beginExternalEdit(path: figure.path) else { return }
        if !ManuscriptEditorEnvironment.shared.openFigureExternally(url, kind) {
            model.lastErrorHint("could not open \(figure.name) in \(FigureKindInfo.info(for: kind).externalEditor ?? "the editor")")
        }
    }
}

private struct PathItem: Identifiable {
    let path: String
    var id: String { path }
}

/// An SVG string rendered in a web view (scales to the pane).
struct FigureSVGView: NSViewRepresentable {
    let svg: String

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let html = """
        <html><head><meta charset="utf-8"><style>
        html,body{margin:0;height:100%;background:transparent;display:flex;align-items:center;justify-content:center}
        svg{max-width:100%;max-height:100%;height:auto}
        </style></head><body>\(svg)</body></html>
        """
        if context.coordinator.last != html {
            context.coordinator.last = html
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last = "" }
}
#endif
