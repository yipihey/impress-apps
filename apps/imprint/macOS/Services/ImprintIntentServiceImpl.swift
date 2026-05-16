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

    func listDocuments(limit: Int) async throws -> [DocumentEntity] {
        let docs = DocumentRegistry.shared.allDocuments.prefix(max(0, limit))
        return docs.map(Self.entity(for:))
    }

    func documentsForIds(_ ids: [UUID]) async throws -> [DocumentEntity] {
        ids.compactMap { id in
            DocumentRegistry.shared.document(withId: id).map(Self.entity(for:))
        }
    }

    func searchDocumentsByTitle(_ query: String) async throws -> [DocumentEntity] {
        let needle = query.lowercased()
        return DocumentRegistry.shared.allDocuments
            .filter { $0.title.lowercased().contains(needle) }
            .map(Self.entity(for:))
    }

    func getDocumentContent(id: UUID) async throws -> String {
        guard let doc = DocumentRegistry.shared.document(withId: id) else {
            throw ImprintIntentError.documentNotFound(id.uuidString)
        }
        return doc.source
    }

    func createDocument(title: String, template: String?) async throws -> DocumentEntity {
        // Document creation routes through DocumentController on the main thread —
        // an App Intent can't reliably drive that workflow, so we surface a clear
        // error rather than partially implement it.
        throw ImprintIntentError.executionFailed("Document creation via App Intent is not yet wired up.")
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
