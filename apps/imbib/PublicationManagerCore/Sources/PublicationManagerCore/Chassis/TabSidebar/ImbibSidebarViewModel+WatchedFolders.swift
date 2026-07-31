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

extension ContextMenuActions {

    @objc func addWatchedFolder(_ sender: NSMenuItem) {
        viewModel?.addWatchedFolder()
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
