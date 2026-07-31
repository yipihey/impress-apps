// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): pure encoding
// (Foundation + ImpressRustCore). No store handle, no I/O.
//
//  ChassisPayloadRow.swift
//  PublicationManagerCore
//
//  ADR-0022 D9 finding 1: the one place that turns a chassis payload struct
//  into a `SharedItemUpsert`. `MailStoreWriter`, `FigureStoreWriter` and
//  `AgentStoreWriter` all route through it, so the two rules below are stated
//  once instead of three times.
//
//  RULE 1 — the id is LOWERCASED at the boundary. The store's canonical id form
//  is lowercase and payload refs are matched by string equality, while Swift's
//  `UUID().uuidString` is uppercase (imbib CLAUDE.md invariant).
//
//  RULE 2 — nil fields are OMITTED, not written as `null`. Swift's synthesized
//  `Encodable` uses `encodeIfPresent` for Optionals, which is exactly the shape
//  the readers decode defensively for ("Stage-0 rows omit empty arrays and
//  optional ids"). A row built here is therefore byte-shaped like a row from a
//  production writer that had nothing to say about a field, not like one that
//  said "nothing".
//

import Foundation
import ImpressRustCore

enum ChassisPayloadRow {

    /// The encoder every chassis row builder shares. `sortedKeys` so a fixture
    /// row is byte-stable across runs and platforms — a seed that hashes
    /// differently on each launch is a seed that cannot be diffed.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Encode a payload struct to its JSON text, using ITS `CodingKeys` and
    /// nothing else. `"{}"` on the encode failure that cannot happen for these
    /// types (all fields are `String`/`Int`/`[String]` optionals) — the readers
    /// treat an undecodable payload as an absent one, so an empty object is the
    /// honest degradation rather than a crash inside a fixture.
    static func payloadJSON<Payload: Encodable>(_ payload: Payload) -> String {
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// A `SharedItemUpsert` carrying `payload`'s own field names.
    static func upsert<Payload: Encodable>(
        id: String,
        schemaRef: String,
        parentID: String?,
        payload: Payload,
        createdMs: Int64? = nil,
        isRead: Bool? = nil,
        isStarred: Bool? = nil,
        tags: [String] = []
    ) -> SharedItemUpsert {
        SharedItemUpsert(
            id: id.lowercased(),
            schemaRef: schemaRef,
            payloadJson: payloadJSON(payload),
            parentId: parentID?.lowercased(),
            tags: tags,
            createdMs: createdMs,
            isRead: isRead,
            isStarred: isStarred)
    }
}
