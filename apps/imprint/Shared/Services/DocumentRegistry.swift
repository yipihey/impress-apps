//
//  DocumentRegistry.swift
//  imprint
//
//  Registry for tracking open documents and their pending automation operations.
//

import Foundation
import ImpressOperationQueue
import ImprintCore

/// Registry for tracking open imprint documents for HTTP API access.
/// Extends the generic OperationRegistry with imprint-specific functionality.
@MainActor
final class DocumentRegistry: OperationRegistry<UUID, DocumentOperation, ImprintDocument> {
    static let shared = DocumentRegistry()

    /// Cached PDF data per document (populated after compilation)
    var cachedPDF: [UUID: Data] = [:]

    /// Map of file URL -> document for URL-based lookup
    var documentsByURL: [String: ImprintDocument] = [:]

    private init() {
        super.init(subsystem: "com.imbib.imprint", category: "registry")
    }

    /// Register a document with optional file URL.
    func register(_ document: ImprintDocument, fileURL: URL?) {
        super.register(document, id: document.id)
        if let url = fileURL {
            documentsByURL[url.absoluteString] = document
        }
    }

    /// Unregister a document and its associated data.
    func unregister(_ document: ImprintDocument, fileURL: URL?) {
        super.unregister(id: document.id)
        cachedPDF.removeValue(forKey: document.id)
        if let url = fileURL {
            documentsByURL.removeValue(forKey: url.absoluteString)
        }
    }

    /// Find document by ID (convenience accessor).
    func document(withId id: UUID) -> ImprintDocument? {
        entity(withId: id)
    }

    /// All registered documents.
    var allDocuments: [ImprintDocument] {
        allEntities
    }

    /// Store compiled PDF for a document.
    func cachePDF(_ data: Data, for documentId: UUID) {
        cachedPDF[documentId] = data
    }
}
