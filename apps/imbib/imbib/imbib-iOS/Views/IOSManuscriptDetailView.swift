//
//  IOSManuscriptDetailView.swift
//  imbib-iOS
//
//  GUI-meld Phase 8. iOS manuscript detail: an editable body (reusing the
//  shared PMC `IOSSourceEditorView`) plus an Info tab with metadata and a
//  revisions list. Body edits are debounced back into the unified store via
//  `RustStoreAdapter.setManuscriptBody`, guarded by the last-loaded content
//  hash (compare-and-set) so a concurrent writer in imprint can't be
//  silently clobbered.
//

import SwiftUI
import PublicationManagerCore
import OSLog

struct IOSManuscriptDetailView: View {

    let manuscriptID: UUID

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    private enum Tab: String, CaseIterable, Identifiable {
        case editor = "Editor"
        case info = "Info"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .editor

    // Loaded detail + editor buffer.
    @State private var detail: ManuscriptDetail?
    @State private var body_ = ""
    @State private var selection: NSRange?
    @State private var lastHash: String?
    @State private var hasLoaded = false

    // Revisions (Info tab).
    @State private var revisions: [ManuscriptRevisionRow] = []

    // Debouncer.
    @State private var debounceTask: Task<Void, Never>?
    private static let debounceInterval: Duration = .milliseconds(400)

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch tab {
                case .editor:
                    editorPane
                case .info:
                    infoPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(detail?.title ?? "Manuscript")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: manuscriptID) { await load() }
        .onChange(of: store.dataVersion) { _, _ in
            // Metadata/revisions may change out from under us (imprint edits,
            // new revision snapshots). Refresh the read-only surfaces, but do
            // NOT stomp the editor buffer while the user is typing.
            if let d = store.getManuscriptDetail(id: manuscriptID) {
                detail = d
            }
            revisions = store.listManuscriptRevisions(manuscriptID: manuscriptID)
        }
        .onChange(of: body_) { _, newValue in
            guard hasLoaded else { return }
            scheduleSave(text: newValue)
        }
        .onDisappear {
            debounceTask?.cancel()
            if hasLoaded { saveNow(text: body_) }
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorPane: some View {
        if hasLoaded {
            if detail?.bodyIsBlobRef == true {
                ContentUnavailableView(
                    "Large Manuscript",
                    systemImage: "doc.badge.gearshape",
                    description: Text("This manuscript's body is stored as a blob and is best edited in imprint.")
                )
            } else {
                IOSSourceEditorView(text: $body_, selection: $selection)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Info

    @ViewBuilder
    private var infoPane: some View {
        if let d = detail {
            List {
                Section("Metadata") {
                    labeledRow("Status", d.status)
                    if !d.authors.isEmpty {
                        labeledRow("Authors", d.authors.joined(separator: ", "))
                    }
                    labeledRow("Format", d.format.isEmpty ? "typst" : d.format)
                    if let journal = d.journalTarget, !journal.isEmpty {
                        labeledRow("Journal Target", journal)
                    }
                    if !d.topicTags.isEmpty {
                        labeledRow("Topics", d.topicTags.joined(separator: ", "))
                    }
                    if let modified = d.bodyModifiedAt, !modified.isEmpty {
                        labeledRow("Body Modified", modified)
                    }
                }

                Section("Revisions") {
                    if revisions.isEmpty {
                        Text("No revisions yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(revisions, id: \.id) { rev in
                            revisionRow(rev)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func revisionRow(_ rev: ManuscriptRevisionRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(rev.revisionTag)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let reason = rev.snapshotReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                Text(Date(timeIntervalSince1970: TimeInterval(rev.dateCreated) / 1000.0),
                     style: .date)
                if let words = rev.wordCount {
                    Text("\(words) words")
                }
                if !rev.author.isEmpty {
                    Text(rev.author)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Data

    private func load() async {
        guard let d = store.getManuscriptDetail(id: manuscriptID) else {
            Logger.library.warningCapture(
                "IOSManuscriptDetailView: manuscript \(manuscriptID) not found",
                category: "manuscripts")
            return
        }
        detail = d
        body_ = d.bodyContent
        lastHash = d.bodyContentHash
        revisions = store.listManuscriptRevisions(manuscriptID: manuscriptID)
        hasLoaded = true
    }

    private func scheduleSave(text: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Self.debounceInterval)
                guard !Task.isCancelled else { return }
                saveNow(text: text)
            } catch is CancellationError {
                // Normal — superseded by a newer keystroke.
            } catch { }
        }
    }

    private func saveNow(text: String) {
        guard let outcome = store.setManuscriptBody(
            id: manuscriptID, body: text, expectedHash: lastHash
        ) else { return }

        if outcome.applied {
            lastHash = outcome.newHash
        } else {
            // Compare-and-set rejected the write (imprint edited the same
            // manuscript). Reconcile by adopting the store's version — the
            // safest non-destructive default on a shared item.
            Logger.library.warningCapture(
                "IOSManuscriptDetailView: save conflict, reloading \(manuscriptID)",
                category: "manuscripts")
            if let d = store.getManuscriptDetail(id: manuscriptID) {
                detail = d
                body_ = d.bodyContent
                lastHash = d.bodyContentHash
            }
        }
    }
}
