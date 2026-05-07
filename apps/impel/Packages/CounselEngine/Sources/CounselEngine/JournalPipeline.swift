//
//  JournalPipeline.swift
//  CounselEngine
//
//  Phase 3 of the impress journal pipeline (per docs/plan-journal-pipeline.md
//  §3.3 + ADR-0011 D7 — the pipeline orchestrator).
//
//  Subscribes to ImpressNotification.manuscriptStatusChanged and dispatches
//  to JournalSnapshotJob when a transition warrants a snapshot
//  (per ADR-0011 D5 snapshot triggers — Phase 3 wires status-change
//  triggers; user-tag and stable-churn are Phase 4–5 work).
//
//  Safety:
//  - 60-second startup grace period per CLAUDE.md "Background Services Must
//    Defer Startup Work". Without this, snapshots fire during the first 90s
//    of app launch and risk the render-loop bug.
//  - Reentrancy guarded by a per-manuscript inFlight set so a status-change
//    event triggered BY a snapshot doesn't trigger another snapshot.
//

import Foundation
import ImpressKit
import OSLog

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

/// Owns event subscriptions and dispatches Archivist work.
public actor JournalPipeline {

    public static let shared = JournalPipeline()

    private let logger = Logger(subsystem: "com.impress.impel", category: "journal-pipeline")
    private var startupGraceUntil: Date
    /// Retained Darwin notification tokens. Each token deregisters on its own
    /// deinit, so storing them in this array keeps the subscriptions alive.
    private var observations: [DarwinObservation] = []
    private var inFlightManuscripts: Set<String> = []

    /// Statuses that should trigger an automatic snapshot when entered.
    /// Per ADR-0011 D5: `submitted`, `published`, `archived` are user-meaningful
    /// transitions that warrant freezing the source. Others (draft,
    /// internal-review, in-revision) are working states.
    private let autoSnapshotStatuses: Set<String> = ["submitted", "published", "archived"]

    private init() {
        // Per CLAUDE.md: defer first work cycle by 60-90s after launch to avoid
        // the startup render-loop. JournalPipeline doesn't poll, so the grace
        // is mainly insurance against firing snapshots before SwiftUI settles.
        self.startupGraceUntil = Date().addingTimeInterval(60)
    }

    /// Internal initializer for tests: configurable startup grace, an
    /// optional shared snapshotJob handle, and an explicit store path so
    /// `findSourceForManuscript` reads from the same in-memory SQLite the
    /// test wrote to (otherwise it falls back to SharedWorkspace).
    internal init(
        startupGraceSeconds: TimeInterval,
        snapshotJob: JournalSnapshotJob? = nil,
        storePath: String? = nil
    ) {
        self.startupGraceUntil = Date().addingTimeInterval(startupGraceSeconds)
        self.testSnapshotJob = snapshotJob
        self.testStorePath = storePath
    }

    /// Test seam: when set, dispatch routes snapshots through this job
    /// instead of `JournalSnapshotJob.shared` so tests can use an isolated
    /// store path.
    private var testSnapshotJob: JournalSnapshotJob?

    /// Test seam: when set, `openStore()` opens this path instead of the
    /// production `SharedWorkspace.databaseURL.path`.
    private var testStorePath: String?

    /// Begin observing status-change events. Idempotent — calling twice is a
    /// no-op. Call from impel's app startup AFTER the workspace is opened.
    public func start() {
        guard observations.isEmpty else { return }
        // Subscribe to events posted from imbib (typical user action) and
        // from impel itself (e.g. submission accept via HTTP route).
        observations = [
            ImpressNotification.observe(
                ImpressNotification.manuscriptStatusChanged,
                from: .imbib
            ) { [weak self] in
                Task { await self?.handleStatusChange() }
            },
            ImpressNotification.observe(
                ImpressNotification.manuscriptStatusChanged,
                from: .impel
            ) { [weak self] in
                Task { await self?.handleStatusChange() }
            },
        ]
        logger.info("JournalPipeline: started observing manuscriptStatusChanged events")
    }

    /// Stop observing. Test hook; production callers use deinit semantics.
    public func stop() {
        for obs in observations { obs.invalidate() }
        observations.removeAll()
        logger.info("JournalPipeline: stopped")
    }

    // MARK: - Event handler

    /// Triggered by the Darwin notification subscription. Reads the latest
    /// payload to find affected manuscript IDs, then dispatches per-manuscript.
    private func handleStatusChange() async {
        if Date() < startupGraceUntil {
            logger.info("JournalPipeline: skipping event during 60s startup grace")
            return
        }

        // Read the latest payload (the writer wrote to the shared container
        // before posting the notification).
        let imbibPayload = ImpressNotification.latestPayload(
            for: ImpressNotification.manuscriptStatusChanged,
            from: .imbib
        )
        let impelPayload = ImpressNotification.latestPayload(
            for: ImpressNotification.manuscriptStatusChanged,
            from: .impel
        )

        var manuscriptIDs: Set<String> = []
        for payload in [imbibPayload, impelPayload] {
            if let ids = payload?.resourceIDs {
                manuscriptIDs.formUnion(ids)
            }
        }

        if manuscriptIDs.isEmpty {
            logger.info("JournalPipeline: status-change event with no resource IDs; ignoring")
            return
        }

        for id in manuscriptIDs {
            await dispatchSnapshotIfWarranted(manuscriptID: id)
        }
    }

    /// For one manuscript: read its current status. If the status warrants
    /// an auto-snapshot AND the manuscript has source content from a recent
    /// accepted submission, fire JournalSnapshotJob.snapshot.
    ///
    /// `internal` so tests can drive it directly without depending on the
    /// Darwin-notification timing.
    internal func dispatchSnapshotIfWarranted(manuscriptID: String) async {
        // Reentrancy guard: if a snapshot for this manuscript is already in
        // flight (or its post-snapshot status-change event is being handled),
        // skip.
        if inFlightManuscripts.contains(manuscriptID) { return }
        inFlightManuscripts.insert(manuscriptID)
        defer { inFlightManuscripts.remove(manuscriptID) }

        #if canImport(ImpressRustCore)
        guard let store = openStore() else { return }
        guard let row = try? store.getItem(id: manuscriptID) else {
            logger.info("JournalPipeline: manuscript \(manuscriptID) not found; ignoring")
            return
        }
        guard let payload = try? decodePayload(row.payloadJson),
              let status = payload["status"] as? String
        else { return }

        if !autoSnapshotStatuses.contains(status) {
            logger.debug("JournalPipeline: status=\(status) for \(manuscriptID) does not auto-snapshot; ignoring")
            return
        }

        // Find the most recent accepted submission for this manuscript.
        // Phase 3 simple resolver: scan all submissions, take the one whose
        // accepted_manuscript_ref equals manuscriptID with the most recent
        // creation. (Phase 5 polish would add a server-side query.)
        // Phase 8: bundle submissions are also resolved here, returning a
        // SnapshotSource enum that the snapshot job dispatches on.
        guard let snapshotSource = findSourceForManuscript(store: store, manuscriptID: manuscriptID) else {
            logger.info(
                "JournalPipeline: no accepted submission found for \(manuscriptID); skipping auto-snapshot"
            )
            return
        }

        do {
            let job = testSnapshotJob ?? JournalSnapshotJob.shared
            let result = try await job.snapshot(
                manuscriptID: manuscriptID,
                source: snapshotSource,
                revisionTag: revisionTag(for: status),
                reason: "status-change"
            )
            if result.wasNoOp {
                logger.info("JournalPipeline: snapshot for \(manuscriptID) was no-op (idempotent)")
            } else {
                logger.info(
                    "JournalPipeline: snapshot \(result.revisionID ?? "?") created for \(manuscriptID) on status=\(status)"
                )
            }
        } catch {
            logger.error("JournalPipeline: snapshot dispatch failed for \(manuscriptID): \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Source resolution

    #if canImport(ImpressRustCore)
    /// Find the source content for the manuscript by looking up the most
    /// recent accepted submission whose `accepted_manuscript_ref` equals
    /// `manuscriptID`. Returns nil if none found.
    ///
    /// Phase 8: returns a `SnapshotSource` enum so bundle submissions
    /// (those whose `source_payload` ends in `.tar.zst`) are routed to
    /// the bundle snapshot path instead of being skipped.
    ///
    /// `nonisolated` so it can be called from within actor methods without
    /// re-entering the actor's serialization queue.
    private nonisolated func findSourceForManuscript(
        store: SharedStore,
        manuscriptID: String
    ) -> JournalSnapshotJob.SnapshotSource? {
        guard let rows = try? store.queryBySchema(
            schemaRef: "manuscript-submission",
            limit: 5000,
            offset: 0
        ) else { return nil }

        // Newest first by created_ms.
        let sorted = rows.sorted(by: { $0.createdMs > $1.createdMs })
        for row in sorted {
            guard let payload = try? decodePayload(row.payloadJson) else { continue }
            guard payload["accepted_manuscript_ref"] as? String == manuscriptID else { continue }
            guard let source = payload["source_payload"] as? String, !source.isEmpty else { continue }

            // Bundle submission: resolve the manifest from the payload
            // and return a .bundle source spec.
            if source.hasSuffix(".tar.zst"),
               source.hasPrefix("blob:sha256:")
            {
                let prefix = "blob:sha256:"
                let middle = String(source.dropFirst(prefix.count))
                guard let dot = middle.firstIndex(of: ".") else { continue }
                let sha = String(middle[..<dot])
                guard sha.count == 64 else { continue }
                guard let manifestJSON = payload["bundle_manifest_json"] as? String,
                      let manifest = try? ManuscriptBundleManifest.parse(manifestJSON)
                else {
                    logger.warning(
                        "JournalPipeline: bundle submission for \(manuscriptID) has missing/invalid manifest; skipping"
                    )
                    continue
                }
                return .bundle(sha256: sha, manifest: manifest)
            }

            // Phase 7-era inline-blob ref to a text body. Phase 3 didn't
            // resolve these back to bytes. We continue to skip these — a
            // dedicated Phase 8.13 follow-up would hydrate them via
            // BlobStore lookup.
            if source.hasPrefix("blob:sha256:") { continue }

            // Inline source text path.
            return .inlineText(source)
        }
        return nil
    }

    private nonisolated func decodePayload(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
    #endif

    // MARK: - Steward dedup sweep (Phase 5.1)

    /// One pair of manuscripts Steward considers a near-duplicate.
    public struct DedupCandidate: Sendable, Equatable {
        public let manuscriptIDA: String
        public let titleA: String
        public let manuscriptIDB: String
        public let titleB: String
        public let titleScore: Double
    }

    /// Result of a single Steward sweep run.
    public struct DedupSweepResult: Sendable {
        public let manuscriptsScanned: Int
        public let candidatePairs: [DedupCandidate]
        /// IDs of `revision-note` items Steward created proposing merges.
        /// Empty if `dryRun: true`.
        public let proposalNoteIDs: [String]
    }

    /// Default title-Jaccard threshold above which Steward proposes a merge.
    /// Per ADR-0011 D6: 0.85 is the dedup-config default in the existing
    /// `crates/imbib-core/src/deduplication/orchestration.rs`. We mirror it
    /// here so the journal's manuscript-level dedup matches imbib's
    /// publication-level dedup.
    public static let stewardDedupTitleThreshold: Double = 0.85

    /// Run the Steward dedup sweep. Bounded to manuscripts modified in the
    /// last `recencyDays` days (default 90 per the implementation plan §9
    /// OQ-8) so cost stays linear-in-recently-active rather than quadratic-
    /// in-all-time.
    ///
    /// For each near-duplicate pair, Steward writes a `revision-note/v1`
    /// item with `verdict = "propose"` and a body suggesting the merge.
    /// The note's `subject_ref` is the OLDER of the two manuscripts (so the
    /// review surface in the older manuscript shows "Steward suggests
    /// merging the newer XYZ into this manuscript").
    ///
    /// - Parameter dryRun: if true, return the candidate pairs without
    ///   writing any revision-note items.
    @discardableResult
    public func runDedupSweep(
        recencyDays: Int = 90,
        threshold: Double = stewardDedupTitleThreshold,
        dryRun: Bool = false
    ) async -> DedupSweepResult {
        #if canImport(ImpressRustCore)
        guard let store = openStore() else {
            return DedupSweepResult(manuscriptsScanned: 0, candidatePairs: [], proposalNoteIDs: [])
        }

        // 1. Load recently-modified manuscripts.
        guard let rows = try? store.queryBySchema(
            schemaRef: "manuscript",
            limit: 5000,
            offset: 0
        ) else {
            return DedupSweepResult(manuscriptsScanned: 0, candidatePairs: [], proposalNoteIDs: [])
        }

        let cutoff = Date().addingTimeInterval(-Double(recencyDays) * 86400)
        let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1000)
        struct RecentManuscript {
            let id: String
            let title: String
            let createdMs: Int64
        }
        var recent: [RecentManuscript] = []
        for row in rows {
            // Use createdMs as a proxy for recently-active (modified time
            // would be ideal but the FFI row only exposes created_ms).
            // Per ADR-0011 D5 / D9 this is acceptable for Phase 5 since
            // status changes also create new revision items, and Phase 6
            // (out of scope) will surface real modified times.
            if row.createdMs < cutoffMs { continue }
            guard let payload = try? self.decodePayload(row.payloadJson),
                  let title = payload["title"] as? String, !title.isEmpty
            else { continue }
            recent.append(RecentManuscript(id: row.id, title: title, createdMs: row.createdMs))
        }

        // 2. Pairwise title Jaccard.
        var candidates: [DedupCandidate] = []
        for i in 0..<recent.count {
            for j in (i + 1)..<recent.count {
                let a = recent[i]
                let b = recent[j]
                let score = Self.titleJaccard(a.title, b.title)
                if score >= threshold {
                    // Older manuscript becomes the "subject" (preserve identity).
                    let (older, newer) = a.createdMs <= b.createdMs ? (a, b) : (b, a)
                    candidates.append(DedupCandidate(
                        manuscriptIDA: older.id,
                        titleA: older.title,
                        manuscriptIDB: newer.id,
                        titleB: newer.title,
                        titleScore: score
                    ))
                }
            }
        }

        if dryRun || candidates.isEmpty {
            logger.info(
                "JournalPipeline.runDedupSweep: scanned=\(recent.count) candidates=\(candidates.count) dry=\(dryRun)"
            )
            return DedupSweepResult(
                manuscriptsScanned: recent.count,
                candidatePairs: candidates,
                proposalNoteIDs: []
            )
        }

        // 3. Write a revision-note proposing the merge for each candidate.
        var proposalIDs: [String] = []
        for candidate in candidates {
            // Look up the older manuscript's current_revision_ref so the
            // revision-note is anchored to a real revision (not the
            // placeholder). If the older manuscript has no revision yet,
            // fall back to anchoring on the manuscript ID itself.
            let subjectRef: String
            if let parentRow = try? store.getItem(id: candidate.manuscriptIDA),
               let parentPayload = try? self.decodePayload(parentRow.payloadJson),
               let curRev = parentPayload["current_revision_ref"] as? String,
               curRev != JournalPipeline.placeholderRevisionRef
            {
                subjectRef = curRev
            } else {
                subjectRef = candidate.manuscriptIDA
            }

            let noteID = UUID().uuidString.lowercased()
            let scoreStr = String(format: "%.2f", candidate.titleScore)
            let body = """
            Steward observed a probable near-duplicate manuscript with
            title-Jaccard score \(scoreStr) (threshold: \(String(format: "%.2f", threshold))).

            **This manuscript:** \(candidate.titleA)

            **Possible duplicate (\(candidate.manuscriptIDB)):** \(candidate.titleB)

            If these are the same manuscript at different stages, consider
            merging via Accept/Reject in the Submissions inbox or by
            archiving one of the two. If they are independent, dismiss this
            proposal.
            """
            let payload: [String: Any] = [
                "subject_ref": subjectRef,
                "verdict":     "propose",
                "body":        body,
                "agent_id":    "steward",
                "target_section": "_journal_dedup",
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                try store.upsertItem(
                    id: noteID,
                    schemaRef: "revision-note",
                    payloadJson: String(data: data, encoding: .utf8) ?? "{}"
                )
                proposalIDs.append(noteID)
                ImpressNotification.post(
                    ImpressNotification.manuscriptReviewCompleted,
                    from: .impel,
                    resourceIDs: [candidate.manuscriptIDA, subjectRef, noteID]
                )
            } catch {
                logger.error("Steward dedup write failed for \(candidate.manuscriptIDA): \(error.localizedDescription)")
            }
        }

        logger.info(
            "JournalPipeline.runDedupSweep: scanned=\(recent.count) proposed=\(proposalIDs.count)"
        )
        return DedupSweepResult(
            manuscriptsScanned: recent.count,
            candidatePairs: candidates,
            proposalNoteIDs: proposalIDs
        )
        #else
        return DedupSweepResult(manuscriptsScanned: 0, candidatePairs: [], proposalNoteIDs: [])
        #endif
    }

    /// Same title-Jaccard implementation that JournalScout uses (per
    /// `JournalScout.titleJaccard` in CounselEngine). Duplicated here as a
    /// nonisolated helper so this actor can call it without re-entering
    /// JournalScout's serialization queue.
    nonisolated static func titleJaccard(_ a: String, _ b: String) -> Double {
        let setA = tokenize(a)
        let setB = tokenize(b)
        if setA.isEmpty || setB.isEmpty { return 0.0 }
        let inter = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union == 0 ? 0.0 : Double(inter) / Double(union)
    }

    nonisolated static func tokenize(_ title: String) -> Set<String> {
        let lower = title.lowercased()
        let cleaned = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        let normalized = String(cleaned)
        let tokens = normalized.split(separator: " ").map(String.init)
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "from", "into", "onto", "over",
            "under", "this", "that", "these", "those", "are", "was", "were",
            "been", "have", "has", "had", "but", "not", "any", "all", "its",
            "their", "them", "they", "than", "via", "per",
        ]
        return Set(tokens.filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    /// Placeholder revision ref used by ManuscriptBridge.createManuscript
    /// before the first real snapshot.
    private static let placeholderRevisionRef = "00000000-0000-0000-0000-000000000000"

    // MARK: - Helpers

    /// Map a manuscript status to a default revision tag for the auto-snapshot.
    private nonisolated func revisionTag(for status: String) -> String {
        switch status {
        case "submitted": return "submitted"
        case "published": return "published"
        case "archived":  return "archived"
        default:          return status
        }
    }

    #if canImport(ImpressRustCore)
    /// Lazy SharedStore opener. Each call returns a fresh handle — the store
    /// is cheap to open against an existing SQLite file. Tests inject
    /// `testStorePath` to point at an isolated database.
    private func openStore() -> SharedStore? {
        let path = testStorePath ?? SharedWorkspace.databaseURL.path
        return try? SharedStore.open(path: path)
    }
    #endif
}

