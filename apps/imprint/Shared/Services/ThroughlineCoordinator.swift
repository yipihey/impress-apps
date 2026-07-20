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

#if os(macOS)
import ImprintCore
#endif

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
        #if os(macOS)
        let itemID = ThroughlineIdentity.itemID(documentID: document.id).uuidString.lowercased()
        ImprintStoreAdapter.shared.deleteThroughline(
            itemID: itemID, documentID: document.id.uuidString)
        #endif
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
        return ThroughlineDerivation.anchorStates(
            map: anchorMap(of: document),
            sectionHashes: sectionHashes(of: document),
            paragraphs: ThroughlineText.extractParagraphs(source)
        )
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
        map.supporting.removeAll { sectionKeys.contains($0) }
        persist(map: map, in: &document)
    }

    /// Remove an anchor from the ledger.
    static func removeAnchor(in document: inout ImprintDocument, label: String) {
        var map = anchorMap(of: document)
        guard map.anchors.removeValue(forKey: label) != nil else { return }
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

    /// Mirror the sidecars into the shared store so headless surfaces
    /// (Rust service, MCP, CLI, agents) see the same state. Also mirrors
    /// the document's heading sections under the same slug keys so the
    /// Rust-side derivation compares against matching section rows.
    /// Only ever called for opted-in documents.
    static func mirror(document: ImprintDocument) {
        guard let source = document.throughlineSource,
              let anchorsJSON = document.throughlineAnchorsJSON else { return }
        #if os(macOS)
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
        // Per-heading section mirror (slug keys). Deterministic ids come
        // from the section key so repeated mirrors are idempotent.
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
            "Mirror saved: throughline + \(sections.count) sections doc=\(document.id)",
            category: "throughline")
        #endif
    }

    /// Deterministic mirror id for a (document, slug-key) section — the
    /// same UUID-v5 scheme `SectionStore::item_id` uses in Rust, so both
    /// layers address the same row.
    static func sectionMirrorID(documentID: UUID, sectionKey: String) -> String {
        ThroughlineIdentity.sectionItemID(documentID: documentID, sectionKey: sectionKey)
            .uuidString.lowercased()
    }

    private static func slice(_ source: String, from start: Int, to end: Int) -> String {
        guard start < end, start >= 0 else { return "" }
        let s = source.index(source.startIndex, offsetBy: min(start, source.count))
        let e = source.index(source.startIndex, offsetBy: min(end, source.count))
        guard s < e else { return "" }
        return String(source[s..<e]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
