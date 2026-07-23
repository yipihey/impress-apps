#if os(macOS)
// Chassis file — macOS-only.
//
//  PlotInspectorPanel.swift
//  PublicationManagerCore
//
//  A native-plotting inspector panel, shared by imbib AND imprint through the
//  ManuscriptSidePanel seam. It drives `impress-plot` via ImprintCore's FFI:
//  a declarative spec → a Typst-rendered figure, with the two first-reached-for
//  interactive controls wired live — per-axis linear/log and min/max — plus
//  colormap selection for the big-N raster fallback.
//
//  Data source is either a built-in demo set OR a real data file: pick a CSV,
//  choose x/y columns, and plot. Column loading reuses implore-io's reader
//  through ImprintCore's `loadDataTable` FFI (numeric columns → [Double]).
//  Insert writes the figure's Typst source at the cursor (inline-safe vector).

import AppKit
import ImprintCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The seam conformer both apps install.
public struct PlotInspectorPanel: ManuscriptSidePanel {
    public init() {}
    public var id: String { "plot" }
    public var label: String { "Plot" }
    public var systemImage: String { "chart.xyaxis.line" }
    public func makeView(_ context: ManuscriptPanelContext) -> AnyView {
        AnyView(PlotPanelView(context: context))
    }
}

// MARK: - Demo data

private enum DemoDataset: String, CaseIterable, Identifiable {
    case dampedSine = "Damped sine"
    case powerLaw = "Power law x³"
    case twoBlobs = "Two blobs (40k)"

    var id: String { rawValue }

    func series() -> (xs: [Double], ys: [Double], kind: FfiSeriesKind) {
        switch self {
        case .dampedSine:
            let xs = (0..<160).map { Double($0) / 160.0 * 12.0 }
            let ys = xs.map { exp(-0.18 * $0) * sin($0 * 1.6) }
            return (xs, ys, .line)
        case .powerLaw:
            let xs = (1...120).map { Double($0) }
            let ys = xs.map { $0 * $0 * $0 }
            return (xs, ys, .line)
        case .twoBlobs:
            var s: UInt64 = 0x1234_5678
            func nrm() -> Double {
                func g() -> Double {
                    s = s &* 6_364_136_223_846_793_005 &+ 1
                    return Double(s >> 11) / Double(UInt64(1) << 53)
                }
                let u1 = max(g(), 1e-12), u2 = g()
                return (-2.0 * log(u1)).squareRoot() * cos(2.0 * .pi * u2)
            }
            var xs = [Double](), ys = [Double]()
            for i in 0..<40_000 {
                if i % 3 == 0 {
                    xs.append(2.0 + 0.5 * nrm())
                    ys.append(1.6 + 0.5 * nrm())
                } else {
                    xs.append(-1.0 + 1.0 * nrm())
                    ys.append(-0.4 + 0.8 * nrm())
                }
            }
            return (xs, ys, .scatter)
        }
    }
}

private enum SourceMode: String, CaseIterable, Identifiable {
    case demo = "Demo"
    case file = "Data file"
    case saved = "Saved"
    var id: String { rawValue }
}

private enum ContourStyleCycle: String, CaseIterable, Identifiable {
    case solid = "Solid"
    case solidDashed = "Solid / Dashed"
    case solidDashedDotted = "Solid / Dashed / Dotted"
    var id: String { rawValue }
    var ffi: [FfiLineStyle] {
        switch self {
        case .solid: return []
        case .solidDashed: return [.solid, .dashed]
        case .solidDashedDotted: return [.solid, .dashed, .dotted]
        }
    }
}

private enum PlotStyle: String, CaseIterable, Identifiable {
    case scatter = "Scatter"
    case line = "Line"
    case contour = "Contour"
    var id: String { rawValue }
    var kind: FfiSeriesKind {
        switch self {
        case .line: return .line
        case .scatter: return .scatter
        case .contour: return .contour
        }
    }
}

// MARK: - Panel view

private struct PlotPanelView: View {
    let context: ManuscriptPanelContext

    // Source
    @State private var sourceMode: SourceMode = .demo
    @State private var dataset: DemoDataset = .dampedSine

    // Loaded data file
    @State private var dataTable: FfiDataTable?
    @State private var fileName = ""
    @State private var xCol = ""
    @State private var yCol = ""
    @State private var style: PlotStyle = .scatter
    @State private var loadError: String?

    // Axis controls
    @State private var xLog = false
    @State private var yLog = false
    @State private var xMin = ""
    @State private var xMax = ""
    @State private var yMin = ""
    @State private var yMax = ""
    @State private var colormap: FfiColormap = .viridis
    @State private var styleCycle: ContourStyleCycle = .solid

    // Saved specs (store-backed)
    @State private var savedSpecs: [PlotSpecRow] = []
    @State private var selectedSavedID: String = ""
    @State private var loadedSpec: FfiPlotSpec?

    // Render output
    @State private var svg = ""
    @State private var rasterized = false
    @State private var rendering = false
    @State private var renderError: String?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            preview
            Divider()
            ScrollView { controls }
        }
        .background(.background)
        .onChange(of: renderKey) { scheduleRender() }
        .task {
            refreshSavedSpecs()
            scheduleRender()
        }
    }

    private var renderKey: String {
        "\(sourceMode.rawValue)|\(dataset.rawValue)|\(fileName)|\(xCol)|\(yCol)|\(style.rawValue)"
            + "|\(xLog)|\(yLog)|\(xMin)|\(xMax)|\(yMin)|\(yMax)|\(colormap.hashValue)|\(styleCycle.rawValue)|\(selectedSavedID)"
    }

    private var preview: some View {
        ZStack {
            PlotSVGView(svg: svg)
            if rendering {
                ProgressView().controlSize(.small)
            }
            if let err = renderError ?? loadError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(minHeight: 200)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var controls: some View {
        Form {
            Picker("Source", selection: $sourceMode) {
                ForEach(SourceMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch sourceMode {
            case .demo:
                Picker("Data", selection: $dataset) {
                    ForEach(DemoDataset.allCases) { Text($0.rawValue).tag($0) }
                }
            case .file:
                fileControls
            case .saved:
                savedControls
            }

            LabeledContent("X axis") {
                HStack(spacing: 6) {
                    Toggle("log", isOn: $xLog).toggleStyle(.button).controlSize(.small)
                    TextField("min", text: $xMin).frame(width: 52)
                    TextField("max", text: $xMax).frame(width: 52)
                }
            }
            LabeledContent("Y axis") {
                HStack(spacing: 6) {
                    Toggle("log", isOn: $yLog).toggleStyle(.button).controlSize(.small)
                    TextField("min", text: $yMin).frame(width: 52)
                    TextField("max", text: $yMax).frame(width: 52)
                }
            }
            if rasterized {
                Picker("Colormap", selection: $colormap) {
                    Text("Viridis").tag(FfiColormap.viridis)
                    Text("Magma").tag(FfiColormap.magma)
                    Text("Plasma").tag(FfiColormap.plasma)
                    Text("Inferno").tag(FfiColormap.inferno)
                    Text("Cividis").tag(FfiColormap.cividis)
                    Text("Turbo").tag(FfiColormap.turbo)
                    Text("Greys").tag(FfiColormap.greys)
                }
            }
            HStack {
                if rasterized {
                    Label("raster (big-N)", systemImage: "square.grid.3x3.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if sourceMode != .saved {
                    Button("Save spec") { saveCurrentSpec() }
                        .disabled(spec(width: 340, height: 220) == nil)
                }
                Button("Insert into manuscript") { insert() }
                    .disabled(spec(width: 340, height: 220) == nil)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private var savedControls: some View {
        if savedSpecs.isEmpty {
            Text("No saved plots yet — use \"Save spec\" on any plot.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Plot", selection: $selectedSavedID) {
                ForEach(savedSpecs, id: \.id) { row in
                    Text(row.specKind == "grid" ? "\(row.name) (grid)" : row.name).tag(row.id)
                }
            }
            .onChange(of: selectedSavedID) { loadSelectedSpec() }
        }
    }

    private func refreshSavedSpecs() {
        savedSpecs = RustStoreAdapter.shared.listPlotSpecs()
        if selectedSavedID.isEmpty, let first = savedSpecs.first {
            selectedSavedID = first.id
            loadSelectedSpec()
        }
    }

    private func loadSelectedSpec() {
        loadedSpec = nil
        guard let row = savedSpecs.first(where: { $0.id == selectedSavedID }),
            row.specKind == "series",
            let data = row.specJson.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            renderError = "Grid specs render via HTTP/MCP; panel loads series specs."
            return
        }
        renderError = nil
        loadedSpec = PlotAutomationHandler.decodeSpec(json)
    }

    private func saveCurrentSpec() {
        guard let s = spec(width: 340, height: 220) else { return }
        let name: String
        switch sourceMode {
        case .demo: name = dataset.rawValue
        case .file: name = "\(fileName): \(yCol) vs \(xCol)"
        case .saved: return  // already saved
        }
        // Serialize the spec into the HTTP-API JSON shape (the store's format).
        var json: [String: Any] = [
            "title": s.title,
            "x": axisJSON(s.x), "y": axisJSON(s.y),
            "series": s.series.map { ser -> [String: Any] in
                [
                    "kind": ser.kind == .line ? "line" : (ser.kind == .contour ? "contour" : "scatter"),
                    "xs": ser.xs, "ys": ser.ys,
                    "color": ["r": Int(ser.color.r), "g": Int(ser.color.g), "b": Int(ser.color.b)],
                ]
            },
            "colormap": colormapName(s.colormap),
            "width": s.width, "height": s.height,
            "contourLabels": s.contourLabels,
        ]
        if s.contourLevels > 0 { json["contourLevels"] = Int(s.contourLevels) }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
            let str = String(data: data, encoding: .utf8)
        else { return }
        let source = sourceMode == .file ? fileName : nil
        RustStoreAdapter.shared.savePlotSpec(
            name: name, specKind: "series", specJSON: str, dataSource: source)
        refreshSavedSpecs()
    }

    private func axisJSON(_ a: FfiAxis) -> [String: Any] {
        var j: [String: Any] = ["scale": a.scale == .log ? "log" : "linear"]
        if let v = a.min { j["min"] = v }
        if let v = a.max { j["max"] = v }
        if let l = a.label { j["label"] = l }
        return j
    }

    private func colormapName(_ c: FfiColormap) -> String {
        switch c {
        case .viridis: return "viridis"
        case .magma: return "magma"
        case .plasma: return "plasma"
        case .inferno: return "inferno"
        case .cividis: return "cividis"
        case .turbo: return "turbo"
        case .greys: return "greys"
        }
    }

    @ViewBuilder
    private var fileControls: some View {
        LabeledContent("File") {
            HStack {
                Text(fileName.isEmpty ? "None" : fileName)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(fileName.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Load data…") { pickFile() }
            }
        }
        if let table = dataTable, !table.columns.isEmpty {
            let names = table.columns.map(\.name)
            Picker("X column", selection: $xCol) {
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            Picker("Y column", selection: $yCol) {
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            Picker("Style", selection: $style) {
                ForEach(PlotStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if style == .contour {
                Picker("Line cycle", selection: $styleCycle) {
                    ForEach(ContourStyleCycle.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Text("\(table.columns.count) numeric columns · \(table.rowCount) rows")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Data + spec

    /// The x/y arrays + series kind for the current source, or nil if unset.
    private func currentSeries() -> (xs: [Double], ys: [Double], kind: FfiSeriesKind)? {
        switch sourceMode {
        case .demo:
            return dataset.series()
        case .saved:
            return nil  // saved mode renders loadedSpec directly
        case .file:
            guard let t = dataTable,
                let xc = t.columns.first(where: { $0.name == xCol }),
                let yc = t.columns.first(where: { $0.name == yCol })
            else { return nil }
            let n = min(xc.values.count, yc.values.count)
            guard n > 0 else { return nil }
            return (Array(xc.values.prefix(n)), Array(yc.values.prefix(n)), style.kind)
        }
    }

    private func spec(width: Double, height: Double) -> FfiPlotSpec? {
        if sourceMode == .saved {
            guard var s = loadedSpec else { return nil }
            s.width = width
            s.height = height
            return s
        }
        guard let d = currentSeries() else { return nil }
        let (xLabel, yLabel): (String, String) = {
            switch sourceMode {
            case .demo, .saved: return ("x", "y")
            case .file: return (xCol, yCol)
            }
        }()
        return FfiPlotSpec(
            title: sourceMode == .file ? fileName : dataset.rawValue,
            x: FfiAxis(scale: xLog ? .log : .linear, min: Double(xMin), max: Double(xMax), label: xLabel),
            y: FfiAxis(scale: yLog ? .log : .linear, min: Double(yMin), max: Double(yMax), label: yLabel),
            series: [FfiSeries(kind: d.kind, xs: d.xs, ys: d.ys, color: FfiColor(r: 31, g: 111, b: 214))],
            strategy: .auto,
            colormap: colormap,
            width: width,
            height: height,
            rasterThreshold: 0,
            contourLevels: 0,
            contourLabels: true,
            contourLineStyles: (sourceMode == .file && style == .contour) ? styleCycle.ffi : [],
            contourLevelValues: []
        )
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let s = spec(width: 360, height: 240) else {
            svg = ""
            return
        }
        renderTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if Task.isCancelled { return }
            rendering = true
            let result = await PlotRenderQueue.shared.render(s)
            if Task.isCancelled { return }
            rendering = false
            rasterized = result.rasterized
            if let e = result.error, !e.isEmpty {
                renderError = e
            } else {
                renderError = nil
                svg = result.svg
            }
        }
    }

    private func insert() {
        guard let s = spec(width: 340, height: 220) else { return }
        let src = renderPlotTypst(spec: s)
        if src.inlineSafe {
            // Vector: the plot IS Typst source — insert inline, no file.
            context.insertAtCursor("\n" + src.typst + "\n")
            return
        }
        // Raster (big-N): persist the heatmap PNG into the manuscript's
        // app-group figures/ dir (Rust does render+write+snippet) and insert
        // the returned figure snippet; the compile resolves it via figuresRoot.
        let manuscriptID = context.manuscriptID
        let name = s.title.isEmpty ? "plot" : s.title
        let insertAtCursor = context.insertAtCursor
        Task { @MainActor in
            let dir = ManuscriptFiguresDirectory.manuscriptRoot(for: manuscriptID).path
            let saved = await PlotRenderQueue.shared.saveFigure(s, manuscriptDir: dir, name: name)
            if let e = saved.error, !e.isEmpty {
                renderError = e
            } else {
                renderError = nil
                insertAtCursor("\n" + saved.typstSnippet + "\n")
            }
        }
    }

    // MARK: File loading

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // CSV/TSV/plain text + numpy .npz + Parquet (no standard UTIs → from ext).
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
            + ["npz", "parquet", "pq"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Load"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        loadError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        let path = url.path
        let name = url.lastPathComponent
        Task { @MainActor in
            let table = await PlotRenderQueue.shared.loadTable(path)
            if scoped { url.stopAccessingSecurityScopedResource() }
            fileName = name
            dataTable = table
            if let e = table.error, !e.isEmpty {
                loadError = e
                xCol = ""
                yCol = ""
            } else {
                loadError = nil
                let names = table.columns.map(\.name)
                xCol = names.first ?? ""
                yCol = names.count > 1 ? names[1] : (names.first ?? "")
            }
        }
    }
}

/// Serializes FFI calls (render + load) onto one background queue so the Rust
/// thread-local plot renderer stays warm between renders.
private actor PlotRenderQueue {
    static let shared = PlotRenderQueue()
    private let queue = DispatchQueue(label: "com.impress.plot-render", qos: .userInitiated)

    func render(_ spec: FfiPlotSpec) async -> FfiRenderedPlot {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: renderPlotSvg(spec: spec)) }
        }
    }

    func loadTable(_ path: String) async -> FfiDataTable {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: loadDataTable(path: path)) }
        }
    }

    func saveFigure(_ spec: FfiPlotSpec, manuscriptDir: String, name: String) async -> FfiSavedFigure {
        await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: savePlotFigure(spec: spec, manuscriptDir: manuscriptDir, name: name))
            }
        }
    }
}

// MARK: - SVG preview (WKWebView)

private struct PlotSVGView: NSViewRepresentable {
    let svg: String

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground")
        web.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:transparent}
        .wrap{height:100%;display:flex;align-items:center;justify-content:center;padding:6px;box-sizing:border-box}
        svg{max-width:100%;max-height:100%;height:auto;width:auto}</style></head>
        <body><div class="wrap">\(svg)</div></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }
}
#endif
