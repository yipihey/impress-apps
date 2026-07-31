// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). Data only: no SwiftUI,
// no AppKit. The pane consumes it; nothing here consumes the pane.
//
//  WatchedFileOffer.swift
//  PublicationManagerCore
//
//  ADR-0023 W4 — what a `file`-unit watched folder actually shows a human.
//
//  ── The unit is the file, so the row is the file ────────────────────────────
//
//  D3 splits the ingest unit two ways. imbib's `.bib` is a CONTAINER: the row
//  the user cares about is the publication that came out of it, and W2 could
//  therefore reuse a publication list (`PublicationSource.tag`) as the folder's
//  surface. impart's `.mbox` and implore's `.vsz` are the other kind — the file
//  IS the record — so a folder of them has no derived list to point at. Its
//  surface is the files, which is what this file models.
//
//  ── Why it is an OFFER and not an import report ─────────────────────────────
//
//  ADR-0023's ingest map left the mbox fan-out to "phase 3", and W4 answers it
//  NO for v1 (see the W4 row in the ADR, and `WatchedFolderImportHooks
//  .recordingOnly`). A discovered archive is therefore something the app is
//  OFFERING the user, not something it has already done to their library:
//
//    * a 2 GB mbox auto-fanning to 50,000 messages the moment a folder is added
//      is precisely D7's burst hazard, and it would happen at the worst moment —
//      while the user is still choosing the folder in a panel;
//    * mail read-state and threading are IMAP-owned (`MessageRecordKind`
//      declares neither dismissal nor deletion for that reason), so minting
//      message rows from a file would create rows with a lifecycle nothing owns;
//    * a `.vsz` cannot be read at all — the suite has no Veusz parser, in Rust
//      or in Swift — so a figure record minted from one could carry a title and
//      nothing else, and `figure`'s store payload has no field for a path
//      (`FigureStoreWriter.figureRow` — title/format/caption/hashes), which
//      means "reference-in-place" has nowhere to put the reference.
//
//  What IS real and useful without any of that: which archives exist, where,
//  how big, whether they changed, whether they vanished. That is the whole
//  `watched-file` row, it is hash-tracked and swept exactly as W0 built it, and
//  it costs the user nothing.
//

import Foundation

// MARK: - One discovered file

/// One discovered file, as a `file`-unit folder's pane needs it.
///
/// A snapshot value over `WatchedFileRecord` (the store's row) rather than a
/// second query: the same relationship `WatchedFolderRowState` has to the
/// watcher's registration, and for the same reason — a row that recomputes
/// itself in a view body is a row that can disagree with the store.
public struct WatchedFileOffer: Identifiable, Hashable, Sendable {

    /// The `watched-file` row id (lowercase UUID string).
    public let id: String
    public let path: String
    public let sizeBytes: Int
    /// `true` when the file is gone from disk. The row is KEPT (D4) — nothing
    /// this feature touches is ever deleted.
    public let isMissing: Bool
    /// Store rows this file has been credited with producing. Zero for a
    /// `recordingOnly` kind, and that is not a failure state.
    public let producedCount: Int
    public let lastSeenAt: String?

    public init(_ record: WatchedFileRecord) {
        self.id = record.id
        self.path = record.path
        self.sizeBytes = record.sizeBytes
        self.isMissing = record.isMissing
        self.producedCount = record.producedIDs.count
        self.lastSeenAt = record.lastSeenAt
    }

    public init(
        id: String, path: String, sizeBytes: Int, isMissing: Bool = false,
        producedCount: Int = 0, lastSeenAt: String? = nil
    ) {
        self.id = id
        self.path = path
        self.sizeBytes = sizeBytes
        self.isMissing = isMissing
        self.producedCount = producedCount
        self.lastSeenAt = lastSeenAt
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var fileName: String { (path as NSString).lastPathComponent }
    public var fileExtension: String { (path as NSString).pathExtension.lowercased() }

    /// Human size. `ByteCountFormatter` rather than a hand-rolled divide,
    /// because "2.1 GB" is the number that makes the refusal below legible.
    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    /// The secondary line — always non-empty, the `WatchedFolderRowState
    /// .statusLine` rule (a field that is blank when healthy trains the eye to
    /// skip it, and makes "not computed yet" indistinguishable from "fine").
    public var statusLine: String {
        if isMissing {
            return "Missing from disk — the row is kept, nothing was deleted"
        }
        return displaySize
    }

    public var systemImage: String {
        isMissing ? "exclamationmark.triangle" : "doc"
    }
}

public extension Array where Element == WatchedFileRecord {
    /// The store's rows as pane rows, present files first then missing ones,
    /// each group by name — a stable order that does not reshuffle when a file
    /// is touched.
    var offers: [WatchedFileOffer] {
        map(WatchedFileOffer.init).sorted {
            $0.isMissing == $1.isMissing
                ? $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                : !$0.isMissing
        }
    }
}

// MARK: - Inspecting a mail archive

/// Reading a discovered `.mbox` / `.eml` **without importing it**.
///
/// ── Why this exists at all ──────────────────────────────────────────────────
///
/// "There is an archive here" is a weak offer; "there is an archive here with
/// 412 messages in it, the first of which is …" is one a human can act on. The
/// count comes from the REAL parser — `imbib_core::mbox::parse_content`, the
/// Stage-7.9 Rust port pinned by 23 whole-archive golden cases — reached
/// through PMC's `MboxParser` shim. There is no second, cheaper, "just count
/// the `From ` lines" implementation here, because a second implementation of a
/// parse is a second answer to it (the rule the suite's no-TypeScript entry
/// records the cost of).
///
/// ── And why it is bounded, explicitly ───────────────────────────────────────
///
/// That parser is whole-file: `parse(url:)` reads the archive into a `String`
/// and returns every message. On a mail archive of the size people actually
/// have, that is hundreds of megabytes of allocation to draw a subtitle — D7's
/// burst hazard wearing a different hat. So the inspection REFUSES above a
/// declared ceiling and says so in words the row renders, rather than
/// succeeding slowly or failing silently. A refusal is not an error state: the
/// archive is fine, and every other affordance on the row still works.
public enum WatchedMailArchive {

    /// The largest archive this will read to count. 64 MB is chosen against
    /// what the parser costs, not against what mail archives are: it is roughly
    /// the point where the whole-file read stops being invisible, and archives
    /// above it are exactly the ones whose message count is least surprising.
    public static let inspectionByteCeiling = 64 * 1024 * 1024

    /// What one archive turned out to contain.
    public struct Inspection: Sendable, Equatable {
        public let messageCount: Int
        /// The first few subjects, for the "is this the archive I meant?"
        /// question the count alone cannot answer.
        public let firstSubjects: [String]

        public init(messageCount: Int, firstSubjects: [String]) {
            self.messageCount = messageCount
            self.firstSubjects = firstSubjects
        }

        public var summary: String {
            messageCount == 1 ? "1 message" : "\(messageCount) messages"
        }
    }

    /// Why an archive was not read.
    public enum Refusal: Error, LocalizedError, Equatable {

        /// Above `inspectionByteCeiling`. The archive is fine; reading it to
        /// draw a row is not.
        case tooLarge(bytes: Int)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                let size = ByteCountFormatter.string(
                    fromByteCount: Int64(bytes), countStyle: .file)
                let ceiling = ByteCountFormatter.string(
                    fromByteCount: Int64(WatchedMailArchive.inspectionByteCeiling),
                    countStyle: .file)
                return "This archive is \(size); archives over \(ceiling) are not read to "
                    + "count their messages. Reveal it in the Finder to open it elsewhere."
            case .unreadable(let reason):
                return "That archive could not be read: \(reason)"
            }
        }
    }

    /// The extensions this understands — READ FROM THE DECLARATION, never
    /// spelled here (ADR-0023 D1: no app names a file extension in discovery
    /// code, and the same rule earns its keep one layer up).
    public static var fileExtensions: Set<String> {
        Set(MessageRecordKind.descriptor.fileDiscovery?.fileExtensions ?? [])
    }

    /// An `.eml` is an RFC 5322 MESSAGE; an `.mbox` is an RFC 4155 ARCHIVE of
    /// them, and the difference is one line.
    ///
    /// The Rust parser splits on the `From ` envelope line and therefore reads
    /// a bare `.eml` as **zero** messages — correctly, since an `.eml` has no
    /// envelope line and never did. Rather than teach the parser (which is
    /// golden-pinned and shared with imbib's export format) or count headers
    /// here (a second, worse parse), the file is given the one line that makes
    /// it a one-message archive. The synthesised sender is the RFC 4155
    /// placeholder `MAILER-DAEMON`, which is what every tool that has to invent
    /// one uses.
    ///
    /// Content that ALREADY starts with `From ` is passed through untouched, so
    /// an `.mbox` — and an `.eml` that someone exported with an envelope line —
    /// both take the ordinary path.
    static func asMboxArchive(_ content: String) -> String {
        content.hasPrefix("From ") || content.isEmpty
            ? content
            : "From MAILER-DAEMON Thu Jan  1 00:00:00 1970\n" + content
    }

    /// Count the messages in one archive, or refuse.
    ///
    /// `nonisolated` and `async`: the parse is off the main actor because it is
    /// the one genuinely expensive thing this pane can do.
    public static func inspect(path: String) async throws -> Inspection {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= inspectionByteCeiling else { throw Refusal.tooLarge(bytes: size) }

        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let messages = await MboxParser().parseContent(Self.asMboxArchive(content))
            return Inspection(
                messageCount: messages.count,
                firstSubjects: messages.prefix(3).map {
                    $0.subject.isEmpty ? "(no subject)" : $0.subject
                })
        } catch let refusal as Refusal {
            throw refusal
        } catch {
            throw Refusal.unreadable(
                (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}
