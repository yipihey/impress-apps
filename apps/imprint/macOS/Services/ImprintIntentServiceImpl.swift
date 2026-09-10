import PublicationManagerCore
import AppKit
import Foundation
import ImpressLogging
import ImprintCore
import OSLog

/// Concrete `ImprintIntentService` that wires App Intents (and the MCP/HTTP
/// surface) to the live document and plot stores.
///
/// Registered at app launch via `ImprintIntentServiceLocator.service`.
@MainActor
final class ImprintIntentServiceImpl: ImprintIntentService {

    static let shared = ImprintIntentServiceImpl()

    nonisolated init() {}

    // MARK: - Documents
    //
    // Phase F1 of /Users/tabel/.claude/plans/one-store-the-store-melodic-wreath.md:
    // Routed through `ManuscriptStoreAdapter` (the unified store) with a
    // `DocumentRegistry` fallback for any legacy in-memory entries. With
    // DocumentGroup retired (Phase 4b), the registry is no longer
    // populated in normal use; the fallback is kept for forward
    // compatibility and one-off recovery flows.

    func listDocuments(limit: Int) async throws -> [DocumentEntity] {
        let n = max(0, limit)
        let manuscripts = await MainActor.run {
            ManuscriptStoreAdapter.shared.allManuscripts(limit: UInt32(n == 0 ? 100 : n))
        }
        let primary = manuscripts.prefix(n == 0 ? Int.max : n).map(Self.entity(for:))
        if !primary.isEmpty { return Array(primary) }
        // Fallback for any legacy DocumentRegistry entries.
        let docs = DocumentRegistry.shared.allDocuments.prefix(n)
        return docs.map(Self.entity(for:))
    }

    func documentsForIds(_ ids: [UUID]) async throws -> [DocumentEntity] {
        await MainActor.run {
            ids.compactMap { id -> DocumentEntity? in
                if let m = ManuscriptStoreAdapter.shared.manuscript(id: id) {
                    return Self.entity(for: m)
                }
                if let doc = DocumentRegistry.shared.document(withId: id) {
                    return Self.entity(for: doc)
                }
                return nil
            }
        }
    }

    func searchDocumentsByTitle(_ query: String) async throws -> [DocumentEntity] {
        let needle = query.lowercased()
        let manuscripts = await MainActor.run {
            ManuscriptStoreAdapter.shared.allManuscripts(limit: 10_000)
        }
        let storeHits = manuscripts
            .filter { $0.title.lowercased().contains(needle) }
            .map(Self.entity(for:))
        if !storeHits.isEmpty { return storeHits }
        return DocumentRegistry.shared.allDocuments
            .filter { $0.title.lowercased().contains(needle) }
            .map(Self.entity(for:))
    }

    func getDocumentContent(id: UUID) async throws -> String {
        if let m = await MainActor.run(body: { ManuscriptStoreAdapter.shared.manuscript(id: id) }) {
            return m.body
        }
        if let doc = DocumentRegistry.shared.document(withId: id) {
            return doc.source
        }
        throw ImprintIntentError.documentNotFound(id.uuidString)
    }

    func createDocument(title: String, template: String?) async throws -> DocumentEntity {
        // Phase F1: creation now routes through `ManuscriptStoreAdapter`
        // — no more DocumentController dance required. `template` selects
        // the format: "latex" or "tex" → LaTeX, anything else → Typst.
        let format: ManuscriptFormat = (template?.lowercased() == "latex" || template?.lowercased() == "tex")
            ? .latex : .typst
        return try await MainActor.run {
            let id = try ManuscriptStoreAdapter.shared.createManuscript(
                title: title,
                format: format
            )
            guard let m = ManuscriptStoreAdapter.shared.manuscript(id: id) else {
                throw ImprintIntentError.executionFailed("Created manuscript \(id) but couldn't read it back.")
            }
            return Self.entity(for: m)
        }
    }

    func compileDocument(id: UUID) async throws {
        // Triggering compilation requires the ContentView's renderer; posted via
        // notification to keep the boundaries clean.
        NotificationCenter.default.post(name: .compileDocument, object: nil, userInfo: ["documentID": id])
    }

    func searchDocument(id: UUID, query: String) async throws -> [String] {
        guard let doc = DocumentRegistry.shared.document(withId: id) else {
            throw ImprintIntentError.documentNotFound(id.uuidString)
        }
        // Simple substring search — for richer regex/range info use the HTTP API.
        let lines = doc.source.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated()
            .filter { $0.element.localizedCaseInsensitiveContains(query) }
            .map { "\($0.offset + 1): \($0.element)" }
    }

    func exportDocument(id: UUID, format: String) async throws -> String {
        guard let doc = DocumentRegistry.shared.document(withId: id) else {
            throw ImprintIntentError.documentNotFound(id.uuidString)
        }
        switch format.lowercased() {
        case "typst", "typ": return doc.source
        default:
            throw ImprintIntentError.executionFailed("Export format \(format) is not implemented yet.")
        }
    }

    func getBibliography(id: UUID) async throws -> String {
        guard let doc = DocumentRegistry.shared.document(withId: id) else {
            throw ImprintIntentError.documentNotFound(id.uuidString)
        }
        return doc.bibliography.values.joined(separator: "\n\n")
    }

    // MARK: - Figures (the "Veusz plot" intents, backed by project figures — ADR-0030 D13)
    //
    // The intents keep their names (Shortcuts and the HTTP routes are wired
    // to them) but act on the manuscript's `figure-source` rows of every
    // kind: Veusz documents, lilaq figures, plot specs, scripts. A plot id is
    // a file row id; only manuscripts this process has loaded are searched,
    // as before ("no open document tracks plot").

    private static func entity(for figure: ManuscriptProjectFile, in model: ManuscriptProjectModel) -> VeuszPlotEntity {
        let output = model.outputs(of: figure).first
        let format = output.map { URL(fileURLWithPath: $0.path).pathExtension } ?? "svg"
        return VeuszPlotEntity(
            id: figure.id,
            title: figure.path,
            documentID: model.manuscriptID,
            renderedFormat: format.isEmpty ? "svg" : format,
            renderedRelativePath: output?.path ?? "",
            lastRenderedAt: output?.modifiedMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
    }

    func listVeuszPlots(documentID: UUID?) async throws -> [VeuszPlotEntity] {
        let models = documentID.map { [ManuscriptProjectModel.shared(for: $0)] } ?? ManuscriptProjectModel.loaded
        return models.flatMap { model in model.figures.map { Self.entity(for: $0, in: model) } }
    }

    func veuszPlotsForIds(_ ids: [UUID]) async throws -> [VeuszPlotEntity] {
        ids.compactMap { id in
            ManuscriptProjectModel.locate(fileID: id).map { Self.entity(for: $0.file, in: $0.model) }
        }
    }

    func searchVeuszPlotsByTitle(_ query: String) async throws -> [VeuszPlotEntity] {
        let needle = query.lowercased()
        return ManuscriptProjectModel.loaded.flatMap { model -> [VeuszPlotEntity] in
            model.figures
                .filter { $0.path.lowercased().contains(needle) }
                .map { Self.entity(for: $0, in: model) }
        }
    }

    func openVeuszPlot(plotID: UUID) async throws {
        guard let (model, figure) = ManuscriptProjectModel.locate(fileID: plotID) else {
            throw ImprintIntentError.executionFailed("No open manuscript holds figure \(plotID).")
        }
        let kind = model.figureKind(of: figure) ?? ""
        guard ManuscriptEditorEnvironment.shared.figureEditorAvailable(kind) else {
            throw ImprintIntentError.executionFailed("No external editor for a \(kind) figure; edit it in imprint.")
        }
        guard let url = model.beginExternalEdit(path: figure.path),
              ManuscriptEditorEnvironment.shared.openFigureExternally(url, kind) else {
            throw ImprintIntentError.executionFailed(model.lastError ?? "The editor did not open.")
        }
    }

    func renderVeuszPlot(plotID: UUID, format: String?) async throws {
        guard let (model, figure) = ManuscriptProjectModel.locate(fileID: plotID) else {
            throw ImprintIntentError.executionFailed("No open manuscript holds figure \(plotID).")
        }
        if let format, let json = figure.buildJSON,
           var raw = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
           let outputs = raw["outputs"] as? [String], let first = outputs.first {
            // A requested format renames the first declared output.
            let stem = (first as NSString).deletingPathExtension
            raw["outputs"] = ["\(stem).\(format.lowercased())"] + outputs.dropFirst()
            if let data = try? JSONSerialization.data(withJSONObject: raw), let text = String(data: data, encoding: .utf8) {
                model.setBuildJSON(path: figure.path, json: text)
            }
        }
        let result = await model.renderFigure(path: figure.path, force: true, allowShell: false, record: true)
        if let result, !result.isSuccess {
            throw ImprintIntentError.executionFailed(result.message)
        }
    }

    func insertVeuszPlot(plotID: UUID, documentID: UUID) async throws {
        let model = ManuscriptProjectModel.shared(for: documentID)
        guard let figure = model.files.first(where: { $0.id == plotID }) else {
            throw ImprintIntentError.executionFailed("Figure \(plotID) is not in manuscript \(documentID).")
        }
        guard let snippet = model.placementSnippet(for: figure) else {
            throw ImprintIntentError.executionFailed("\(figure.path) has no output to place; render it first.")
        }
        ManuscriptSnippetInsertion.post(documentID: documentID, snippet: snippet)
    }

    func createVeuszPlot(documentID: UUID, name: String) async throws -> VeuszPlotEntity {
        let model = ManuscriptProjectModel.shared(for: documentID)
        let path = name.contains("/") ? name : "figures/\(name)"
        guard let row = model.newFigure(kind: "veusz", path: path) else {
            throw ImprintIntentError.executionFailed(model.lastError ?? "The figure could not be created.")
        }
        return Self.entity(for: row, in: model)
    }

    // MARK: - Mapping helpers

    private static func entity(for document: ImprintDocument) -> DocumentEntity {
        DocumentEntity(
            id: document.id,
            title: document.title,
            wordCount: document.source.split(separator: " ", omittingEmptySubsequences: true).count,
            lastModified: document.modifiedAt,
            hasUnsavedChanges: false
        )
    }

    /// Phase F1: `ManuscriptModel`-driven overload. Source of truth post-Phase-4b.
    /// The `lastModified` falls back to `createdAt` when the manuscript hasn't
    /// had a body edit yet (a brand-new manuscript via File → New).
    private static func entity(for manuscript: ManuscriptModel) -> DocumentEntity {
        DocumentEntity(
            id: manuscript.id,
            title: manuscript.title,
            wordCount: manuscript.body.split(separator: " ", omittingEmptySubsequences: true).count,
            lastModified: manuscript.bodyModifiedAt ?? manuscript.createdAt,
            hasUnsavedChanges: false
        )
    }

}
