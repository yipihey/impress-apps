#if os(macOS)
import Foundation
import ImpressAutomation
import ImpressKit
import ImprintVerbsFFI
import PublicationManagerCore

/// Calls imprint's existing app-state handlers without a loopback HTTP request.
private final class NativeImprintHost: ImprintVerbHost, @unchecked Sendable {
    private let router = ImprintHTTPRouter()

    func invoke(method: String, argsJson: String) async -> NativeReply {
        guard let data = argsJson.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return failure(400, "Invalid native arguments")
        }
        func string(_ key: String) -> String? { args[key] as? String }
        func documentPath(_ suffix: String = "") -> String? {
            guard let id = string("document_id"), UUID(uuidString: id) != nil else { return nil }
            return "/api/documents/\(id)\(suffix)"
        }
        func commentPath() -> String? {
            guard let id = string("comment_id"), UUID(uuidString: id) != nil else { return nil }
            return "/api/comments/\(id)"
        }
        var verb = "GET"
        var path: String?
        var query: [String: String] = [:]
        var body: [String: Any]?
        switch method {
        case "status": path = "/api/status"
        case "get_logs":
            path = "/api/logs"
            if let n = args["limit"] as? UInt32 { query["limit"] = String(n) }
            if let n = args["limit"] as? Int { query["limit"] = String(n) }
            query["level"] = string("level")
            query["category"] = string("category")
        case "create_document":
            let formatName = string("format") ?? "typst"
            guard let format = ManuscriptFormat(rawValue: formatName) else {
                return failure(400, "Unsupported manuscript format")
            }
            let title = string("title") ?? "Untitled"
            return await MainActor.run {
                logInfo("Native create_document requested (format \(formatName))", category: "manuscripts")
                guard let actualPath = RustStoreAdapter.shared.databaseLocation,
                      URL(fileURLWithPath: actualPath).resolvingSymlinksInPath().path
                        == URL(fileURLWithPath: SharedWorkspace.databasePath).resolvingSymlinksInPath().path else {
                    return failure(500, "Manuscript store is not the requested workspace")
                }
                do {
                    let id = try ManuscriptStoreAdapter.shared.createManuscript(title: title, format: format)
                    logInfo("Native create_document saved manuscript \(id)", category: "manuscripts")
                    guard ManuscriptStoreAdapter.shared.manuscript(id: id) != nil else {
                        return failure(500, "Created manuscript could not be read back")
                    }
                    logInfo("Native create_document displayed manuscript \(id)", category: "manuscripts")
                    return success(["status": "ok", "id": id.uuidString])
                } catch {
                    return failure(500, "Unable to create manuscript")
                }
            }
        case "update_document":
            verb = "POST"; path = documentPath("/update")
            body = [:]
            if let title = string("title") { body?["title"] = title }
        case "update_metadata":
            verb = "PUT"; path = documentPath("/metadata")
            guard let raw = string("metadata_json"), let value = raw.data(using: .utf8),
                  let metadata = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any] else {
                return failure(400, "metadata_json must be a JSON object")
            }
            body = metadata
        case "get_content": path = documentPath("/content")
        case "insert_text":
            verb = "POST"; path = documentPath("/insert")
            body = ["position": args["offset"] ?? 0, "text": string("text") ?? ""]
        case "delete_text":
            verb = "POST"; path = documentPath("/delete")
            guard let start = args["offset"] as? Int, let length = args["length"] as? Int else {
                return failure(400, "Missing delete range")
            }
            body = ["start": start, "end": start + length]
        case "replace":
            verb = "POST"; path = documentPath("/replace")
            body = ["search": string("find") ?? "", "replacement": string("replace") ?? "", "all": true]
        case "get_pdf": path = documentPath("/pdf")
        case "get_bibliography": path = documentPath("/bibliography")
        case "list_comments": path = documentPath("/comments")
        case "create_comment":
            verb = "POST"; path = documentPath("/comments")
            guard let id = string("document_id"), let content = string("body") else {
                return failure(400, "Missing document or comment body")
            }
            var start = 0
            var end = 0
            if let anchor = string("anchor"), !anchor.isEmpty {
                let contentResponse = await router.invokeNativeVerb(
                    method: "get_content", id: id,
                    request: HTTPRequest(method: "GET", path: "/api/documents/\(id)/content"))
                guard contentResponse.status == 200,
                      let object = try? JSONSerialization.jsonObject(with: contentResponse.body) as? [String: Any],
                      let source = object["source"] as? String,
                      let range = source.range(of: anchor) else {
                    return failure(400, "Anchor text not found in document")
                }
                // Comment TextRange is an editor NSRange (UTF-16). The
                // comment store converts it to persistent UTF-8 bytes later.
                start = source[..<range.lowerBound].utf16.count
                end = start + anchor.utf16.count
            }
            body = ["content": content, "start": start, "end": end]
        case "update_comment":
            verb = "PATCH"; path = commentPath(); body = [:]
            if let text = string("body") { body?["content"] = text }
            if let status = string("status") {
                switch status {
                case "open": body?["isResolved"] = false
                case "resolved", "accepted", "rejected": body?["isResolved"] = true
                default: return failure(400, "Unsupported comment status")
                }
            }
        case "delete_comment": verb = "DELETE"; path = commentPath()
        default: return failure(404, "Unknown imprint native method")
        }
        guard let path else { return failure(400, "Invalid identifier") }
        let jsonBody: String?
        if let body {
            guard let bytes = try? JSONSerialization.data(withJSONObject: body),
                  let text = String(data: bytes, encoding: .utf8) else {
                return failure(400, "Invalid request body")
            }
            jsonBody = text
        } else {
            jsonBody = nil
        }
        let targetID = string("document_id") ?? string("comment_id")
        let response = await router.invokeNativeVerb(
            method: method, id: targetID,
            request: HTTPRequest(method: verb, path: path, queryParams: query, body: jsonBody))
        if response.status >= 300 {
            return NativeReply(status: UInt16(response.status), bodyJson: String(data: response.body, encoding: .utf8)
                ?? "{\"status\":\"error\",\"error\":\"Native response is not UTF-8\"}")
        }
        if method == "get_pdf", response.headers["Content-Type"]?.hasPrefix("application/pdf") == true {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("imprint-native-\(UUID().uuidString).pdf")
            do {
                try response.body.write(to: file, options: .atomic)
                return success(["ok": true, "path": file.path, "byte_size": response.body.count, "messages": []])
            } catch {
                return failure(500, "Unable to save compiled PDF")
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return failure(500, "Native handler returned non-JSON")
        }
        if method == "get_logs" {
            let entries = (object["data"] as? [String: Any])?["entries"] ?? object["entries"] ?? []
            return success(["entries": entries])
        }
        if method == "get_bibliography" {
            let citations = object["citations"] as? [[String: String]] ?? []
            return success(["bibtex": citations.compactMap { $0["bibtex"] }.joined(separator: "\n\n")])
        }
        if method == "list_comments" || method == "create_comment" {
            var normalized = object
            if let list = object["comments"] as? [[String: Any]] {
                normalized["comments"] = list.map(normalizeComment)
            }
            if let comment = object["comment"] as? [String: Any] {
                normalized["comment"] = normalizeComment(comment)
            }
            return success(normalized)
        }
        return success(object)
    }

    private func normalizeComment(_ source: [String: Any]) -> [String: Any] {
        var item = source
        item["body"] = source["content"]
        item["status"] = (source["isResolved"] as? Bool == true) ? "resolved" : "open"
        return item
    }

    private func success(_ object: [String: Any]) -> NativeReply {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return NativeReply(status: 200, bodyJson: String(data: data, encoding: .utf8) ?? "{}")
    }

    private func failure(_ status: UInt16, _ message: String) -> NativeReply {
        success(["status": "error", "error": message]).withStatus(status)
    }
}

private extension NativeReply {
    func withStatus(_ status: UInt16) -> NativeReply {
        NativeReply(status: status, bodyJson: bodyJson)
    }
}

enum ImprintNativeVerbs {
    static func install() throws {
        if let error = installNativeHost(databasePath: SharedWorkspace.databasePath, host: NativeImprintHost()) {
            throw NativeInstallFailure(message: error)
        }
        VerbAutomationRoutes.registerDomainDispatcher(
            services: ["imprint-app-service", "imprint-manuscript-service", "imprint-text-service",
                       "imprint-throughline-service", "imprint-project-service"]
        ) { name, argsJSON, callerJSON in
            let result = await dispatchVerbAsync(name: name, argsJson: argsJSON, callerJson: callerJSON)
            return VerbDispatchResponse(status: Int(result.status), bodyJSON: result.bodyJson)
        }
    }
}

private struct NativeInstallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
#endif
