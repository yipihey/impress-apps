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
            ManuscriptStoreAdapter.shared.listManuscripts(limit: UInt32(n == 0 ? 100 : n))
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
            ManuscriptStoreAdapter.shared.listManuscripts(limit: 10_000)
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

    // MARK: - Veusz plots

    func listVeuszPlots(documentID: UUID?) async throws -> [VeuszPlotEntity] {
        let stores: [VeuszPlotStore]
        if let documentID {
            guard let store = VeuszPlotStoreRegistry.shared.store(forDocumentID: documentID) else {
                return []
            }
            stores = [store]
        } else {
            stores = VeuszPlotStoreRegistry.shared.allStores
        }
        return stores.flatMap { store in
            store.plots.map { Self.entity(for: $0, in: store) }
        }
    }

    func veuszPlotsForIds(_ ids: [UUID]) async throws -> [VeuszPlotEntity] {
        ids.compactMap { id in
            guard let store = VeuszPlotStoreRegistry.shared.store(owningPlotID: id) else {
                return nil
            }
            guard let plot = store.plots.first(where: { $0.id == id }) else { return nil }
            return Self.entity(for: plot, in: store)
        }
    }

    func searchVeuszPlotsByTitle(_ query: String) async throws -> [VeuszPlotEntity] {
        let needle = query.lowercased()
        return VeuszPlotStoreRegistry.shared.allStores.flatMap { store -> [VeuszPlotEntity] in
            store.plots
                .filter { $0.displayName.lowercased().contains(needle) }
                .map { Self.entity(for: $0, in: store) }
        }
    }

    func openVeuszPlot(plotID: UUID) async throws {
        guard let store = VeuszPlotStoreRegistry.shared.store(owningPlotID: plotID) else {
            throw ImprintIntentError.executionFailed("No open document tracks plot \(plotID).")
        }
        guard store.openInVeusz(plotID: plotID) else {
            throw ImprintIntentError.executionFailed("Launch Services declined to open Veusz.")
        }
    }

    func renderVeuszPlot(plotID: UUID, format: String?) async throws {
        guard let store = VeuszPlotStoreRegistry.shared.store(owningPlotID: plotID) else {
            throw ImprintIntentError.executionFailed("No open document tracks plot \(plotID).")
        }
        if let format,
           let typed = VeuszPlotRef.ExportFormat(rawValue: format.lowercased()) {
            await store.setFormat(plotID: plotID, to: typed)
        } else {
            await store.rerender(plotID: plotID)
        }
    }

    func insertVeuszPlot(plotID: UUID, documentID: UUID) async throws {
        guard let store = VeuszPlotStoreRegistry.shared.store(forDocumentID: documentID) else {
            throw ImprintIntentError.documentNotFound(documentID.uuidString)
        }
        guard let plot = store.plots.first(where: { $0.id == plotID }) else {
            throw ImprintIntentError.executionFailed("Plot \(plotID) not found in document \(documentID).")
        }
        guard let document = DocumentRegistry.shared.document(withId: documentID) else {
            throw ImprintIntentError.documentNotFound(documentID.uuidString)
        }
        let snippet = VeuszPlotInsertion.block(for: plot, format: document.format)
        NotificationCenter.default.post(
            name: VeuszPlotInsertion.notificationName,
            object: nil,
            userInfo: [
                "plotID": plot.id,
                "snippet": snippet,
                "documentID": documentID,
            ]
        )
    }

    func createVeuszPlot(documentID: UUID, name: String) async throws -> VeuszPlotEntity {
        guard let store = VeuszPlotStoreRegistry.shared.store(forDocumentID: documentID) else {
            throw ImprintIntentError.documentNotFound(documentID.uuidString)
        }
        let plot = try await store.createPlot(name: name)
        return Self.entity(for: plot, in: store)
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

    private static func entity(for plot: VeuszPlotRef, in store: VeuszPlotStore) -> VeuszPlotEntity {
        VeuszPlotEntity(
            id: plot.id,
            title: plot.displayName,
            documentID: store.documentID,
            renderedFormat: plot.exportFormat.rawValue,
            renderedRelativePath: plot.renderedRelativePath,
            lastRenderedAt: plot.lastRenderedAt
        )
    }
}
