//
//  SubmissionsInboxView.swift
//  imbib
//
//  Phase 2.5 of the impress journal pipeline (per docs/plan-journal-pipeline.md
//  §3.4 + ADR-0011 D8).
//
//  List view of pending manuscript-submission items triaged by Scout.
//  Each row shows the submission's title, kind, source preview, and
//  Accept / Reject buttons. Per Phase 2 UX decision (Tom 2026-05-05),
//  Accept on a `.newManuscript` outcome creates the manuscript item;
//  on `.newRevisionOf` and `.fragmentOf` it annotates the parent.
//  Phase 3's Archivist backfills actual revision items.
//
//  Stacked layout (no TabView), no `.focusable()` (parent owns h/l).
//

import SwiftUI
import PublicationManagerCore

struct SubmissionsInboxView: View {

    @State private var submissions: [JournalSubmissionRecord] = []
    @State private var isLoading = false
    @State private var inFlightSubmissionIDs: Set<String> = []
    @State private var lastError: String?

    private var bridge: ManuscriptBridge { ManuscriptBridge.shared }

    var body: some View {
        Group {
            if submissions.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Pending Submissions",
                    systemImage: "tray",
                    description: Text("Submissions appear here when an agent or the journal-submit CLI posts a manuscript for triage.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let lastError {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(lastError).font(.callout)
                                Spacer()
                                Button("Dismiss") { self.lastError = nil }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.horizontal)
                        }
                        ForEach(submissions) { submission in
                            SubmissionRow(
                                submission: submission,
                                inFlight: inFlightSubmissionIDs.contains(submission.id),
                                onAccept: {
                                    Task { await accept(submission) }
                                },
                                onReject: {
                                    Task { await reject(submission) }
                                }
                            )
                            Divider()
                        }
                    }
                    .padding()
                    .padding(.top, 40)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .submissionsDidChange)) { _ in
            Task { await reload() }
        }
    }

    // MARK: - Actions

    private func reload() async {
        await MainActor.run { self.isLoading = true }
        let pending = await bridge.listPendingSubmissions()
        await MainActor.run {
            self.submissions = pending
            self.isLoading = false
        }
    }

    /// Phase 2 simplification: the inbox always treats Accept as a
    /// `.newManuscript` outcome (matching what Scout does most often
    /// in pure title-Jaccard mode). For Phase 4 we'll wire the actual
    /// Scout-proposed outcome into the row UI so the user can confirm
    /// per-submission whether to accept as new / revision / fragment.
    private func accept(_ submission: JournalSubmissionRecord) async {
        let id = submission.id
        await MainActor.run { inFlightSubmissionIDs.insert(id) }
        defer { Task { @MainActor in inFlightSubmissionIDs.remove(id) } }

        do {
            // Simple heuristic for Phase 2: if the submitter declared a
            // parent_manuscript_ref AND the kind is new-revision/fragment,
            // honor it. Otherwise treat as new manuscript.
            let outcome: ManuscriptBridge.AcceptOutcome
            if let parent = submission.parentManuscriptRef {
                switch submission.submissionKind {
                case .newRevision: outcome = .newRevisionOf(manuscriptID: parent)
                case .fragment:    outcome = .fragmentOf(manuscriptID: parent)
                case .newManuscript: outcome = .newManuscript
                }
            } else {
                outcome = .newManuscript
            }
            _ = try await bridge.acceptSubmission(id: id, outcome: outcome)
            await reload()
        } catch {
            await MainActor.run {
                self.lastError = "Accept failed: \(error.localizedDescription)"
            }
        }
    }

    private func reject(_ submission: JournalSubmissionRecord) async {
        let id = submission.id
        await MainActor.run { inFlightSubmissionIDs.insert(id) }
        defer { Task { @MainActor in inFlightSubmissionIDs.remove(id) } }

        do {
            try await bridge.rejectSubmission(id: id, reason: "rejected from inbox UI")
            await reload()
        } catch {
            await MainActor.run {
                self.lastError = "Reject failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Row

private struct SubmissionRow: View {

    let submission: JournalSubmissionRecord
    let inFlight: Bool
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: submission.submissionKind.systemImage)
                    .foregroundStyle(.secondary)
                Text(submission.title)
                    .font(.headline)
                Spacer()
                Text(submission.submissionKind.displayName)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }

            // Metadata row
            HStack(spacing: 12) {
                if let persona = submission.submitterPersonaID {
                    Label(persona, systemImage: "person.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let format = submission.sourceFormat {
                    Label(format, systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let hint = submission.similarityHint {
                    Label("hint: \(hint.prefix(8))…", systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Source preview
            let preview = submission.sourcePreview(maxLines: 8)
            if !preview.isEmpty {
                Text(preview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            }

            // Action buttons
            HStack {
                Spacer()
                Button(role: .destructive, action: onReject) {
                    Label("Reject", systemImage: "xmark")
                }
                .disabled(inFlight)
                Button(action: onAccept) {
                    Label("Accept", systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(inFlight)
                if inFlight {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when a submission's state changes (accept, reject, new arrival)
    /// so the inbox view can refresh without polling.
    static let submissionsDidChange = Notification.Name("imbib.submissionsDidChange")
}
