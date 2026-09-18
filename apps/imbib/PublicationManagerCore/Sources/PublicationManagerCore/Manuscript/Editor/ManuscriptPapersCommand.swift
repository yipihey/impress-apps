#if os(macOS)
//
//  ManuscriptPapersCommand.swift
//  PublicationManagerCore
//
//  "Papers" from inside the editor: fold what the manuscript cites into its
//  imbib collection — from the LIVE buffer, which is newer than anything
//  saved — then ask imbib to show that collection in its papers window.
//
//  The editor host (imprint) calls this instead of hosting a paper panel. The
//  window is imbib's, in imbib's process, so the request travels as the
//  `imbib://manuscript/<id>/papers` URL, which also launches imbib if it is
//  closed. The sync happens HERE rather than only in imbib because only this
//  process can see the unsaved buffer; imbib syncs again on open (additive and
//  idempotent, so the two compose).
//

import AppKit
import Foundation
import ImpressKit
import OSLog

public extension Notification.Name {
    /// Show the manuscript's papers in imbib. Posted by imprint's menu item,
    /// its command palette and the editor's toolbar button; handled by the
    /// live editor, which is the only place the unsaved buffer exists.
    /// userInfo (optional): `documentID` (UUID) to target one manuscript.
    static let manuscriptShowPapers = Notification.Name("impress.manuscript.showPapers")
}

@MainActor
public enum ManuscriptPapersCommand {

    /// Ask the live editor to show its papers. Safe from anywhere — a menu
    /// item, a palette, an App Intent.
    public static func request(manuscriptID: UUID? = nil) {
        NotificationCenter.default.post(
            name: .manuscriptShowPapers,
            object: nil,
            userInfo: manuscriptID.map { ["documentID": $0] })
    }

    /// What the command did, for a host that wants to say something about it.
    public struct Result: Sendable, Equatable {
        public let collectionName: String
        public let memberCount: UInt32
        /// Cite keys in the manuscript that imbib has no paper for.
        public let missingCiteKeys: [String]
        /// Nil when everything worked.
        public let problem: String?

        public var didOpen: Bool { problem == nil }
    }

    /// Show the manuscript's papers in imbib.
    ///
    /// - Parameters:
    ///   - manuscriptID: the manuscript being edited.
    ///   - buffer: the editor's current text.
    ///   - format: its citation syntax.
    ///   - title: the manuscript's title, for the window and the collection name.
    @discardableResult
    public static func open(
        manuscriptID: UUID,
        buffer: String,
        format: DocumentFormat,
        title: String?
    ) -> Result {
        let keys = ManuscriptCiteKeyScanner.citeKeys(
            buffer: buffer,
            format: format,
            otherFiles: ManuscriptCiteKeyScanner.projectTexts(of: manuscriptID))

        guard let outcome = CollectionStoreAdapter.shared.syncManuscriptPapers(
            manuscriptID: manuscriptID,
            citeKeys: keys,
            // The name is Rust's default ("<title> — papers"); one definition.
            collectionName: nil
        ) else {
            let problem = "The imbib library is unavailable, so this manuscript has no "
                + "papers collection yet."
            Logger.editor.errorCapture("papers command: \(problem)", category: "citation")
            return Result(
                collectionName: "", memberCount: 0, missingCiteKeys: [], problem: problem)
        }

        guard let url = papersURL(manuscriptID: manuscriptID, title: title, format: format) else {
            return Result(
                collectionName: outcome.collectionName,
                memberCount: outcome.memberCount,
                missingCiteKeys: outcome.missingCiteKeys,
                problem: "Could not build the imbib URL for this manuscript.")
        }
        NSWorkspace.shared.open(url)
        Logger.editor.infoCapture(
            "papers command: \(keys.count) cited key(s) → '\(outcome.collectionName)' "
                + "(\(outcome.memberCount) paper(s), \(outcome.missingCiteKeys.count) not in imbib); "
                + "asked imbib to show it",
            category: "citation")
        return Result(
            collectionName: outcome.collectionName,
            memberCount: outcome.memberCount,
            missingCiteKeys: outcome.missingCiteKeys,
            problem: nil)
    }

    /// `imbib://manuscript/<id>/papers?title=…&format=…`
    static func papersURL(manuscriptID: UUID, title: String?, format: DocumentFormat) -> URL? {
        var components = URLComponents()
        components.scheme = SiblingApp.imbib.urlScheme
        components.host = "manuscript"
        components.path = "/\(manuscriptID.uuidString.lowercased())/papers"
        var query = [URLQueryItem(name: "format", value: format.rawValue)]
        if let title, !title.isEmpty {
            query.append(URLQueryItem(name: "title", value: title))
        }
        components.queryItems = query
        return components.url
    }
}
#endif
