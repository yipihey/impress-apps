import ImploreRustCore
import ImpressLogging
import OSLog

/// Observable state for the 1D plot viewer.
///
/// Manages series selection, histogram computation, and SVG rendering
/// via Rust FFI. Uses `plotVersion` to gate view updates.
@MainActor @Observable
final class PlotViewerState {
    let dataset: RgDatasetHandle
    let info: RgDatasetInfo

    /// Which data series are selected for plotting.
    var selectedSeriesNames: Set<String> = []

    /// Current rendered SVG (nil until first render).
    private(set) var currentSVG: String?

    /// Monotonically increasing version for gated rendering.
    private(set) var plotVersion: Int = 0

    /// Axis scale toggles.
    var logScaleX: Bool = false
    var logScaleY: Bool = false

    /// Show grid lines.
    var showGrid: Bool = true

    /// Current plot mode.
    var plotMode: PlotMode = .series

    /// Histogram settings.
    var histogramField: String = "velocity_magnitude"
    var histogramBins: Int = 0 // 0 = auto

    private let logger = Logger(subsystem: "com.impress.implore", category: "plot-viewer")

    enum PlotMode: String, CaseIterable {
        case series = "Series"
        case cascade = "Cascade"
        case histogram = "Histogram"
    }

    init(dataset: RgDatasetHandle) {
        self.dataset = dataset
        self.info = dataset.info()

        // Auto-select first few series if available
        let names = info.dataSeriesNames
        if !names.isEmpty {
            selectedSeriesNames = Set(names.prefix(min(3, names.count)))
            renderPlot()
        }

        // Default histogram field
        if let first = info.availableQuantities.first {
            histogramField = first
        }
    }

    /// Re-render the plot from selected series.
    func renderPlot() {
        guard !selectedSeriesNames.isEmpty else {
            currentSVG = nil
            plotVersion += 1
            return
        }

        let names = Array(selectedSeriesNames).sorted()

        do {
            let svg = try dataset.plotDataSeries(
                names: names,
                title: names.count == 1 ? names[0] : "\(names.count) series"
            )
            currentSVG = svg
            plotVersion += 1
            logger.infoCapture("Plot rendered: \(names.joined(separator: ", "))", category: "plot-viewer")
        } catch {
            logError("Plot render failed: \(error)", category: "plot-viewer")
        }
    }

    /// Render the canonical cascade statistics plot.
    func renderCascadePlot() {
        if let svg = dataset.plotCascadeStats() {
            currentSVG = svg
            plotVersion += 1
            logger.infoCapture("Cascade stats plot rendered", category: "plot-viewer")
        } else {
            logError("No cascade stats available", category: "plot-viewer")
        }
    }

    /// Render a histogram of a 3D field's values.
    func renderHistogram() {
        guard info.hasVolumeData else {
            logError("No volume data for histogram", category: "plot-viewer")
            return
        }

        do {
            let svg = try dataset.plotFieldHistogram(
                quantity: histogramField,
                numBins: UInt32(histogramBins)
            )
            currentSVG = svg
            plotVersion += 1
            logger.infoCapture("Histogram rendered: \(histogramField) bins=\(histogramBins)", category: "plot-viewer")
        } catch {
            logError("Histogram render failed: \(error)", category: "plot-viewer")
        }
    }

    /// Toggle a series on/off and re-render.
    func toggleSeries(_ name: String) {
        if selectedSeriesNames.contains(name) {
            selectedSeriesNames.remove(name)
        } else {
            selectedSeriesNames.insert(name)
        }
        renderPlot()
    }

    /// Select all available series.
    func selectAll() {
        selectedSeriesNames = Set(info.dataSeriesNames)
        renderPlot()
    }

    /// Deselect all series.
    func selectNone() {
        selectedSeriesNames.removeAll()
        renderPlot()
    }

    /// Render a custom PlotSpec (as JSON) to SVG.
    func renderCustomSpec(_ specJSON: String) {
        do {
            let svg = try renderPlotSvg(specJson: specJSON)
            currentSVG = svg
            plotVersion += 1
        } catch {
            logError("Custom plot spec failed: \(error)", category: "plot-viewer")
        }
    }

    /// Export current plot as Typst source.
    func exportAsTypst(_ specJSON: String) -> String? {
        try? renderPlotTypst(specJson: specJSON)
    }

    /// Render a multi-panel grid of PlotSpecs.
    func renderGrid(_ gridJSON: String) {
        do {
            let svg = try ImploreRustCore.renderGridSvg(gridJson: gridJSON)
            currentSVG = svg
            plotVersion += 1
        } catch {
            logError("Grid render failed: \(error)", category: "plot-viewer")
        }
    }
}
