//
//  SignalCollector.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import CoreData
import OSLog

// MARK: - Signal Collector (ADR-020)

/// Collects user interaction signals for the recommendation engine.
///
/// Hooks into existing services (InboxTriageService, LibraryViewModel, PDFManager)
/// to capture keep/dismiss/star/read/download actions.
public actor SignalCollector {

    // MARK: - Singleton

    public static let shared = SignalCollector()

    // MARK: - Properties

    private let persistenceController: PersistenceController
    private var eventBuffer: [TrainingEvent] = []
    private let bufferFlushThreshold = 10

    // MARK: - Initialization

    private init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - Signal Recording

    /// Record when a paper is kept from Inbox.
    public func recordKeep(_ publication: CDPublication) async {
        await recordAction(.kept, for: publication)
    }

    /// Record when a paper is dismissed from Inbox.
    public func recordDismiss(_ publication: CDPublication) async {
        await recordAction(.dismissed, for: publication)
    }

    /// Record when a paper is starred.
    public func recordStar(_ publication: CDPublication) async {
        await recordAction(.starred, for: publication)
    }

    /// Record when a paper is unstarred.
    public func recordUnstar(_ publication: CDPublication) async {
        await recordAction(.unstarred, for: publication)
    }

    /// Record when a paper is marked as read.
    public func recordRead(_ publication: CDPublication) async {
        await recordAction(.read, for: publication)
    }

    /// Record when a PDF is downloaded.
    public func recordPDFDownload(_ publication: CDPublication) async {
        await recordAction(.pdfDownloaded, for: publication)
    }

    /// Record explicit "more like this" request.
    public func recordMoreLikeThis(_ publication: CDPublication) async {
        await recordAction(.moreLikeThis, for: publication)
    }

    /// Record explicit "less like this" request.
    public func recordLessLikeThis(_ publication: CDPublication) async {
        await recordAction(.lessLikeThis, for: publication)
    }

    /// Record when paper is added to a collection.
    public func recordAddToCollection(_ publication: CDPublication) async {
        await recordAction(.addedToCollection, for: publication)
    }

    // MARK: - Core Recording Logic

    private func recordAction(_ action: TrainingAction, for publication: CDPublication) async {
        // Check if recommendations are enabled
        let enabled = await RecommendationSettingsStore.shared.isEnabled()
        guard enabled else { return }

        // THREAD SAFETY: Extract ALL needed Core Data properties on main actor FIRST
        // CDPublication is bound to the main actor context, so we cannot access its
        // properties directly from this actor's thread.
        let (publicationID, title, authorString, citeKey, authors, journal, categories) = await MainActor.run {
            (publication.id,
             publication.title ?? "Untitled",
             publication.authorString,
             publication.citeKey,
             publication.sortedAuthors.map { $0.familyName.lowercased() },
             publication.fields["journal"]?.lowercased(),
             publication.fields["primaryclass"] ?? publication.fields["categories"])
        }

        // Compute weight deltas using extracted Sendable values (safe on actor thread)
        let weightDeltas = computeWeightDeltas(
            authors: authors,
            journal: journal,
            title: title,
            categories: categories,
            action: action
        )

        // Create training event using extracted values
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
    /// Accepts pre-extracted Sendable values to avoid accessing Core Data off main actor.
    private func computeWeightDeltas(
        authors: [String],
        journal: String?,
        title: String,
        categories: String?,
        action: TrainingAction
    ) -> [String: Double] {
        var deltas: [String: Double] = [:]
        let multiplier = action.learningMultiplier

        // Author affinities
        for authorFamilyName in authors {
            let key = "author:\(authorFamilyName)"
            deltas[key] = multiplier
        }

        // Venue/journal affinity
        if let journal = journal {
            let key = "venue:\(journal)"
            deltas[key] = multiplier * 0.5  // Venue is weaker signal than author
        }

        // Topic affinities from title keywords
        let titleKeywords = extractTitleKeywords(title)
        for keyword in titleKeywords {
            let key = "topic:\(keyword.lowercased())"
            deltas[key] = multiplier * 0.3  // Topic is weaker signal
        }

        // arXiv category
        if let categories = categories {
            for category in categories.split(separator: " ").map(String.init) {
                let key = "category:\(category.lowercased())"
                deltas[key] = multiplier * 0.4
            }
        }

        return deltas
    }

    /// Extract meaningful keywords from title for topic tracking.
    private func extractTitleKeywords(_ title: String) -> [String] {
        // Common stop words to filter out
        let stopWords: Set<String> = [
            "a", "an", "the", "and", "or", "but", "in", "on", "at", "to", "for",
            "of", "with", "by", "from", "as", "is", "was", "are", "were", "been",
            "be", "have", "has", "had", "do", "does", "did", "will", "would",
            "could", "should", "may", "might", "must", "shall", "can", "need",
            "using", "via", "based", "new", "novel", "approach", "method", "study"
        ]

        // Extract words, filter stop words, require minimum length
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopWords.contains($0) }

        // Return up to 5 most significant words
        return Array(words.prefix(5))
    }

    // MARK: - Buffer Management

    /// Flush buffered events to persistent storage.
    public func flushBuffer() async {
        guard !eventBuffer.isEmpty else { return }

        let events = eventBuffer
        eventBuffer.removeAll()

        // Get or create the global recommendation profile
        await MainActor.run {
            let context = persistenceController.viewContext

            let request = NSFetchRequest<CDRecommendationProfile>(entityName: "RecommendationProfile")
            request.predicate = NSPredicate(format: "library == nil")  // Global profile
            request.fetchLimit = 1

            let profile: CDRecommendationProfile
            if let existing = try? context.fetch(request).first {
                profile = existing
            } else {
                // Create new global profile
                profile = CDRecommendationProfile(context: context)
                profile.id = UUID()
                profile.lastUpdated = Date()
            }

            // Append events to profile's training data
            var existingEvents: [TrainingEvent] = []
            if let data = profile.trainingEventsData,
               let decoded = try? JSONDecoder().decode([TrainingEvent].self, from: data) {
                existingEvents = decoded
            }

            existingEvents.append(contentsOf: events)

            // Keep only last 1000 events to prevent unbounded growth
            if existingEvents.count > 1000 {
                existingEvents = Array(existingEvents.suffix(1000))
            }

            if let encoded = try? JSONEncoder().encode(existingEvents) {
                profile.trainingEventsData = encoded
            }

            profile.lastUpdated = Date()
            persistenceController.save()
        }

        Logger.recommendation.info("Flushed \(events.count) training events to storage")
    }

    /// Get recent training events (for UI display).
    public func recentEvents(limit: Int = 50) async -> [TrainingEvent] {
        return await MainActor.run {
            let context = persistenceController.viewContext

            let request = NSFetchRequest<CDRecommendationProfile>(entityName: "RecommendationProfile")
            request.predicate = NSPredicate(format: "library == nil")
            request.fetchLimit = 1

            guard let profile = try? context.fetch(request).first,
                  let data = profile.trainingEventsData,
                  let events = try? JSONDecoder().decode([TrainingEvent].self, from: data) else {
                return []
            }

            return Array(events.suffix(limit).reversed())
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
            let context = persistenceController.viewContext

            let request = NSFetchRequest<CDRecommendationProfile>(entityName: "RecommendationProfile")
            request.predicate = NSPredicate(format: "library == nil")
            request.fetchLimit = 1

            guard let profile = try? context.fetch(request).first,
                  let data = profile.trainingEventsData,
                  var events = try? JSONDecoder().decode([TrainingEvent].self, from: data) else {
                return
            }

            events.removeAll { $0.id == event.id }

            if let encoded = try? JSONEncoder().encode(events) {
                profile.trainingEventsData = encoded
            }

            profile.lastUpdated = Date()
            persistenceController.save()
        }

        Logger.recommendation.info("Undone training event: \(event.action.rawValue)")
    }

    // MARK: - Deduplication

    /// Check if we've recently recorded the same action for the same publication.
    /// Prevents duplicate signals from rapid UI interactions.
    private var recentActions: [(UUID, TrainingAction, Date)] = []
    private let deduplicationWindow: TimeInterval = 2.0  // 2 seconds

    private func isDuplicateAction(_ action: TrainingAction, publicationID: UUID) -> Bool {
        let now = Date()

        // Clean old entries
        recentActions.removeAll { now.timeIntervalSince($0.2) > deduplicationWindow }

        // Check for duplicate
        if recentActions.contains(where: { $0.0 == publicationID && $0.1 == action }) {
            return true
        }

        // Record this action
        recentActions.append((publicationID, action, now))
        return false
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when a training event is recorded
    static let recommendationTrainingEventRecorded = Notification.Name("recommendationTrainingEventRecorded")

    /// Posted when a training event is undone
    static let recommendationTrainingEventUndone = Notification.Name("recommendationTrainingEventUndone")
}

// MARK: - Logger Extension

extension Logger {
    static let recommendation = Logger(subsystem: "com.imbib.app", category: "recommendation")
}
