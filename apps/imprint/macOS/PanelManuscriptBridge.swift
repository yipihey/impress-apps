//
//  PanelManuscriptBridge.swift
//  imprint
//
//  Panels Phase B/C: the store↔ImprintDocument adapter for the document-coupled
//  flanking panels (Throughline, Veusz). The shared chassis has no
//  `ImprintDocument` — only a store-backed `ManuscriptEditorSession`. These
//  panels still bind `$document: ImprintDocument`, so imprint hydrates one from
//  the store per manuscript, keeps its `source` in sync with the editor (the
//  editor stays the source of truth), and lets the panels persist their own
//  non-source fields through their existing coordinators (ThroughlineCoordinator
//  → ImprintStoreAdapter; VeuszWorkingDirectory). imbib never constructs one.
//

#if os(macOS)
import Foundation
import ImprintCore
import PublicationManagerCore

@MainActor
@Observable
final class PanelManuscriptBridge {
    let manuscriptID: UUID
    var doc: ImprintDocument

    init(manuscriptID: UUID) {
        self.manuscriptID = manuscriptID

        // Load the manuscript from the store (mirrors ManuscriptEditorView.loadFromStore).
        var d: ImprintDocument
        if let m = ManuscriptStoreAdapter.shared.manuscript(id: manuscriptID) {
            d = ImprintDocument(format: m.format == .latex ? .latex : .typst)
            d.id = manuscriptID
            d.title = m.title
            d.authors = m.authors
            d.source = m.body
            d.modifiedAt = m.bodyModifiedAt ?? Date()
        } else {
            d = ImprintDocument(format: .typst)
            d.id = manuscriptID
        }

        // Hydrate the throughline sidecars from the store (no .imprint file in
        // store-first) so the throughline pane opens populated.
        if let tl = ImprintStoreAdapter.shared.loadThroughline(documentID: manuscriptID.uuidString) {
            d.throughlineSource = tl.source
            d.throughlineAnchorsJSON = tl.anchorMapJSON.isEmpty ? nil : tl.anchorMapJSON
        }

        // Veusz plots manifest is rebuilt from the working directory in Panels
        // Phase C (`refreshPlots()`); left empty here.

        self.doc = d
    }

    /// Keep the bridged document's body in lockstep with the live editor buffer
    /// (the editor owns `source`; the panels only read it for section extraction
    /// / plot insertion context).
    func syncSource(_ latest: String) {
        if doc.source != latest { doc.source = latest }
    }
}

/// One bridge per manuscript, cached so switching the inspector panel (or
/// selection round-trips) doesn't reload the document. Mirrors
/// `ManuscriptSessionRegistry`'s keyed-by-UUID pattern.
@MainActor
final class PanelBridgeRegistry {
    static let shared = PanelBridgeRegistry()
    private var bridges: [UUID: PanelManuscriptBridge] = [:]

    func bridge(for manuscriptID: UUID) -> PanelManuscriptBridge {
        if let existing = bridges[manuscriptID] { return existing }
        let bridge = PanelManuscriptBridge(manuscriptID: manuscriptID)
        bridges[manuscriptID] = bridge
        return bridge
    }
}
#endif
