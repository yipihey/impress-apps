//
//  DocumentOperationConsumer.swift
//  imprint
//
//  The HTTP edit routes acknowledge a DocumentRegistry operation and return
//  an operationId. After the editor moved into PublicationManagerCore, no
//  view popped that queue, so a successful acknowledgement was not a save.
//  This consumer applies the same edits the native verbs commit, then marks
//  the tracker the poll endpoint reads.
//

import Foundation
import ImpressLogging
import PublicationManagerCore

struct DocumentEditFailure: Error, Equatable {
    let message: String
}

/// Pure source and bibliography transforms for queued document operations.
enum DocumentSourceEdit {
    /// Replace a UTF-16 range. `nil` means the range is outside the source.
    static func replaceUTF16(_ source: String, location: Int, length: Int, with text: String) -> String? {
        guard location >= 0, length >= 0,
              let range = Range(NSRange(location: location, length: length), in: source) else {
            return nil
        }
        var edited = source
        edited.replaceSubrange(range, with: text)
        return edited
    }

    /// Replace `search`. `all` replaces every match; otherwise only the first.
    /// An empty search or a missing first match is an error.
    static func replace(_ source: String, search: String, replacement: String, all: Bool) -> Result<String, DocumentEditFailure> {
        guard !search.isEmpty else { return .failure(DocumentEditFailure(message: "search text is empty")) }
        if all {
            return .success(source.replacingOccurrences(of: search, with: replacement))
        }
        guard let range = source.range(of: search) else {
            return .failure(DocumentEditFailure(message: "search text not found"))
        }
        return .success(source.replacingCharacters(in: range, with: replacement))
    }

    /// Insert or replace one BibTeX entry, keeping every other entry.
    static func upsertBibliography(_ existing: String, citeKey: String, bibtex: String) -> String {
        let trimmed = bibtex.trimmingCharacters(in: .whitespacesAndNewlines)
        var kept: [String] = []
        var replaced = false
        for entry in bibliographyEntries(existing) {
            if entry.key == citeKey {
                kept.append(trimmed)
                replaced = true
            } else {
                kept.append(entry.text)
            }
        }
        if !replaced { kept.append(trimmed) }
        return kept.joined(separator: "\n\n") + (kept.isEmpty ? "" : "\n")
    }

    /// Drop the entry whose cite key matches. Other entries stay in order.
    static func removeBibliography(_ existing: String, citeKey: String) -> String {
        let kept = bibliographyEntries(existing)
            .filter { $0.key != citeKey }
            .map(\.text)
        return kept.joined(separator: "\n\n") + (kept.isEmpty ? "" : "\n")
    }

    private struct BibEntry {
        let key: String
        let text: String
    }

    private static func bibliographyEntries(_ text: String) -> [BibEntry] {
        let scalars = Array(text)
        var entries: [BibEntry] = []
        var index = 0
        while index < scalars.count {
            if scalars[index] == "@" {
                let start = index
                index += 1
                while index < scalars.count, scalars[index] != "{" { index += 1 }
                guard index < scalars.count else { break }
                index += 1
                let keyStart = index
                while index < scalars.count, scalars[index] != "," && scalars[index] != "}" { index += 1 }
                let key = String(scalars[keyStart..<index])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var depth = 1
                while index < scalars.count, depth > 0 {
                    if scalars[index] == "{" { depth += 1 }
                    if scalars[index] == "}" { depth -= 1 }
                    index += 1
                }
                let body = String(scalars[start..<index])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty, !body.isEmpty {
                    entries.append(BibEntry(key: key, text: body))
                }
            } else {
                index += 1
            }
        }
        return entries
    }
}

/// Drains `DocumentRegistry` into the live manuscript session.
@MainActor
enum DocumentOperationConsumer {
    private static var running = false
    private static var again = false

    static func scheduleDrain() {
        again = true
        guard !running else { return }
        running = true
        Task { @MainActor in
            while again {
                again = false
                await drain()
            }
            running = false
        }
    }

    static func drain() async {
        let registry = DocumentRegistry.shared
        let ids = registry.entitiesWithPendingOperations
        for id in ids {
            while let operation = registry.popOperation(for: id) {
                await apply(operation, documentID: id)
            }
        }
    }

    private static func apply(_ operation: DocumentOperation, documentID: UUID) async {
        let operationID = operation.id
        logInfo(
            "Applying queued \(operation.operationDescription) to \(documentID)",
            category: "manuscripts"
        )
        switch operation {
        case .updateContent(_, let source, let title):
            if source == nil && title == nil {
                OperationTracker.shared.markFailed(id: operationID, reason: "update contained neither source nor title")
                return
            }
            if let source {
                let saved = await commitBody(
                    source, documentID: documentID, operationID: operationID, record: title == nil)
                guard saved else { return }
            }
            if let title {
                applyMetadata(documentID: documentID, operationID: operationID, title: title, authors: nil)
            }
        case .insertText(_, let position, let text):
            await editBody(documentID: documentID, operationID: operationID) { source in
                guard let edited = DocumentSourceEdit.replaceUTF16(source, location: position, length: 0, with: text) else {
                    return .failure(DocumentEditFailure(message: "insertion position is outside the document"))
                }
                return .success(edited)
            }
        case .deleteText(_, let start, let end):
            await editBody(documentID: documentID, operationID: operationID) { source in
                guard end > start,
                      let edited = DocumentSourceEdit.replaceUTF16(source, location: start, length: end - start, with: "") else {
                    return .failure(DocumentEditFailure(message: "deletion range is outside the document"))
                }
                return .success(edited)
            }
        case .replaceRange(_, let start, let end, let text):
            await editBody(documentID: documentID, operationID: operationID) { source in
                guard end >= start,
                      let edited = DocumentSourceEdit.replaceUTF16(source, location: start, length: end - start, with: text) else {
                    return .failure(DocumentEditFailure(message: "replacement range is outside the document"))
                }
                return .success(edited)
            }
        case .replace(_, let search, let replacement, let all):
            await editBody(documentID: documentID, operationID: operationID) { source in
                DocumentSourceEdit.replace(source, search: search, replacement: replacement, all: all)
            }
        case .updateMetadata(_, let title, let authors):
            applyMetadata(documentID: documentID, operationID: operationID, title: title, authors: authors)
        case .addCitation(_, let citeKey, let bibtex):
            writeBibliography(documentID: documentID, operationID: operationID) { existing in
                DocumentSourceEdit.upsertBibliography(existing, citeKey: citeKey, bibtex: bibtex)
            }
        case .removeCitation(_, let citeKey):
            writeBibliography(documentID: documentID, operationID: operationID) { existing in
                DocumentSourceEdit.removeBibliography(existing, citeKey: citeKey)
            }
        }
    }

    private static func editBody(
        documentID: UUID,
        operationID: UUID,
        transform: (String) -> Result<String, DocumentEditFailure>
    ) async {
        guard let session = ManuscriptSessionRegistry.shared.session(for: documentID) else {
            OperationTracker.shared.markFailed(id: operationID, reason: "manuscript session unavailable")
            return
        }
        switch transform(session.source) {
        case .failure(let failure):
            OperationTracker.shared.markFailed(id: operationID, reason: failure.message)
        case .success(let edited):
            _ = await commitBody(edited, documentID: documentID, operationID: operationID)
        }
    }

    @discardableResult
    private static func commitBody(
        _ body: String,
        documentID: UUID,
        operationID: UUID,
        record: Bool = true
    ) async -> Bool {
        guard let session = ManuscriptSessionRegistry.shared.session(for: documentID) else {
            OperationTracker.shared.markFailed(id: operationID, reason: "manuscript session unavailable")
            return false
        }
        let outcome = await session.applyAutomationBody(body)
        if case .failed = outcome {
            logInfo("Save failed for queued edit \(operationID)", category: "manuscripts")
            OperationTracker.shared.markFailed(id: operationID, reason: "editor save failed")
            return false
        }
        logInfo(
            "Save: queued edit \(operationID) committed; display \(session.source.utf8.count) bytes",
            category: "manuscripts"
        )
        if record { OperationTracker.shared.markCompleted(id: operationID) }
        return true
    }

    private static func applyMetadata(documentID: UUID, operationID: UUID, title: String?, authors: [String]?) {
        guard title != nil || authors != nil else {
            OperationTracker.shared.markFailed(id: operationID, reason: "metadata update was empty")
            return
        }
        do {
            try ManuscriptStoreAdapter.shared.updateMetadata(id: documentID, title: title, authors: authors)
            ManuscriptSessionRegistry.shared.postManuscriptChanged(id: documentID)
            logInfo("Save: metadata \(operationID) written for \(documentID)", category: "manuscripts")
            OperationTracker.shared.markCompleted(id: operationID)
        } catch {
            OperationTracker.shared.markFailed(id: operationID, reason: error.localizedDescription)
        }
    }

    private static func writeBibliography(
        documentID: UUID,
        operationID: UUID,
        transform: (String) -> String
    ) {
        let project = ManuscriptProjectModel.shared(for: documentID)
        let path = ManuscriptProjectModel.implicitBibliographyPath
        let existing: String
        if let file = project.files.first(where: { $0.path == path }) {
            guard let inline = file.content else {
                OperationTracker.shared.markFailed(id: operationID, reason: "bibliography is not inline text")
                return
            }
            existing = inline
        } else {
            existing = ""
        }
        let updated = transform(existing)
        guard project.putText(path: path, text: updated, role: "bibliography") != nil else {
            OperationTracker.shared.markFailed(id: operationID, reason: "bibliography save failed")
            return
        }
        logInfo("Display: bibliography.bib for \(documentID) is \(updated.utf8.count) bytes", category: "manuscripts")
        OperationTracker.shared.markCompleted(id: operationID)
    }
}
