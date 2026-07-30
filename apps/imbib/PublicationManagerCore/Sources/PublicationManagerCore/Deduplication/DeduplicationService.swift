//
//  DeduplicationService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//
//  Stage 7 item 5: the grouping algorithm, the source-priority table and the
//  fuzzy matcher moved to `imbib_core::deduplication::orchestration`. What is
//  left here is the actor shim — `SearchViewModel` holds this service and calls
//  it with `await`, and `SearchResult` / `DeduplicatedResult` are the app's
//  value types, so the boundary conversion has to live somewhere.
//
//  The Rust side is the ported Swift algorithm, not a different one: transitive
//  grouping through an identifier index, the numeric priority table
//  (crossref 10 … dblp 70, unknown 100), and the single-source fast path.
//  `crates/imbib-core/tests/golden_parity.rs` asserts group-for-group parity
//  against output captured from this file before the port, with the one
//  deliberate divergence named there (Rust also normalizes an `arXiv:` prefix,
//  so `arXiv:2301.99999` and `2301.99999` now merge — Swift left the duplicate
//  in the list).
//
//  Fuzzy matching stays OFF, which is also parity: the `fuzzyMatch` /
//  `titleSimilarity` / `normalizeTitle` helpers that used to sit here were
//  never called by `deduplicate`. Enabling them would start merging papers that
//  share no identifier at all — a real product change, not a port.
//

import Foundation
import ImbibRustCore
import OSLog

// MARK: - Deduplication Service

/// Deduplicates search results from multiple sources.
/// Uses identifier matching (and, if configured, fuzzy title matching).
public actor DeduplicationService {

    private let config: DeduplicationOrchestratorConfig

    // MARK: - Initialization

    public init(config: DeduplicationOrchestratorConfig = .default) {
        self.config = config
    }

    // MARK: - Public API

    /// Deduplicate search results from multiple sources.
    public func deduplicate(_ results: [SearchResult]) -> [DeduplicatedResult] {
        Logger.deduplication.entering()
        defer { Logger.deduplication.exiting() }

        guard !results.isEmpty else { return [] }

        let groups = RustDeduplicationOrchestrator.deduplicate(results, config: config)
        let deduplicated = groups.map { group in
            DeduplicatedResult(
                primary: group.primary,
                alternates: group.alternates,
                identifiers: group.identifiers
            )
        }

        Logger.deduplication.info("Deduplicated \(results.count) results to \(deduplicated.count)")
        return deduplicated
    }

    /// Priority of a source when choosing a group's primary result — lower
    /// wins, unknown sources get 100. Reads the Rust table so the app cannot
    /// hold a second copy of it.
    public static func priority(forSource sourceID: String) -> Int {
        Int(dedupSourcePriority(sourceId: sourceID))
    }

    /// The whole source-priority table, highest priority first.
    public static var sourcePriorities: [(sourceID: String, priority: Int)] {
        dedupSourcePriorities().map { ($0.sourceId, Int($0.priority)) }
    }
}
