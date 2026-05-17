import AppKit
import Foundation
import ImpressLogging
import OSLog

/// Abstraction over `VeuszService` so the store can be tested with a stub renderer
/// that doesn't shell out to Veusz.
@MainActor
protocol VeuszRendering {
    func openInVeusz(_ url: URL) -> Bool
    func export(source: URL, to destination: URL, format: VeuszPlotRef.ExportFormat) async throws
}

extension VeuszService: VeuszRendering {}

/// Document-scoped store for tracked Veusz plots.
///
/// Owns the on-disk working directory, the per-plot file watcher, and the
/// list of `VeuszPlotRef`s. Mutations call `onChange` so the surrounding view
/// can push the updated `plots` and `figureFiles` back into the document
/// binding — keeping the store ignorant of `ImprintDocument` directly.
///
/// Single source of truth contract: while a document is open, the store's
/// `plots` array is authoritative; the document's `plots` field reflects what
/// will be persisted at next save.
@MainActor
@Observable
final class VeuszPlotStore {

    struct Snapshot: Equatable, Sendable {
        let plots: [VeuszPlotRef]
        let figureFiles: [String: Data]
    }

    /// Document identity (stable across renames/moves).
    let documentID: UUID

    /// Mutable list of plots — view code reads this directly.
    private(set) var plots: [VeuszPlotRef]

    /// On-disk working directory holding the .vsz sources + rendered output.
    let workingDirectory: URL

    private let renderer: any VeuszRendering
    private let storage: VeuszWorkingDirectory
    private let onChange: @MainActor (Snapshot) -> Void
    /// VeuszPlotWatcher manages its own internal queue and is thread-safe, so the
    /// reference doesn't need to be main-actor isolated. Holding it nonisolated
    /// lets `deinit` call `stopAll()` without hopping back to the main actor.
    nonisolated(unsafe) private var watcher: VeuszPlotWatcher?

    init(
        documentID: UUID,
        initialPlots: [VeuszPlotRef],
        initialFigureFiles: [String: Data],
        renderer: any VeuszRendering,
        storage: VeuszWorkingDirectory = VeuszWorkingDirectory(),
        onChange: @escaping @MainActor (Snapshot) -> Void = { _ in }
    ) throws {
        self.documentID = documentID
        self.plots = initialPlots
        self.renderer = renderer
        self.storage = storage
        self.onChange = onChange
        self.workingDirectory = try storage.materializeFigures(initialFigureFiles, for: documentID)

        // Watcher fires when Veusz (or any external editor) saves a .vsz back to disk.
        let weakRef = WeakStoreRef()
        self.watcher = VeuszPlotWatcher { plotID in
            Task { @MainActor in
                await weakRef.store?.handleExternalSave(plotID: plotID)
            }
        }
        weakRef.store = self

        for plot in initialPlots {
            let url = workingDirectory.appending(path: (plot.sourceRelativePath as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: url.path) {
                watcher?.watch(plotID: plot.id, url: url)
            }
        }
    }

    deinit {
        watcher?.stopAll()
    }

    // MARK: - Mutations

    /// Create a new plot from the minimal template, write the .vsz to disk, and
    /// (best-effort) render its initial output so the panel has a thumbnail.
    ///
    /// `format` is the rendered output format. Callers pick based on the
    /// host manuscript: SVG for Typst (native), PDF for LaTeX (pdfLaTeX
    /// has no native SVG support and requires `--shell-escape` + Inkscape
    /// via the `svg` package, which we'd rather not impose).
    @discardableResult
    func createPlot(name: String, format: VeuszPlotRef.ExportFormat = .svg) async throws -> VeuszPlotRef {
        let baseName = Self.sanitize(name: name)
        let sourceName = "\(baseName).vsz"
        let ext = format.fileExtension
        let renderedName = "\(baseName).\(ext)"

        // Avoid clobbering an existing plot with the same name.
        let sourceURL = uniquePath(in: workingDirectory, named: sourceName)
        let renderedURL = workingDirectory.appending(path: renderedName)
        let finalSourceName = sourceURL.lastPathComponent
        let finalRenderedName = (sourceURL.deletingPathExtension().lastPathComponent) + ".\(ext)"

        try Self.minimalVszTemplate(title: baseName)
            .data(using: .utf8)!
            .write(to: sourceURL, options: .atomic)

        var plot = VeuszPlotRef(
            displayName: baseName,
            sourceRelativePath: "figures/\(finalSourceName)",
            renderedRelativePath: "figures/\(finalRenderedName)",
            exportFormat: format,
            sourceModifiedAt: Date(),
            renderStatus: .rendering
        )

        plots.append(plot)
        watcher?.watch(plotID: plot.id, url: sourceURL)
        notifyChanged()

        do {
            try await renderer.export(
                source: sourceURL,
                to: renderedURL,
                format: format
            )
            plot.lastRenderedAt = Date()
            plot.renderStatus = .idle
        } catch {
            plot.renderStatus = .failed(error.localizedDescription)
            Logger.veusz.errorCapture("Initial render of \(finalSourceName) failed: \(error.localizedDescription)", category: "veusz")
        }
        replace(plot)
        return plot
    }

    /// Remove the plot and its on-disk files.
    func deletePlot(_ plotID: UUID) {
        guard let index = plots.firstIndex(where: { $0.id == plotID }) else { return }
        let plot = plots[index]
        watcher?.stop(plotID: plotID)
        for name in [
            (plot.sourceRelativePath as NSString).lastPathComponent,
            (plot.renderedRelativePath as NSString).lastPathComponent,
        ] {
            let url = workingDirectory.appending(path: name)
            try? FileManager.default.removeItem(at: url)
        }
        plots.remove(at: index)
        notifyChanged()
    }

    /// Render the plot's rendered output from its current .vsz source.
    func rerender(plotID: UUID) async {
        guard var plot = plots.first(where: { $0.id == plotID }) else { return }
        let sourceURL = workingDirectory.appending(path: (plot.sourceRelativePath as NSString).lastPathComponent)
        let renderedURL = workingDirectory.appending(path: (plot.renderedRelativePath as NSString).lastPathComponent)

        plot.renderStatus = .rendering
        replace(plot)

        do {
            try await renderer.export(source: sourceURL, to: renderedURL, format: plot.exportFormat)
            plot.lastRenderedAt = Date()
            plot.sourceModifiedAt = (try? FileManager.default
                .attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date) ?? plot.sourceModifiedAt
            plot.renderStatus = .idle
        } catch {
            plot.renderStatus = .failed(error.localizedDescription)
            Logger.veusz.errorCapture("Re-render of \(plot.displayName) failed: \(error.localizedDescription)", category: "veusz")
        }
        replace(plot)
    }

    /// Change the rendered output format for a plot. Renames the existing rendered
    /// file's extension to match and re-renders so the new output exists on disk.
    func setFormat(plotID: UUID, to newFormat: VeuszPlotRef.ExportFormat) async {
        guard var plot = plots.first(where: { $0.id == plotID }) else { return }
        if plot.exportFormat == newFormat { return }

        // Remove the old rendered file so stale outputs don't accumulate.
        let oldRenderedName = (plot.renderedRelativePath as NSString).lastPathComponent
        try? FileManager.default.removeItem(at: workingDirectory.appending(path: oldRenderedName))

        // Rewrite the rendered path to use the new extension, keeping the same stem.
        let stem = (oldRenderedName as NSString).deletingPathExtension
        let newRenderedName = "\(stem).\(newFormat.fileExtension)"
        plot.renderedRelativePath = "figures/\(newRenderedName)"
        plot.exportFormat = newFormat
        replace(plot)

        await rerender(plotID: plotID)
    }

    /// Launch Veusz on the plot's .vsz source.
    @discardableResult
    func openInVeusz(plotID: UUID) -> Bool {
        guard let plot = plots.first(where: { $0.id == plotID }) else { return false }
        let url = workingDirectory.appending(path: (plot.sourceRelativePath as NSString).lastPathComponent)
        return renderer.openInVeusz(url)
    }

    // MARK: - Snapshot

    /// Read every figure file back from disk for inclusion in the next save.
    func currentFigureFiles() -> [String: Data] {
        (try? storage.readFigures(for: documentID)) ?? [:]
    }

    // MARK: - Watcher callback

    fileprivate func handleExternalSave(plotID: UUID) async {
        Logger.veusz.infoCapture("External save detected for plot \(plotID)", category: "veusz")
        await rerender(plotID: plotID)
        NotificationCenter.default.post(
            name: .veuszPlotDidRender,
            object: nil,
            userInfo: ["plotID": plotID, "documentID": documentID]
        )
    }

    // MARK: - Helpers

    private func replace(_ plot: VeuszPlotRef) {
        if let idx = plots.firstIndex(where: { $0.id == plot.id }) {
            plots[idx] = plot
            notifyChanged()
        }
    }

    private func notifyChanged() {
        let snapshot = Snapshot(plots: plots, figureFiles: currentFigureFiles())
        onChange(snapshot)
    }

    private func uniquePath(in directory: URL, named name: String) -> URL {
        let candidate = directory.appending(path: name)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for i in 2... {
            let attempt = directory.appending(path: ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            if !FileManager.default.fileExists(atPath: attempt.path) { return attempt }
        }
        return candidate
    }

    /// Sanitize a user-entered plot name into a safe filename stem.
    /// Strips slashes/colons/dots and trims whitespace.
    static func sanitize(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: #"[/:\\?%*|"<>.]"#, with: "-", options: .regularExpression)
        return cleaned.isEmpty ? "Untitled Plot" : cleaned
    }

    /// Minimal valid Veusz document for new plots — one page, one graph, no data.
    /// Edited from the GUI immediately on creation.
    ///
    /// Page is set to 10×7 cm so the rendered PDF/SVG has manuscript-friendly
    /// dimensions (Veusz's 15×15 cm default leaves so much whitespace around
    /// the graph that `\includegraphics[width=0.8\textwidth]` floats the
    /// figure onto its own page in LaTeX, or eats half of a Typst page).
    /// Users can override Page → Width/Height in the Veusz GUI if they
    /// need a different aspect for a specific plot.
    static func minimalVszTemplate(title: String) -> String {
        """
        # Veusz saved document (version 0.9)
        # Created by imprint for plot "\(title)"
        Add('page', name='page1', autoadd=False)
        To('page1')
        Set('width', '10cm')
        Set('height', '7cm')
        Add('graph', name='graph1', autoadd=False)
        To('graph1')
        Add('axis', name='x', autoadd=False)
        Add('axis', name='y', autoadd=False, direction='vertical')
        To('..')
        To('..')
        """
    }
}

/// Weak holder so the watcher callback (created in init) can reference the
/// store without forming a cycle.
@MainActor
private final class WeakStoreRef {
    weak var store: VeuszPlotStore?
}

extension Notification.Name {
    static let veuszPlotDidRender = Notification.Name("com.imprint.veuszPlotDidRender")
}
