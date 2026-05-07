//
//  JournalEventBridge.swift
//  imbib
//
//  Phase 3 of the impress journal pipeline (per docs/plan-journal-pipeline.md
//  §3.4 + the Phase 2 follow-up flagged at the end of that phase).
//
//  Bridges cross-app Darwin notifications (`ImpressNotification.manuscript*`)
//  to the local NotificationCenter so SwiftUI views can observe them via
//  `.onReceive(...publisher(for:))`. Without this bridge, journal mutations
//  written by impel (Archivist, Submission API) wouldn't trigger imbib UI
//  refresh.
//
//  The bridge is one-way (Darwin → NC). Nothing in imbib needs to listen to
//  NotificationCenter and re-broadcast as Darwin — local writes (e.g.
//  ManuscriptBridge.createManuscript) already post Darwin notifications
//  directly via ImpressNotification.post.
//

import Foundation
import ImpressKit
import OSLog

@MainActor
final class JournalEventBridge {

    static let shared = JournalEventBridge()

    private let logger = Logger(subsystem: "com.imbib.app", category: "journal-event-bridge")
    private var observations: [DarwinObservation] = []

    private init() {}

    /// Begin bridging journal Darwin events into NotificationCenter.
    /// Idempotent.
    func start() {
        guard observations.isEmpty else { return }

        let mappings: [(event: String, sources: [SiblingApp], local: Notification.Name)] = [
            (ImpressNotification.manuscriptStatusChanged,
             [.imbib, .impel, .imprint],
             .manuscriptDidChange),
            (ImpressNotification.manuscriptSnapshotCreated,
             [.imbib, .impel, .imprint],
             .manuscriptSnapshotDidLand),
            (ImpressNotification.manuscriptSubmissionReceived,
             [.imbib, .impel],
             .submissionsDidChange),
            (ImpressNotification.manuscriptSubmissionProposed,
             [.imbib, .impel],
             .submissionsDidChange),
            (ImpressNotification.manuscriptReviewCompleted,
             [.imbib, .impel],
             .manuscriptDidChange),
        ]

        for mapping in mappings {
            for source in mapping.sources {
                let observation = ImpressNotification.observe(
                    mapping.event,
                    from: source
                ) { [weak self] in
                    self?.republish(event: mapping.event, source: source, localName: mapping.local)
                }
                observations.append(observation)
            }
        }

        logger.info("JournalEventBridge: started — observing \(self.observations.count) cross-app journal events")
    }

    func stop() {
        for obs in observations { obs.invalidate() }
        observations.removeAll()
        logger.info("JournalEventBridge: stopped")
    }

    private nonisolated func republish(
        event: String,
        source: SiblingApp,
        localName: Notification.Name
    ) {
        // Read the latest payload that the writer staged before posting the
        // Darwin notification. Carry the resource IDs through into the local
        // userInfo so views can filter by manuscript ID.
        let payload = ImpressNotification.latestPayload(for: event, from: source)
        var userInfo: [AnyHashable: Any] = [
            "event": event,
            "source": source.rawValue,
        ]
        if let ids = payload?.resourceIDs {
            userInfo["resourceIDs"] = ids
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: localName,
                object: nil,
                userInfo: userInfo
            )
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when ImpressNotification.manuscriptSnapshotCreated fires.
    /// userInfo includes ["resourceIDs"] = [manuscriptID, revisionID].
    static let manuscriptSnapshotDidLand = Notification.Name("imbib.manuscriptSnapshotDidLand")
}
