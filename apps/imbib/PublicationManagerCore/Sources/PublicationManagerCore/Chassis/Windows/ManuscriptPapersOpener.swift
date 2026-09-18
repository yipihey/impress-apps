#if os(macOS)
//
//  ManuscriptPapersOpener.swift
//  PublicationManagerCore
//
//  One way in to the manuscript-papers window, whoever asks: imprint's Papers
//  command (in-process, with the editor's live cite keys), the
//  `imbib://manuscript/<id>/papers` URL, the
//  `imbib-app-service_open-manuscript-papers` verb, the command palette.
//
//  Every caller gets the same two steps in the same order — sync the
//  manuscript's collection, then open the window on it — so no caller can
//  show a window that is missing the papers the manuscript cites.
//

import Foundation
import OSLog

@MainActor
public enum ManuscriptPapersOpener {

    public enum Outcome: Equatable {
        case opened(ManuscriptPapersRequest)
        case failed(String)

        public var request: ManuscriptPapersRequest? {
            if case .opened(let request) = self { return request }
            return nil
        }

        public var errorMessage: String? {
            if case .failed(let why) = self { return why }
            return nil
        }
    }

    /// Sync the manuscript's papers collection and show it.
    ///
    /// - Parameters:
    ///   - citeKeys: the keys to fold into the collection. Pass the editor's
    ///     live buffer when there is one; `nil` reads the manuscript's stored
    ///     text, which is what an out-of-process caller can see.
    @discardableResult
    public static func open(
        manuscriptID: UUID,
        titleOverride: String? = nil,
        formatOverride: DocumentFormat? = nil,
        citeKeys: [String]? = nil
    ) -> Outcome {
        let manuscript = RustStoreAdapter.shared.getManuscriptDetail(id: manuscriptID)
        if manuscript == nil {
            Logger.editor.warningCapture(
                "papers window: no manuscript \(manuscriptID) in the store", category: "citation")
        }
        let storedFormat = manuscript.flatMap { DocumentFormat(rawValue: $0.format) }
        let format = formatOverride ?? storedFormat ?? .typst
        let keys = citeKeys ?? ManuscriptCiteKeyScanner.keys(of: manuscriptID, detail: manuscript, format: format)
        let title = titleOverride ?? manuscript?.title

        guard let outcome = CollectionStoreAdapter.shared.syncManuscriptPapers(
            manuscriptID: manuscriptID,
            citeKeys: keys,
            // The name is Rust's default ("<title> — papers"); one definition.
            collectionName: nil
        ), let collectionID = UUID(uuidString: outcome.collectionId) else {
            return .failed(
                "imbib could not make a papers collection for this manuscript — it needs at "
                    + "least one library.")
        }

        let request = ManuscriptPapersRequest(
            collectionID: collectionID,
            collectionName: outcome.collectionName,
            manuscriptID: manuscriptID,
            manuscriptTitle: title,
            format: format,
            missingCiteKeys: outcome.missingCiteKeys
        )
        guard ManuscriptPapersWindowController.shared.open(request) else {
            return .failed("imbib is still starting up — try again in a moment.")
        }
        return .opened(request)
    }

}
#endif
