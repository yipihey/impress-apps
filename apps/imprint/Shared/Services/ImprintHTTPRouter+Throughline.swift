//
//  ImprintHTTPRouter+Throughline.swift
//  imprint
//
//  Throughline HTTP routes (ADR-0016). Thin wrappers over the shared-store
//  mirror — the same rows the Rust `ImprintThroughlineService` reads — so
//  agents get identical state over HTTP, MCP, and CLI.
//
//  Routes (dispatched from `ImprintHTTPRouter.route`):
//    GET    /api/documents/{id}/throughline           → mirror record
//    GET    /api/documents/{id}/throughline/anchors   → derived anchor states
//    GET    /api/documents/{id}/throughline/coverage  → uncovered sections
//    POST   /api/documents/{id}/throughline           → create (explicit opt-in)
//    PATCH  /api/documents/{id}/throughline/anchors   → set/remove/mark-supporting
//
//  Opt-in (ADR-0016 D1): GETs on a non-opted document return 404 with
//  `has_throughline: false`; nothing is created implicitly.
//

import Foundation
import ImpressAutomation
import ImpressLogging
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

extension ImprintHTTPRouter {

    // MARK: - Mirror row access

    /// Parsed throughline mirror payload (field names match
    /// `imprint_service::throughline::ThroughlinePayload`).
    struct ThroughlineMirror {
        let itemID: String
        let documentID: UUID
        let title: String
        let source: String
        let anchorsJSON: String
        let paragraphCount: Int

        var anchorMap: ThroughlineAnchorMap? {
            try? ThroughlineAnchorMap.parse(anchorsJSON)
        }
    }

    private func readThroughlineMirror(documentID: UUID) -> ThroughlineMirror? {
        let itemID = ThroughlineIdentity.itemID(documentID: documentID).uuidString.lowercased()
        guard let row = try? ManuscriptStoreAdapter.shared.sharedStore.getItem(id: itemID),
              let data = row.payloadJson.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ThroughlineMirror(
            itemID: itemID,
            documentID: documentID,
            title: payload["title"] as? String ?? "",
            source: payload["body_content"] as? String ?? "",
            anchorsJSON: payload["anchor_map_json"] as? String ?? "{}",
            paragraphCount: payload["paragraph_count"] as? Int ?? 0
        )
    }

    private func writeThroughlineMirror(
        documentID: UUID, title: String, source: String, anchorsJSON: String
    ) throws {
        let paragraphs = ThroughlineText.extractParagraphs(source)
        let payload: [String: Any] = [
            "title": title,
            "document_ref": documentID.uuidString.lowercased(),
            "body_content": source,
            "anchor_map_json": anchorsJSON,
            "content_hash": ThroughlineText.sha256Hex(source),
            "anchor_map_hash": ThroughlineText.sha256Hex(anchorsJSON),
            "paragraph_count": paragraphs.count,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let itemID = ThroughlineIdentity.itemID(documentID: documentID).uuidString.lowercased()
        try ManuscriptStoreAdapter.shared.sharedStore.upsertItem(
            id: itemID,
            schemaRef: "throughline",
            payloadJson: String(data: data, encoding: .utf8) ?? "{}"
        )
    }

    /// Current section hashes for a document from the store mirror
    /// (`section_key` → SHA-256 of body; offloaded bodies use the stored
    /// CAS digest, matching Rust `section_body_hash`).
    private func storeSectionState(documentID: UUID) -> (hashes: [String: String], keys: [String]) {
        let docID = documentID.uuidString.lowercased()
        var hashes: [String: String] = [:]
        var keys: [String] = []
        let rows = (try? ManuscriptStoreAdapter.shared.sharedStore.queryBySchema(
            schemaRef: "manuscript-section", limit: 500, offset: 0)) ?? []
        for row in rows {
            guard let data = row.payloadJson.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (payload["document_id"] as? String)?.lowercased() == docID,
                  let key = payload["section_key"] as? String, !key.isEmpty else { continue }
            let hash = (payload["content_hash"] as? String)
                ?? ThroughlineText.sha256Hex(payload["body"] as? String ?? "")
            hashes[key] = hash
            keys.append(key)
        }
        return (hashes, keys)
    }

    // MARK: - GET handlers

    /// GET /api/documents/{id}/throughline
    func handleGetThroughline(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }
        guard let mirror = readThroughlineMirror(documentID: uuid) else {
            return .json(["has_throughline": false, "document_id": id], status: 404)
        }
        return .json([
            "has_throughline": true,
            "item_id": mirror.itemID,
            "document_id": mirror.documentID.uuidString.lowercased(),
            "title": mirror.title,
            "source": mirror.source,
            "anchor_map": (try? JSONSerialization.jsonObject(
                with: Data(mirror.anchorsJSON.utf8))) ?? [:],
            "paragraph_count": mirror.paragraphCount,
        ])
    }

    /// GET /api/documents/{id}/throughline/anchors — derived states
    /// (ADR-0016 D5; derivation never writes).
    func handleGetThroughlineAnchors(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }
        guard let mirror = readThroughlineMirror(documentID: uuid),
              let map = mirror.anchorMap else {
            return .json(["has_throughline": false, "anchors": []], status: 404)
        }
        let (hashes, _) = storeSectionState(documentID: uuid)
        let paragraphs = ThroughlineText.extractParagraphs(mirror.source)
        let states = ThroughlineDerivation.anchorStates(
            map: map, sectionHashes: hashes, paragraphs: paragraphs)
        return .json([
            "has_throughline": true,
            "anchors": states.map { a in
                [
                    "label": a.label,
                    "state": a.state,
                    "manuscript_ahead": a.manuscriptAhead,
                    "throughline_ahead": a.throughlineAhead,
                    "broken": a.broken,
                    "missing_paragraph": a.missingParagraph,
                ] as [String: Any]
            },
        ])
    }

    /// GET /api/documents/{id}/throughline/coverage (ADR-0016 D7).
    func handleGetThroughlineCoverage(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }
        guard let mirror = readThroughlineMirror(documentID: uuid),
              let map = mirror.anchorMap else {
            return .json(["has_throughline": false, "uncovered_section_keys": []], status: 404)
        }
        let (_, keys) = storeSectionState(documentID: uuid)
        let uncovered = ThroughlineDerivation.coverage(map: map, sectionKeys: keys)
        return .json([
            "has_throughline": true,
            "uncovered_section_keys": uncovered,
            "supporting": map.supporting,
        ])
    }

    // MARK: - Mutation handlers

    /// POST /api/documents/{id}/throughline — explicit opt-in creation.
    /// 409 when one already exists (activation is deliberate, never upsert).
    func handleCreateThroughline(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }
        if readThroughlineMirror(documentID: uuid) != nil {
            return .json(["error": "document already has a throughline"], status: 409)
        }
        let json = (request.body?.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let storeTitle = await MainActor.run {
            ManuscriptStoreAdapter.shared.manuscript(id: uuid)?.title
        }
        let title = (json["title"] as? String) ?? storeTitle ?? "Untitled"
        logInfo("HTTP create throughline doc=\(id)", category: "throughline")
        let source = ThroughlineIdentity.scaffoldSource(title: title)
        let map = ThroughlineIdentity.initialAnchorMap(documentID: uuid, source: source)
        guard let anchorsJSON = try? map.serialize() else {
            return .json(["error": "anchor map serialization failed"], status: 500)
        }
        do {
            try writeThroughlineMirror(
                documentID: uuid, title: title, source: source, anchorsJSON: anchorsJSON)
        } catch {
            return .json(["error": "store write failed: \(error.localizedDescription)"], status: 500)
        }
        logInfo("HTTP throughline created doc=\(id)", category: "throughline")
        return await handleGetThroughline(id: id)
    }

    /// DELETE /api/documents/{id}/throughline — remove the store mirror
    /// (deactivation parity with the pane's Remove Throughline; the
    /// sidecar files, if any, disappear on the document's next save).
    func handleDeleteThroughline(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }
        guard let mirror = readThroughlineMirror(documentID: uuid) else {
            return .json(["has_throughline": false, "deleted": false], status: 404)
        }
        do {
            try ManuscriptStoreAdapter.shared.sharedStore.deleteItem(id: mirror.itemID)
        } catch {
            return .json(["error": "store delete failed: \(error.localizedDescription)"], status: 500)
        }
        logInfo("HTTP throughline deleted doc=\(id)", category: "throughline")
        return .json(["has_throughline": false, "deleted": true])
    }

    /// PATCH /api/documents/{id}/throughline/anchors
    /// Body: {"action": "set" | "remove" | "mark-supporting",
    ///        "label": …, "section_keys": […], "section_key": …,
    ///        "supporting": Bool}
    /// `set` baselines the ledger at current store state (a deliberate
    /// anchoring act, equivalent to accepting a sync — ADR-0016 D6).
    func handlePatchThroughlineAnchors(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }
        guard let mirror = readThroughlineMirror(documentID: uuid),
              var map = mirror.anchorMap else {
            return .json(["has_throughline": false], status: 404)
        }
        guard let body = request.body, let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            return .badRequest("Body must be JSON with an 'action' field")
        }

        switch action {
        case "set":
            guard let label = json["label"] as? String,
                  let sectionKeys = json["section_keys"] as? [String] else {
                return .badRequest("'set' requires 'label' and 'section_keys'")
            }
            let paragraphs = ThroughlineText.extractParagraphs(mirror.source)
            guard let paragraph = paragraphs.first(where: { $0.label == label }) else {
                return .badRequest("no paragraph labeled <\(label)> in throughline")
            }
            let (hashes, _) = storeSectionState(documentID: uuid)
            var manuscriptHashes: [String: String] = [:]
            for key in sectionKeys {
                guard let h = hashes[key] else {
                    return .badRequest("unknown section key '\(key)'")
                }
                manuscriptHashes[key] = h
            }
            map.anchors[label] = ThroughlineAnchorEntry(
                sectionKeys: sectionKeys,
                manuscriptHashes: manuscriptHashes,
                throughlineHash: paragraph.contentHash
            )
            map.supporting.removeAll { sectionKeys.contains($0) }

        case "remove":
            guard let label = json["label"] as? String else {
                return .badRequest("'remove' requires 'label'")
            }
            map.anchors.removeValue(forKey: label)

        case "mark-supporting":
            guard let key = json["section_key"] as? String else {
                return .badRequest("'mark-supporting' requires 'section_key'")
            }
            let supporting = json["supporting"] as? Bool ?? true
            map.supporting.removeAll { $0 == key }
            if supporting {
                map.supporting.append(key)
                map.supporting.sort()
            }

        default:
            return .badRequest("Unknown action '\(action)'")
        }

        guard let anchorsJSON = try? map.serialize() else {
            return .json(["error": "anchor map serialization failed"], status: 500)
        }
        do {
            try writeThroughlineMirror(
                documentID: uuid, title: mirror.title, source: mirror.source,
                anchorsJSON: anchorsJSON)
        } catch {
            return .json(["error": "store write failed: \(error.localizedDescription)"], status: 500)
        }
        logInfo("HTTP anchors '\(action)' applied doc=\(id)", category: "throughline")
        return await handleGetThroughlineAnchors(id: id)
    }
}
