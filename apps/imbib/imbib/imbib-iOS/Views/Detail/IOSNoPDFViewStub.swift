//
//  IOSNoPDFViewStub.swift
//  imbib-iOS
//
//  Temporary working replacement for IOSNoPDFView.swift, which still
//  uses deleted Core Data types and the removed AttachmentManager
//  import path. This stub keeps the iOS PDF tab compiling by
//  preserving the public shape while deferring the real implementation
//  to the migration-debt list.
//

import SwiftUI
import PublicationManagerCore

struct IOSNoPDFView: View {
    let publicationID: UUID?
    let libraryID: UUID?

    init(publicationID: UUID? = nil, libraryID: UUID? = nil) {
        self.publicationID = publicationID
        self.libraryID = libraryID
    }

    var body: some View {
        ContentUnavailableView {
            Label("No PDF Attached", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Attach a PDF from the macOS app; in-app download and Files.app import are being rebuilt.")
        }
    }
}
