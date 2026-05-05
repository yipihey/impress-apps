//
//  IOSPDFBrowserViewStub.swift
//  imbib-iOS
//
//  Temporary working replacement for IOSPDFBrowserView.swift, which
//  still references deleted Core Data types. This stub keeps the
//  iOS target compiling by preserving the public shape of the view
//  while rendering a "feature unavailable" placeholder.
//
//  The real PDF browser (publisher-page fetcher + embedded WKWebView
//  + download capture) is an iOS migration-debt item; see
//  docs/adr/ios-migration-debt.md for the tracking list.
//

import SwiftUI
import PublicationManagerCore

struct IOSPDFBrowserView: View {
    let publicationID: UUID?
    let libraryID: UUID?
    var onPDFSaved: ((Data) -> Void)?

    init(
        publicationID: UUID? = nil,
        libraryID: UUID? = nil,
        onPDFSaved: ((Data) -> Void)? = nil
    ) {
        self.publicationID = publicationID
        self.libraryID = libraryID
        self.onPDFSaved = onPDFSaved
    }

    var body: some View {
        ContentUnavailableView {
            Label("PDF Browser Rebuilding", systemImage: "globe")
        } description: {
            Text("The in-app publisher browser is being migrated to the Rust store. Use the macOS app to download PDFs for now.")
        }
    }
}
