//
//  IOSPDFTabStub.swift
//  imbib-iOS
//
//  Temporary working replacement for IOSPDFTab.swift. The original
//  relied on `LibraryModel.containerURL` (no longer exposed on the
//  value-type model), a bibliography `Table(...)` whose generics
//  broke after the Rust migration's row type change, and a
//  PDF-attachment signature that has been rewritten. This stub keeps
//  the iOS detail tab compiling while deferring the real PDF tab
//  rewrite to the migration-debt list.
//
//  The stub still accepts the same `publicationID` property so the
//  surrounding `IOSInfoTab` / `IOSDetailView` doesn't need to change.
//

import SwiftUI
import PublicationManagerCore

struct IOSPDFTab: View {
    let publicationID: UUID
    let libraryID: UUID?
    var pendingSearchQuery: String?
    @Binding var isFullscreen: Bool

    init(
        publicationID: UUID,
        libraryID: UUID? = nil,
        pendingSearchQuery: String? = nil,
        isFullscreen: Binding<Bool> = .constant(false)
    ) {
        self.publicationID = publicationID
        self.libraryID = libraryID
        self.pendingSearchQuery = pendingSearchQuery
        self._isFullscreen = isFullscreen
    }

    var body: some View {
        ContentUnavailableView {
            Label("PDF Viewer Rebuilding", systemImage: "doc.richtext")
        } description: {
            Text("Open this paper in the macOS app to view its PDF. The iOS PDF viewer is being migrated to the value-type store.")
        }
    }
}
