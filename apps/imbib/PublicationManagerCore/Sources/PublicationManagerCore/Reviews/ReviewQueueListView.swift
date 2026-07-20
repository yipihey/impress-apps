//
//  ReviewQueueListView.swift
//  PublicationManagerCore
//
//  Review queue for impel AwaitHumanResponse checkpoints.
//
//  Lists unresolved `review-request@1.0.0` items from the shared
//  impress-core store (written by agent pipelines, e.g. keyword auto-tag)
//  and lets the human approve or reject each one. Resolution is written
//  through the attributed `resolve_review` FFI so the operation audit
//  trail records the human author, not `system:local`.
//
//  Follows the ArtifactListView snapshot idiom: @State row array,
//  `.task` initial load, `.onChange(of: store.dataVersion)` reload.
//

import SwiftUI
import ImpressFTUI
import ImpressLogging
import OSLog

/// List of pending agent review requests with Approve/Reject actions.
public struct ReviewQueueListView: View {

    @State private var reviews: [PendingReview] = []

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    public init() {}

    public var body: some View {
        Group {
            if reviews.isEmpty {
                ContentUnavailableView(
                    "No Pending Reviews",
                    systemImage: "checklist.checked",
                    description: Text("Agent review requests will appear here")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(reviews) { review in
                        ReviewQueueRow(
                            review: review,
                            onResolve: { resolution in
                                resolve(review, as: resolution)
                            }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .task {
            loadReviews()
        }
        .onChange(of: store.dataVersion) { _, _ in
            loadReviews()
        }
    }

    private func loadReviews() {
        reviews = store.listPendingReviews()
    }

    private func resolve(_ review: PendingReview, as resolution: String) {
        // Capture the value before any async/mutating work — never read
        // @State inside deferred closures (root CLAUDE.md capture rule).
        let reviewID = review.id
        Logger.library.infoCapture(
            "Review row action: \(resolution) for \(reviewID)",
            category: "reviews"
        )
        store.resolveReview(id: reviewID, resolution: resolution)
        // dataVersion bump from resolveReview triggers the reload via
        // .onChange, but reload immediately for snappy row removal.
        loadReviews()
    }
}

// MARK: - Row

/// A single review-request row: question, proposed tags, Approve/Reject.
private struct ReviewQueueRow: View {
    let review: PendingReview
    let onResolve: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(review.question)
                    .font(.body)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.leading)
                Spacer()
                Text(review.created, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !review.proposedTags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(review.proposedTags, id: \.self) { tag in
                        TagChip(tag: TagDisplayData(
                            id: UUID(),
                            path: tag,
                            leaf: tag   // show the full path text in the chip
                        ))
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    onResolve("approved")
                } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(role: .destructive) {
                    onResolve("rejected")
                } label: {
                    Label("Reject", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
        }
        .padding(.vertical, 6)
    }
}
