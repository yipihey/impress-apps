//
//  DocumentOperation.swift
//  imprint
//
//  Operations for imprint document automation via HTTP API.
//

import Foundation
import ImpressOperationQueue

/// Operations that can be queued for document automation via HTTP API.
enum DocumentOperation: QueueableOperation {
    case updateContent(source: String?, title: String?)
    case insertText(position: Int, text: String)
    case deleteText(start: Int, end: Int)
    case replace(search: String, replacement: String, all: Bool)
    case addCitation(citeKey: String, bibtex: String)
    case removeCitation(citeKey: String)
    case updateMetadata(title: String?, authors: [String]?)

    var id: UUID { UUID() }

    var operationDescription: String {
        switch self {
        case .updateContent(let source, let title):
            return "updateContent(source:\(source != nil), title:\(title != nil))"
        case .insertText(let pos, _):
            return "insertText@\(pos)"
        case .deleteText(let start, let end):
            return "deleteText[\(start)..<\(end)]"
        case .replace(let search, _, let all):
            return "replace(\(search), all:\(all))"
        case .addCitation(let key, _):
            return "addCitation(\(key))"
        case .removeCitation(let key):
            return "removeCitation(\(key))"
        case .updateMetadata(let title, let authors):
            return "updateMetadata(title:\(title != nil), authors:\(authors?.count ?? 0))"
        }
    }
}
