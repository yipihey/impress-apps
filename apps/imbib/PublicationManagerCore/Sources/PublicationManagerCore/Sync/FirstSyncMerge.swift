//
//  FirstSyncMerge.swift
//  PublicationManagerCore
//
//  ADR-0007 Phase 3 (Phase D): reconcile the overlapping-libraries case on
//  first sync.
//
//  ## The problem
//
//  Two devices used imbib independently before sync existed. Both imported
//  Peebles 2020 — from BibTeX on the laptop, from arXiv on the phone. Those
//  are two DIFFERENT item UUIDs describing one paper. Sync will happily
//  replicate both, and the user ends up with a doubled library on both
//  devices. Whole-record LWW cannot fix this: the records aren't in conflict,
//  they're distinct items.
//
//  ## The rule (plan decision, Phase D)
//
//  Pair publications on identifier (DOI → bibcode → arXiv, in that order of
//  authority) and collapse each cross-device pair to ONE survivor:
//
//  **survivor = lexicographically smallest UUID.**
//
//  That choice is the whole trick. It is a pure function of data both devices
//  already hold, so each device independently reaches the same verdict with
//  zero coordination — no leader election, no "who synced first". The loser is
//  removed through the normal delete path, so its tombstone propagates and the
//  other device's pass becomes a no-op instead of a fight.
//
//  Before deleting, everything the loser knew is folded into the survivor:
//  tags are unioned, read/starred are OR-ed (a paper read on either device is
//  read), and collection + library memberships are re-pointed.
//
//  ## What it deliberately does NOT do
//
//  Groups whose members all share one `origin` are LOCAL duplicates — the user
//  imported the same paper twice on one device. That is the existing manual
//  dedup UI's job, and silently deleting there would be a surprise. We only
//  merge groups spanning two or more origins, i.e. genuine cross-device pairs.
//  Publications with no identifier at all are untouched (nothing reliable to
//  pair on).
//

import Foundation
import ImbibRustCore
import ImpressLogging
import OSLog

/// Outcome of a first-sync merge pass, surfaced in Settings (Phase E).
public struct FirstSyncMergeReport: Sendable, Equatable {
    /// Identifier groups with more than one publication.
    public var duplicateGroups: Int = 0
    /// Groups merged (spanning ≥2 origins).
    public var groupsMerged: Int = 0
    /// Publications deleted as losers.
    public var publicationsRemoved: Int = 0
    /// Tag paths copied onto survivors.
    public var tagsUnioned: Int = 0
    /// Collection/library memberships re-pointed to survivors.
    public var membershipsRepointed: Int = 0
    /// Groups left alone because every member shared one origin (local
    /// duplicates — the manual dedup UI's territory).
    public var groupsSkippedSingleOrigin: Int = 0

    public init() {}
}

public enum FirstSyncMerge {

    /// One publication as the merge pass sees it.
    struct Candidate {
        let id: String
        let doi: String?
        let arxivID: String?
        let bibcode: String?
        let isRead: Bool
        let isStarred: Bool
        let tagPaths: [String]
        var libraryIDs: Set<String>
    }

    /// Run the merge over every publication in the store.
    ///
    /// Safe to run more than once: after a pass, each identifier group has a
    /// single member, so subsequent passes find nothing to do.
    @discardableResult
    public static func run(store: ImbibStore) throws -> FirstSyncMergeReport {
        var report = FirstSyncMergeReport()

        let candidates = try collectCandidates(store: store)
        let groups = groupByIdentifier(candidates)

        for group in groups where group.count > 1 {
            report.duplicateGroups += 1

            // Cross-device only: a group confined to one origin is a local
            // duplicate and belongs to the manual dedup UI.
            let origins = try originsFor(ids: group.map(\.id), store: store)
            guard origins.count > 1 else {
                report.groupsSkippedSingleOrigin += 1
                continue
            }

            // Deterministic on both devices — pure function of the UUIDs.
            let sorted = group.sorted { $0.id.lowercased() < $1.id.lowercased() }
            guard let survivor = sorted.first else { continue }
            let losers = sorted.dropFirst()

            var survivorTags = Set(survivor.tagPaths)
            var shouldRead = survivor.isRead
            var shouldStar = survivor.isStarred

            for loser in losers {
                // Union tags.
                for tag in loser.tagPaths where !survivorTags.contains(tag) {
                    _ = try store.addTag(ids: [survivor.id], tagPath: tag)
                    survivorTags.insert(tag)
                    report.tagsUnioned += 1
                }

                shouldRead = shouldRead || loser.isRead
                shouldStar = shouldStar || loser.isStarred

                // Re-point collection membership.
                for collection in try store.listCollectionsForPublication(
                    publicationId: loser.id)
                {
                    _ = try store.addToCollection(
                        publicationIds: [survivor.id], collectionId: collection.id)
                    report.membershipsRepointed += 1
                }

                // Re-point library membership the survivor doesn't already have.
                for libraryID in loser.libraryIDs.subtracting(survivor.libraryIDs) {
                    _ = try store.libraryAddMembers(
                        libraryId: libraryID, publicationIds: [survivor.id])
                    report.membershipsRepointed += 1
                }

                // Normal delete path → tombstone → the peer's pass no-ops.
                try store.deletePublications(ids: [loser.id])
                report.publicationsRemoved += 1
            }

            if shouldRead && !survivor.isRead {
                _ = try store.setRead(ids: [survivor.id], read: true)
            }
            if shouldStar && !survivor.isStarred {
                _ = try store.setStarred(ids: [survivor.id], starred: true)
            }

            report.groupsMerged += 1
        }

        Logger.sync.infoCapture(
            """
            FirstSyncMerge: \(report.duplicateGroups) duplicate groups, \
            \(report.groupsMerged) merged, \(report.publicationsRemoved) removed, \
            \(report.groupsSkippedSingleOrigin) local-only groups left alone
            """,
            category: "sync")

        return report
    }

    // MARK: - Internals

    /// Every publication in the store, with the libraries it belongs to.
    /// A paper can live in several libraries, so we accumulate memberships
    /// while walking them and de-duplicate by publication id.
    static func collectCandidates(store: ImbibStore) throws -> [Candidate] {
        var byID: [String: Candidate] = [:]

        for library in try store.listLibraries() {
            let rows = try store.queryPublications(
                parentId: library.id,
                sortField: "created",
                ascending: true,
                limit: nil,
                offset: nil)
            for row in rows {
                if var existing = byID[row.id] {
                    existing.libraryIDs.insert(library.id)
                    byID[row.id] = existing
                } else {
                    byID[row.id] = Candidate(
                        id: row.id,
                        doi: normalize(row.doi),
                        arxivID: normalize(row.arxivId),
                        bibcode: normalize(row.bibcode),
                        isRead: row.isRead,
                        isStarred: row.isStarred,
                        tagPaths: row.tags.map(\.path),
                        libraryIDs: [library.id])
                }
            }
        }
        return Array(byID.values)
    }

    /// Group by the most authoritative identifier each publication carries.
    /// Publications with no identifier form no group (nothing to pair on).
    static func groupByIdentifier(_ candidates: [Candidate]) -> [[Candidate]] {
        var buckets: [String: [Candidate]] = [:]
        for candidate in candidates {
            guard let key = groupKey(for: candidate) else { continue }
            buckets[key, default: []].append(candidate)
        }
        return Array(buckets.values)
    }

    /// DOI → bibcode → arXiv, in descending order of authority.
    static func groupKey(for candidate: Candidate) -> String? {
        if let doi = candidate.doi { return "doi:\(doi)" }
        if let bibcode = candidate.bibcode { return "bibcode:\(bibcode)" }
        if let arxiv = candidate.arxivID { return "arxiv:\(arxiv)" }
        return nil
    }

    /// Identifiers are user- and importer-supplied; compare them case- and
    /// whitespace-insensitively so "10.1234/ABC" and "10.1234/abc " pair.
    static func normalize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed.lowercased()
    }

    /// The distinct `origin` values behind a set of publications. Origin is
    /// only exposed through the sync projection, which is exactly the right
    /// source: it is the same value the peer device will see.
    static func originsFor(ids: [String], store: ImbibStore) throws -> Set<String> {
        let records = try store.syncSnapshotItems(ids: ids.map { $0.lowercased() })
        return Set(records.map(\.origin))
    }
}
