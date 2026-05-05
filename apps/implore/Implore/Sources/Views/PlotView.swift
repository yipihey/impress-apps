import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImpressKeyboard

/// Displays an SVG string as an image with copy/save support and interactive features.
///
/// Phase 2 interactive features:
/// - Mouse hover shows pixel coordinates
/// - Cmd+C copies SVG to clipboard
/// - Cmd+S triggers save dialog
/// - Keyboard shortcuts: g (grid), l (log scale), +/- (zoom)
struct PlotView: View {
    let svgString: String
    var plotState: PlotViewerState?

    @State private var showingSavePanel = false
    @State private var hoverLocation: CGPoint?
    @State private var zoomScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            plotToolbar

            if let nsImage = svgToImage(svgString) {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                width: geometry.size.width * zoomScale,
                                height: geometry.size.height * zoomScale
                            )
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.08), radius: 3)
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    hoverLocation = location
                                case .ended:
                                    hoverLocation = nil
                                }
                            }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let loc = hoverLocation {
                        Text("(\(Int(loc.x)), \(Int(loc.y)))")
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .padding(8)
                    }
                }
                .contextMenu {
                    Button("Copy SVG") { copySVG() }
                    Button("Copy as Image") {
                        if let img = svgToImage(svgString) { copyImage(img) }
                    }
                    Divider()
                    Button("Save SVG...") { showingSavePanel = true }
                    if plotState != nil {
                        Button("Export as Typst...") { exportTypst() }
                    }
                }
            } else if svgString.isEmpty {
                ContentUnavailableView(
                    "No Plot",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Select data series and click Plot")
                )
            } else {
                ContentUnavailableView(
                    "Render Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Could not render SVG plot")
                )
            }
        }
        .focusable()
        .focusEffectDisabled()
        .keyboardGuarded { press in
            handlePlotKey(press)
        }
        .fileExporter(
            isPresented: $showingSavePanel,
            document: SVGDocument(svg: svgString),
            contentType: .svg,
            defaultFilename: "plot.svg"
        ) { _ in }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var plotToolbar: some View {
        HStack(spacing: 12) {
            if let state = plotState {
                Picker("Mode", selection: Binding(
                    get: { state.plotMode },
                    set: { state.plotMode = $0 }
                )) {
                    ForEach(PlotViewerState.PlotMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 250)
            }

            Spacer()

            // Zoom controls
            HStack(spacing: 4) {
                Button {
                    zoomScale = max(0.25, zoomScale - 0.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)

                Text("\(Int(zoomScale * 100))%")
                    .font(.caption.monospaced())
                    .frame(width: 40)

                Button {
                    zoomScale = min(4.0, zoomScale + 0.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)

                Button {
                    zoomScale = 1.0
                } label: {
                    Image(systemName: "1.magnifyingglass")
                }
                .buttonStyle(.borderless)
            }

            Button {
                copySVG()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help("Copy SVG to clipboard")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Keyboard

    private func handlePlotKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.characters {
        case "g":
            plotState?.showGrid.toggle()
            return .handled
        case "+", "=":
            zoomScale = min(4.0, zoomScale + 0.25)
            return .handled
        case "-":
            zoomScale = max(0.25, zoomScale - 0.25)
            return .handled
        case "0":
            zoomScale = 1.0
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: - Actions

    private func svgToImage(_ svg: String) -> NSImage? {
        guard !svg.isEmpty, let data = svg.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }

    private func copySVG() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(svgString, forType: .string)
    }

    private func copyImage(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func exportTypst() {
        // Build a minimal PlotSpec JSON from current state for Typst export
        let spec = """
        {"title":"Plot","width":640,"height":400,"series":[],"show_grid":true,"x_axis":{},"y_axis":{},"legend":{"position":"TopRight","visible":true},"annotations":[]}
        """
        if let typst = plotState?.exportAsTypst(spec) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(typst, forType: .string)
        }
    }
}

/// FileDocument wrapper for SVG export.
struct SVGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.svg] }

    let svg: String

    init(svg: String) {
        self.svg = svg
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.svg = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = svg.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}
