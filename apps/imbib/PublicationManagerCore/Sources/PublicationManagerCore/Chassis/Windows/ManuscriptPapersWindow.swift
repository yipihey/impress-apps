#if os(macOS)
//
//  ManuscriptPapersWindow.swift
//  PublicationManagerCore
//
//  The papers of a manuscript, shown in imbib's OWN list and detail — one
//  window, no sidebar, scoped to the manuscript's imbib collection.
//
//  This replaced imprint's Papers side panel, which had grown a second
//  implementation of imbib's list, inspector, PDF acquisition and catalog
//  search inside the manuscript editor. Curating a collection and citing from
//  it are the same act, so they are now the same surface: the rows, the
//  context menu, the Info/PDF/Notes/BibTeX tabs, the filter field, the
//  triage keys and the full-screen PDF are imbib's, and the only things this
//  window adds are the manuscript's context and the two verbs the editor needs
//  — insert a citation, and keep what you cite in the collection.
//
//  The window is opened by `imbib://manuscript/<id>/papers`, by the
//  `imbib-app-service_open-manuscript-papers` verb, and (in-process) by
//  imprint's Papers command.
//

import AppKit
import ImpressKit
import ImpressSidebar
import OSLog
import SwiftUI

// MARK: - Request

/// What to show, and which manuscript it belongs to.
public struct ManuscriptPapersRequest: Sendable, Equatable {
    /// The imbib collection that holds the manuscript's papers. This is the
    /// whole scope — `project-sync-reading-collection` has already folded the
    /// cited papers into it.
    public let collectionID: UUID
    public let collectionName: String
    /// The manuscript, when one asked for the window. Nil means "just show me
    /// this collection", and the citation verbs stay hidden.
    public let manuscriptID: UUID?
    public let manuscriptTitle: String?
    /// The manuscript's citation syntax, for the text the window writes.
    public let format: DocumentFormat
    /// Cite keys the manuscript uses that imbib does not hold. No paper exists
    /// to list, so the window says so rather than leaving them invisible.
    public let missingCiteKeys: [String]

    public init(
        collectionID: UUID,
        collectionName: String,
        manuscriptID: UUID? = nil,
        manuscriptTitle: String? = nil,
        format: DocumentFormat = .typst,
        missingCiteKeys: [String] = []
    ) {
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.manuscriptID = manuscriptID
        self.manuscriptTitle = manuscriptTitle
        self.format = format
        self.missingCiteKeys = missingCiteKeys
    }

    var windowTitle: String {
        guard let manuscriptTitle, !manuscriptTitle.isEmpty else { return collectionName }
        return "\(manuscriptTitle) — Papers"
    }
}

// MARK: - View

struct ManuscriptPapersWindowView: View {

    let request: ManuscriptPapersRequest

    /// What the list shows. The collection IS the manuscript's paper set; the
    /// catalog is how a paper joins it (the panel this replaced had a separate
    /// ⌘F search mode for exactly this, over a hand-written result list).
    private enum Scope: String, CaseIterable, Identifiable {
        case collection
        case catalog
        var id: String { rawValue }
        var label: String {
            switch self {
            case .collection: return "This manuscript"
            case .catalog: return "All papers"
            }
        }
    }

    @Environment(LibraryManager.self) private var libraryManager

    @State private var scope: Scope = .collection
    @State private var selectedPublicationID: UUID?
    @State private var selectedPublicationIDs = Set<UUID>()
    @State private var selectedDetailTab: DetailTab = .info
    /// One line under the header: what the last citation or collect did.
    @State private var status: String?
    @State private var statusIsError = false
    @State private var showMissingKeys = false

    private var source: PublicationSource {
        switch scope {
        case .collection:
            return .collection(request.collectionID)
        case .catalog:
            // Every library the user has — imbib's list filter (⌘F) narrows it.
            let libraries = libraryManager.libraries.map { PublicationSource.library($0.id) }
            return libraries.count == 1 ? libraries[0] : .combined(libraries)
        }
    }

    /// The papers the citation verbs act on: the multi-selection when there is
    /// one, else the focused row.
    private var actionTargets: [UUID] {
        if !selectedPublicationIDs.isEmpty { return Array(selectedPublicationIDs) }
        return selectedPublicationID.map { [$0] } ?? []
    }

    private var canCite: Bool { request.manuscriptID != nil && !actionTargets.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ImpressSplitView(
                listMinWidth: 260,
                fractionStorageKey: "impress.split.manuscript-papers",
                detailMinWidth: 360
            ) {
                UnifiedPublicationListWrapper(
                    source: source,
                    selectedPublicationID: $selectedPublicationID,
                    selectedPublicationIDs: $selectedPublicationIDs,
                    // The papers you are reading while you write belong at the
                    // top — the order the deleted panel had. The sort menu (and
                    // the user's saved choice for this scope) still wins.
                    initialSortOrder: .recentActivity
                )
                .id(source.viewID)
            } detail: {
                detail
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .onChange(of: scope) { _, _ in
            // A row from the previous scope is not in the new one.
            selectedPublicationID = nil
            selectedPublicationIDs = []
        }
        // ⏎ cites; ⌘⏎ cites and hands the keyboard back to imprint. Guarded so
        // typing in the list's filter field never fires them.
        .keyboardGuarded { press in
            guard press.key == .return, canCite else { return .ignored }
            insertCitation(activateImprint: press.modifiers.contains(.command))
            return .handled
        }
        .sheet(isPresented: $showMissingKeys) {
            MissingCiteKeysSheet(keys: request.missingCiteKeys) { showMissingKeys = false }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                if let title = request.manuscriptTitle, !title.isEmpty {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if !request.missingCiteKeys.isEmpty {
                    Button {
                        showMissingKeys = true
                    } label: {
                        Label("\(request.missingCiteKeys.count) not in imbib", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .help("Cite keys this manuscript uses that imbib has no paper for")
                }

                if request.manuscriptID != nil {
                    Button {
                        collectTargets()
                    } label: {
                        Label("Keep for this manuscript", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(actionTargets.isEmpty)
                    .help("Add the selected papers to this manuscript's collection")

                    Button {
                        insertCitation(activateImprint: false)
                    } label: {
                        Label("Cite", systemImage: "quote.opening")
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!canCite)
                    .help("Insert \(citationPreview) at the caret in imprint (⌘⏎ also switches to imprint)")
                }
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Color.red : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// What the Cite button will write, for its help text.
    private var citationPreview: String {
        let keys = citeKeys(of: actionTargets)
        let sample = keys.isEmpty ? ["key"] : keys
        return ManuscriptCitationInserter.citationText(for: sample, format: request.format)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedPublicationID,
           let view = DetailView(
               publicationID: id,
               selectedTab: $selectedDetailTab,
               isMultiSelection: selectedPublicationIDs.count > 1,
               selectedPublicationIDs: selectedPublicationIDs
           ) {
            view
        } else {
            ChassisEmptyState.noRowSelection(isArtifact: false).view
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func citeKeys(of ids: [UUID]) -> [String] {
        ids.compactMap { RustStoreAdapter.shared.getPublication(id: $0)?.citeKey }
            .filter { !$0.isEmpty }
    }

    /// Insert the selection's cite keys into the manuscript's editor, and keep
    /// those papers in its collection so the window's own scope stays the
    /// manuscript's paper set.
    ///
    /// The editor is usually in ANOTHER PROCESS — this window is imbib's,
    /// imprint holds the manuscript — so the local registry is tried first
    /// (for a host that opened this window with an editor of its own) and
    /// imprint's HTTP API second. Both end at the same
    /// `ManuscriptCitationInserter` in whichever process owns the caret.
    private func insertCitation(activateImprint: Bool) {
        guard let manuscriptID = request.manuscriptID else { return }
        let targets = actionTargets
        let keys = citeKeys(of: targets)
        guard !keys.isEmpty else {
            report("These papers have no cite key.", isError: true)
            return
        }

        let local = ManuscriptCitationInserter.shared.insert(keys, into: manuscriptID)
        if local.didInsert {
            finishCitation(targets, manuscriptID: manuscriptID, text: local.message,
                           activateImprint: activateImprint)
            return
        }
        if case .refused(let why) = local {
            report(why, isError: true)
            return
        }

        // No editor here: ask imprint.
        report("Citing in imprint…", isError: false)
        Task { @MainActor in
            do {
                let response = try await ImprintBridge.insertCitation(
                    citeKeys: keys, into: manuscriptID)
                if response.inserted {
                    finishCitation(
                        targets, manuscriptID: manuscriptID,
                        text: ManuscriptCitationInserter.citationText(
                            for: keys, format: request.format),
                        activateImprint: activateImprint)
                } else {
                    report(
                        response.message
                            ?? "imprint has no open editor for this manuscript — open it there, then cite again.",
                        isError: true)
                }
            } catch {
                report(
                    "imprint is not answering — is it running? (\(error.localizedDescription))",
                    isError: true)
            }
        }
    }

    /// Shared tail of a successful citation: the paper belongs to the
    /// manuscript now, whether it came from the collection or the catalog.
    private func finishCitation(
        _ targets: [UUID], manuscriptID: UUID, text: String, activateImprint: Bool
    ) {
        collect(targets, manuscriptID: manuscriptID, quiet: true)
        report("Cited \(text)", isError: false)
        if activateImprint { Self.activateImprint() }
    }

    private func collectTargets() {
        guard let manuscriptID = request.manuscriptID else { return }
        collect(actionTargets, manuscriptID: manuscriptID, quiet: false)
    }

    private func collect(_ ids: [UUID], manuscriptID: UUID, quiet: Bool) {
        guard !ids.isEmpty else { return }
        let outcome = CollectionStoreAdapter.shared.keepForManuscript(
            manuscriptID: manuscriptID, publicationIDs: ids)
        guard !quiet else { return }
        if let outcome {
            report(
                outcome.added.isEmpty
                    ? "Already in this manuscript's papers."
                    : "Added \(outcome.added.count) paper(s) to this manuscript.",
                isError: false)
        } else {
            report("Could not add these papers to the manuscript's collection.", isError: true)
        }
    }

    private func report(_ message: String, isError: Bool) {
        status = message
        statusIsError = isError
        Logger.editor.infoCapture("papers window: \(message)", category: "citation")
    }

    /// Bring imprint to the front — the author asked to go back to writing.
    static func activateImprint() {
        let imprints = NSRunningApplication.runningApplications(withBundleIdentifier: "com.impress.imprint")
        if let imprint = imprints.first {
            imprint.activate(options: [.activateAllWindows])
        }
    }
}

// MARK: - Missing cite keys

private struct MissingCiteKeysSheet: View {
    let keys: [String]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cited, but not in imbib")
                .font(.headline)
            Text("These keys appear in the manuscript and match no paper in your library. "
                 + "Find them in imbib (⌘F in \u{201C}All papers\u{201D}) or import them, and they "
                 + "will join this manuscript's papers on the next sync.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(keys, id: \.self) { key in
                        Text(key).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            HStack {
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(keys.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

// MARK: - Window controller

/// Opens and reuses the manuscript-papers window.
///
/// One window per manuscript (or per collection when no manuscript asked), so
/// citing from two manuscripts at once works and asking twice raises the window
/// that is already open — the failure mode of imprint's old "Open in imbib"
/// link, which left a new window behind every time.
@MainActor
public final class ManuscriptPapersWindowController {

    public static let shared = ManuscriptPapersWindowController()

    private var windows: [UUID: NSWindow] = [:]
    private var delegates: [UUID: WindowDelegate] = [:]

    /// The app's view models, needed by imbib's list and detail. The host
    /// installs them once at launch; a window opened by URL later finds them.
    private var libraryViewModel: LibraryViewModel?
    private var searchViewModel: SearchViewModel?
    private var libraryManager: LibraryManager?

    private init() {}

    /// Install the environment the window's imbib views read. Called once by
    /// the app at launch.
    public func configure(
        libraryViewModel: LibraryViewModel,
        searchViewModel: SearchViewModel,
        libraryManager: LibraryManager
    ) {
        self.libraryViewModel = libraryViewModel
        self.searchViewModel = searchViewModel
        self.libraryManager = libraryManager
    }

    /// Whether `configure` has run — a URL that arrives before launch finishes
    /// can be retried rather than dropped.
    public var isReady: Bool { libraryViewModel != nil && libraryManager != nil }

    @discardableResult
    public func open(_ request: ManuscriptPapersRequest) -> Bool {
        guard let libraryViewModel, let searchViewModel, let libraryManager else {
            Logger.editor.errorCapture(
                "papers window: imbib is still starting up", category: "citation")
            return false
        }
        let key = request.manuscriptID ?? request.collectionID
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Logger.editor.infoCapture(
                "papers window: raised the window already open for \(request.windowTitle)",
                category: "citation")
            return true
        }

        let content = ManuscriptPapersWindowView(request: request)
            .environment(libraryViewModel)
            .environment(searchViewModel)
            .environment(libraryManager)

        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = request.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.minSize = NSSize(width: 900, height: 520)
        window.center()
        window.isReleasedWhenClosed = false

        let delegate = WindowDelegate(key: key, controller: self)
        window.delegate = delegate
        delegates[key] = delegate
        windows[key] = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Logger.editor.infoCapture(
            "papers window: opened '\(request.windowTitle)' on collection \(request.collectionID)"
                + (request.manuscriptID == nil ? "" : ", citing into \(request.manuscriptID!)"),
            category: "citation")
        return true
    }

    /// Close the window for a manuscript (or collection), if one is open.
    public func close(key: UUID) {
        windows[key]?.close()
    }

    fileprivate func windowDidClose(key: UUID) {
        windows.removeValue(forKey: key)
        delegates.removeValue(forKey: key)
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        let key: UUID
        weak var controller: ManuscriptPapersWindowController?

        init(key: UUID, controller: ManuscriptPapersWindowController) {
            self.key = key
            self.controller = controller
        }

        func windowWillClose(_ notification: Notification) {
            Task { @MainActor in controller?.windowDidClose(key: key) }
        }
    }
}
#endif
