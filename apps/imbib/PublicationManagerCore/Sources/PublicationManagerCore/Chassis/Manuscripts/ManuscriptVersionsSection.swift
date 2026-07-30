// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): plain SwiftUI over
// the revision list.
//
//  ManuscriptVersionsSection.swift
//  PublicationManagerCore
//
//  Info-pane "Versions" section (GUI-meld plan §4/§History): the named
//  revision chain (manuscript-revision items) with Save Version + restore.
//  Self-contained so it drops into either the current ManuscriptDetailView
//  or the future Info tab. Reads the Phase-0 Rust surface via RustStoreAdapter.

import SwiftUI
import ImbibRustCore

public struct ManuscriptVersionsSection: View {

    let manuscriptID: UUID
    /// Called with the source text of a revision the user chose to restore, so
    /// the host (editor/detail) can apply it as a new edit. Nil = restore hidden.
    var onRestore: ((String) -> Void)?

    @State private var revisions: [ManuscriptRevisionRow] = []
    @State private var newVersionTag = ""
    @State private var showingSaveField = false

    public init(manuscriptID: UUID, onRestore: ((String) -> Void)? = nil) {
        self.manuscriptID = manuscriptID
        self.onRestore = onRestore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if revisions.isEmpty {
                Text("No saved versions yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(revisions, id: \.id) { rev in
                    revisionRow(rev)
                    if rev.id != revisions.last?.id { Divider() }
                }
            }
            if showingSaveField { saveField }
        }
        .task(id: manuscriptID) { reload() }
    }

    private var header: some View {
        HStack {
            Text("Versions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Button {
                showingSaveField.toggle()
            } label: {
                Label("Save Version", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    private var saveField: some View {
        HStack(spacing: 6) {
            TextField("Version name (e.g. v1, submitted)", text: $newVersionTag)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveVersion)
            Button("Save", action: saveVersion)
                .disabled(newVersionTag.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 4)
    }

    private func revisionRow(_ rev: ManuscriptRevisionRow) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                    Text(rev.revisionTag).fontWeight(.medium)
                    if let reason = rev.snapshotReason, reason != "manual" {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                HStack(spacing: 8) {
                    Text(Date(timeIntervalSince1970: TimeInterval(rev.dateCreated) / 1000.0),
                         format: .dateTime.month().day().year().hour().minute())
                    if let wc = rev.wordCount, wc > 0 {
                        Text("· \(wc) words")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let onRestore {
                Button("Restore") {
                    // Restore is an ordinary edit — never a chain rewrite. The
                    // snapshot's source is carried inline for in-store revisions.
                    if let body = RustStoreAdapter.shared.manuscriptRevisionSource(rev) {
                        onRestore(body)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    private func reload() {
        revisions = RustStoreAdapter.shared.listManuscriptRevisions(manuscriptID: manuscriptID)
    }

    private func saveVersion() {
        let tag = newVersionTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        RustStoreAdapter.shared.createManuscriptRevision(
            manuscriptID: manuscriptID, tag: tag, reason: "user-tag")
        newVersionTag = ""
        showingSaveField = false
        reload()
    }
}
