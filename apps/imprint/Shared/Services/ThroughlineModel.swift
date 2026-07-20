//
//  ThroughlineModel.swift
//  imprint
//
//  Swift model for throughlines (ADR-0016): anchor map (sync ledger),
//  labeled-paragraph extraction, and the pure 4-state staleness derivation.
//
//  PARITY: this file is a deliberate transliteration of
//  `crates/imprint-service/src/throughline.rs`. The Rust side is canonical
//  (ADR-0016 D4); any behavior change must land there first and be mirrored
//  here, keeping the shared test vectors below green on both sides:
//    - item id: doc 6e2a0000-0000-0000-0000-000000000000
//                 → 2410e2a2-fa90-5132-9ab4-39b1fccf48b6
//    - paragraph hash = SHA-256 hex of the trimmed body with the label
//      token removed.
//

import CryptoKit
import Foundation

// MARK: - Anchor map (the sync ledger)

/// Ledger entry for one throughline paragraph. Hashes are SHA-256 hex
/// recorded at the last accepted sync (ADR-0016 D6).
struct ThroughlineAnchorEntry: Codable, Equatable {
    var sectionKeys: [String] = []
    var manuscriptHashes: [String: String] = [:]
    var throughlineHash: String = ""

    enum CodingKeys: String, CodingKey {
        case sectionKeys = "section_keys"
        case manuscriptHashes = "manuscript_hashes"
        case throughlineHash = "throughline_hash"
    }

    init(sectionKeys: [String] = [], manuscriptHashes: [String: String] = [:], throughlineHash: String = "") {
        self.sectionKeys = sectionKeys
        self.manuscriptHashes = manuscriptHashes
        self.throughlineHash = throughlineHash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sectionKeys = try c.decodeIfPresent([String].self, forKey: .sectionKeys) ?? []
        manuscriptHashes = try c.decodeIfPresent([String: String].self, forKey: .manuscriptHashes) ?? [:]
        throughlineHash = try c.decodeIfPresent(String.self, forKey: .throughlineHash) ?? ""
    }
}

/// The anchor map — `throughline.anchors.json` (ADR-0016 D2). Written only
/// by creation, explicit anchoring, or the accept path of a sync proposal.
struct ThroughlineAnchorMap: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var documentID: String
    var anchors: [String: ThroughlineAnchorEntry]
    var supporting: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case documentID = "document_id"
        case anchors
        case supporting
    }

    init(documentID: UUID) {
        self.version = Self.currentVersion
        self.documentID = documentID.uuidString.lowercased()
        self.anchors = [:]
        self.supporting = []
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        documentID = try c.decode(String.self, forKey: .documentID)
        anchors = try c.decodeIfPresent([String: ThroughlineAnchorEntry].self, forKey: .anchors) ?? [:]
        supporting = try c.decodeIfPresent([String].self, forKey: .supporting) ?? []
    }

    /// Parse with a version gate: newer-than-known maps are rejected rather
    /// than silently misread (the map is a ledger; misreads corrupt sync).
    static func parse(_ json: String) throws -> ThroughlineAnchorMap {
        guard let data = json.data(using: .utf8) else {
            throw ThroughlineError.parse("anchor map is not UTF-8")
        }
        let map = try JSONDecoder().decode(ThroughlineAnchorMap.self, from: data)
        guard map.version <= currentVersion else {
            throw ThroughlineError.parse(
                "anchor map version \(map.version) is newer than supported \(currentVersion)")
        }
        return map
    }

    /// Deterministic serialization (sorted keys) so ledger diffs stay clean.
    func serialize() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard let s = String(data: data, encoding: .utf8) else {
            throw ThroughlineError.parse("anchor map serialization produced non-UTF-8")
        }
        return s
    }
}

enum ThroughlineError: LocalizedError {
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .parse(let message): return "Throughline: \(message)"
        }
    }
}

// MARK: - Paragraph extraction

/// A labeled paragraph extracted from `throughline.typ`.
struct TLParagraph: Equatable {
    let label: String
    let body: String
    let contentHash: String
    let orderIndex: Int
}

enum ThroughlineText {

    /// Extract labeled paragraphs. A paragraph is a run of non-blank lines
    /// containing a `<tl-...>` label token; the first label in a run wins,
    /// duplicate labels keep first occurrence. Transliteration of
    /// `throughline.rs::extract_paragraphs` — keep in lockstep.
    static func extractParagraphs(_ source: String) -> [TLParagraph] {
        var out: [TLParagraph] = []
        var seen = Set<String>()

        var runs: [String] = []
        var current: [Substring] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    runs.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { runs.append(current.joined(separator: "\n")) }

        for run in runs {
            guard let label = findTLLabel(run), !seen.contains(label) else { continue }
            seen.insert(label)
            let token = "<\(label)>"
            var body = run
            if let range = body.range(of: token) {
                body.removeSubrange(range)
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(
                TLParagraph(
                    label: label,
                    body: body,
                    contentHash: sha256Hex(body),
                    orderIndex: out.count
                ))
        }
        return out
    }

    /// First `<tl-...>` label in a text run. Conservative character set:
    /// alphanumerics, `-`, `_`, `.` (matches the Rust side).
    static func findTLLabel(_ text: String) -> String? {
        var rest = Substring(text)
        while let open = rest.range(of: "<tl-") {
            let after = rest[rest.index(after: open.lowerBound)...]
            guard let close = after.firstIndex(of: ">") else { return nil }
            let candidate = after[..<close]
            if !candidate.isEmpty,
               candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) {
                return String(candidate)
            }
            rest = after[after.index(after: close)...]
        }
        return nil
    }

    /// SHA-256 hex digest. Interoperates with `BlobStore::sha256_hex` and
    /// the Swift `ImprintStoreAdapter.sha256Hex` — same function, same hex.
    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical section key for a heading title: lowercased, non-alphanumerics
    /// collapsed to single hyphens. The throughline feature uses these slugs as
    /// its anchor coordinates (ADR-0016 D4); the store mirror writes sections
    /// under the same keys so the Rust derivation sees matching state.
    static func sectionKey(forHeading title: String) -> String {
        var slug = ""
        var lastWasHyphen = true  // suppress leading hyphen
        for ch in title.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                slug.append(ch)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                slug.append("-")
                lastWasHyphen = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "untitled" : slug
    }
}

// MARK: - Staleness derivation (pure — ADR-0016 D5)

/// Derived assessment of one anchor. Never persisted.
struct ThroughlineAnchorAssessment: Equatable, Identifiable {
    let label: String
    let manuscriptAhead: [String]
    let throughlineAhead: Bool
    let broken: [String]
    let missingParagraph: Bool

    var id: String { label }

    /// `synced | manuscript-ahead | throughline-ahead |
    /// manuscript-ahead+throughline-ahead | broken`. Broken dominates.
    var state: String {
        if !broken.isEmpty || missingParagraph { return "broken" }
        switch (!manuscriptAhead.isEmpty, throughlineAhead) {
        case (false, false): return "synced"
        case (true, false): return "manuscript-ahead"
        case (false, true): return "throughline-ahead"
        case (true, true): return "manuscript-ahead+throughline-ahead"
        }
    }
}

enum ThroughlineDerivation {

    /// Derive the assessment of every ledger anchor. Pure; transliteration
    /// of `throughline.rs::derive_anchor_states` — keep in lockstep.
    /// `sectionHashes` maps current section keys to SHA-256 body hashes.
    static func anchorStates(
        map: ThroughlineAnchorMap,
        sectionHashes: [String: String],
        paragraphs: [TLParagraph]
    ) -> [ThroughlineAnchorAssessment] {
        let paragraphHashes = Dictionary(
            paragraphs.map { ($0.label, $0.contentHash) },
            uniquingKeysWith: { first, _ in first })

        return map.anchors.sorted(by: { $0.key < $1.key }).map { label, entry in
            var manuscriptAhead: [String] = []
            var broken: [String] = []
            for key in entry.sectionKeys {
                if let current = sectionHashes[key] {
                    if entry.manuscriptHashes[key] != current {
                        manuscriptAhead.append(key)
                    }
                } else {
                    broken.append(key)
                }
            }
            let throughlineAhead: Bool
            let missingParagraph: Bool
            if let current = paragraphHashes[label] {
                throughlineAhead = current != entry.throughlineHash
                missingParagraph = false
            } else {
                throughlineAhead = false
                missingParagraph = true
            }
            return ThroughlineAnchorAssessment(
                label: label,
                manuscriptAhead: manuscriptAhead,
                throughlineAhead: throughlineAhead,
                broken: broken,
                missingParagraph: missingParagraph
            )
        }
    }

    /// Section keys not narrated and not marked supporting (ADR-0016 D7).
    static func coverage(map: ThroughlineAnchorMap, sectionKeys: [String]) -> [String] {
        let anchored = Set(map.anchors.values.flatMap(\.sectionKeys))
        let supporting = Set(map.supporting)
        return sectionKeys.filter { !anchored.contains($0) && !supporting.contains($0) }
    }
}

// MARK: - Identity + scaffold

enum ThroughlineIdentity {

    /// Frozen UUID-v5 namespace — MUST match `THROUGHLINE_ID_NAMESPACE` in
    /// `crates/imprint-service/src/throughline.rs`.
    private static let throughlineNamespace: [UInt8] = [
        0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
        0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
    ]

    /// Frozen UUID-v5 namespace for sections — MUST match
    /// `SECTION_ID_NAMESPACE` in `crates/imprint-service/src/sections.rs`.
    private static let sectionNamespace: [UInt8] = [
        0x6f, 0x9b, 0x4b, 0x16, 0xdb, 0xb1, 0x4a, 0xea,
        0x9d, 0x52, 0x16, 0x4f, 0xa2, 0x71, 0xfb, 0xb6,
    ]

    /// Deterministic store item id for a document's throughline. True RFC
    /// 4122 UUID-v5 (SHA-1) so it matches Rust `Uuid::new_v5`. Parity
    /// vector: 6e2a0000-0000-0000-0000-000000000000 →
    /// 2410e2a2-fa90-5132-9ab4-39b1fccf48b6.
    static func itemID(documentID: UUID) -> UUID {
        uuidV5(
            namespace: throughlineNamespace,
            name: "\(documentID.uuidString.lowercased())::throughline")
    }

    /// Deterministic store item id for a (document, section-key) pair —
    /// matches `SectionStore::item_id` in Rust so both layers address the
    /// same section row.
    static func sectionItemID(documentID: UUID, sectionKey: String) -> UUID {
        uuidV5(
            namespace: sectionNamespace,
            name: "\(documentID.uuidString.lowercased())::\(sectionKey)")
    }

    /// RFC 4122 UUID-v5 (SHA-1 over namespace ‖ name).
    private static func uuidV5(namespace: [UInt8], name: String) -> UUID {
        var message = Data(namespace)
        message.append(Data(name.utf8))
        let digest = Insecure.SHA1.hash(data: message)
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        let uuid: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }

    /// Scaffold narrative for a fresh throughline — MUST match
    /// `ThroughlineStore::scaffold_source` in Rust so creation via UI, HTTP,
    /// CLI, or MCP produces the same document.
    static func scaffoldSource(title: String) -> String {
        """
        = \(title)

        // One paragraph per beat of the story. Each paragraph carries a
        // stable <tl-*> label; anchor labels to manuscript sections from
        // the throughline pane or via set_anchor.

        What we claim, in one paragraph. <tl-overview>

        """
    }

    /// Initial anchor map for a fresh throughline: every scaffold paragraph
    /// baselined (synced, no anchored sections yet).
    static func initialAnchorMap(documentID: UUID, source: String) -> ThroughlineAnchorMap {
        var map = ThroughlineAnchorMap(documentID: documentID)
        for p in ThroughlineText.extractParagraphs(source) {
            map.anchors[p.label] = ThroughlineAnchorEntry(
                sectionKeys: [],
                manuscriptHashes: [:],
                throughlineHash: p.contentHash
            )
        }
        return map
    }
}
