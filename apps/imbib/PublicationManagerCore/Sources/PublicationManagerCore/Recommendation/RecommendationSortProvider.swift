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

    /// Sort publications by recommendation score.
    ///
    /// - Parameters:
    ///   - publications: Publications to sort
    ///   - ascending: If true, lowest scores first (unusual but supported)
    /// - Returns: Sorted publications
    public func sort(
        _ publications: [CDPublication],
        ascending: Bool = false
    ) async -> [CDPublication] {
        // Check if we need to recompute
        let needsRecompute = cachedRanking.isEmpty ||
            !isCacheValid(for: publications) ||
            lastRankingDate == nil ||
            Date().timeIntervalSince(lastRankingDate!) > cacheValiditySeconds

        if needsRecompute {
            await computeRanking(for: publications)
        }

        // Sort using cached scores
        return publications.sorted { pub1, pub2 in
            let score1 = cachedRanking[pub1.id] ?? 0
            let score2 = cachedRanking[pub2.id] ?? 0

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
    public func refresh(for publications: [CDPublication]) async {
        invalidateCache()
        await computeRanking(for: publications)
    }

    // MARK: - Cache Management

    /// Invalidate the cached ranking.
    public func invalidateCache() {
        cachedRanking.removeAll()
        serendipitySlotIDs.removeAll()
        lastRankingDate = nil
        rankingTask?.cancel()
        rankingTask = nil
        Logger.recommendation.debug("Recommendation sort cache invalidated")
    }

    // MARK: - Private Methods

    private func isCacheValid(for publications: [CDPublication]) -> Bool {
        // Cache is valid if we have scores for all publications
        let publicationIDs = Set(publications.map(\.id))
        let cachedIDs = Set(cachedRanking.keys)
        return publicationIDs.isSubset(of: cachedIDs)
    }

    private func computeRanking(for publications: [CDPublication]) async {
        // Cancel any existing ranking task
        rankingTask?.cancel()

        guard !publications.isEmpty else {
            cachedRanking.removeAll()
            serendipitySlotIDs.removeAll()
            return
        }

        isRanking = true
        defer { isRanking = false }

        // Get ranking from engine
        let ranked = await RecommendationEngine.shared.rank(publications)

        // Update cache
        var newRanking: [UUID: Double] = [:]
        var newSerendipitySlots: Set<UUID> = []

        for rankedPub in ranked {
            newRanking[rankedPub.publicationID] = rankedPub.score.total
            if rankedPub.isSerendipitySlot {
                newSerendipitySlots.insert(rankedPub.publicationID)
            }
        }

        cachedRanking = newRanking
        serendipitySlotIDs = newSerendipitySlots
        lastRankingDate = Date()

        Logger.recommendation.info("Computed recommendation ranking for \(publications.count) publications")
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
}
