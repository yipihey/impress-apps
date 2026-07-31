#if os(macOS)
// Chassis file — macOS-only (this sidebar is an NSOutlineView; iOS's watched
// folders ride `RecordSidebarSectionContent` in `ImbibSidebarBindings`).
//
//  ImbibSidebarViewModel+WatchedFolders.swift
//  PublicationManagerCore
//
//  ADR-0023 W2 — the macOS half of "a watched folder is a feed".
//
//  ── The recorded decision ───────────────────────────────────────────────────
//
//  W1 shipped the row model (`WatchedFolderRowState`) able to become a chassis
//  `RecordSidebarNode` with no chassis edit, and left one thing open in the
//  capability matrix: **this sidebar does not read `RecordSidebarBuilder`**, so
//  the seam W1 prepared reaches iOS and not macOS. W1's matrix note named the
//  two candidates and left the choice to W2.
//
//  W2 chooses **a node case** (`ImbibSidebarNodeType.watchedFolder`) over the
//  `customSurface` seam. `CustomSurface.swift`'s own header fixes what a custom
//  surface is: a TOP-LEVEL sidebar node with no children, no count, no context
//  menu and a whole-pane view, deliberately (the capability matrix records all
//  four as ➖ "by design"). A watched-folder row needs every one of them — it
//  sits under Libraries, it carries the trustworthy-only badge that is the D6
//  invariant's whole point, it offers Refresh / Reveal / Stop Watching, and
//  selecting it opens a normal publication list. Building that inside a custom
//  surface would mean re-implementing a sidebar row in a pane.
//
//  The cost is honest and bounded: four exhaustive switches gain an arm
//  (`imbibTab`, `publicationSource`, `currentLibraryID`, `capabilities`), which
//  is exactly the "node/tab/route case-addition pattern" ADR-0021 records as
//  the remaining cost of a new row kind, and the compiler enforces all four.
//
//  ── Rendering the row VERBATIM ──────────────────────────────────────────────
//
//  `WatchedFolderRowState` computes `statusLine`, `explanation`, `systemImage`
//  and `badgeCount`; this file passes them through and computes nothing. In
//  particular `displayCount: row.badgeCount` — NOT `row.discoveredCount` — is
//  the one line that keeps ADR-0023's stated risk ("Spotlight blind spots read
//  as data loss") from re-entering through the sidebar.
//

import AppKit
import Foundation
import ImpressLogging
import ImpressSidebar
import OSLog

extension ImbibSidebarViewModel {

    /// The rows, from the one coordinator the app runs.
    var watchedFolderRows: [WatchedFolderRowState] {
        WatchedFolderIngestCoordinator.shared.rows
    }

    /// The watched-folder rows as sidebar nodes, appended under Libraries.
    ///
    /// Under Libraries and not in a section of their own: D2 says a watched
    /// folder is surfaced "through the existing feed machinery — not a new
    /// sidebar concept", and imbib's feeds live beside the libraries they feed.
    /// A new `SidebarSectionType` case would also widen a String-rawValue enum
    /// that backs persisted section order, which the matrix records as the
    /// reason custom surfaces are nodes rather than sections.
    func watchedFolderNodes() -> [ImbibSidebarNode] {
        watchedFolderRows.map { row in
            ImbibSidebarNode(
                id: ImbibSidebarNodeID.watchedFolder(row.id),
                nodeType: .watchedFolder(
                    folderID: row.id,
                    tagPath: WatchedFolderProvenanceTag.path(forFolderNamed: row.displayName)),
                // The state travels in the title for degraded rows exactly as
                // `WatchedFolderRowState.sidebarNode` does it, because this
                // outline row has no subtitle either. D6 requires the state to
                // be VISIBLE, not to be visible in a particular slot.
                displayName: row.state.isDegraded || !row.isEnabled
                    ? "\(row.displayName) — \(row.statusLine)"
                    : row.displayName,
                iconName: row.systemImage,
                // The invariant. `badgeCount` is nil for any folder that cannot
                // honestly claim its count is the whole count.
                displayCount: row.badgeCount,
                starCount: nil,
                iconColor: row.state.isDegraded ? .secondary : nil)
        }
    }

    // MARK: - ADR-0023 W4: the file-unit half

    /// The rows of ONE non-publication kind's coordinator.
    ///
    /// `runningCoordinator` and not `coordinator(forKindScope:)`: a sidebar
    /// section that RENDERS rows must never be the thing that starts a watcher,
    /// or the rows appear before the host has decided it wants them. The shell
    /// starts its coordinators in `configure`; this only reads them.
    func watchedFileFolderRows(kindScope: String) -> [WatchedFolderRowState] {
        WatchedFolderIngestCoordinator.runningCoordinator(forKindScope: kindScope)?.rows ?? []
    }

    /// A file-unit kind's watched folders as sidebar nodes.
    ///
    /// Rendered by exactly the same rules as the publication row above —
    /// `badgeCount` (never `discoveredCount`), the state in the title when
    /// degraded, the state's own glyph — because those rules are D6's and D6
    /// does not know which kind it is looking at.
    func watchedFileFolderNodes(kindScope: String) -> [ImbibSidebarNode] {
        watchedFileFolderRows(kindScope: kindScope).map { row in
            ImbibSidebarNode(
                id: ImbibSidebarNodeID.watchedFileFolder(row.id, kindScope: kindScope),
                nodeType: .watchedFileFolder(folderID: row.id, kindScope: kindScope),
                displayName: row.state.isDegraded || !row.isEnabled
                    ? "\(row.displayName) — \(row.statusLine)"
                    : row.displayName,
                iconName: row.systemImage,
                displayCount: row.badgeCount,
                starCount: nil,
                iconColor: row.state.isDegraded ? .secondary : nil)
        }
    }

    /// "Watch Folder for Archives…" / "…for Veusz Documents…" — the same panel,
    /// pointed at a different record kind.
    ///
    /// The prompt text is DERIVED from the kind's declaration rather than
    /// written per app: the extensions in the sentence are the ones the
    /// discovery query is actually built from, so a kind that gains one gains
    /// it in the panel too, with no edit here (ADR-0023 D1).
    func addWatchedFileFolder(kindScope: String) {
        guard let capability = BuiltinRecordKinds.fileDiscovery(forKindScope: kindScope),
            let descriptor = BuiltinRecordKinds.all.first(where: { $0.id.rawValue == kindScope })
        else { return }
        let extensions = capability.fileExtensions.map { ".\($0)" }.joined(separator: ", ")
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Watch"
        panel.message = "Choose a folder to watch for \(extensions) files. "
            + "\(descriptor.displayName) files found there are indexed in place — "
            + "nothing is copied, moved or imported."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adoptWatchedFileFolder(at: url, kindScope: kindScope)
    }

    /// The half with no panel in it, so a test drives the identical path.
    func adoptWatchedFileFolder(at url: URL, kindScope: String) {
        guard let coordinator = WatchedFolderIngestCoordinator.coordinator(
            forKindScope: kindScope, hooks: .recordingOnly)
        else { return }
        Task { @MainActor in
            do {
                let row = try await coordinator.addFolder(at: url)
                if let section = Self.watchedFileSections[kindScope] {
                    expansionState.expand(ImbibSidebarNodeID.section(section))
                }
                bumpDataVersion()
                selectedNodeID = ImbibSidebarNodeID.watchedFileFolder(row.id, kindScope: kindScope)
            } catch {
                Logger.files.errorCapture(
                    "Add watched \(kindScope) folder failed for \(url.path): "
                        + error.localizedDescription,
                    category: "watched-folders")
                let alert = NSAlert()
                alert.messageText = "That folder could not be watched."
                alert.informativeText =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    func buildWatchedFileFolderContextMenu(
        _ menu: NSMenu, folderID: WatchedFolderID, kindScope: String
    ) {
        guard let row = watchedFileFolderRows(kindScope: kindScope)
            .first(where: { $0.id == folderID })
        else { return }
        let token = WatchedFileFolderToken(folderID: folderID, kindScope: kindScope)

        // Same rule as the publication row: OMIT a dead affordance.
        if row.offersRefresh {
            let item = NSMenuItem(
                title: "Refresh",
                action: #selector(ContextMenuActions.refreshWatchedFileFolder(_:)),
                keyEquivalent: "")
            item.target = ContextMenuActions.shared
            item.representedObject = token
            menu.addItem(item)
        }
        if row.offersReauthorization {
            let item = NSMenuItem(
                title: "Choose Again…",
                action: #selector(ContextMenuActions.reauthorizeWatchedFileFolder(_:)),
                keyEquivalent: "")
            item.target = ContextMenuActions.shared
            item.representedObject = token
            menu.addItem(item)
        }

        let reveal = NSMenuItem(
            title: "Reveal in Finder",
            action: #selector(ContextMenuActions.revealWatchedFileFolder(_:)),
            keyEquivalent: "")
        reveal.target = ContextMenuActions.shared
        reveal.representedObject = token
        menu.addItem(reveal)

        menu.addItem(.separator())
        let explanation = NSMenuItem(title: row.explanation, action: nil, keyEquivalent: "")
        explanation.isEnabled = false
        menu.addItem(explanation)
        menu.addItem(.separator())

        let stop = NSMenuItem(
            title: "Stop Watching",
            action: #selector(ContextMenuActions.stopWatchingFileFolder(_:)),
            keyEquivalent: "")
        stop.target = ContextMenuActions.shared
        stop.representedObject = token
        menu.addItem(stop)
    }

    // MARK: - Verbs

    /// "Add Watched Folder…" — the macOS picker.
    ///
    /// `NSOpenPanel` with `canChooseDirectories`, the same configuration
    /// `SettingsView.chooseLibraryLocation` and `EInkSettingsView.chooseFolder`
    /// use. The panel is what mints a URL the sandbox will let us bookmark;
    /// everything after it is the coordinator's.
    func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Watch"
        panel.message = "Choose a folder to watch for BibTeX and RIS files. "
            + "imbib will import the entries it finds and keep up as they change."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adoptWatchedFolder(at: url)
    }

    /// The half of "add a watched folder" that has no panel in it.
    ///
    /// Separate so a test — and the iOS `fileImporter`, which produces a URL by
    /// a different route — drives the identical path.
    func adoptWatchedFolder(at url: URL) {
        Task { @MainActor in
            do {
                let row = try await WatchedFolderIngestCoordinator.shared.addFolder(at: url)
                expansionState.expand(ImbibSidebarNodeID.section(.libraries))
                bumpDataVersion()
                selectedNodeID = ImbibSidebarNodeID.watchedFolder(row.id)
            } catch {
                Logger.files.errorCapture(
                    "Add Watched Folder failed for \(url.path): \(error.localizedDescription)",
                    category: "watched-folders")
                let alert = NSAlert()
                alert.messageText = "That folder could not be watched."
                alert.informativeText =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    func refreshWatchedFolder(_ id: WatchedFolderID) {
        Task { @MainActor in
            await WatchedFolderIngestCoordinator.shared.refresh(id)
            bumpDataVersion()
        }
    }

    /// Stop watching. Keeps every paper the folder imported, and keeps their
    /// provenance tag — un-watching is not a retraction (D4, and the store verb
    /// says so in its own doc comment).
    func stopWatchingFolder(_ id: WatchedFolderID) {
        Task { @MainActor in
            await WatchedFolderIngestCoordinator.shared.removeFolder(id)
            if selectedNodeID == ImbibSidebarNodeID.watchedFolder(id) {
                selectDefaultSectionLeaf()
            }
            bumpDataVersion()
        }
    }

    // MARK: - ADR-0023 W5: reviewing unattached PDFs

    /// The PDFs in one folder that were not attached automatically.
    ///
    /// Everything the coordinator published, unfiltered: ambiguous candidates
    /// AND files that matched nothing. Both belong in the review list — "this
    /// PDF is in your folder and in no entry" is exactly as useful an answer as
    /// "it might be one of these two".
    func pendingAttachmentOffers(_ id: WatchedFolderID) -> [WatchedAttachmentOffer] {
        WatchedFolderIngestCoordinator.shared.attachmentOffers[id] ?? []
    }

    /// Open the review surface for one folder.
    func reviewWatchedAttachments(_ id: WatchedFolderID) {
        guard let row = watchedFolderRows.first(where: { $0.id == id }) else { return }
        attachmentReviewRequest = WatchedAttachmentReviewRequest(
            folderID: id,
            folderName: row.displayName,
            offers: pendingAttachmentOffers(id))
    }

    /// The user's decision, executed: attach ONE PDF to ONE publication.
    ///
    /// The same verb the automatic path uses, so a confirmed offer and an
    /// auto-attach produce the same row — there is no second kind of
    /// attachment, and no way to tell later which route a file took (nor should
    /// there be: the user's answer and the matcher's are equally true).
    func confirmAttachment(
        _ offer: WatchedAttachmentOffer, to candidate: WatchedAttachmentOffer.Candidate
    ) {
        let libraryID = RustStoreAdapter.shared.getDefaultLibrary()?.id
        guard AttachmentManager.shared.linkExistingPDF(
            relativePath: offer.path, for: candidate.id, in: libraryID) != nil
        else {
            Logger.files.errorCapture(
                "the store refused to link \(offer.path) to \(candidate.citeKey)",
                category: "watched-folders")
            return
        }
        // Drop it from the offer list: it has an answer now, and leaving it
        // there would invite the user to attach it twice.
        let coordinator = WatchedFolderIngestCoordinator.shared
        for (folderID, offers) in coordinator.attachmentOffers
        where offers.contains(where: { $0.id == offer.id }) {
            coordinator.attachmentOffers[folderID] = offers.filter { $0.id != offer.id }
        }
        Logger.files.infoCapture(
            "attached \(offer.fileName) to \(candidate.citeKey) on the user's say-so",
            category: "watched-folders")
    }

    func revealWatchedFolder(_ id: WatchedFolderID) {
        guard let path = watchedFolderRows.first(where: { $0.id == id })?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Menu

    func buildWatchedFolderContextMenu(_ menu: NSMenu, folderID: WatchedFolderID) {
        guard let row = watchedFolderRows.first(where: { $0.id == folderID }) else { return }

        // The chassis rule `WatchedFolderRowState` encodes: OMIT a dead
        // affordance rather than showing one. A folder we cannot open needs the
        // user to choose it again, not to press Refresh.
        if row.offersRefresh {
            let item = NSMenuItem(
                title: "Refresh",
                action: #selector(ContextMenuActions.refreshWatchedFolder(_:)),
                keyEquivalent: "")
            item.target = ContextMenuActions.shared
            item.representedObject = folderID
            menu.addItem(item)
        }
        if row.offersReauthorization {
            let item = NSMenuItem(
                title: "Choose Again…",
                action: #selector(ContextMenuActions.reauthorizeWatchedFolder(_:)),
                keyEquivalent: "")
            item.target = ContextMenuActions.shared
            item.representedObject = folderID
            menu.addItem(item)
        }

        // ADR-0023 W5. OMITTED ENTIRELY when there is nothing to review — the
        // same rule Refresh and Choose Again… follow two lines up, and the
        // reason this row's matrix entry says "omit a dead affordance, never
        // show one". A folder whose PDFs all attached cleanly is the common
        // case and must not grow a menu item that opens an empty list.
        let pending = pendingAttachmentOffers(folderID)
        if !pending.isEmpty {
            let item = NSMenuItem(
                title: pending.count == 1
                    ? "Review 1 PDF Match…" : "Review \(pending.count) PDF Matches…",
                action: #selector(ContextMenuActions.reviewWatchedAttachments(_:)),
                keyEquivalent: "")
            item.target = ContextMenuActions.shared
            item.representedObject = folderID
            menu.addItem(item)
        }

        let reveal = NSMenuItem(
            title: "Reveal in Finder",
            action: #selector(ContextMenuActions.revealWatchedFolder(_:)),
            keyEquivalent: "")
        reveal.target = ContextMenuActions.shared
        reveal.representedObject = folderID
        menu.addItem(reveal)

        menu.addItem(.separator())

        // The state, verbatim, as a disabled row. The outline row has no
        // subtitle; this is where `explanation` — the sentence that says what a
        // degraded folder will and will not do — actually reaches the user.
        let explanation = NSMenuItem(title: row.explanation, action: nil, keyEquivalent: "")
        explanation.isEnabled = false
        menu.addItem(explanation)

        menu.addItem(.separator())

        let stop = NSMenuItem(
            title: "Stop Watching",
            action: #selector(ContextMenuActions.stopWatchingFolder(_:)),
            keyEquivalent: "")
        stop.target = ContextMenuActions.shared
        stop.representedObject = folderID
        menu.addItem(stop)
    }
}

/// The (folder, kind) pair a file-unit menu item carries.
///
/// `representedObject` is `Any?`, so the publication row could get away with a
/// bare `WatchedFolderID`. A file-unit row cannot: the coordinator is looked up
/// BY kind scope, and a menu item that knew only the folder id would have to
/// guess which of the process's coordinators owns it.
final class WatchedFileFolderToken: NSObject {
    let folderID: WatchedFolderID
    let kindScope: String

    init(folderID: WatchedFolderID, kindScope: String) {
        self.folderID = folderID
        self.kindScope = kindScope
    }
}

extension ContextMenuActions {

    @objc func addWatchedFolder(_ sender: NSMenuItem) {
        viewModel?.addWatchedFolder()
    }

    // MARK: ADR-0023 W4

    /// Section context-menu entry: "Watch Folder…", carrying the kind scope in
    /// `representedObject` so ONE selector serves impart and implore.
    @objc func addWatchedFileFolder(_ sender: NSMenuItem) {
        guard let kindScope = sender.representedObject as? String else { return }
        viewModel?.addWatchedFileFolder(kindScope: kindScope)
    }

    @objc func refreshWatchedFileFolder(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? WatchedFileFolderToken else { return }
        Task { @MainActor in
            await WatchedFolderIngestCoordinator
                .runningCoordinator(forKindScope: token.kindScope)?.refresh(token.folderID)
            viewModel?.bumpDataVersion()
        }
    }

    @objc func reauthorizeWatchedFileFolder(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? WatchedFileFolderToken else { return }
        viewModel?.addWatchedFileFolder(kindScope: token.kindScope)
    }

    @objc func revealWatchedFileFolder(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? WatchedFileFolderToken,
            let path = WatchedFolderIngestCoordinator
                .runningCoordinator(forKindScope: token.kindScope)?
                .rows.first(where: { $0.id == token.folderID })?.path
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Stop watching. Keeps every `watched-file` row's history? No — the folder
    /// row goes and its file rows go with it, because for a file-unit kind
    /// those rows ARE the folder's content and nothing was produced from them
    /// that could be stranded. Nothing on disk is touched (D4).
    @objc func stopWatchingFileFolder(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? WatchedFileFolderToken else { return }
        Task { @MainActor in
            await WatchedFolderIngestCoordinator
                .runningCoordinator(forKindScope: token.kindScope)?.removeFolder(token.folderID)
            if viewModel?.selectedNodeID
                == ImbibSidebarNodeID.watchedFileFolder(
                    token.folderID, kindScope: token.kindScope) {
                viewModel?.selectDefaultSectionLeaf()
            }
            viewModel?.bumpDataVersion()
        }
    }

    @objc func refreshWatchedFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WatchedFolderID else { return }
        viewModel?.refreshWatchedFolder(id)
    }

    /// Re-granting access is the same gesture as adding: the user picks the
    /// folder again, and `persistAndAdd` mints a fresh bookmark for the id the
    /// path already derives.
    @objc func reauthorizeWatchedFolder(_ sender: NSMenuItem) {
        viewModel?.addWatchedFolder()
    }

    /// ADR-0023 W5.
    @objc func reviewWatchedAttachments(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WatchedFolderID else { return }
        viewModel?.reviewWatchedAttachments(id)
    }

    @objc func revealWatchedFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WatchedFolderID else { return }
        viewModel?.revealWatchedFolder(id)
    }

    @objc func stopWatchingFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WatchedFolderID else { return }
        viewModel?.stopWatchingFolder(id)
    }
}
#endif


// MARK: - ADR-0023 W5: the review request

/// One folder's review surface, as a `.sheet(item:)` payload.
///
/// A VALUE and not a folder id: the sheet must render what was offered at the
/// moment the user asked, not re-read a list that a background scan can change
/// underneath an open window. The same reason `WatchedFolderRowState` is a
/// snapshot of the watcher's registration rather than a live handle on it.
public struct WatchedAttachmentReviewRequest: Identifiable, Hashable, Sendable {
    public let folderID: WatchedFolderID
    public let folderName: String
    public let offers: [WatchedAttachmentOffer]

    public var id: WatchedFolderID { folderID }

    public init(
        folderID: WatchedFolderID, folderName: String, offers: [WatchedAttachmentOffer]
    ) {
        self.folderID = folderID
        self.folderName = folderName
        self.offers = offers
    }
}
