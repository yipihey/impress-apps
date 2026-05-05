//
//  IOSInfoTabStub.swift
//  imbib-iOS
//
//  Temporary working replacement for IOSInfoTab.swift. The original
//  660-line tab still reaches through `LibraryModel.containerURL`
//  (removed when Library became a value type), calls into the deleted
//  `AttachmentManager` import path, and subscribes to
//  `NSNotification.Name.exploreCoReads` / `.exploreWoSRelated`
//  notifications that no longer exist. This stub keeps the iOS
//  detail view compiling by rendering a minimal header with the
//  publication's title, authors, year, and abstract — enough to
//  verify the detail route works end-to-end.
//
//  Migration debt: attachments UI, file drop/import, PDF source row,
//  comments, explore/references, and cite-in-manuscripts badge. See
//  docs/adr/ios-migration-debt.md for the tracking list.
//

import SwiftUI
import PublicationManagerCore

struct IOSInfoTab: View {
    let publicationID: UUID
    let libraryID: UUID

    @State private var publication: PublicationRowData?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let pub = publication {
                    header(pub)
                    if let abstract = pub.abstract, !abstract.isEmpty {
                        Text("Abstract")
                            .font(.headline)
                        Text(abstract)
                            .font(.body)
                    }
                    migrationNotice
                } else {
                    ContentUnavailableView(
                        "Loading…",
                        systemImage: "doc.text"
                    )
                }
            }
            .padding()
        }
        .task(id: publicationID) {
            publication = RustStoreAdapter.shared.getPublication(id: publicationID)
        }
    }

    @ViewBuilder
    private func header(_ pub: PublicationRowData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pub.title)
                .font(.title3)
                .fontWeight(.semibold)
            Text(pub.authorString)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let year = pub.year {
                Text(String(year))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var migrationNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("iOS rebuild in progress")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text("Attachments, comments, explore, and citation-usage badges on iOS are temporarily hidden while the info tab is migrated off the deleted AttachmentManager and containerURL APIs.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 16)
    }
}
