//
//  EditorNotificationNames.swift
//  imprint
//
//  GUI-meld Phase 3: the inline citation palette + cite-key hover moved into PMC
//  and post these notifications. imprint's `ContentView` observes them. PMC also
//  declares these names (public) with the SAME raw string values, so poster and
//  observer match at runtime via NotificationCenter regardless of which module's
//  symbol each side references.
//
//  These are re-declared here (rather than imported from PMC) so imprint files
//  that observe them need no `import PublicationManagerCore` — which keeps PMC's
//  `Logger` category extensions from colliding with imprint's own.
//

import Foundation

extension Notification.Name {
    /// Posted when the inline citation palette inserts a citation into the editor.
    /// userInfo: `publicationID` (String), `citeKey` (String)
    static let inlineCitationInserted = Notification.Name("imprint.inlineCitationInserted")

    /// Posted to request opening the paper detail panel for a given publication.
    /// userInfo: `publicationID` (String)
    static let openPaperPanel = Notification.Name("imprint.openPaperPanel")

    /// Posted when the inline citation palette opens.
    static let inlineCitationPaletteOpened = Notification.Name("imprint.inlineCitationPaletteOpened")

    /// Posted when the inline citation palette closes (either by insert or cancel).
    static let inlineCitationPaletteClosed = Notification.Name("imprint.inlineCitationPaletteClosed")
}
