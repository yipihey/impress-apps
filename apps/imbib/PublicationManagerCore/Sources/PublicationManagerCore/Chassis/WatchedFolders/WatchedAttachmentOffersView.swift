// Chassis VIEW file — CROSS-PLATFORM (macOS + iOS). ADR-0023 W5's review
// surface. Reads `WatchedAttachmentOffer` (a data value) and nothing else;
// the model does not know this exists.
//
//  WatchedAttachmentOffersView.swift
//  PublicationManagerCore
//
//  ── Why there is a surface at all ───────────────────────────────────────────
//
//  W5's feature is that a PDF beside a watched `.bib` attaches itself. The
//  surface exists for the cases where it must not: a file two entries could
//  equally be, a file named nothing like anything, a guess the matcher is
//  willing to make but not to act on. ADR-0023 W4 established the shape — a
//  per-folder pane listing what the app is OFFERING rather than reporting what
//  it has already done — and this is that pattern for a different unit.
//
//  ── What it deliberately is not ─────────────────────────────────────────────
//
//  Not a modal that blocks the scan, and not a notification. A folder with
//  nine ambiguous PDFs is not an emergency, and interrupting a researcher to
//  triage filenames is the opposite of flow. It is reachable from the folder's
//  own context menu, the menu entry is omitted entirely when there is nothing
//  to review (the same "omit a dead affordance" rule the row's Refresh and
//  Choose Again… follow), and everything in it is optional forever: the PDFs
//  are the user's, they are still on disk, and Reveal in Finder is one row
//  away.
//

import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// One folder's unattached PDFs, and what the matcher thinks each one is.
public struct WatchedAttachmentOffersView: View {

    private let folderName: String
    private let offers: [WatchedAttachmentOffer]
    /// Attach one PDF to one publication — the user's decision, executed.
    private let onAttach: (WatchedAttachmentOffer, WatchedAttachmentOffer.Candidate) -> Void
    private let onDismiss: () -> Void

    @State private var attached: Set<String> = []

    public init(
        folderName: String,
        offers: [WatchedAttachmentOffer],
        onAttach: @escaping (WatchedAttachmentOffer, WatchedAttachmentOffer.Candidate) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.folderName = folderName
        self.offers = offers
        self.onAttach = onAttach
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if offers.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(offers) { offer in
                        offerSection(offer)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Sidebar.watchedAttachmentOfferList)
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 320)
    }

    // MARK: Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PDFs in \(folderName)")
                .font(.headline)
            // The sentence that says why these are HERE and not attached. The
            // pane's whole job is to be legible without the ADR open.
            Text(
                "These files were not attached automatically — either more than one entry "
                    + "could be theirs, or the match was a guess. Nothing has been changed."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var summary: String {
        let unmatched = offers.filter(\.isUnmatched).count
        let reviewable = offers.count - unmatched
        var parts: [String] = []
        if reviewable > 0 {
            parts.append(reviewable == 1 ? "1 file to review" : "\(reviewable) files to review")
        }
        if unmatched > 0 {
            parts.append("\(unmatched) matched no entry")
        }
        return parts.isEmpty ? "Nothing to review" : parts.joined(separator: ", ")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Every PDF in this folder is accounted for.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: One file

    @ViewBuilder
    private func offerSection(_ offer: WatchedAttachmentOffer) -> some View {
        Section {
            if offer.isUnmatched {
                // Not an error state, and it must not read as one. A watched
                // folder legitimately holds PDFs its `.bib` never mentions.
                Text(offer.statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if attached.contains(offer.id) {
                Label("Attached", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(offer.candidates) { candidate in
                    candidateRow(offer, candidate)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: offer.systemImage)
                    .foregroundStyle(.secondary)
                Text(offer.fileName)
                    .font(.body.weight(.medium))
                Spacer()
                #if os(macOS)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([offer.url])
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                #endif
            }
        }
    }

    private func candidateRow(
        _ offer: WatchedAttachmentOffer, _ candidate: WatchedAttachmentOffer.Candidate
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .lineLimit(2)
                Text("\(candidate.citeKey) — \(candidate.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(candidate.confidenceLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Attach") {
                onAttach(offer, candidate)
                attached.insert(offer.id)
            }
            .accessibilityIdentifier(
                AccessibilityID.Sidebar.watchedAttachmentAttachButton(candidate.citeKey))
        }
        .padding(.vertical, 2)
    }
}
