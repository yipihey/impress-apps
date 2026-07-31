//
//  ManuscriptStoreAdapter+External.swift
//  imprint
//
//  ADR-0023 D4 / W3 — the store verbs for reference-in-place manuscripts.
//
//  Three verbs and one rule. The rule is that every write here REPLACES the
//  snapshot from the file rather than merging anything into it, so the store
//  can never hold a body the file does not (see `ExternalManuscriptSource`'s
//  header for why that is the whole safety argument).
//
//  `upsertExternal` is deliberately NOT `createManuscript` + `setBody`:
//  `setBody` stamps `body_modified_at` as though a human typed, and an external
//  manuscript has no edit history of its own — its history is the file's. The
//  timestamp this path writes is `external_source.read_at`, which says what it
//  means: when imprint last LOOKED.
//

import Foundation
import ImpressLogging
import ImpressRustCore
import OSLog
import PublicationManagerCore

public extension ManuscriptStoreAdapter {

    /// What one external file's ingest did.
    struct ExternalUpsertOutcome: Sendable, Equatable {
        public let id: UUID
        /// True when this pass minted the row; false when it refreshed one.
        public let created: Bool
        /// True when the file's bytes had moved since the last snapshot.
        public let contentChanged: Bool
    }

    /// Index one file as a manuscript, or refresh the row that already indexes
    /// it. **Never writes the file.**
    @discardableResult
    func upsertExternalManuscript(
        path: String,
        folderName: String? = nil,
        watchedFolderID: String? = nil,
        watchedFileID: String? = nil
    ) throws -> ExternalUpsertOutcome {
        let snapshot = try ExternalManuscriptReader.read(at: path)
        let id = ExternalManuscriptSource.manuscriptID(forPath: path)
        let existing = manuscript(id: id)
        let previousHash = existing?.externalSource?.contentHash

        let source = ExternalManuscriptSource(
            path: URL(fileURLWithPath: path).standardizedFileURL.path,
            contentHash: snapshot.contentHash,
            sizeBytes: snapshot.sizeBytes,
            watchedFileID: watchedFileID,
            watchedFolderID: watchedFolderID,
            folderName: folderName,
            readAt: Date(),
            state: .present)

        // The whole row, written in one upsert. `current_revision_ref` self-refs
        // exactly as `createManuscript` does — an external manuscript has no
        // revision chain, because snapshotting one would be the store claiming
        // authorship of a file it does not own.
        var payload: [String: Any] = [
            "title": existingTitleOverride(existing) ?? snapshot.title,
            "status": existing?.status ?? "draft",
            "current_revision_ref": id.uuidString,
            "format": snapshot.format.rawValue,
            // The SNAPSHOT. Replaced wholesale on every pass; authoritative
            // nowhere. `body_content_hash` stays the hash OF THE SNAPSHOT so
            // the ordinary readers (search, preview, the comment anchors) keep
            // their existing contract; the FILE's hash lives in
            // `external_source.content_hash`, and the two are equal only
            // because the snapshot is a verbatim copy of what was read.
            "body_content": snapshot.text,
            "body_content_hash": ManuscriptStoreAdapter.bodyContentHash(snapshot.text),
            "format_schema_version": 140,
            "external_source": try Self.encodeExternalSource(source),
        ]
        // Only stamp a body time on the first index: later passes are re-reads
        // of somebody else's edit, and `external_source.read_at` records those.
        if existing == nil {
            payload["body_modified_at"] = ISO8601DateFormatter().string(from: Date())
        }

        try sharedStore.upsertItem(
            id: id.uuidString,
            schemaRef: ManuscriptStoreAdapter.manuscriptSchemaRef,
            payloadJson: try Self.encodeExternalPayload(payload))

        let changed = previousHash != nil && previousHash != snapshot.contentHash
        Logger.sharedStore.infoCapture(
            "watched manuscript \(id): \(existing == nil ? "indexed" : (changed ? "re-read" : "unchanged")) "
                + "\((path as NSString).lastPathComponent) "
                + "(\(snapshot.sizeBytes) bytes, hash \(snapshot.contentHash.prefix(8)))",
            category: "watched-folders")
        noteExternalMutation(id: id, structural: existing == nil)
        return ExternalUpsertOutcome(
            id: id, created: existing == nil, contentChanged: changed)
    }

    /// Flag an external manuscript whose file has vanished. **Never deletes.**
    ///
    /// The body snapshot is left exactly as it was: it is the last thing the
    /// file said, and throwing it away would turn "your file moved" into "your
    /// text is gone", which is the failure D4 forbids in its other direction.
    @discardableResult
    func markExternalManuscriptMissing(path: String) throws -> UUID? {
        let id = ExternalManuscriptSource.manuscriptID(forPath: path)
        guard let source = manuscript(id: id)?.externalSource, !source.isMissing else {
            return nil
        }
        try writeExternalSource(source.with(state: .missing), to: id)
        Logger.sharedStore.warningCapture(
            "watched manuscript \(id): \((path as NSString).lastPathComponent) is gone from disk "
                + "— row kept and flagged missing, nothing deleted",
            category: "watched-folders")
        return id
    }

    /// Un-flag a manuscript whose file came back (the user restored it, or the
    /// volume remounted). The symmetric half of the rule above: a flag a system
    /// raises, a system must be able to lower.
    @discardableResult
    func markExternalManuscriptPresent(path: String) throws -> UUID? {
        let id = ExternalManuscriptSource.manuscriptID(forPath: path)
        guard let source = manuscript(id: id)?.externalSource, source.isMissing else {
            return nil
        }
        try writeExternalSource(source.with(state: .present), to: id)
        return id
    }

    /// **Import a copy** (D4's second affordance). The copy is an ORDINARY
    /// manuscript: it carries `import_source`, not `external_source`, so it
    /// takes an editor session, saves to the store, and has no claim on the
    /// file whatsoever. The original row is untouched and keeps watching.
    @discardableResult
    func importCopyOfExternalManuscript(id: UUID) throws -> UUID {
        guard let model = manuscript(id: id), let source = model.externalSource else {
            throw ExternalManuscriptError.notExternal(id)
        }
        // Read the FILE, not the snapshot: a copy taken now should be a copy of
        // what is on disk now. If the file is gone, the snapshot is all there
        // is and copying it is better than refusing — that is the case the
        // snapshot exists for.
        let body: String
        if let snapshot = try? ExternalManuscriptReader.read(at: source.path), !snapshot.text.isEmpty
        {
            body = snapshot.text
        } else {
            body = model.body
        }
        let copyID = try createManuscript(
            title: "\(model.title) (copy)", format: model.format, body: body,
            authors: model.authors)
        try updateMetadata(
            id: copyID,
            importSource: ImportSource(
                kind: Self.importKind(for: model.format),
                originalPath: source.path,
                originalPathBookmarkBase64: source.bookmarkBase64))
        Logger.sharedStore.infoCapture(
            "watched manuscript \(id): imported a copy as \(copyID) — the copy is an ordinary "
                + "manuscript and the file is no longer involved",
            category: "watched-folders")
        return copyID
    }

    // MARK: Reads

    /// Every manuscript that indexes a file, newest first. Used by the
    /// provenance surfaces and by the sweep.
    func externalManuscripts() -> [ManuscriptModel] {
        allManuscripts(limit: 0).filter { $0.externalSource != nil }
    }

    // MARK: Private

    private func existingTitleOverride(_ existing: ManuscriptModel?) -> String? {
        // A user who renamed the row in imprint keeps that name: the title is
        // the one piece of an external manuscript that is genuinely the store's
        // (the file's name is still in `external_source.path`).
        guard let existing, let source = existing.externalSource else { return nil }
        let derived = URL(fileURLWithPath: source.path).deletingPathExtension().lastPathComponent
        return existing.title == derived ? nil : existing.title
    }

    private func writeExternalSource(_ source: ExternalManuscriptSource, to id: UUID) throws {
        try sharedStore.upsertItem(
            id: id.uuidString,
            schemaRef: ManuscriptStoreAdapter.manuscriptSchemaRef,
            payloadJson: try Self.encodeExternalPayload([
                "external_source": try Self.encodeExternalSource(source)
            ]))
        noteExternalMutation(id: id, structural: false)
    }

    private static func encodeExternalSource(_ source: ExternalManuscriptSource) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        guard let text = String(data: try encoder.encode(source), encoding: .utf8) else {
            throw ExternalManuscriptError.encoding
        }
        return text
    }

    private static func encodeExternalPayload(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ExternalManuscriptError.encoding
        }
        return text
    }

    private static func importKind(for format: ManuscriptFormat) -> ImportSource.Kind {
        switch format {
        case .latex: return .tex
        case .markdown: return .markdown
        case .plaintext: return .plaintext
        case .typst: return .imprint
        }
    }
}

/// Why an external-manuscript verb could not run.
public enum ExternalManuscriptError: Error, LocalizedError, Equatable {
    case notExternal(UUID)
    case encoding

    public var errorDescription: String? {
        switch self {
        case .notExternal:
            return "That manuscript does not reference a file on disk."
        case .encoding:
            return "The external-source payload could not be encoded."
        }
    }
}

// MARK: - Decoding

public extension ManuscriptModel {

    /// The file this manuscript indexes, or nil for an ordinary manuscript.
    ///
    /// Decoded from the payload's `external_source` by
    /// `ManuscriptStoreAdapter.decode`, which stores the raw JSON on the model
    /// so this stays one parse per read rather than one per call site.
    var externalSource: ExternalManuscriptSource? {
        guard let json = externalSourceJSON, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExternalManuscriptSource.self, from: data)
    }

    /// True when the file — not the store — is authoritative for this body.
    ///
    /// The single predicate every no-write-back gate reads. Spelled as a
    /// computed property rather than a stored flag so it cannot disagree with
    /// the payload it is derived from.
    var isExternalReference: Bool { externalSourceJSON != nil }
}
