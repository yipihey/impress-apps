//
//  ManuscriptSnippetInsertion.swift
//  PublicationManagerCore
//
//  Insert text at the caret of an open manuscript editor from outside the
//  editor's view tree — App Intents, the HTTP API, a panel that is not
//  mounted. The Source tab of the manuscript observes it; nothing happens
//  when no editor is open, and the caller is told so by the return value
//  of `post`.
//

import Foundation

extension Notification.Name {
    /// userInfo: `documentID` (UUID, optional: any editor when absent),
    /// `snippet` (String).
    public static let manuscriptInsertSnippet = Notification.Name("impress.manuscript.insertSnippet")
}

extension Notification.Name {
    /// userInfo: `panel` (String — a side panel id such as `plots`, `files`,
    /// `build`). The open editor shows its inspector on that panel.
    public static let manuscriptShowSidePanel = Notification.Name("impress.manuscript.showSidePanel")
}

public enum ManuscriptSnippetInsertion {
    /// Ask the open editor of `documentID` to insert `snippet` at its caret.
    @MainActor
    public static func post(documentID: UUID, snippet: String) {
        NotificationCenter.default.post(
            name: .manuscriptInsertSnippet,
            object: nil,
            userInfo: ["documentID": documentID, "snippet": snippet])
    }
}
