//
//  DocumentOperation.swift
//  imprint
//
//  Operations for imprint document automation via HTTP API.
//

import Foundation
import ImpressOperationQueue

/// Operations that can be queued for document automation via HTTP API.
///
/// Each case carries an `operationID` that agents use with
/// `GET /api/operations/{id}` to confirm completion. The router generates
/// the id when it queues the op; the editor view updates the registry when
/// the op is applied.
enum DocumentOperation: QueueableOperation {
    case updateContent(operationID: UUID, source: String?, title: String?)
    case insertText(operationID: UUID, position: Int, text: String)
    case deleteText(operationID: UUID, start: Int, end: Int)
    case replaceRange(operationID: UUID, start: Int, end: Int, text: String)
    case replace(operationID: UUID, search: String, replacement: String, all: Bool)
    case addCitation(operationID: UUID, citeKey: String, bibtex: String)
    case removeCitation(operationID: UUID, citeKey: String)
    case updateMetadata(operationID: UUID, title: String?, authors: [String]?)

    var id: UUID {
        switch self {
        case .updateContent(let id, _, _),
             .insertText(let id, _, _),
             .deleteText(let id, _, _),
             .replaceRange(let id, _, _, _),
             .replace(let id, _, _, _),
             .addCitation(let id, _, _),
             .removeCitation(let id, _),
             .updateMetadata(let id, _, _):
            return id
        }
    }

    var operationDescription: String {
        switch self {
        case .updateContent(_, let source, let title):
            return "updateContent(source:\(source != nil), title:\(title != nil))"
        case .insertText(_, let pos, _):
            return "insertText@\(pos)"
        case .deleteText(_, let start, let end):
            return "deleteText[\(start)..<\(end)]"
        case .replaceRange(_, let start, let end, let text):
            return "replaceRange[\(start)..<\(end)]=\(text.count)ch"
        case .replace(_, let search, _, let all):
            return "replace(\(search), all:\(all))"
        case .addCitation(_, let key, _):
            return "addCitation(\(key))"
        case .removeCitation(_, let key):
            return "removeCitation(\(key))"
        case .updateMetadata(_, let title, let authors):
            return "updateMetadata(title:\(title != nil), authors:\(authors?.count ?? 0))"
        }
    }
}
