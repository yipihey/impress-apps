//
//  PanelManuscriptBridge.swift
//  imprint
//
//  Panels Phase B/C: the store↔ImprintDocument adapter for the document-coupled
//  flanking panels (Throughline, Veusz). The shared chassis has no
//  `ImprintDocument` — only a store-backed `ManuscriptEditorSession`. These
//  panels still bind `$document: ImprintDocument`, so imprint hydrates one from
//  the store per manuscript, keeps its `source` in sync with the editor (the
//  editor stays the source of truth), and lets the panels persist their own
//  non-source fields through their existing coordinators (ThroughlineCoordinator
//  → ImprintStoreAdapter; VeuszWorkingDirectory). imbib never constructs one.
//

#if os(macOS)
import Foundation
import ImprintCore
import PublicationManagerCore

@MainActor
@Observable
final class PanelManuscriptBridge {
    let manuscriptID: UUID
    var doc: ImprintDocument

    init(manuscriptID: UUID) {
        self.manuscriptID = manuscriptID

        // Load the manuscript from the store (mirrors ManuscriptEditorView.loadFromStore).
        var d: ImprintDocument
        if let m = ManuscriptStoreAdapter.shared.manuscript(id: manuscriptID) {
            d = ImprintDocument(format: m.format == .latex ? .latex : .typst)
            d.id = manuscriptID
            d.title = m.title
            d.authors = m.authors
            d.source = m.body
            d.modifiedAt = m.bodyModifiedAt ?? Date()
        } else {
            d = ImprintDocument(format: .typst)
            d.id = manuscriptID
        }

        // Hydrate the throughline sidecars from the store (no .imprint file in
        // store-first) so the throughline pane opens populated.
        if let tl = ImprintStoreAdapter.shared.loadThroughline(documentID: manuscriptID.uuidString) {
            d.throughlineSource = tl.source
            d.throughlineAnchorsJSON = tl.anchorMapJSON.isEmpty ? nil : tl.anchorMapJSON
        }

        // Rebuild the Veusz plots manifest from the working directory
        // (filesystem is source of truth).
        let scanned = Self.scanPlots(forManuscriptID: manuscriptID)
        d.plots = scanned.plots
        d.figureFiles = scanned.figureFiles

        self.doc = d
    }

    /// Keep the bridged document's body in lockstep with the live editor buffer
    /// (the editor owns `source`; the panels only read it for section extraction
    /// / plot insertion context).
    func syncSource(_ latest: String) {
        if doc.source != latest { doc.source = latest }
    }

    /// Re-scan the working directory for `.vsz` plots (e.g. after a render).
    func refreshPlots() {
        let scanned = Self.scanPlots(forManuscriptID: manuscriptID)
        doc.plots = scanned.plots
        doc.figureFiles = scanned.figureFiles
    }

    // MARK: - Veusz plots scan

    /// Rebuild `(plots, figureFiles)` from the manuscript's working directory.
    /// Lifted from `ManuscriptEditorView.scanPlots` (the legacy bridge) so the
    /// chassis panel shows the same plots. Empty when there are no `.vsz` files.
    static func scanPlots(forManuscriptID manuscriptID: UUID)
        -> (plots: [VeuszPlotRef], figureFiles: [String: Data])
    {
        let wd = VeuszWorkingDirectory()
        guard let figuresDir = try? wd.figuresDirectory(forDocumentID: manuscriptID) else {
            return ([], [:])
        }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: figuresDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return ([], [:]) }

        var figureFiles: [String: Data] = [:]
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if let data = try? Data(contentsOf: url) {
                figureFiles[url.lastPathComponent] = data
            }
        }

        let renderedExtensions: [VeuszPlotRef.ExportFormat] = [.pdf, .svg, .png]
        var plots: [VeuszPlotRef] = []
        for url in contents where url.pathExtension.lowercased() == "vsz" {
            let stem = url.deletingPathExtension().lastPathComponent
            var renderedRelPath = "figures/\(stem).svg"
            var format: VeuszPlotRef.ExportFormat = .svg
            var lastRenderedAt: Date?
            for candidateFormat in renderedExtensions {
                let candidate = figuresDir.appendingPathComponent("\(stem).\(candidateFormat.fileExtension)")
                if fm.fileExists(atPath: candidate.path) {
                    renderedRelPath = "figures/\(stem).\(candidateFormat.fileExtension)"
                    format = candidateFormat
                    lastRenderedAt = (try? fm.attributesOfItem(atPath: candidate.path))?[.modificationDate] as? Date
                    break
                }
            }
            let sourceMtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            plots.append(
                VeuszPlotRef(
                    displayName: stem,
                    sourceRelativePath: "figures/\(stem).vsz",
                    renderedRelativePath: renderedRelPath,
                    exportFormat: format,
                    lastRenderedAt: lastRenderedAt,
                    sourceModifiedAt: sourceMtime,
                    renderStatus: lastRenderedAt == nil ? .stale : .idle
                )
            )
        }
        plots.sort { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        return (plots, figureFiles)
    }
}

/// One bridge per manuscript, cached so switching the inspector panel (or
/// selection round-trips) doesn't reload the document. Mirrors
/// `ManuscriptSessionRegistry`'s keyed-by-UUID pattern.
@MainActor
final class PanelBridgeRegistry {
    static let shared = PanelBridgeRegistry()
    private var bridges: [UUID: PanelManuscriptBridge] = [:]

    func bridge(for manuscriptID: UUID) -> PanelManuscriptBridge {
        if let existing = bridges[manuscriptID] { return existing }
        let bridge = PanelManuscriptBridge(manuscriptID: manuscriptID)
        bridges[manuscriptID] = bridge
        return bridge
    }
}
#endif
