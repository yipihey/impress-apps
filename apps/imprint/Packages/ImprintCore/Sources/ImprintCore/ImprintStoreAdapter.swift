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
import OSLog
import CommonCrypto

private let logger = Logger(subsystem: "com.imbib.imprint", category: "shared-store")

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

    // MARK: - Initialisation

    private init() {
        setup()
    }

    private func setup() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            isReady = true
            logger.info("ImprintStoreAdapter ready at \(self.databasePath, privacy: .public)")
        } catch {
            isReady = false
            logger.warning("ImprintStoreAdapter: could not open shared workspace — \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Mutation Signal

    /// Signal that the store was mutated.  Bumps `dataVersion` so observers update.
    public func didMutate() {
        dataVersion += 1
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
            logger.debug("ImprintStoreAdapter.storeSection skipped — adapter not ready")
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

        // TODO: Call impress-core UniFFI to upsert this item.
        //
        // The UniFFI bindings for impress-core's SqliteItemStore are not yet
        // generated for Swift.  When they are, replace the log below with:
        //
        //   let store = try SqliteItemStore.open(path: databasePath)
        //   try store.upsert(Item(
        //       id: UUID(uuidString: sectionID) ?? UUID(),
        //       schema: "manuscript-section",
        //       payload: payload,
        //       ...
        //   ))
        //
        // For now the method is a well-typed stub so call-sites can be wired
        // correctly before the FFI layer is ready.
        logger.info(
            "ImprintStoreAdapter.storeSection: sectionID=\(sectionID, privacy: .public) " +
            "title='\(title, privacy: .private)' wordCount=\(wordCount) " +
            "docID=\(documentID ?? "nil", privacy: .public) " +
            "contentAddressed=\(contentHash != nil)"
        )

        didMutate()
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
            logger.info("ImprintStoreAdapter: stored content-addressed body at \(hash, privacy: .public)")
        } catch {
            logger.warning("ImprintStoreAdapter: failed to write content-addressed body \(hash, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
