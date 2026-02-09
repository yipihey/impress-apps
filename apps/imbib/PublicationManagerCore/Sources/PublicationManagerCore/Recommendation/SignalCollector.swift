//
//  SignalCollector.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import OSLog

// MARK: - Signal Collector (ADR-020)

/// Collects user interaction signals for the recommendation engine.
///
/// Hooks into existing services to capture save/dismiss/star/read/download actions.
public actor SignalCollector {

    // MARK: - Singleton

    public static let shared = SignalCollector()

    // MARK: - Properties

    private var eventBuffer: [TrainingEvent] = []
    private let bufferFlushThreshold = 10

    // MARK: - Initialization

    private init() {}

    // MARK: - Store Access Helper

    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - Signal Recording

    /// Record when a paper is saved from Inbox.
    public func recordSave(_ publicationID: UUID) async {
        await recordAction(.saved, for: publicationID)
    }

    /// Record when a paper is dismissed from Inbox.
    public func recordDismiss(_ publicationID: UUID) async {
        await recordAction(.dismissed, for: publicationID)
    }

    /// Record when a paper is starred.
    public func recordStar(_ publicationID: UUID) async {
        await recordAction(.starred, for: publicationID)
    }

    /// Record when a paper is unstarred.
    public func recordUnstar(_ publicationID: UUID) async {
        await recordAction(.unstarred, for: publicationID)
    }

    /// Record when a paper is marked as read.
    public func recordRead(_ publicationID: UUID) async {
        await recordAction(.read, for: publicationID)
    }

    /// Record when a PDF is downloaded.
    public func recordPDFDownload(_ publicationID: UUID) async {
        await recordAction(.pdfDownloaded, for: publicationID)
    }

    /// Record explicit "more like this" request.
    public func recordMoreLikeThis(_ publicationID: UUID) async {
        await recordAction(.moreLikeThis, for: publicationID)
    }

    /// Record explicit "less like this" request.
    public func recordLessLikeThis(_ publicationID: UUID) async {
        await recordAction(.lessLikeThis, for: publicationID)
    }

    /// Record when paper is added to a collection.
    public func recordAddToCollection(_ publicationID: UUID) async {
        await recordAction(.addedToCollection, for: publicationID)
    }

    // MARK: - Core Recording Logic

    private func recordAction(_ action: TrainingAction, for publicationID: UUID) async {
        // Check if recommendations are enabled
        let enabled = await RecommendationSettingsStore.shared.isEnabled()
        guard enabled else { return }

        // Extract publication data from the store
        guard let pub = await withStore({ $0.getPublicationDetail(id: publicationID) }) else { return }

        let title = pub.title
        let authorString = pub.authorString
        let citeKey = pub.citeKey
        let authors = pub.authors.map { $0.familyName.lowercased() }
        let journal = pub.journal?.lowercased()
        let categories = pub.fields["primaryclass"] ?? pub.fields["categories"]

        // Compute weight deltas
        let weightDeltas = computeWeightDeltas(
            authors: authors,
            journal: journal,
            title: title,
            categories: categories,
            action: action
        )

        // Create training event
        let event = TrainingEvent(
            action: action,
            publicationID: publicationID,
            publicationTitle: title,
            publicationAuthors: authorString,
            weightDeltas: weightDeltas
        )

        // Buffer the event
        eventBuffer.append(event)

        Logger.recommendation.debug("Recorded \(action.rawValue) for: \(citeKey)")

        // Flush if buffer is full
        if eventBuffer.count >= bufferFlushThreshold {
            await flushBuffer()
        }

        // Notify for immediate weight update
        NotificationCenter.default.post(
            name: .recommendationTrainingEventRecorded,
            object: event
        )
    }

    /// Compute which features and affinities should be updated for this action.
    private func computeWeightDeltas(
        authors: [String],
        journal: String?,
        title: String,
        categories: String?,
        action: TrainingAction
    ) -> [String: Double] {
        var deltas: [String: Double] = [:]
        let multiplier = action.learningMultiplier

        for authorFamilyName in authors {
            let key = "author:\(authorFamilyName)"
            deltas[key] = multiplier
        }

        if let journal = journal {
            let key = "venue:\(journal)"
            deltas[key] = multiplier * 0.5
        }

        let titleKeywords = extractTitleKeywords(title)
        for keyword in titleKeywords {
            let key = "topic:\(keyword.lowercased())"
            deltas[key] = multiplier * 0.3
        }

        if let categories = categories {
            for category in categories.split(separator: " ").map(String.init) {
                let key = "category:\(category.lowercased())"
                deltas[key] = multiplier * 0.4
            }
        }

        return deltas
    }

    private func extractTitleKeywords(_ title: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "the", "and", "or", "but", "in", "on", "at", "to", "for",
            "of", "with", "by", "from", "as", "is", "was", "are", "were", "been",
            "be", "have", "has", "had", "do", "does", "did", "will", "would",
            "could", "should", "may", "might", "must", "shall", "can", "need",
            "using", "via", "based", "new", "novel", "approach", "method", "study"
        ]

        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopWords.contains($0) }

        return Array(words.prefix(5))
    }

    // MARK: - Buffer Management

    /// Flush buffered events to persistent storage.
    public func flushBuffer() async {
        guard !eventBuffer.isEmpty else { return }

        let events = eventBuffer
        eventBuffer.removeAll()

        await MainActor.run {
            let store = RustStoreAdapter.shared

            guard let defaultLibrary = store.getDefaultLibrary() else { return }

            // Get existing profile or start fresh
            var profile: RecommendationProfile
            if let existingJSON = store.getRecommendationProfile(libraryId: defaultLibrary.id),
               let existing = RecommendationProfile.fromJSON(existingJSON) {
                profile = existing
            } else {
                profile = RecommendationProfile()
            }

            // Append events
            profile.trainingEvents.append(contentsOf: events)

            // Keep only last 1000 events
            if profile.trainingEvents.count > 1000 {
                profile.trainingEvents = Array(profile.trainingEvents.suffix(1000))
            }

            profile.lastUpdated = Date()

            // Save back
            let eventsJSON = (try? JSONEncoder().encode(profile.trainingEvents)).flatMap { String(data: $0, encoding: .utf8) }

            store.createOrUpdateRecommendationProfile(
                libraryId: defaultLibrary.id,
                trainingEventsJson: eventsJSON
            )
        }

        Logger.recommendation.info("Flushed \(events.count) training events to storage")
    }

    /// Get recent training events (for UI display).
    public func recentEvents(limit: Int = 50) async -> [TrainingEvent] {
        return await MainActor.run {
            let store = RustStoreAdapter.shared

            guard let defaultLibrary = store.getDefaultLibrary(),
                  let json = store.getRecommendationProfile(libraryId: defaultLibrary.id),
                  let profile = RecommendationProfile.fromJSON(json) else {
                return []
            }

            return Array(profile.trainingEvents.suffix(limit).reversed())
        }
    }

    /// Undo a training event (remove its effects).
    public func undoEvent(_ event: TrainingEvent) async {
        // Post notification for OnlineLearner to reverse the weights
        NotificationCenter.default.post(
            name: .recommendationTrainingEventUndone,
            object: event
        )

        // Remove from storage
        await MainActor.run {
            let store = RustStoreAdapter.shared

            guard let defaultLibrary = store.getDefaultLibrary(),
                  let json = store.getRecommendationProfile(libraryId: defaultLibrary.id),
                  var profile = RecommendationProfile.fromJSON(json) else {
                return
            }

            profile.trainingEvents.removeAll { $0.id == event.id }
            profile.lastUpdated = Date()

            let eventsJSON = (try? JSONEncoder().encode(profile.trainingEvents)).flatMap { String(data: $0, encoding: .utf8) }

            store.createOrUpdateRecommendationProfile(
                libraryId: defaultLibrary.id,
                trainingEventsJson: eventsJSON
            )
        }

        Logger.recommendation.info("Undone training event: \(event.action.rawValue)")
    }

    // MARK: - Deduplication

    private var recentActions: [(UUID, TrainingAction, Date)] = []
    private let deduplicationWindow: TimeInterval = 2.0

    private func isDuplicateAction(_ action: TrainingAction, publicationID: UUID) -> Bool {
        let now = Date()
        recentActions.removeAll { now.timeIntervalSince($0.2) > deduplicationWindow }

        if recentActions.contains(where: { $0.0 == publicationID && $0.1 == action }) {
            return true
        }

        recentActions.append((publicationID, action, now))
        return false
    }
}

// MARK: - Notifications

public extension Notification.Name {
    static let recommendationTrainingEventRecorded = Notification.Name("recommendationTrainingEventRecorded")
    static let recommendationTrainingEventUndone = Notification.Name("recommendationTrainingEventUndone")
}

// MARK: - Logger Extension

extension Logger {
    static let recommendation = Logger(subsystem: "com.imbib.app", category: "recommendation")
}
