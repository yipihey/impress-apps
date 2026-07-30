// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): plain SwiftUI over
// store rows.
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
//  ## PUBLIC since C1 (2026-07-30) — imbib-iOS's Info tab renders it
//
//  The view was cross-platform from wave 2 but INTERNAL, so the only module
//  that could name it was PMC itself — i.e. the macOS `InfoTab`. imbib-iOS's
//  Info tab is app-target code, so "adding the section to iOS is one line"
//  (the wave-4 report) was one line plus an access modifier. Nothing else
//  changed: same rows, same copy, same self-owned refresh.
//
//  One structural caveat the host has to know, and it is why `IOSInfoTab` warms
//  the snapshot itself: the `.task(id:)` below sits INSIDE the non-empty
//  branch, and `EmptyView` does not run attached lifecycle modifiers — so this
//  section cannot bootstrap its own first load. Something that is on screen
//  regardless (the sidebar's cited row on macOS, the Info tab's own load task on
//  iOS) has to call `CitedInManuscriptsSnapshot.refresh()` at least once.
//  Recorded as a follow-up rather than fixed here, because every fix that lets
//  the empty branch run a task also puts a zero-size VIEW in a `VStack(spacing:
//  20)` — which adds 20 pt of blank space to every uncited paper's Info tab on
//  both platforms.
//

import SwiftUI

public struct CitedInManuscriptsSection: View {
    public let publicationID: UUID

    /// Observable singleton; view-body reads trigger redraws when the
    /// snapshot's `records` change. Injectable so a host (or a test) can render
    /// a known record set without the store.
    public var snapshot: CitedInManuscriptsSnapshot

    public init(
        publicationID: UUID,
        snapshot: CitedInManuscriptsSnapshot = .shared
    ) {
        self.publicationID = publicationID
        self.snapshot = snapshot
    }

    /// The subset of records that resolve to this publication.
    private var matchingRecords: [CitationUsageRecord] {
        snapshot.records.filter { $0.paperID == publicationID }
    }

    public var body: some View {
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
