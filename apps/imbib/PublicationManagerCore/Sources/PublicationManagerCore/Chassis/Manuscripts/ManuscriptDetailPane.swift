#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  ManuscriptDetailPane.swift
//  PublicationManagerCore
//
//  The tabbed manuscript detail (GUI-meld plan §4): the standard chassis
//  detail experience for a manuscript, mirroring DetailView's tab host but for
//  manuscript items — Info / Source / Preview. The editor session comes from
//  the registry (outside the view tree), so this pane carries NO `.id()`; tab
//  and selection switches never tear down the editor or an in-flight compile.

import SwiftUI

public struct ManuscriptDetailPane: View {

    let manuscriptID: UUID
    @Binding var selectedTab: DetailTab

    /// Top clearance for the tab picker. The section host reclaims the toolbar
    /// band with `.ignoresSafeArea(.top)`, which would otherwise draw the
    /// segmented picker up inside the window's titlebar drag region — clicks
    /// there hit the drag region, not the control, so tabs can't be switched.
    /// The standalone editor window (which sits below its own header) passes 0.
    let topInset: CGFloat

    /// The live editor session (registry-owned), resolved by the HOST — the
    /// section view or the standalone editor window — and passed down.
    ///
    /// It is deliberately NOT `@State` here: local state survived the pane's
    /// reuse across selection changes, so Source/Preview kept showing the
    /// previously selected manuscript while Info (which reads `manuscriptID`
    /// directly) updated. With the session as a plain input, the panes cannot
    /// disagree with the selection.
    let session: ManuscriptEditorSession?

    public init(
        manuscriptID: UUID,
        session: ManuscriptEditorSession?,
        selectedTab: Binding<DetailTab>,
        topInset: CGFloat = 0
    ) {
        self.manuscriptID = manuscriptID
        self.session = session
        self._selectedTab = selectedTab
        self.topInset = topInset
    }

    /// The session only counts when it belongs to the manuscript on screen.
    private var liveSession: ManuscriptEditorSession? {
        session?.manuscriptID == manuscriptID ? session : nil
    }

    /// Preview kind of the loaded manuscript's format (PDF for Typst/LaTeX,
    /// rendered Markdown, or none for plain text). Defaults to compiledPDF
    /// while the session is still resolving.
    private var previewKind: DocumentFormat.PreviewKind {
        liveSession?.format.previewKind ?? .compiledPDF
    }

    private var tabContext: RecordTabContext { RecordTabContext(previewKind: previewKind) }

    private var availableTabs: [DetailTab] {
        ManuscriptRecordKind.descriptor.availableTabs(for: tabContext)
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabPicker
                .padding(.top, topInset)
            Divider()
            content
        }
        .onChange(of: previewKind, initial: true) { _, _ in
            // Plain text drops the Preview tab; markdown relabels it. Keep a
            // persisted tab valid for whatever format just loaded.
            let coerced = ManuscriptRecordKind.descriptor.coercedTab(selectedTab, for: tabContext)
            if coerced != selectedTab { selectedTab = coerced }
        }
        .task(id: manuscriptID) {
            // Cross-process wake-up: refresh the session when this manuscript
            // mutates in another view/app.
            for await event in ImbibImpressStore.shared.events.subscribe() {
                if case .itemsMutated(_, let ids) = event, ids.contains(manuscriptID) {
                    liveSession?.absorbExternalChange()
                }
            }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(availableTabs) { tab in
                // The manuscript "PDF" tab is really a preview surface —
                // label it as such (it renders Markdown live for .md).
                Label(tab == .pdf ? "Preview" : tab.label, systemImage: tab.icon).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .info:
            ManuscriptDetailView(manuscriptID: manuscriptID.uuidString)
        case .source:
            if let session = liveSession {
                ManuscriptSourceTab(session: session)
            } else {
                unavailable
            }
        case .pdf:
            // The Preview tab — shared with the layout tree's `pdf` pane over
            // manuscripts (`ManuscriptPreviewContent`). A click in it switches
            // to the Source tab here.
            ManuscriptPreviewContent(session: liveSession, onShowSource: { selectedTab = .source })
        case .notes, .bibtex:
            // Not part of the manuscript tab set; coerced away on entry.
            unavailable
        }
    }

    private var unavailable: some View {
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
