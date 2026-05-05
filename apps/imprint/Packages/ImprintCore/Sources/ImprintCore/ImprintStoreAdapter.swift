//
//  ImprintStoreAdapter.swift
//  ImprintCore
//
//  Stores imprint manuscript sections in the shared impress-core SQLite store
//  as `manuscript-section@1.0.0` items.
//
//  Pattern mirrors imbib's RustStoreAdapter: a @MainActor @Observable singleton
//  that bumps `dataVersion` on every mutation so SwiftUI views update automatically.
//
//  Usage
//  -----
//  Wherever imprint saves Typst document content, call:
//
//      Task { @MainActor in
//          ImprintStoreAdapter.shared.storeSection(
//              sectionID: doc.id.uuidString,
//              title: doc.title,
//              body: doc.source,
//              sectionType: nil,
//              orderIndex: 0,
//              documentID: doc.id.uuidString
//          )
//      }
//
//  The adapter is non-fatal: if the shared workspace is unavailable the call
//  is a silent no-op so document saving is never blocked.
//
//  Payload schema (manuscript-section@1.0.0)
//  -----------------------------------------
//  | field         | type    | notes                                         |
//  |---------------|---------|-----------------------------------------------|
//  | title         | String  | required – section heading                    |
//  | body          | String  | Typst source; empty when content_hash is set  |
//  | section_type  | String  | e.g. "introduction", "methods", "results"     |
//  | order_index   | Int     | zero-based position within the document       |
//  | word_count    | Int     | approximate word count (agent-readable)       |
//  | document_id   | String  | UUID string of the parent ImprintDocument     |
//  | content_hash  | String  | SHA-256 hex for bodies > 64 KiB               |
//

import Foundation
import ImpressKit
import ImpressLogging
import ImpressStoreKit
import OSLog
import CommonCrypto
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

private let logger = Logger(subsystem: "com.imprint.app", category: "shared-store")

/// Large-body threshold: sections whose body exceeds this size are stored
/// content-addressed rather than inline.
private let largeBodyThreshold = 65_536  // 64 KiB

// MARK: - ImprintStoreAdapter

/// Stores imprint manuscript sections in the shared impress-core store
/// as `manuscript-section@1.0.0` items.
///
/// The Typst body content is stored in the `body` field.  For large sections
/// (body > 64 KiB) the content is written to a content-addressed file at
/// `~/.local/share/impress/content/{sha256}` and only the hash is stored,
/// keeping the SQLite row small.
@MainActor
@Observable
public final class ImprintStoreAdapter {

    // MARK: - Shared Instance

    public static let shared = ImprintStoreAdapter()

    // MARK: - Observable State

    /// Bumped on every mutation.  Views can observe this to trigger updates.
    public private(set) var dataVersion: Int = 0

    /// Whether the adapter successfully opened the shared workspace.
    public private(set) var isReady = false

    // MARK: - Paths

    /// Path to the shared impress-core SQLite database.
    public var databasePath: String {
        SharedWorkspace.databaseURL.path
    }

    /// Content-addressed storage directory for large section bodies.
    ///
    /// Files are named `{sha256}` (no extension) and contain raw UTF-8 Typst source.
    public var contentStoreDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/impress/content", isDirectory: true)
    }

    // MARK: - Shared Store

    #if canImport(ImpressRustCore)
    private var store: SharedStore?
    #endif

    /// Sections we've already written through `storeSection` this session.
    /// Used to classify mutations: first write of an id is `.structural`
    /// (new section), subsequent writes are body edits → `.otherField`.
    /// Snapshot maintainers that only care about add/remove can ignore
    /// the cheap field events.
    private var knownSectionIDs: Set<String> = []

    // MARK: - Initialisation

    private init() {
        setup()
    }

    private func setup() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            #if canImport(ImpressRustCore)
            store = try SharedStore.open(path: databasePath)
            #endif
            isReady = true
            logger.infoCapture("ImprintStoreAdapter ready at \(self.databasePath)", category: "shared-store")
        } catch {
            isReady = false
            logger.warningCapture("ImprintStoreAdapter: could not open shared workspace — \(error.localizedDescription)", category: "shared-store")
        }
    }

    // MARK: - Mutation Signal

    /// Signal that the store was mutated.  Bumps `dataVersion` so observers update.
    ///
    /// Call sites classify the mutation so snapshot maintainers can do
    /// O(k) updates instead of full rebuilds:
    /// - `structural: true` — shape of the item graph changed (new/deleted section)
    /// - `structural: false` with `affectedIDs` + `kind` — an existing item's
    ///   fields changed (body edit, metadata update)
    public func didMutate(
        structural: Bool = true,
        affectedIDs: Set<UUID>? = nil,
        kind: MutationKind? = nil
    ) {
        dataVersion += 1
        ImprintImpressStore.shared.postMutation(
            structural: structural,
            affectedIDs: affectedIDs,
            kind: kind
        )
    }

    // MARK: - Store Section

    /// Store a manuscript section in the shared store.
    ///
    /// - Parameters:
    ///   - sectionID:   Stable identifier for this section (UUID string). Used as the
    ///                  item's stable external key so repeated saves are idempotent.
    ///   - title:       Section heading (required by schema).
    ///   - body:        Full Typst source of the section.  If the body exceeds
    ///                  `largeBodyThreshold` bytes it is stored content-addressed and
    ///                  only the SHA-256 hash is kept in the payload.
    ///   - sectionType: Semantic type string, e.g. "introduction", "methods".
    ///   - orderIndex:  Zero-based position within the document.
    ///   - documentID:  UUID string of the parent `ImprintDocument`.
    public func storeSection(
        sectionID: String,
        title: String,
        body: String,
        sectionType: String?,
        orderIndex: Int?,
        documentID: String?
    ) {
        guard isReady else {
            logger.debugCapture("ImprintStoreAdapter.storeSection skipped — adapter not ready", category: "shared-store")
            return
        }

        let wordCount = countWords(in: body)

        // Decide whether to inline the body or store it content-addressed.
        let (inlineBody, contentHash): (String, String?)
        if body.utf8.count > largeBodyThreshold {
            let hash = sha256Hex(body)
            writeContentAddressed(body: body, hash: hash)
            inlineBody = ""
            contentHash = hash
        } else {
            inlineBody = body
            contentHash = nil
        }

        // Build the JSON payload that matches manuscript-section@1.0.0 schema.
        var payload: [String: Any] = [
            "title": title,
            "body": inlineBody,
            "word_count": wordCount
        ]
        if let sectionType = sectionType { payload["section_type"] = sectionType }
        if let orderIndex = orderIndex   { payload["order_index"] = orderIndex }
        if let documentID = documentID   { payload["document_id"] = documentID }
        if let hash = contentHash        { payload["content_hash"] = hash }

        guard let payloadJSON = try? JSONSerialization.data(withJSONObject: payload),
              let payloadString = String(data: payloadJSON, encoding: .utf8) else {
            logger.warningCapture("ImprintStoreAdapter.storeSection: failed to encode payload for \(sectionID)", category: "shared-store")
            return
        }

        #if canImport(ImpressRustCore)
        do {
            try store?.upsertItem(id: sectionID, schemaRef: "manuscript-section", payloadJson: payloadString)
            logger.infoCapture(
                "ImprintStoreAdapter.storeSection: synced \(sectionID) '\(title)' wordCount=\(wordCount)", category: "shared-store"
            )
        } catch {
            logger.errorCapture(
                "ImprintStoreAdapter.storeSection: upsert failed for \(sectionID) — \(error.localizedDescription)", category: "shared-store"
            )
        }
        #else
        logger.infoCapture(
            "ImprintStoreAdapter.storeSection: sectionID=\(sectionID) " +
            "title='\(title)' wordCount=\(wordCount) " +
            "docID=\(documentID ?? "nil") " +
            "contentAddressed=\(contentHash != nil) (ImpressRustCore not linked)", category: "shared-store"
        )
        #endif

        // First write of a given section id is a structural change (new
        // section appears in the graph); subsequent writes are body
        // edits on an existing section.
        let isNew = knownSectionIDs.insert(sectionID).inserted
        if isNew {
            didMutate(structural: true)
        } else if let uuid = UUID(uuidString: sectionID) {
            didMutate(structural: false, affectedIDs: [uuid], kind: .otherField)
        } else {
            didMutate(structural: true)
        }
    }

    // MARK: - Citation Usage

    /// Upsert a `citation-usage@1.0.0` record. Writes are keyed by the
    /// deterministic record id (`citationUsageID` below) so repeated
    /// writes of the same `(section, citeKey)` pair are idempotent.
    ///
    /// The record links a manuscript section to the paper it cites.
    /// Imbib consumes these records to surface a "papers cited in your
    /// writing" view without needing to parse imprint source files.
    public func upsertCitationUsage(
        sectionID: String,
        documentID: String?,
        citeKey: String,
        paperID: String?,
        firstCitedAt: Date,
        lastSeenAt: Date
    ) {
        guard isReady else { return }
        let recordID = Self.citationUsageID(sectionID: sectionID, citeKey: citeKey)
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "cite_key": citeKey,
            "section_id": sectionID,
            "first_cited": iso.string(from: firstCitedAt),
            "last_seen": iso.string(from: lastSeenAt)
        ]
        if let documentID { payload["document_id"] = documentID }
        if let paperID, !paperID.isEmpty { payload["paper_id"] = paperID }

        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let payloadString = String(data: json, encoding: .utf8) else {
            return
        }

        #if canImport(ImpressRustCore)
        do {
            try store?.upsertItem(id: recordID, schemaRef: "citation-usage", payloadJson: payloadString)
            if let recordUUID = UUID(uuidString: recordID) {
                didMutate(structural: false, affectedIDs: [recordUUID], kind: .otherField)
            } else {
                didMutate(structural: true)
            }
        } catch {
            logger.warningCapture(
                "upsertCitationUsage failed for \(citeKey)@\(sectionID): \(error.localizedDescription)",
                category: "shared-store"
            )
        }
        #endif
    }

    /// Delete a previously-written citation-usage record.
    public func deleteCitationUsage(sectionID: String, citeKey: String) {
        guard isReady else { return }
        let recordID = Self.citationUsageID(sectionID: sectionID, citeKey: citeKey)
        #if canImport(ImpressRustCore)
        do {
            try store?.deleteItem(id: recordID)
            didMutate(structural: true)
        } catch {
            logger.debugCapture(
                "deleteCitationUsage ignored for \(citeKey)@\(sectionID): \(error.localizedDescription)",
                category: "shared-store"
            )
        }
        #endif
    }

    /// Deterministic UUID for a `(sectionID, citeKey)` pair. Used as
    /// the citation-usage record id so repeated upserts are idempotent.
    /// Uses a UUIDv5-style hash over a namespace + name string, but
    /// degraded to a simple SHA-256 truncation since CommonCrypto
    /// doesn't ship a v5 primitive. The output is deterministic and
    /// collision-resistant for realistic citation volumes.
    static func citationUsageID(sectionID: String, citeKey: String) -> String {
        let composed = "citation-usage:\(sectionID):\(citeKey)"
        guard let data = composed.data(using: .utf8) else { return UUID().uuidString }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        // Take the first 16 bytes and format as a UUID string. Set the
        // version/variant bits so the result parses as a valid UUID.
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let s = Array(hex)
        return "\(String(s[0..<8]))-\(String(s[8..<12]))-\(String(s[12..<16]))-\(String(s[16..<20]))-\(String(s[20..<32]))"
    }

    // MARK: - Content-Addressed Storage

    /// Write `body` to the content-addressed store under `hash`.
    ///
    /// The file is written atomically.  Existing files with the same hash are
    /// not overwritten (they are immutable by definition).
    private func writeContentAddressed(body: String, hash: String) {
        let dir = contentStoreDirectory
        let fileURL = dir.appendingPathComponent(hash)

        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            return  // already stored
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = body.data(using: .utf8) else { return }
            try data.write(to: fileURL, options: .atomicWrite)
            logger.infoCapture("ImprintStoreAdapter: stored content-addressed body at \(hash)", category: "shared-store")
        } catch {
            logger.warningCapture("ImprintStoreAdapter: failed to write content-addressed body \(hash): \(error.localizedDescription)", category: "shared-store")
        }
    }

    // MARK: - Helpers

    /// Approximate word count (split on whitespace).
    private func countWords(in text: String) -> Int {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    /// SHA-256 hex digest of a UTF-8 string.
    private func sha256Hex(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
