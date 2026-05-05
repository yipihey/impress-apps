//
//  CitationUsageTracker.swift
//  ImprintCore
//
//  Writes `citation-usage@1.0.0` records that link manuscript sections
//  to the bibliography entries they cite. Subscribes to
//  `ImprintImpressStore.shared.events` so every section mutation is
//  re-scanned for cite keys; the diff against the previous scan drives
//  upserts and deletes.
//
//  This is the imprint half of T6 (bidirectional citation visibility).
//  Imbib consumes these records to surface a "papers cited in your
//  manuscripts" view — see `ImprintImpressStore.listCitationUsages()`
//  for the read side.
//
//  ## Cite key extraction
//
//  Cite keys are extracted from the section body with the same patterns
//  the `BibliographyGenerator` uses in the imprint macOS target:
//  - LaTeX: `\cite{key}`, `\citep{key}`, `\citet{key,other}`, extended
//    variants (`\citeauthor`, `\citeyear`, ...).
//  - Typst: `@citeKey` with word-boundary guards so emails don't match.
//
//  The tracker duplicates the extraction here (a small, dependency-free
//  regex pair) so `ImprintCore` doesn't gain a new cross-module dep.
//

import Foundation
import ImpressLogging
import ImpressStoreKit
import OSLog

private let usageLog = Logger(subsystem: "com.imprint.app", category: "citation-usage-tracker")

/// Background worker that keeps `citation-usage@1.0.0` records in sync
/// with the cite keys present in each manuscript section's body.
public actor CitationUsageTracker {

    public static let shared = CitationUsageTracker()

    /// Optional async resolver from cite key → imbib paper UUID string.
    /// The imprint macOS target wires this up to
    /// `ImprintPublicationService.shared.findByCiteKey(...)` so each
    /// citation-usage record carries the publication it resolves to.
    /// Unresolved keys are written with an empty `paper_id`; imbib's
    /// sidebar can still show them under "unresolved citations".
    public var paperIDResolver: (@Sendable (String) async -> String?)?

    public func setPaperIDResolver(_ resolver: @escaping @Sendable (String) async -> String?) {
        self.paperIDResolver = resolver
    }

    private var isRunning = false
    private var isRefreshing = false
    private var pendingRefresh = false
    /// Last-seen cite keys per section id. Used to compute the
    /// per-refresh diff so we can delete records for keys that have
    /// been removed from the source.
    private var lastSeenKeys: [UUID: Set<String>] = [:]
    /// When we first saw a given cite key in a given section. Preserved
    /// across refreshes so the `first_cited` timestamp is stable.
    private var firstCited: [String: Date] = [:]
    private var eventTask: Task<Void, Never>?

    public init() {}

    /// Start the event subscription. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let stream = ImprintImpressStore.shared.events.subscribe()
        eventTask = Task.detached(priority: .utility) { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .collectionMembershipChanged:
                    continue
                case .structural, .itemsMutated:
                    await self.triggerRefresh()
                }
            }
        }
        triggerRefresh()
    }

    // MARK: - Refresh orchestration

    private func triggerRefresh() {
        if isRefreshing {
            pendingRefresh = true
            return
        }
        isRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        defer { Task { [weak self] in await self?.finishRefresh() } }

        #if canImport(ImpressRustCore)
        // Walk every stored section and diff its current cite keys
        // against the last-seen set.
        let stubs = ImprintImpressStore.shared.listAllSections(limit: 10_000, offset: 0)

        var observedSectionIDs: Set<UUID> = []
        let now = Date()

        for stub in stubs {
            observedSectionIDs.insert(stub.id)
            // Need the full body to extract cite keys. listAllSections
            // returns inline bodies (no rehydrate); fall back to
            // loadSection if the body is empty but a hash is present.
            var body = stub.body ?? ""
            if body.isEmpty, stub.contentHash != nil,
               let full = ImprintImpressStore.shared.loadSection(id: stub.id) {
                body = full.body ?? ""
            }

            let currentKeys = Self.extractCiteKeys(from: body)
            let previousKeys = lastSeenKeys[stub.id] ?? []
            let added = currentKeys.subtracting(previousKeys)
            let removed = previousKeys.subtracting(currentKeys)

            if added.isEmpty && removed.isEmpty && currentKeys.isEmpty {
                continue
            }

            let sectionIDString = stub.id.uuidString
            let documentIDString = stub.documentID?.uuidString
            let continuing = currentKeys.intersection(previousKeys)

            // Pre-compute first-cited timestamps on the actor so the
            // MainActor block doesn't have to reach back through
            // isolation.
            let resolver = self.paperIDResolver
            var addedWithFirstCited: [(String, Date, String?)] = []
            for key in added {
                let paperID = await resolver?(key)
                addedWithFirstCited.append((key, firstCited["\(sectionIDString):\(key)"] ?? now, paperID))
            }
            var continuingWithFirstCited: [(String, Date, String?)] = []
            for key in continuing {
                let paperID = await resolver?(key)
                continuingWithFirstCited.append((key, firstCited["\(sectionIDString):\(key)"] ?? now, paperID))
            }
            let removedSnapshot = removed

            await MainActor.run {
                for (key, firstCitedAt, paperID) in addedWithFirstCited {
                    ImprintStoreAdapter.shared.upsertCitationUsage(
                        sectionID: sectionIDString,
                        documentID: documentIDString,
                        citeKey: key,
                        paperID: paperID,
                        firstCitedAt: firstCitedAt,
                        lastSeenAt: now
                    )
                }
                for key in removedSnapshot {
                    ImprintStoreAdapter.shared.deleteCitationUsage(
                        sectionID: sectionIDString,
                        citeKey: key
                    )
                }
                // Refresh lastSeen on keys that are still present so
                // stale records don't drift.
                for (key, firstCitedAt, paperID) in continuingWithFirstCited {
                    ImprintStoreAdapter.shared.upsertCitationUsage(
                        sectionID: sectionIDString,
                        documentID: documentIDString,
                        citeKey: key,
                        paperID: paperID,
                        firstCitedAt: firstCitedAt,
                        lastSeenAt: now
                    )
                }
            }

            for key in added {
                firstCited["\(sectionIDString):\(key)"] = now
            }
            for key in removed {
                firstCited.removeValue(forKey: "\(sectionIDString):\(key)")
            }
            lastSeenKeys[stub.id] = currentKeys
        }

        // Sections that were previously indexed but have disappeared
        // from the store need their records deleted.
        let droppedSections = Set(lastSeenKeys.keys).subtracting(observedSectionIDs)
        for sectionID in droppedSections {
            guard let keys = lastSeenKeys[sectionID] else { continue }
            let sectionIDString = sectionID.uuidString
            await MainActor.run {
                for key in keys {
                    ImprintStoreAdapter.shared.deleteCitationUsage(
                        sectionID: sectionIDString,
                        citeKey: key
                    )
                }
            }
            for key in keys {
                firstCited.removeValue(forKey: "\(sectionIDString):\(key)")
            }
            lastSeenKeys.removeValue(forKey: sectionID)
        }

        usageLog.infoCapture(
            "CitationUsageTracker refresh complete: \(observedSectionIDs.count) sections tracked",
            category: "citation-usage-tracker"
        )
        #endif
    }

    private func finishRefresh() async {
        isRefreshing = false
        if pendingRefresh {
            pendingRefresh = false
            triggerRefresh()
        }
    }

    // MARK: - Extraction

    /// Extract the set of cite keys referenced in a Typst/LaTeX body.
    static func extractCiteKeys(from source: String) -> Set<String> {
        var keys: Set<String> = []

        // LaTeX: \cite{a,b} \citep{c} \citet{d} \citeauthor{e} \citeyear*{f}
        let latexPatterns = [
            #"\\cite(?:author|year|alp|alt|p|t|num|text)?\*?\{([^}]+)\}"#
        ]
        for pattern in latexPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                let raw = String(source[keyRange])
                for key in raw.split(separator: ",") {
                    let trimmed = key.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { keys.insert(trimmed) }
                }
            }
        }

        // Typst: @citeKey with a word-boundary guard before the @.
        let typstPattern = #"(?<![a-zA-Z0-9_@])@([a-zA-Z][a-zA-Z0-9_-]*)"#
        if let regex = try? NSRegularExpression(pattern: typstPattern) {
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[keyRange])
                let lower = key.lowercased()
                let exclusions = ["param", "example", "deprecated", "available", "objc", "main"]
                if exclusions.contains(where: { lower.hasPrefix($0) }) { continue }
                keys.insert(key)
            }
        }

        return keys
    }
}
