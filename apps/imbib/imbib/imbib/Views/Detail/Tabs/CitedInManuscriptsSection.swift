//
//  CitedInManuscriptsSection.swift
//  imbib
//
//  Detail-view section that shows every manuscript section (written in
//  imprint) that cites the currently-viewed publication. Reads from
//  `CitedInManuscriptsSnapshot.shared`, which is kept warm by
//  `CitationUsageReader` reading citation-usage@1.0.0 records from the
//  shared impress-core store.
//
//  This is the imbib end of the T6 bidirectional citation story:
//  imprint writes records when the user cites a paper, imbib displays
//  "Cited in N manuscripts" on the detail view for that paper.
//
//  Refresh model: on-demand. Cross-process mutations from imprint are
//  not visible to imbib's in-process event publisher, so a full
//  push-based live update would need a Darwin notification bridge.
//  For Phase 1 we refresh on view-appear and when the publication id
//  changes, which covers every user-driven navigation.
//

import SwiftUI
import PublicationManagerCore

struct CitedInManuscriptsSection: View {
    let publicationID: UUID

    /// Observable singleton; view-body reads trigger redraws when the
    /// snapshot's `records` change.
    var snapshot: CitedInManuscriptsSnapshot = .shared

    /// The subset of records that resolve to this publication.
    private var matchingRecords: [CitationUsageRecord] {
        snapshot.records.filter { $0.paperID == publicationID }
    }

    var body: some View {
        if matchingRecords.isEmpty {
            // Nothing to show for this publication — avoid rendering
            // an empty section.
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "text.book.closed.fill")
                        .foregroundStyle(.secondary)
                    Text(headerText)
                        .font(.headline)
                    Spacer()
                }
                ForEach(matchingRecords) { record in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("@\(record.citeKey)")
                                .font(.system(size: 12, design: .monospaced))
                            if let lastSeen = record.lastSeen {
                                Text("last seen \(lastSeen.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 4)
                }
            }
            .padding(.vertical, 4)
            .task(id: publicationID) {
                await snapshot.refresh()
            }

            Divider()
        }
    }

    private var headerText: String {
        let count = matchingRecords.count
        return count == 1 ? "Cited in 1 manuscript section" : "Cited in \(count) manuscript sections"
    }
}
