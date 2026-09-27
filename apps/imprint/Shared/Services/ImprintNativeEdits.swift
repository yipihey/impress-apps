#if os(macOS)
import Foundation
import ImpressAutomation
import ImpressKit
import ImpressLogging
import PublicationManagerCore

/// Immediate native mutations for the app-service edit verbs. The old REST
/// handlers only queue DocumentRegistry operations; no editor consumes that
/// queue after the PMC editor migration, so their 200 response is not a save.
@MainActor
enum ImprintNativeEdits {
    static func apply(method: String, id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else { return .badRequest("Invalid document ID") }
        let actualPath = RustStoreAdapter.shared.databaseLocation.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        let expectedPath = URL(fileURLWithPath: SharedWorkspace.databasePath)
            .resolvingSymlinksInPath().path
        guard actualPath == expectedPath else {
            return .serverError("Editor store is not the requested workspace")
        }
        guard ManuscriptStoreAdapter.shared.manuscript(id: uuid) != nil else {
            return .notFound("Document not found")
        }
        guard let body = request.body, let data = body.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }
        logInfo("Native \(method) requested for manuscript \(id)", category: "manuscripts")

        switch method {
        case "update_document", "update_metadata":
            let allowed: Set<String> = method == "update_document"
                ? ["title"]
                : ["title", "status", "authors", "orcid", "affiliation", "funder", "license"]
            let unknown = Set(args.keys).subtracting(allowed)
            guard unknown.isEmpty else { return .badRequest("Unsupported metadata field") }
            for (key, value) in args {
                if key == "authors" {
                    guard value is [String] else { return .badRequest("authors must be strings") }
                } else {
                    guard value is String else { return .badRequest("Metadata fields must be strings") }
                }
            }
            let title = args["title"] as? String
            let status = args["status"] as? String
            let authors = args["authors"] as? [String]
            guard !args.isEmpty else { return .badRequest("No metadata fields supplied") }
            do {
                try ManuscriptStoreAdapter.shared.updateMetadata(
                    id: uuid, title: title, status: status, authors: authors,
                    orcid: args["orcid"] as? String,
                    affiliation: args["affiliation"] as? String,
                    funder: args["funder"] as? String,
                    license: args["license"] as? String)
            } catch {
                return .serverError("Metadata save failed: \(error.localizedDescription)")
            }
            guard let saved = ManuscriptStoreAdapter.shared.manuscript(id: uuid),
                  title.map({ saved.title == $0 }) ?? true,
                  status.map({ saved.status == $0 }) ?? true,
                  authors.map({ saved.authors == $0 }) ?? true,
                  (args["orcid"] as? String).map({ saved.orcid == $0 }) ?? true,
                  (args["affiliation"] as? String).map({ saved.affiliation == $0 }) ?? true,
                  (args["funder"] as? String).map({ saved.funder == $0 }) ?? true,
                  (args["license"] as? String).map({ saved.license == $0 }) ?? true else {
                return .serverError("Metadata readback did not match requested fields")
            }
            RustStoreAdapter.shared.noteExternalMutation(structural: false, affectedIDs: [uuid])
            ManuscriptSessionRegistry.shared.postManuscriptChanged(id: uuid)
            logInfo("Native \(method) saved and displayed for manuscript \(id)", category: "manuscripts")
            return .json(["status": "ok", "documentId": id])
        case "insert_text", "delete_text", "replace":
            guard let session = ManuscriptSessionRegistry.shared.session(for: uuid) else {
                return .serverError("Editor session unavailable")
            }
            let source = session.source
            var edited = source
            var replaced = 0
            switch method {
            case "insert_text":
                guard let position = args["position"] as? Int, let text = args["text"] as? String,
                      position >= 0,
                      let range = Range(NSRange(location: position, length: 0), in: source) else {
                    return .badRequest("Invalid insertion position or text")
                }
                edited.insert(contentsOf: text, at: range.lowerBound)
            case "delete_text":
                guard let start = args["start"] as? Int, let end = args["end"] as? Int,
                      start >= 0, end > start,
                      let range = Range(NSRange(location: start, length: end - start), in: source) else {
                    return .badRequest("Invalid deletion range")
                }
                edited.removeSubrange(range)
            default:
                guard let search = args["search"] as? String, !search.isEmpty,
                      let replacement = args["replacement"] as? String else {
                    return .badRequest("Missing search or replacement")
                }
                replaced = max(0, source.components(separatedBy: search).count - 1)
                edited = source.replacingOccurrences(of: search, with: replacement)
            }
            let outcome = await session.applyAutomationBody(edited)
            if case .failed = outcome { return .serverError("Editor save failed") }
            guard let saved = ManuscriptStoreAdapter.shared.manuscript(id: uuid),
                  saved.body == session.source else {
                return .serverError("Editor save readback did not match the live buffer")
            }
            ManuscriptStoreAdapter.shared.noteExternalMutation(id: uuid, structural: false)
            logInfo("Native \(method) saved \(saved.body.utf8.count) bytes and displayed in editor", category: "manuscripts")
            return .json(["status": "ok", "documentId": id, "replaced": replaced])
        default:
            return .notFound("Unknown native edit")
        }
    }
}
#endif
