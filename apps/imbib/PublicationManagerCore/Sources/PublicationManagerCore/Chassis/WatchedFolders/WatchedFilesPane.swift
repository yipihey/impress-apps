// Chassis file — CROSS-PLATFORM (macOS + iOS) SwiftUI. The one whole-pane
// surface ADR-0023 W4 adds; `#if os(macOS)` guards only the Finder verb.
//
//  WatchedFilesPane.swift
//  PublicationManagerCore
//
//  ADR-0023 W4 — the `file`-unit folder's surface, for impart and implore.
//
//  ── What it is, and what it refuses to pretend ──────────────────────────────
//
//  W2's watched-folder row opened a publication LIST, because a `.bib` fans out
//  to publications. A `.mbox` and a `.vsz` do not fan out at all in v1 (see
//  `WatchedFileOffer`'s header for the three reasons), so this pane shows the
//  FILES, states in plain words what has and has not happened to them, and
//  offers the verbs that are actually wired.
//
//  The chassis rule it follows throughout is `WatchedFolderRowState`'s: **omit
//  a dead affordance rather than render one.** There is no greyed-out "Import"
//  button here waiting for phase 3. What there is instead is a sentence saying
//  where the import lives today, which is a thing a user can act on.
//
//  ── One view, two hosts ─────────────────────────────────────────────────────
//
//  impart and implore differ in exactly one value — the actions a row offers —
//  so that is a parameter (`WatchedFileVerbs`) and everything else is shared.
//  A third host (W3's imprint, if it ever wants a file listing rather than
//  manuscript rows) supplies its own verbs and writes no view.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - The per-kind verbs

/// What one discovered file can be asked to do, per record kind.
///
/// Data, not closures over the store: every verb here is either a platform
/// action (reveal) or a read (inspect). The one thing that WOULD need a closure
/// — "import this into my library" — is exactly the thing v1 does not have.
public struct WatchedFileVerbs: Sendable {

    /// Whether the row offers "Count Messages" — the bounded real-parser read
    /// (`WatchedMailArchive.inspect`). Mail archives only; a `.vsz` has no
    /// parser in the suite to count anything with.
    public var offersArchiveInspection: Bool

    /// The sentence under the file list saying what the watcher did, and where
    /// the import verb lives. Rendered verbatim.
    public var handoffExplanation: String

    public init(offersArchiveInspection: Bool, handoffExplanation: String) {
        self.offersArchiveInspection = offersArchiveInspection
        self.handoffExplanation = handoffExplanation
    }

    /// impart's: mail archives are indexed and OFFERED, never bulk-ingested.
    public static let mailArchives = WatchedFileVerbs(
        offersArchiveInspection: true,
        handoffExplanation: """
            impart is tracking these archives — where they are, how big they are, \
            and when they change — but it has not imported any mail from them. \
            Fanning an archive out into messages is not wired in this version: \
            message read state and threading are owned by IMAP, and a large \
            archive would import tens of thousands of rows the moment you added \
            the folder. Reveal an archive in the Finder to open it in a mail \
            client that can import it.
            """)

    /// implore's: Veusz documents are indexed in place, and nothing more.
    public static let veuszDocuments = WatchedFileVerbs(
        offersArchiveInspection: false,
        handoffExplanation: """
            implore is tracking these Veusz documents in place — the files stay \
            yours and are never copied, moved or written to. It does not open \
            them: there is no Veusz reader in the suite, so a figure minted from \
            one would carry a name and nothing else. Reveal a document in the \
            Finder to open it in Veusz.
            """)

    /// The verbs for one record kind, or a neutral default.
    public static func forKindScope(_ kindScope: String) -> WatchedFileVerbs {
        switch kindScope {
        case RecordKindID.message.rawValue: return .mailArchives
        case RecordKindID.figure.rawValue: return .veuszDocuments
        default:
            return WatchedFileVerbs(
                offersArchiveInspection: false,
                handoffExplanation:
                    "These files are tracked in place. Nothing has been imported from them.")
        }
    }
}

// MARK: - The pane

/// One `file`-unit watched folder's discovered files.
public struct WatchedFilesPane: View {

    private let folderID: WatchedFolderID
    private let kindScope: String

    @State private var inspections: [String: String] = [:]
    @State private var inspecting: Set<String> = []
    @State private var version = 0

    public init(folderID: WatchedFolderID, kindScope: String) {
        self.folderID = folderID
        self.kindScope = kindScope
    }

    private var coordinator: WatchedFolderIngestCoordinator? {
        WatchedFolderIngestCoordinator.runningCoordinator(forKindScope: kindScope)
    }

    private var row: WatchedFolderRowState? {
        coordinator?.rows.first { $0.id == folderID }
    }

    private var offers: [WatchedFileOffer] {
        _ = version
        return (coordinator?.files(in: folderID) ?? []).offers
    }

    private var verbs: WatchedFileVerbs { .forKindScope(kindScope) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                if offers.isEmpty {
                    emptyState
                } else {
                    ForEach(offers) { offer in
                        fileRow(offer)
                        Divider()
                    }
                }
                explanation
            }
            .padding(.horizontal, 20)
            // The chassis scroll-clearance rule (imbib CLAUDE.md): detail
            // content starts below the toolbar icons but scrolls up into them.
            .padding(.top, 40)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onNotifications([(.watchedFoldersDidChange, { _ in version += 1 })])
    }

    // MARK: Pieces

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: row?.systemImage ?? "folder.badge.gearshape")
                    .foregroundStyle(.secondary)
                Text(row?.displayName ?? "Watched Folder")
                    .font(.title2).bold()
            }
            // D6, verbatim: the declared state is rendered as the row computed
            // it, never paraphrased and never replaced by an empty state.
            Text(row?.statusLine ?? "Not watching")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let path = row?.path {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        // Never "0 files" for a folder that cannot see its own contents — the
        // ADR's stated risk, and the reason `countIsTrustworthy` exists.
        VStack(alignment: .leading, spacing: 6) {
            Text(
                row?.state.countIsTrustworthy == false
                    ? "This folder's contents cannot be listed right now."
                    : "No matching files here yet.")
                .font(.headline)
            Text(row?.explanation ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func fileRow(_ offer: WatchedFileOffer) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: offer.systemImage)
                .foregroundStyle(offer.isMissing ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 3) {
                Text(offer.fileName)
                    .font(.body)
                    .strikethrough(offer.isMissing)
                Text(offer.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = inspections[offer.id] {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            actions(for: offer)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func actions(for offer: WatchedFileOffer) -> some View {
        HStack(spacing: 8) {
            if verbs.offersArchiveInspection, !offer.isMissing {
                Button(inspecting.contains(offer.id) ? "Reading…" : "Count Messages") {
                    inspect(offer)
                }
                .disabled(inspecting.contains(offer.id))
            }
            #if os(macOS)
            // Omitted for a missing file rather than shown dead: revealing a
            // path that is gone selects nothing and explains nothing.
            if !offer.isMissing {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([offer.url])
                }
            }
            #endif
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What this folder does", systemImage: "info.circle")
                .font(.headline)
            Text(verbs.handoffExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    // MARK: The one expensive verb

    private func inspect(_ offer: WatchedFileOffer) {
        // Capture before the Task — the @State-in-Task rule (root CLAUDE.md).
        let id = offer.id
        let path = offer.path
        inspecting.insert(id)
        Task { @MainActor in
            do {
                let inspection = try await WatchedMailArchive.inspect(path: path)
                var note = inspection.summary
                if !inspection.firstSubjects.isEmpty {
                    note += " — " + inspection.firstSubjects.joined(separator: "; ")
                }
                inspections[id] = note
            } catch {
                // A refusal is rendered like any other answer: it is a fact
                // about the archive, not a failure of the pane.
                inspections[id] =
                    (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            inspecting.remove(id)
        }
    }
}
