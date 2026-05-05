//
//  CitedInManuscriptsSnapshot.swift
//  PublicationManagerCore
//
//  @Observable snapshot of the set of publications that appear in any
//  imprint manuscript. Fed by `CitationUsageReader` and refreshed on
//  demand (typically when the sidebar smart-library row appears or
//  when the user explicitly refreshes).
//
//  Kept as a simple main-actor snapshot rather than a full
//  SnapshotMaintainer because cross-process writes from imprint are not
//  visible to imbib's in-process event publisher — we'd need a Darwin
//  notification bridge or a periodic refresh to stay live. For Phase 1,
//  on-demand refresh from the sidebar row is fine.
//

import Foundation
import OSLog

@MainActor
@Observable
public final class CitedInManuscriptsSnapshot {

    public static let shared = CitedInManuscriptsSnapshot()

    /// Publication UUIDs that appear in at least one citation-usage
    /// record with a resolved `paper_id`.
    public private(set) var citedPaperIDs: Set<UUID> = []

    /// All records seen on the last refresh, sorted by
    /// `lastSeen` descending. Exposed so a detail panel can show
    /// "cited in 3 sections across 2 manuscripts".
    public private(set) var records: [CitationUsageRecord] = []

    /// Wall-clock time of the last successful refresh.
    public private(set) var lastRefreshedAt: Date?

    /// Bumped on every refresh so `.onChange` observers can react.
    public private(set) var revision: Int = 0

    public init() {}

    /// Pull the latest records from `CitationUsageReader` and publish
    /// them. Safe to call repeatedly; each call is O(n) over the
    /// record set, which is at most a few thousand in practice.
    public func refresh() async {
        let all = await CitationUsageReader.shared.listAll()
        var ids: Set<UUID> = []
        for record in all {
            if let paperID = record.paperID {
                ids.insert(paperID)
            }
        }
        let sorted = all.sorted { lhs, rhs in
            (lhs.lastSeen ?? .distantPast) > (rhs.lastSeen ?? .distantPast)
        }
        self.citedPaperIDs = ids
        self.records = sorted
        self.lastRefreshedAt = Date()
        self.revision &+= 1
    }
}
