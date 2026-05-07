//
//  ManuscriptDetailView.swift
//  imbib
//
//  Phase 2.4 of the impress journal pipeline (per docs/plan-journal-pipeline.md
//  §3.4 + ADR-0011 D8).
//
//  Stacked-section detail view for a journal manuscript. Mirrors the
//  ArtifactDetailView pattern (ScrollView + VStack of sections, NO TabView,
//  NO `.focusable()` wrapper — the parent SectionContentView owns h/l pane
//  cycling per CLAUDE.md and the DetailView pattern).
//
//  Phase 2 sections:
//    - header (title, status badge, persona indicator, "Open in imprint" button)
//    - metadata (status, journal target, submission ID, authors, topic tags)
//    - imprint source bridge status (linked / not yet linked)
//    - revisions placeholder ("no revisions yet — Phase 3 ships the snapshot job")
//    - notes (free-form)
//
//  Reviews tab is deferred to Phase 4 (Counsel + Artificer).
//  Per-revision PDF rendering is deferred to Phase 3 (Archivist).
//

import SwiftUI
import PublicationManagerCore
#if canImport(AppKit)
import AppKit
#endif

struct ManuscriptDetailView: View {

    let manuscriptID: String

    @State private var manuscript: JournalManuscript?
    @State private var revisions: [JournalRevision] = []
    @State private var reviews: [JournalReview] = []
    @State private var revisionNotes: [JournalRevisionNote] = []
    @State private var imprintDocumentUUID: String?
    @State private var isOpeningInImprint = false
    @State private var openInImprintError: String?
    @State private var requestingReview = false
    @State private var requestingRevision = false
    @State private var lastRequestError: String?
    @State private var showDiff: String? = nil   // diff body to display in sheet

    private var bridge: ManuscriptBridge { ManuscriptBridge.shared }

    var body: some View {
        Group {
            if let manuscript {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerSection(manuscript)
                        metadataSection(manuscript)
                        imprintSourceSection(manuscript)
                        revisionsSection(manuscript)
                        reviewsSection(manuscript)
                        revisionNotesSection(manuscript)
                        notesSection(manuscript)
                    }
                    .padding()
                    .padding(.top, 40)   // scroll clearance for the toolbar overlap
                }
                .sheet(item: Binding<DiffSheetData?>(
                    get: { showDiff.map { DiffSheetData(diff: $0) } },
                    set: { showDiff = $0?.diff }
                )) { sheet in
                    diffSheet(sheet)
                }
            } else {
                ContentUnavailableView(
                    "Manuscript Not Found",
                    systemImage: "doc.text.image",
                    description: Text("This manuscript may have been deleted.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: manuscriptID) {
            // Ensure the Darwin → NotificationCenter bridge is running so
            // status/snapshot events fire local NotificationCenter posts.
            JournalEventBridge.shared.start()
            await loadManuscript()
        }
        .onReceive(NotificationCenter.default.publisher(for: .manuscriptDidChange)) { note in
            // Refresh when the bridge or any other writer signals a change
            // for our manuscript ID. Conservative: reload on any matching event.
            if let ids = note.userInfo?["resourceIDs"] as? [String], ids.contains(manuscriptID) {
                Task { await loadManuscript() }
            } else if (note.userInfo?["resourceIDs"] as? [String])?.isEmpty ?? true {
                // Event with no IDs — reload conservatively.
                Task { await loadManuscript() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .manuscriptSnapshotDidLand)) { _ in
            // Snapshots create a new revision item — always reload to pick up
            // the latest revisions list.
            Task { await loadManuscript() }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func headerSection(_ m: JournalManuscript) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.title)
                    .font(.title2).bold()
                    .lineLimit(3)
                Spacer()
                statusBadge(m.status)
            }
            HStack(spacing: 12) {
                Button {
                    Task { await openInImprint() }
                } label: {
                    Label(
                        imprintDocumentUUID == nil ? "Create in imprint" : "Open in imprint",
                        systemImage: "square.and.pencil"
                    )
                }
                .disabled(isOpeningInImprint)

                Button {
                    Task { await requestReview() }
                } label: {
                    Label("Request Review", systemImage: "eye.fill")
                }
                .disabled(requestingReview || revisions.isEmpty)
                .help(revisions.isEmpty
                      ? "A revision must exist before Counsel can review it. Snapshots are created when the manuscript transitions to submitted/published/archived."
                      : "Ask Counsel to produce a structured review of the latest revision.")

                Button {
                    Task { await requestRevision() }
                } label: {
                    Label("Request Revision", systemImage: "wand.and.stars")
                }
                .disabled(requestingRevision || revisions.isEmpty)
                .help("Ask Artificer to propose a revision (and optionally respond to the latest review).")

                if isOpeningInImprint || requestingReview || requestingRevision {
                    ProgressView().controlSize(.small)
                }
            }
            if let openInImprintError {
                Text(openInImprintError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let lastRequestError {
                Text(lastRequestError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: JournalManuscriptStatus) -> some View {
        Label(status.displayName, systemImage: status.systemImage)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func metadataSection(_ m: JournalManuscript) -> some View {
        GroupBox("Metadata") {
            VStack(alignment: .leading, spacing: 8) {
                metadataRow(label: "Status", value: m.status.displayName)
                if !m.authors.isEmpty {
                    metadataRow(label: "Authors", value: m.authors.joined(separator: ", "))
                }
                if let journal = m.journalTarget {
                    metadataRow(label: "Target Journal", value: journal)
                }
                if let subID = m.submissionID {
                    metadataRow(label: "Submission ID", value: subID)
                }
                if !m.topicTags.isEmpty {
                    metadataRow(label: "Topics", value: m.topicTags.joined(separator: " • "))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
    }

    @ViewBuilder
    private func imprintSourceSection(_ m: JournalManuscript) -> some View {
        GroupBox("Source") {
            VStack(alignment: .leading, spacing: 6) {
                if let docUUID = imprintDocumentUUID {
                    Label("Linked to imprint document", systemImage: "link.circle.fill")
                        .foregroundStyle(.green)
                    Text(docUUID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Label("No imprint document yet", systemImage: "link.badge.plus")
                        .foregroundStyle(.secondary)
                    Text("Click \"Create in imprint\" above to author a new .imprint package and bind it to this manuscript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func revisionsSection(_ m: JournalManuscript) -> some View {
        GroupBox(label: HStack {
            Text("Revisions")
            Spacer()
            Text("\(revisions.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }) {
            VStack(alignment: .leading, spacing: 6) {
                if revisions.isEmpty {
                    Label("No revisions yet", systemImage: "doc.badge.ellipsis")
                        .foregroundStyle(.secondary)
                    Text("A revision is created when the manuscript transitions to Submitted, Published, or Archived (Phase 3 — Archivist).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedRevisions(), id: \.id) { rev in
                        revisionRow(rev, isCurrent: rev.id == m.currentRevisionRef)
                        if rev.id != sortedRevisions().last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func sortedRevisions() -> [JournalRevision] {
        // Newest-first by predecessor chain length: revisions with no
        // predecessor go last; revisions with longer chains go first.
        // Falls back to revision_tag as a tiebreaker.
        let byID: [String: JournalRevision] = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        func depth(_ rev: JournalRevision, seen: Set<String> = []) -> Int {
            guard let pred = rev.predecessorRevisionRef,
                  !seen.contains(pred),
                  let parent = byID[pred]
            else { return 0 }
            return 1 + depth(parent, seen: seen.union([rev.id]))
        }
        return revisions.sorted { (a, b) in
            let da = depth(a), db = depth(b)
            return da != db ? da > db : a.revisionTag > b.revisionTag
        }
    }

    @ViewBuilder
    private func revisionRow(_ rev: JournalRevision, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCurrent ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(rev.revisionTag).font(.body).bold()
                    if isCurrent {
                        Text("CURRENT")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer()
                    if let wc = rev.wordCount, wc > 0 {
                        Text("\(wc) words")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        let revID = rev.id
                        Task { await openPDF(revisionID: revID) }
                    } label: {
                        Label("Open PDF", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(rev.pdfArtifactRef.hasPrefix("blob:sha256:")
                          ? "Open the compiled PDF for this revision"
                          : "PDF compile is deferred — start imprint and re-snapshot to backfill")
                    .disabled(!rev.pdfArtifactRef.hasPrefix("blob:sha256:"))
                }
                HStack(spacing: 8) {
                    Text(rev.contentHash.prefix(12))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let reason = rev.snapshotReason {
                        Text("• \(reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if rev.isBundle, let format = rev.bundleSourceFormat {
                        Text("• \(format) bundle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if rev.isBundle {
                    bundleFilesDisclosure(rev)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Phase 8.12: a disclosure group listing the bundle's entries with
    /// their roles. The list is parsed from the manifest JSON stored in
    /// the revision payload — no extraction needed for browsing.
    @ViewBuilder
    private func bundleFilesDisclosure(_ rev: JournalRevision) -> some View {
        if let entries = rev.bundleEntries(), !entries.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entries.sorted(by: { $0.path < $1.path }), id: \.path) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.systemImage)
                                .frame(width: 14)
                                .foregroundStyle(.secondary)
                            Text(entry.path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Text(entry.displayRole)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Spacer()
                        Button {
                            let revID = rev.id
                            Task { await revealBundleArchive(revisionID: revID) }
                        } label: {
                            Label("Reveal Archive", systemImage: "archivebox")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Show the .tar.zst bundle archive in Finder.")
                    }
                }
                .padding(.leading, 8)
            } label: {
                let main = rev.bundleMainSource ?? "main"
                Text("\(entries.count) files — main: \(main)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    /// Reveal the bundle's `.tar.zst` archive in Finder. Captures the
    /// revisionID locally per the CLAUDE.md @State-capture rule.
    private func revealBundleArchive(revisionID: String) async {
        let url = await bridge.getRevisionBundleArchiveURL(revisionID: revisionID)
        guard let url else {
            await MainActor.run {
                openInImprintError = "Bundle archive not found in the local content store."
            }
            return
        }
        #if canImport(AppKit)
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        #endif
    }

    /// Resolve the revision's PDF on disk and open it (Phase 6 / OQ-10).
    /// Captures revisionID into a local before async work per the
    /// CLAUDE.md @State-capture rule.
    private func openPDF(revisionID: String) async {
        let url = await bridge.getRevisionPDFURL(revisionID: revisionID)
        guard let url else {
            await MainActor.run {
                openInImprintError = "PDF not yet compiled. Start imprint and re-snapshot to backfill."
            }
            return
        }
        #if canImport(AppKit)
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: - Reviews (Phase 4)

    @ViewBuilder
    private func reviewsSection(_ m: JournalManuscript) -> some View {
        GroupBox(label: HStack {
            Text("Reviews")
            Spacer()
            Text("\(reviews.count)")
                .font(.caption).foregroundStyle(.secondary)
        }) {
            VStack(alignment: .leading, spacing: 8) {
                if reviews.isEmpty {
                    Label("No reviews yet", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                    Text("Ask Counsel to review the latest revision via the Request Review button above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(reviews, id: \.id) { review in
                        reviewRow(review)
                        if review.id != reviews.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func reviewRow(_ review: JournalReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: review.verdict.systemImage)
                    .foregroundStyle(.secondary)
                Text(review.verdict.displayName).font(.body).bold()
                Spacer()
                if let agentID = review.agentID {
                    Text(agentID)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                if let confidence = review.confidence {
                    Text("\(Int(confidence * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let summary = review.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Full review") {
                Text(review.body)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func revisionNotesSection(_ m: JournalManuscript) -> some View {
        GroupBox(label: HStack {
            Text("Revision Notes")
            Spacer()
            Text("\(revisionNotes.count)")
                .font(.caption).foregroundStyle(.secondary)
        }) {
            VStack(alignment: .leading, spacing: 8) {
                if revisionNotes.isEmpty {
                    Label("No revision notes yet", systemImage: "doc.badge.ellipsis")
                        .foregroundStyle(.secondary)
                    Text("Use Request Revision to ask Artificer to propose changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(revisionNotes, id: \.id) { note in
                        revisionNoteRow(note)
                        if note.id != revisionNotes.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func revisionNoteRow(_ note: JournalRevisionNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: note.verdict.systemImage)
                    .foregroundStyle(.secondary)
                Text(note.verdict.displayName).font(.body).bold()
                if let target = note.targetSection {
                    Text("§\(target)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let agentID = note.agentID {
                    Text(agentID)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            Text(note.body)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let diff = note.diff, !diff.isEmpty {
                Button {
                    showDiff = diff
                } label: {
                    Label("Show diff (\(diff.split(separator: "\n").count) lines)", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private struct DiffSheetData: Identifiable {
        let id = UUID()
        let diff: String
    }

    @ViewBuilder
    private func diffSheet(_ data: DiffSheetData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Proposed Diff").font(.headline)
                Spacer()
                Button("Close") { showDiff = nil }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(data.diff)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            }
            .frame(minWidth: 600, minHeight: 400)
            Text("Apply-to-imprint workflow lands in Phase 5 polish. For now, copy the diff and apply manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private func notesSection(_ m: JournalManuscript) -> some View {
        GroupBox("Notes") {
            if let notes = m.notes, !notes.isEmpty {
                Text(notes)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text("No notes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Actions

    private func loadManuscript() async {
        let m = await bridge.getManuscript(id: manuscriptID)
        let imprintUUID = await bridge.imprintDocumentUUID(forManuscript: manuscriptID)
        let revs = await bridge.listRevisions(manuscriptID: manuscriptID)
        let revs_reviews = await bridge.listReviews(manuscriptID: manuscriptID)
        let notes = await bridge.listRevisionNotes(manuscriptID: manuscriptID)
        await MainActor.run {
            self.manuscript = m
            self.imprintDocumentUUID = imprintUUID
            self.revisions = revs
            self.reviews = revs_reviews
            self.revisionNotes = notes
        }
    }

    // MARK: - Phase 4 actions

    /// Request a Counsel review of the most recent revision.
    /// Routes via impel's HTTP API (CounselReviewService runs in impel process).
    private func requestReview() async {
        guard let m = manuscript,
              let latestRevision = revisions.first(where: { $0.id == m.currentRevisionRef })
                ?? revisions.first
        else { return }
        let manuscriptID = self.manuscriptID
        let revisionID = latestRevision.id
        await MainActor.run {
            requestingReview = true
            lastRequestError = nil
        }
        defer { Task { @MainActor in requestingReview = false } }

        let body: [String: Any] = [
            "manuscript_id": manuscriptID,
            "revision_id":   revisionID,
        ]
        do {
            try await postToImpel(path: "/api/journal/reviews", body: body)
            await loadManuscript()
        } catch {
            await MainActor.run {
                lastRequestError = "Review request failed: \(error.localizedDescription)"
            }
        }
    }

    /// Request an Artificer revision proposal — optionally responding to the
    /// most recent review.
    private func requestRevision() async {
        guard let m = manuscript,
              let latestRevision = revisions.first(where: { $0.id == m.currentRevisionRef })
                ?? revisions.first
        else { return }
        let manuscriptID = self.manuscriptID
        let revisionID = latestRevision.id
        let latestReviewID = reviews.first?.id

        await MainActor.run {
            requestingRevision = true
            lastRequestError = nil
        }
        defer { Task { @MainActor in requestingRevision = false } }

        var body: [String: Any] = [
            "manuscript_id": manuscriptID,
            "revision_id":   revisionID,
        ]
        if let latestReviewID { body["review_id"] = latestReviewID }
        do {
            try await postToImpel(path: "/api/journal/revision-notes", body: body)
            await loadManuscript()
        } catch {
            await MainActor.run {
                lastRequestError = "Revision request failed: \(error.localizedDescription)"
            }
        }
    }

    /// POST a JSON body to impel's HTTP API on port 23124.
    private func postToImpel(path: String, body: [String: Any]) async throws {
        guard let url = URL(string: "http://127.0.0.1:23124\(path)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "imbib.imprint-request", code: code, userInfo: [
                NSLocalizedDescriptionKey: "impel returned HTTP \(code) — make sure impel is running",
            ])
        }
    }

    /// Per Phase 2 UX decision (Tom 2026-05-05): on first click for an
    /// unbridged manuscript, fire `imprint://create?title=...` and write
    /// the bridge edge in the URL handler's response. On subsequent clicks,
    /// fire `imprint://open?imbibManuscript={id}&documentUUID={uuid}`.
    private func openInImprint() async {
        let m = self.manuscript
        let docUUID = self.imprintDocumentUUID
        await MainActor.run {
            self.isOpeningInImprint = true
            self.openInImprintError = nil
        }
        defer { Task { @MainActor in self.isOpeningInImprint = false } }

        guard let m else { return }

        let urlString: String
        if let docUUID {
            // Bridge already exists — open the existing document.
            urlString = "imprint://open?imbibManuscript=\(manuscriptID)&documentUUID=\(docUUID)"
        } else {
            // No bridge — ask imprint to create a fresh document.
            // imprint's URL handler writes back the new document UUID via a
            // separate notification (Phase 2 wires this via ManuscriptBridge.
            // attachImprintSource called from imprint's response handler).
            let title = m.title.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? "Untitled"
            urlString = "imprint://create?title=\(title)&imbibManuscript=\(manuscriptID)"
        }

        guard let url = URL(string: urlString) else {
            await MainActor.run { self.openInImprintError = "Could not build imprint URL" }
            return
        }

        #if canImport(AppKit)
        let opened = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        if !opened {
            await MainActor.run {
                self.openInImprintError = "Could not open imprint. Is it installed?"
            }
        }
        #else
        await MainActor.run {
            self.openInImprintError = "Opening imprint is only supported on macOS in this build."
        }
        #endif
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted by code paths that mutate journal manuscripts so detail views
    /// can refresh without polling. Bridges Darwin notifications from
    /// ImpressNotification.manuscriptStatusChanged into local NotificationCenter.
    static let manuscriptDidChange = Notification.Name("imbib.manuscriptDidChange")
}
