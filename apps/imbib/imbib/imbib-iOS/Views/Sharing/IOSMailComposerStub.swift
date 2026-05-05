//
//  IOSMailComposerStub.swift
//  imbib-iOS
//
//  Temporary working replacement for IOSMailComposer.swift, which
//  still takes a `CDPublication` parameter. The real composer (a
//  `MFMailComposeViewController` wrapper that pre-fills subject and
//  body from a publication) can come back once the caller paths are
//  migrated to the value-type `PublicationModel`.
//

import SwiftUI
import PublicationManagerCore

struct IOSMailComposer: View {
    let publicationID: UUID?

    init(publicationID: UUID? = nil) {
        self.publicationID = publicationID
    }

    var body: some View {
        ContentUnavailableView {
            Label("Email Composer Rebuilding", systemImage: "envelope")
        } description: {
            Text("Use the Share sheet to send papers via mail from the iOS app in the meantime.")
        }
    }
}
