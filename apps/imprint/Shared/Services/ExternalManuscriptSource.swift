//
//  ExternalManuscriptSource.swift
//  imprint
//
//  ADR-0023 D4 / W3 — the reference-in-place representation.
//
//  ── The claim this type makes ───────────────────────────────────────────────
//
//  A manuscript row carrying an `ExternalManuscriptSource` is an INDEX ENTRY,
//  not a copy. The file at `path` is authoritative for the body; the row's
//  `body_content` is a SNAPSHOT taken at `readAt`, and `contentHash` is the
//  hash of the FILE at that moment — not of the snapshot. Those two facts are
//  what let every reader (list row, search, preview, the Info tab) work exactly
//  as it does for an ordinary manuscript while still being able to say, at any
//  moment, "the file has moved on since this text was read".
//
//  ── Why it cannot fight the file ────────────────────────────────────────────
//
//  The failure mode D4 exists to prevent is a store row whose debounced
//  compare-and-set save writes an old buffer over a file the user has since
//  edited elsewhere — the delete-session-discard invariant's cousin, and worse,
//  because the loser is a user's file rather than a store row. Three things
//  make it structurally impossible here rather than merely unlikely:
//
//    1. **No editor session is ever created for an external manuscript.**
//       `WatchedManuscriptGuard.allowsEditorSession(_:)` is consulted where
//       sessions are minted; an external row gets a read-only surface. A save
//       that cannot be scheduled cannot fire late.
//    2. **The snapshot is REPLACED, never merged.** Every re-read overwrites
//       `body_content` wholesale from the file, so the store never holds a
//       version the file does not.
//    3. **Nothing writes the file.** The one verb that reaches disk here is
//       `read(at:)`. Import-a-copy makes an ORDINARY manuscript (no
//       `external_source`, an `import_source` instead) and edits go to that
//       copy, which is the explicit handoff D4 permits.
//
//  ── Identity ────────────────────────────────────────────────────────────────
//
//  The manuscript row's id is DERIVED FROM THE PATH (`manuscriptID(forPath:)`),
//  so a re-scan of the same file resolves the same row without a query, across
//  launches, and two watched folders that both see one file agree it is one
//  manuscript. It is the same rule the kernel uses one layer down —
//  `watched_file_id` is derived from `(folder, path)` — for the same reason.
//

import CryptoKit
import Foundation
import PublicationManagerCore

/// The payload of a manuscript that lives in a file the user owns.
///
/// Serialized as JSON into the `manuscript` payload's `external_source` field
/// (declared in `crates/impress-core/src/schemas/manuscript.rs`). Snake-case
/// keys, because the field's contract is written in the Rust schema and a
/// Swift-side spelling would be a second answer to what the JSON says.
public struct ExternalManuscriptSource: Sendable, Codable, Equatable {

    /// Mirrors the `watched-file` row's own state. A `missing` file's
    /// manuscript row is KEPT and flagged — never deleted (D4).
    public enum State: String, Sendable, Codable, Equatable {
        case present
        case missing
    }

    /// Absolute path of the file. Authoritative; the row indexes it.
    public let path: String

    /// Security-scoped bookmark, when one was minted for the file itself.
    /// Usually nil: access comes from the watched FOLDER's bookmark.
    public let bookmarkBase64: String?

    /// SHA-256 hex of the FILE's bytes as of `readAt` — the same scheme the
    /// kernel uses (`sha256_bytes_hex` over the raw bytes, never over a
    /// lossily-decoded string). `ExternalManuscriptReader` is the only writer,
    /// and `externalHashMatchesTheKernel` pins the two together.
    public let contentHash: String

    public let sizeBytes: Int?

    /// The `watched-file` row this manuscript was produced by, when known.
    public let watchedFileID: String?
    public let watchedFolderID: String?

    /// The watched folder's display name — also the provenance tag's leaf, so
    /// the row can name its origin without consulting the coordinator.
    public let folderName: String?

    /// When the snapshot in `body_content` was read off disk.
    public let readAt: Date?

    public let state: State

    public init(
        path: String,
        bookmarkBase64: String? = nil,
        contentHash: String,
        sizeBytes: Int? = nil,
        watchedFileID: String? = nil,
        watchedFolderID: String? = nil,
        folderName: String? = nil,
        readAt: Date? = nil,
        state: State = .present
    ) {
        self.path = path
        self.bookmarkBase64 = bookmarkBase64
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.watchedFileID = watchedFileID
        self.watchedFolderID = watchedFolderID
        self.folderName = folderName
        self.readAt = readAt
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case path
        case bookmarkBase64 = "bookmark_base64"
        case contentHash = "content_hash"
        case sizeBytes = "size_bytes"
        case watchedFileID = "watched_file_id"
        case watchedFolderID = "watched_folder_id"
        case folderName = "folder_name"
        case readAt = "read_at"
        case state
    }

    // MARK: Derived

    public var fileName: String { (path as NSString).lastPathComponent }

    public var isMissing: Bool { state == .missing }

    /// The same copy in every surface that has to explain this row.
    public var statusLine: String {
        if isMissing {
            return "The file is missing from \(folderName ?? "its watched folder"). "
                + "This entry is kept so nothing you filed is lost."
        }
        return "Lives in \(fileName). imprint reads this file and never writes it."
    }

    /// A copy of `self` in a new state, leaving every other fact alone.
    public func with(state: State) -> ExternalManuscriptSource {
        ExternalManuscriptSource(
            path: path,
            bookmarkBase64: bookmarkBase64,
            contentHash: contentHash,
            sizeBytes: sizeBytes,
            watchedFileID: watchedFileID,
            watchedFolderID: watchedFolderID,
            folderName: folderName,
            readAt: readAt,
            state: state)
    }

    // MARK: Identity

    /// The manuscript row id for a path.
    ///
    /// Deterministic so a re-scan updates rather than duplicates, and stable
    /// across launches because it is a pure function of the standardized path.
    /// The shape (SHA-256 folded into 16 bytes, RFC-4122 version/variant bits)
    /// matches PMC's `UUID.deterministic(from:)`; the value is namespaced so it
    /// can never collide with an ordinary manuscript's random UUID by
    /// construction of the namespace, and with another kind's derived id by the
    /// prefix.
    public static func manuscriptID(forPath path: String) -> UUID {
        let key = "impress/external-manuscript/"
            + URL(fileURLWithPath: path).standardizedFileURL.path
        var digest = Array(SHA256.hash(data: Data(key.utf8)))
        digest[6] = (digest[6] & 0x0F) | 0x40
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

// MARK: - Reading the file

/// The one place an external manuscript's bytes are read.
///
/// Read-only by construction: there is no write verb here and no caller may
/// add one — D4's no-write-back rule is this file's whole subject.
public enum ExternalManuscriptReader {

    /// One file, as much as a manuscript row needs.
    public struct Snapshot: Sendable, Equatable {
        public let text: String
        /// SHA-256 hex of the RAW BYTES — see `ExternalManuscriptSource.contentHash`.
        public let contentHash: String
        public let sizeBytes: Int
        public let format: ManuscriptFormat
        /// The title the row shows: the file's own name, without its extension.
        public let title: String
    }

    /// Files this big are indexed but not snapshotted.
    ///
    /// The row still exists, still says where the file is, and still offers
    /// "Open in…" and "Import a Copy" — only the body snapshot is withheld,
    /// because a 10 MB string in a payload is a store problem, not a manuscript.
    /// The manuscript schema's own escape hatch (a `blob:sha256:` ref) is the
    /// eventual answer and is recorded as a W3 deferral rather than half-built.
    public static let maximumSnapshotBytes = 4 * 1024 * 1024

    public enum Failure: Error, LocalizedError, Equatable {
        case unreadable(path: String, reason: String)
        case notText(path: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path, let reason):
                return "\((path as NSString).lastPathComponent) could not be read: \(reason)"
            case .notText(let path):
                return "\((path as NSString).lastPathComponent) is not UTF-8 text."
            }
        }
    }

    public static func read(at path: String) throws -> Snapshot {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw Failure.unreadable(path: path, reason: error.localizedDescription)
        }

        // Hash the BYTES, always — including for a file too large to snapshot,
        // so "has this changed?" stays answerable for every indexed file.
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let ext = url.pathExtension.lowercased()
        let format = DocumentFormat.detect(fromExtension: ext)
            .flatMap { ManuscriptFormat(rawValue: $0.rawValue) }
            ?? .plaintext

        var text = ""
        if data.count <= maximumSnapshotBytes {
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw Failure.notText(path: path)
            }
            text = decoded
        }

        return Snapshot(
            text: text,
            contentHash: hash,
            sizeBytes: data.count,
            format: format,
            title: url.deletingPathExtension().lastPathComponent)
    }
}
