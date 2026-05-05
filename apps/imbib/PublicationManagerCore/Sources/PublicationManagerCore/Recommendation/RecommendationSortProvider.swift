//
//  RecommendationSortProvider.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import SwiftUI
import OSLog

// MARK: - Recommendation Sort Provider (ADR-020)

/// Observable object that provides recommendation-based sorting for publication lists.
///
/// Use this in views to get sorted publications when "Recommended" sort is selected.
/// The provider caches results and invalidates on training events.
@MainActor
@Observable
public final class RecommendationSortProvider {

    // MARK: - Singleton

    public static let shared = RecommendationSortProvider()

    // MARK: - Published State

    /// Cached ranking results (publication ID to score)
    public private(set) var cachedRanking: [UUID: Double] = [:]

    /// Cached top reasons per publication (for inline display)
    public private(set) var cachedReasons: [UUID: [String]] = [:]

    /// Whether a ranking computation is in progress
    public private(set) var isRanking = false

    /// IDs of serendipity slot publications
    public private(set) var serendipitySlotIDs: Set<UUID> = []

    // MARK: - Properties

    private var lastRankingDate: Date?
    private let cacheValiditySeconds: TimeInterval = 300  // 5 minutes
    private var rankingTask: Task<Void, Never>?

    // MARK: - Initialization

    private init() {
        // Observe training events to invalidate cache
        NotificationCenter.default.addObserver(
            forName: .recommendationTrainingEventRecorded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateCache()
        }
    }

    // MARK: - Sorting

    /// Sort publication IDs by recommendation score.
    ///
    /// - Parameters:
    ///   - publicationIDs: Publication IDs to sort
    ///   - ascending: If true, lowest scores first (unusual but supported)
    /// - Returns: Sorted publication IDs
    public func sort(
        _ publicationIDs: [UUID],
        ascending: Bool = false
    ) async -> [UUID] {
        // Check if we need to recompute
        let needsRecompute = cachedRanking.isEmpty ||
            !isCacheValid(for: publicationIDs) ||
            lastRankingDate == nil ||
            Date().timeIntervalSince(lastRankingDate!) > cacheValiditySeconds

        if needsRecompute {
            await computeRanking(for: publicationIDs)
        }

        // Sort using cached scores
        return publicationIDs.sorted { id1, id2 in
            let score1 = cachedRanking[id1] ?? 0
            let score2 = cachedRanking[id2] ?? 0

            if ascending {
                return score1 < score2
            } else {
                return score1 > score2
            }
        }
    }

    /// Get the recommendation score for a publication.
    ///
    /// Returns cached score if available, otherwise 0.
    public func score(for publicationID: UUID) -> Double {
        cachedRanking[publicationID] ?? 0
    }

    /// Check if a publication is a serendipity slot.
    public func isSerendipitySlot(_ publicationID: UUID) -> Bool {
        serendipitySlotIDs.contains(publicationID)
    }

    /// Force recompute ranking for publications.
    public func refresh(for publicationIDs: [UUID]) async {
        invalidateCache()
        await computeRanking(for: publicationIDs)
    }

    // MARK: - Cache Management

    /// Get the top reasons for a publication's recommendation.
    public func topReasons(for publicationID: UUID) -> [String] {
        cachedReasons[publicationID] ?? []
    }

    /// Get a one-line recommendation reason for display in list rows.
    public func inlineReason(for publicationID: UUID) -> String? {
        let reasons = cachedReasons[publicationID] ?? []
        guard !reasons.isEmpty else { return nil }
        if serendipitySlotIDs.contains(publicationID) {
            return "Discovery: new area for you"
        }
        return reasons.prefix(2).joined(separator: " · ")
    }

    /// Invalidate the cached ranking.
    public func invalidateCache() {
        cachedRanking.removeAll()
        cachedReasons.removeAll()
        serendipitySlotIDs.removeAll()
        lastRankingDate = nil
        rankingTask?.cancel()
        rankingTask = nil
        Logger.recommendation.debug("Recommendation sort cache invalidated")
    }

    // MARK: - Private Methods

    private func isCacheValid(for publicationIDs: [UUID]) -> Bool {
        // Cache is valid if we have scores for all publications
        let idSet = Set(publicationIDs)
        let cachedIDs = Set(cachedRanking.keys)
        return idSet.isSubset(of: cachedIDs)
    }

    private func computeRanking(for publicationIDs: [UUID]) async {
        // Cancel any existing ranking task
        rankingTask?.cancel()

        guard !publicationIDs.isEmpty else {
            cachedRanking.removeAll()
            serendipitySlotIDs.removeAll()
            return
        }

        isRanking = true
        defer { isRanking = false }

        // Get ranking from engine
        let ranked = await RecommendationEngine.shared.rank(publicationIDs)

        // Update cache
        var newRanking: [UUID: Double] = [:]
        var newReasons: [UUID: [String]] = [:]
        var newSerendipitySlots: Set<UUID> = []

        for rankedPub in ranked {
            newRanking[rankedPub.publicationID] = rankedPub.score.total
            newReasons[rankedPub.publicationID] = rankedPub.score.topReasons
            if rankedPub.isSerendipitySlot {
                newSerendipitySlots.insert(rankedPub.publicationID)
            }
        }

        cachedRanking = newRanking
        cachedReasons = newReasons
        serendipitySlotIDs = newSerendipitySlots
        lastRankingDate = Date()

        Logger.recommendation.info("Computed recommendation ranking for \(publicationIDs.count) publications")
    }
}

// MARK: - Publication Row Data Extension

@MainActor
extension PublicationRowData {

    /// Recommendation score for this publication (if available).
    public var recommendationScore: Double {
        RecommendationSortProvider.shared.score(for: id)
    }

    /// Whether this is a serendipity slot.
    public var isSerendipitySlot: Bool {
        RecommendationSortProvider.shared.isSerendipitySlot(id)
    }

    /// One-line reason for the recommendation (for display in list rows).
    public var inlineRecommendationReason: String? {
        RecommendationSortProvider.shared.inlineReason(for: id)
    }
}
