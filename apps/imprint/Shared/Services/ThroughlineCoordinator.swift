//
//  ThroughlineCoordinator.swift
//  imprint
//
//  Bridges the open document's throughline sidecars (ADR-0016 D2) to the
//  shared store mirror and computes derived anchor state for the UI.
//
//  Opt-in invariant (ADR-0016 D1): every function short-circuits for
//  documents without a throughline. No mirror rows, no section writes, no
//  log lines for non-opted documents.
//
//  Three-point trace (CLAUDE.md): mutations log request → save → display
//  under the "throughline" category.
//

import Foundation
import ImpressLogging

// `ImprintStoreAdapter` (and the rest of ImprintCore) is cross-platform: the
// package declares .iOS(.v26), the imprint-iOS target already links it, and
// the adapter's only conditional is `#if canImport(ImpressRustCore)` — the
// same FFI guard the store uses on every platform. The `#if os(macOS)` that
// used to wrap this import (and three call sites below) gated the store
// WRITER, not any AppKit dependency, and was pure inertia: it made the
// throughline mirror silently no-op on iOS. Deleted 2026-07-29.
import ImprintCore

@MainActor
enum ThroughlineCoordinator {

    // MARK: - Creation / removal (explicit opt-in acts)

    /// Create the throughline sidecars for a document. The activation act of
    /// ADR-0016 D1 — only ever called from an explicit user action.
    static func create(in document: inout ImprintDocument) {
        guard !document.hasThroughline else { return }
        let title = document.title.isEmpty ? "Untitled" : document.title
        logInfo("Throughline create requested for doc=\(document.id)", category: "throughline")
        let source = ThroughlineIdentity.scaffoldSource(title: title)
        let map = ThroughlineIdentity.initialAnchorMap(documentID: document.id, source: source)
        document.throughlineSource = source
        document.throughlineAnchorsJSON = (try? map.serialize()) ?? "{}"
        mirror(document: document)
        logInfo("Throughline created for doc=\(document.id)", category: "throughline")
    }

    /// Remove the throughline (deactivation). The sidecars disappear from
    /// the package on next save; the store mirror is dropped immediately.
    static func remove(from document: inout ImprintDocument) {
        guard document.hasThroughline else { return }
        logInfo("Throughline remove requested for doc=\(document.id)", category: "throughline")
        document.throughlineSource = nil
        document.throughlineAnchorsJSON = nil
        let itemID = ThroughlineIdentity.itemID(documentID: document.id).uuidString.lowercased()
        ImprintStoreAdapter.shared.deleteThroughline(
            itemID: itemID, documentID: document.id.uuidString)
    }

    // MARK: - Derivation for the UI

    /// Current anchor map, parsed leniently (a corrupt ledger yields an
    /// empty map rather than crashing the pane; the file stays untouched).
    static func anchorMap(of document: ImprintDocument) -> ThroughlineAnchorMap {
        guard let json = document.throughlineAnchorsJSON,
              let map = try? ThroughlineAnchorMap.parse(json) else {
            return ThroughlineAnchorMap(documentID: document.id)
        }
        return map
    }

    /// Sections of the open buffer under their canonical slug keys, with
    /// current body hashes. This is the Swift-side view of "current
    /// manuscript state" that derivation compares the ledger against.
    static func sectionHashes(of document: ImprintDocument) -> [String: String] {
        var hashes: [String: String] = [:]
        for section in extractSections(of: document) {
            hashes[section.key] = ThroughlineText.sha256Hex(section.body)
        }
        return hashes
    }

    /// (slug key, title, body) for every heading section of the document.
    static func extractSections(of document: ImprintDocument)
        -> [(key: String, title: String, body: String)]
    {
        let format: SectionFormat = document.format == .latex ? .latex : .typst
        let sections = SectionExtractor.extract(
            from: document.source, documentID: document.id, format: format)
        var out: [(key: String, title: String, body: String)] = []
        var seenKeys = Set<String>()
        for section in sections {
            var key = ThroughlineText.sectionKey(forHeading: section.title)
            // Disambiguate duplicate headings by order of appearance so
            // every section stays addressable.
            if seenKeys.contains(key) {
                key = "\(key)-\(section.orderIndex)"
            }
            seenKeys.insert(key)
            let body = Self.slice(document.source, from: section.bodyStart, to: section.end)
            out.append((key: key, title: section.title, body: body))
        }
        return out
    }

    /// Derived anchor assessments for the pane badges.
    static func anchorStates(of document: ImprintDocument) -> [ThroughlineAnchorAssessment] {
        guard let source = document.throughlineSource else { return [] }
        return PerfMetrics.shared.measure(
            PerfBucket.throughline, detail: "anchorStates"
        ) {
            ThroughlineDerivation.anchorStates(
                map: anchorMap(of: document),
                sectionHashes: sectionHashes(of: document),
                paragraphs: ThroughlineText.extractParagraphs(source)
            )
        }
    }

    /// Unanchored, non-supporting section keys (ADR-0016 D7).
    static func coverage(of document: ImprintDocument) -> [String] {
        guard document.hasThroughline else { return [] }
        return ThroughlineDerivation.coverage(
            map: anchorMap(of: document),
            sectionKeys: extractSections(of: document).map(\.key)
        )
    }

    // MARK: - Ledger mutations (human acts — baseline on anchor)

    /// Anchor a paragraph to section keys, baselining ledger hashes at the
    /// current buffer state (equivalent to accepting a sync, ADR-0016 D6).
    static func setAnchor(
        in document: inout ImprintDocument, label: String, sectionKeys: [String]
    ) {
        guard let source = document.throughlineSource else { return }
        guard let paragraph = ThroughlineText.extractParagraphs(source)
            .first(where: { $0.label == label }) else {
            logWarning("setAnchor: no paragraph <\(label)>", category: "throughline")
            return
        }
        logInfo(
            "setAnchor <\(label)> → \(sectionKeys.joined(separator: ",")) doc=\(document.id)",
            category: "throughline")
        let hashes = sectionHashes(of: document)
        var map = anchorMap(of: document)
        var manuscriptHashes: [String: String] = [:]
        for key in sectionKeys {
            if let h = hashes[key] { manuscriptHashes[key] = h }
        }
        map.anchors[label] = ThroughlineAnchorEntry(
            sectionKeys: sectionKeys,
            manuscriptHashes: manuscriptHashes,
            throughlineHash: paragraph.contentHash
        )
        map.narrativeOrder[label] = paragraph.orderIndex
        map.supporting.removeAll { sectionKeys.contains($0) }
        persist(map: map, in: &document)
    }

    /// Remove an anchor from the ledger.
    static func removeAnchor(in document: inout ImprintDocument, label: String) {
        var map = anchorMap(of: document)
        guard map.anchors.removeValue(forKey: label) != nil else { return }
        map.narrativeOrder.removeValue(forKey: label)
        logInfo("removeAnchor <\(label)> doc=\(document.id)", category: "throughline")
        persist(map: map, in: &document)
    }

    /// Mark/unmark a section as deliberate supporting detail (ADR-0016 D7).
    static func markSupporting(
        in document: inout ImprintDocument, sectionKey: String, supporting: Bool
    ) {
        var map = anchorMap(of: document)
        map.supporting.removeAll { $0 == sectionKey }
        if supporting {
            map.supporting.append(sectionKey)
            map.supporting.sort()
        }
        logInfo(
            "markSupporting '\(sectionKey)' = \(supporting) doc=\(document.id)",
            category: "throughline")
        persist(map: map, in: &document)
    }

    /// Reorder a narrative beat without touching paragraph words. Legacy maps
    /// receive their first order baseline immediately before the move, so the
    /// resulting positions derive `throughline-ahead` and enter normal review.
    static func reorderParagraph(
        in document: inout ImprintDocument,
        label: String,
        beforeLabel: String
    ) -> Bool {
        guard let source = document.throughlineSource else { return false }
        let paragraphs = ThroughlineText.extractParagraphs(source)
        guard let reordered = ThroughlineText.reorderParagraph(
            source, label: label, beforeLabel: beforeLabel),
            reordered != source else { return false }
        logInfo(
            "Throughline reorder requested: <\(label)> before <\(beforeLabel)>",
            category: "throughline")
        var map = anchorMap(of: document)
        for paragraph in paragraphs where map.narrativeOrder[paragraph.label] == nil {
            map.narrativeOrder[paragraph.label] = paragraph.orderIndex
        }
        guard let json = try? map.serialize() else { return false }
        document.throughlineSource = reordered
        document.throughlineAnchorsJSON = json
        mirrorThroughlineOnly(document: document)
        logInfo("Throughline reorder saved", category: "throughline")
        let moved = anchorStates(of: document).filter(\.orderAhead).count
        logInfo("Throughline display: \(moved) order-ahead beats", category: "throughline")
        return true
    }

    private static func persist(map: ThroughlineAnchorMap, in document: inout ImprintDocument) {
        guard let json = try? map.serialize() else {
            logWarning("persist: anchor map serialization failed", category: "throughline")
            return
        }
        document.throughlineAnchorsJSON = json
        mirror(document: document)
        logInfo(
            "Ledger saved: \(map.anchors.count) anchors, \(map.supporting.count) supporting",
            category: "throughline")
    }

    // MARK: - Store mirror

    /// Skip all store mirroring under UI testing: `ManuscriptStoreAdapter`
    /// runs in-memory there, but `ImprintStoreAdapter` always opens the
    /// on-disk workspace — mirroring would pollute the real user store.
    /// (Adapter unification is the proper fix; tracked as follow-up.)
    private static var mirroringDisabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    /// Debounce handles. Static on a @MainActor enum; each schedule call
    /// captures a VALUE SNAPSHOT of the document (struct copy), never the
    /// live binding (CLAUDE.md: capture before async work).
    private static var pendingThroughlineMirror: Task<Void, Never>?

    /// Full mirror: throughline row + per-heading section rows. Used by
    /// creation and ledger mutations (rare, deliberate acts). Editor
    /// keystrokes use the debounced variants instead.
    static func mirror(document: ImprintDocument) {
        mirrorThroughlineOnly(document: document)
        mirrorSections(document: document)
    }

    /// Mirror ONLY the throughline row (one upsert). The manuscript's
    /// section rows can't change from a throughline edit.
    static func mirrorThroughlineOnly(document: ImprintDocument) {
        guard let source = document.throughlineSource,
              let anchorsJSON = document.throughlineAnchorsJSON,
              !mirroringDisabled else { return }
        let paragraphs = ThroughlineText.extractParagraphs(source)
        let itemID = ThroughlineIdentity.itemID(documentID: document.id).uuidString.lowercased()
        ImprintStoreAdapter.shared.storeThroughline(
            itemID: itemID,
            documentID: document.id.uuidString,
            title: document.title.isEmpty ? "Untitled" : document.title,
            source: source,
            anchorMapJSON: anchorsJSON,
            paragraphCount: paragraphs.count
        )
    }

    /// Mirror the document's heading sections under their slug keys so
    /// headless derivation (Rust service, HTTP, agents) compares against
    /// current manuscript state. Opted-in documents only.
    static func mirrorSections(document: ImprintDocument) {
        guard document.hasThroughline, !mirroringDisabled else { return }
        let sections = extractSections(of: document)
        for (index, section) in sections.enumerated() {
            ImprintStoreAdapter.shared.storeSection(
                sectionID: sectionMirrorID(documentID: document.id, sectionKey: section.key),
                title: section.title,
                body: section.body,
                sectionType: nil,
                orderIndex: index,
                documentID: document.id.uuidString.lowercased(),
                sectionKey: section.key
            )
        }
        logInfo(
            "Mirror saved: \(sections.count) sections doc=\(document.id)",
            category: "throughline")
    }

    /// Debounced throughline-row mirror for editor keystrokes (single
    /// upsert after the typing pause; one `try? await Task.sleep`, never
    /// in a loop, so cancellation propagates).
    static func scheduleThroughlineMirror(document: ImprintDocument) {
        let snapshot = document
        pendingThroughlineMirror?.cancel()
        pendingThroughlineMirror = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            mirrorThroughlineOnly(document: snapshot)
        }
    }

    // `scheduleSectionMirror` (debounced per-heading section mirror) was
    // deleted 2026-07-29: it had zero callers. Section rows are mirrored by
    // `mirror(document:)` on creation and ledger mutations, which is the only
    // path that ever ran. Its presence made the section subsystem look more
    // live than it is — see schema-refs.json for the surrounding audit.

    /// Deterministic mirror id for a (document, slug-key) section — the
    /// same UUID-v5 scheme `SectionStore::item_id` uses in Rust, so both
    /// layers address the same row.
    static func sectionMirrorID(documentID: UUID, sectionKey: String) -> String {
        ThroughlineIdentity.sectionItemID(documentID: documentID, sectionKey: sectionKey)
            .uuidString.lowercased()
    }

    // MARK: - Sync proposals (review-request checkpoints, ADR-0016 D6)

    /// A pending `throughline-sync` review checkpoint for this document.
    struct SyncProposal: Identifiable, Equatable {
        let id: String            // review-request item id
        let question: String
        let direction: String     // manuscript-ahead | throughline-ahead | broken
        let anchor: String
        let proposedParagraph: String?
        let currentParagraph: String?
        let note: String?
    }

    /// Pending (unresolved) sync proposals for a document, newest first.
    /// Read-only; resolution is the only write, and application happens in
    /// the task executor when the suspended task resumes — the UI never
    /// applies edits directly (one apply path, ADR-0016 D6).
    static func pendingProposals(documentID: UUID) -> [SyncProposal] {
        let docID = documentID.uuidString.lowercased()
        let rows = (try? ManuscriptStoreAdapter.shared.sharedStore.queryBySchema(
            schemaRef: "review-request@1.0.0", limit: 200, offset: 0)) ?? []
        var out: [SyncProposal] = []
        for row in rows {
            guard let data = row.payloadJson.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (payload["context_document_id"] as? String)?.lowercased() == docID,
                  (payload["resolution"] as? String ?? "").isEmpty,
                  let anchor = payload["context_anchor"] as? String else { continue }
            out.append(
                SyncProposal(
                    id: row.id,
                    question: payload["question"] as? String ?? "Apply proposed sync?",
                    direction: payload["context_direction"] as? String ?? "unknown",
                    anchor: anchor,
                    proposedParagraph: payload["context_proposed_paragraph"] as? String,
                    currentParagraph: payload["context_current_paragraph"] as? String,
                    note: payload["context_note"] as? String
                ))
        }
        return out
    }

    /// Resolve a proposal. `approved: true` → the suspended sync task
    /// applies + rebaselines on its next scheduler pass; `false` → the
    /// anchor stays visibly stale (staleness is a state, not an error).
    static func resolveProposal(id: String, approved: Bool) {
        let actor = "human:\(NSUserName())@imprint"
        let resolution = approved ? "approved" : "rejected"
        logInfo(
            "Proposal \(id) resolved '\(resolution)' by \(actor)",
            category: "throughline")
        do {
            try ManuscriptStoreAdapter.shared.sharedStore.resolveReview(
                id: id, resolution: resolution, resolvedBy: actor)
            logInfo("Proposal \(id) resolution saved", category: "throughline")
        } catch {
            logWarning(
                "Proposal \(id) resolution failed: \(error.localizedDescription)",
                category: "throughline")
        }
    }

    private static func slice(_ source: String, from start: Int, to end: Int) -> String {
        guard start < end, start >= 0 else { return "" }
        let s = source.index(source.startIndex, offsetBy: min(start, source.count))
        let e = source.index(source.startIndex, offsetBy: min(end, source.count))
        guard s < e else { return "" }
        return String(source[s..<e]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
