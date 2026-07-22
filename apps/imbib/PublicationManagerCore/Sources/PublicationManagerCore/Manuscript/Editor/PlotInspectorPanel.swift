#if os(macOS)
// Chassis file — macOS-only.
//
//  PlotInspectorPanel.swift
//  PublicationManagerCore
//
//  A native-plotting inspector panel, shared by imbib AND imprint through the
//  ManuscriptSidePanel seam. It drives `impress-plot` via ImprintCore's FFI
//  (`renderPlotSvg`): a declarative spec → a Typst-rendered figure, with the two
//  first-reached-for interactive controls wired live — per-axis linear/log and
//  min/max — plus colormap selection for the big-N raster fallback.
//
//  Data is a small built-in demo set for now (the panel proves the pipeline +
//  interactivity end-to-end in the GUI); binding to real datasets and inserting
//  the figure into the manuscript are the next steps (Insert already works for
//  inline-safe vector plots).

import AppKit
import ImprintCore
import SwiftUI
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

    /// (xs, ys, kind). Sized so the first two stay vector and the last trips the
    /// auto raster fallback.
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

// MARK: - Panel view

private struct PlotPanelView: View {
    let context: ManuscriptPanelContext

    @State private var dataset: DemoDataset = .dampedSine
    @State private var xLog = false
    @State private var yLog = false
    @State private var xMin = ""
    @State private var xMax = ""
    @State private var yMin = ""
    @State private var yMax = ""
    @State private var colormap: FfiColormap = .viridis

    @State private var svg = ""
    @State private var rasterized = false
    @State private var rendering = false
    @State private var errorMessage: String?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            preview
            Divider()
            controls
        }
        .background(.background)
        .onChange(of: renderKey) { scheduleRender() }
        .task { scheduleRender() }
    }

    // A single value that changes whenever any input changes.
    private var renderKey: String {
        "\(dataset.rawValue)|\(xLog)|\(yLog)|\(xMin)|\(xMax)|\(yMin)|\(yMax)|\(colormap.hashValue)"
    }

    private var preview: some View {
        ZStack {
            PlotSVGView(svg: svg)
            if rendering {
                ProgressView().controlSize(.small)
            }
            if let err = errorMessage {
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

    private var controls: some View {
        Form {
            Picker("Data", selection: $dataset) {
                ForEach(DemoDataset.allCases) { Text($0.rawValue).tag($0) }
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
                Button("Insert into manuscript") { insert() }
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }

    // MARK: Spec + rendering

    private func spec(width: Double, height: Double) -> FfiPlotSpec {
        let d = dataset.series()
        return FfiPlotSpec(
            title: dataset.rawValue,
            x: FfiAxis(scale: xLog ? .log : .linear, min: Double(xMin), max: Double(xMax), label: "x"),
            y: FfiAxis(scale: yLog ? .log : .linear, min: Double(yMin), max: Double(yMax), label: "y"),
            series: [FfiSeries(kind: d.kind, xs: d.xs, ys: d.ys, color: FfiColor(r: 31, g: 111, b: 214))],
            strategy: .auto,
            colormap: colormap,
            width: width,
            height: height,
            rasterThreshold: 0
        )
    }

    private func scheduleRender() {
        renderTask?.cancel()
        let s = spec(width: 360, height: 240)
        renderTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if Task.isCancelled { return }
            rendering = true
            // Off the main thread on a shared serial queue so the FFI's
            // thread-local engine stays warm between renders.
            let result = await PlotRenderQueue.shared.render(s)
            if Task.isCancelled { return }
            rendering = false
            rasterized = result.rasterized
            if let e = result.error, !e.isEmpty {
                errorMessage = e
            } else {
                errorMessage = nil
                svg = result.svg
            }
        }
    }

    private func insert() {
        let s = spec(width: 340, height: 220)
        let src = renderPlotTypst(spec: s)
        if src.inlineSafe {
            context.insertAtCursor("\n" + src.typst + "\n")
        } else {
            errorMessage = "Raster plots can't be inserted inline yet — vector only."
        }
    }
}

/// Serializes FFI plot renders onto one background queue so the Rust
/// thread-local renderer is reused (warm engine).
private actor PlotRenderQueue {
    static let shared = PlotRenderQueue()
    private let queue = DispatchQueue(label: "com.impress.plot-render", qos: .userInitiated)

    func render(_ spec: FfiPlotSpec) async -> FfiRenderedPlot {
        await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: renderPlotSvg(spec: spec))
            }
        }
    }
}

// MARK: - SVG preview (WKWebView)

private struct PlotSVGView: NSViewRepresentable {
    let svg: String

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        // Transparent background so the panel chrome shows through.
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
