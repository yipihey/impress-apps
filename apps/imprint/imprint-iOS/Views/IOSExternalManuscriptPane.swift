//
//  IOSExternalManuscriptPane.swift
//  imprint-iOS
//
//  ADR-0023 D4 / W3 — what a reference-in-place manuscript looks like.
//
//  ── Why this is a pane and not an editor with saving turned off ─────────────
//
//  D4's rule is one-way: the watcher never writes user files, and an external
//  manuscript's body is the FILE's. "An editor whose save is disabled" would
//  still hold a live buffer, still diverge from the file the moment the user
//  typed, and still have to answer "what happens to what I typed?" — a question
//  with no honest answer when the file is authoritative. So the row gets a
//  READER, and the two things the user can actually do are the two things D4
//  names:
//
//    * **Open in <the file's default app>** — the explicit handoff. From that
//      moment the user's editor owns the file, imprint re-reads it on the next
//      pass, and the hash tells the row it moved.
//    * **Import a Copy** — the copy is an ordinary manuscript with an editor,
//      an undo stack and a store-backed save, and no claim on the file.
//
//  Open-in-place-with-imprint's-editor is what the session cannot do today:
//  `ManuscriptEditorSession.saveCAS` writes `setManuscriptBody`, and it has no
//  file-writing seam. Adding one would mean editing a frozen lifecycle to gain
//  a second writer for a user's file — the precise risk ADR-0023 lists first.
//  Recorded as W3's deferral rather than half-built.
//

import ImpressLogging
import OSLog
import PublicationManagerCore
import SwiftUI

struct IOSExternalManuscriptPane: View {

    let manuscript: ManuscriptModel

    @Bindable private var adapter = ManuscriptStoreAdapter.shared
    @State private var importedCopyID: UUID?
    @State private var failure: String?

    private var source: ExternalManuscriptSource? { manuscript.externalSource }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                banner
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("external-manuscript.error")
                }
                affordances
                Divider()
                bodySnapshot
            }
            .padding()
        }
        .navigationTitle(manuscript.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("external-manuscript.pane")
    }

    // MARK: Banner

    @ViewBuilder
    private var banner: some View {
        let missing = source?.isMissing ?? false
        VStack(alignment: .leading, spacing: 6) {
            Label(
                missing ? "The file is missing" : "Lives in a watched folder",
                systemImage: missing ? "questionmark.folder" : "folder.badge.gearshape")
                .font(.headline)
                .foregroundStyle(missing ? Color.orange : Color.secondary)
            // The state, VERBATIM from the payload — the D6 discipline W1 set
            // for folder rows, applied to the record the folder produced.
            Text(source?.statusLine ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let path = source?.path {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("external-manuscript.path")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(
            missing ? "external-manuscript.missing" : "external-manuscript.present")
    }

    // MARK: The two affordances

    @ViewBuilder
    private var affordances: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let source, !source.isMissing {
                Button {
                    open(source)
                } label: {
                    Label("Open in Another App", systemImage: "arrow.up.forward.app")
                }
                .accessibilityIdentifier("external-manuscript.open-in-place")
                Text(
                    "imprint hands the file to the app that owns it. Your edits go to the "
                        + "file, and imprint re-reads it — it never writes it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                importCopy()
            } label: {
                Label("Import a Copy", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("external-manuscript.import-copy")
            Text(
                "The copy becomes an ordinary imprint manuscript you can edit here. "
                    + "The original file is left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let importedCopyID {
                Label(
                    "Copied. The new manuscript is in your library.",
                    systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("external-manuscript.copied")
                    .id(importedCopyID)
            }
        }
    }

    // MARK: The snapshot

    @ViewBuilder
    private var bodySnapshot: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source")
                .font(.headline)
            if manuscript.body.isEmpty {
                Text(
                    "This file is too large for imprint to hold a copy of. It is still "
                        + "indexed, and \"Open in Another App\" still works.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(manuscript.body)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("external-manuscript.source")
            }
        }
    }

    // MARK: Verbs

    private func open(_ source: ExternalManuscriptSource) {
        let url = URL(fileURLWithPath: source.path)
        // The handoff. `UIApplication.open` on a file URL presents the system's
        // own chooser for the type; nothing here writes.
        UIApplication.shared.open(url) { opened in
            if !opened {
                failure = "No app on this device offers to open \(source.fileName)."
            }
        }
    }

    private func importCopy() {
        do {
            importedCopyID = try adapter.importCopyOfExternalManuscript(id: manuscript.id)
            failure = nil
        } catch {
            failure = error.localizedDescription
            Logger.sharedStore.errorCapture(
                "import a copy of \(manuscript.id) failed: \(error.localizedDescription)",
                category: "watched-folders")
        }
    }
}
