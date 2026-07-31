// Chassis WIRING file — CROSS-PLATFORM (macOS + iOS).
//
//  WatchedFolderProvenance.swift
//  PublicationManagerCore
//
//  ADR-0023 W2 — "where did this paper come from?", answered in the Info tab.
//
//  ── The question, and why it needs a reverse index ──────────────────────────
//
//  The store's provenance edge points one way: a `watched-file` row lists the
//  publications it PRODUCED. That is the right direction for the writer (one
//  file, N entries, written once per import) and the wrong one for the reader
//  (one publication, "which file?"). W0's `list_watched_files` therefore
//  answers by folder or by file id, and deliberately not by produced id — a
//  reverse index in the store would be a second copy of the same fact, and the
//  kind of second copy that goes stale silently.
//
//  So the reverse map is BUILT here, in memory, from the forward one. That is
//  affordable for a reason worth stating rather than assuming: a watched
//  bibliography folder holds `.bib` files, not papers — tens, not thousands —
//  and the map is one row per FILE, not per publication.
//
//  ── The early-out that makes this free for everyone else ────────────────────
//
//  A user with no watched folders pays NOTHING: `folders()` returns empty and
//  the whole thing short-circuits before a single file row is read. The Info
//  tab's new row simply does not render. This matters because the detail pane
//  is on the hot path of every arrow-key press through a list.
//

import Foundation
import OSLog

/// One publication's source file, as the detail pane needs it.
public struct WatchedFileProvenance: Equatable, Sendable {

    /// Absolute path of the `.bib`/`.ris` the entry came from.
    public let path: String

    /// The watched folder's display name — also the provenance tag's leaf.
    public let folderName: String

    /// True when the file is no longer on disk. The row says so rather than
    /// showing a path that leads nowhere (D4 keeps the row; the UI must not
    /// pretend the file is still there).
    public let isMissing: Bool

    /// True when the file changed after the last import — the entry on screen
    /// may be older than its source.
    public let needsReimport: Bool

    public var fileName: String { (path as NSString).lastPathComponent }

    /// The line the Info tab shows.
    public var summary: String {
        if isMissing { return "\(fileName) (file is missing)" }
        if needsReimport { return "\(fileName) (source has changed since import)" }
        return fileName
    }

    public init(path: String, folderName: String, isMissing: Bool, needsReimport: Bool) {
        self.path = path
        self.folderName = folderName
        self.isMissing = isMissing
        self.needsReimport = needsReimport
    }
}

/// The reverse provenance index: publication id → the file that produced it.
@MainActor
@Observable
public final class WatchedFolderProvenanceIndex {

    public static let shared = WatchedFolderProvenanceIndex()

    @ObservationIgnored private let store: WatchedFolderStoreAdapter
    @ObservationIgnored private var index: [UUID: WatchedFileProvenance] = [:]
    @ObservationIgnored private var builtForVersion: Int = -1

    public init(store: WatchedFolderStoreAdapter = .shared) {
        self.store = store
    }

    /// The file a publication came from, or nil when it was not imported by a
    /// watched folder (which is every paper in a library that watches nothing).
    ///
    /// `dataVersion` is the invalidation key — `RustStoreAdapter`'s own counter,
    /// which every import bumps. Passing it rather than reading it keeps this
    /// type usable from a test with no adapter.
    public func provenance(of publicationID: UUID, dataVersion: Int) -> WatchedFileProvenance? {
        rebuildIfNeeded(dataVersion: dataVersion)
        return index[publicationID]
    }

    /// Force the next read to rebuild. Used when the ingest loop has just run.
    public func invalidate() { builtForVersion = -1 }

    private func rebuildIfNeeded(dataVersion: Int) {
        guard builtForVersion != dataVersion else { return }
        builtForVersion = dataVersion
        index.removeAll(keepingCapacity: true)

        guard store.isReady else { return }
        let folders: [WatchedFolderRecord]
        do {
            folders = try store.folders(kindScope: WatchedFolderIngestCoordinator.kindScope)
        } catch {
            Logger.files.errorCapture(
                "provenance index: \(error.localizedDescription)", category: "watched-folders")
            return
        }
        // The early-out. No watched folders, no work, no file reads.
        guard !folders.isEmpty else { return }

        for folder in folders {
            guard let files = try? store.files(folderID: folder.id).files else { continue }
            for file in files {
                let provenance = WatchedFileProvenance(
                    path: file.path,
                    folderName: folder.displayName,
                    isMissing: file.isMissing,
                    needsReimport: file.needsReimport)
                for id in file.producedPublicationIDs {
                    // Two files legitimately claiming one publication is the
                    // DEDUP case (the same entry in two watched `.bib`s), and
                    // it is not an error. First writer wins, and the tags —
                    // which are additive — carry the full story.
                    if index[id] == nil { index[id] = provenance }
                }
            }
        }
    }
}
