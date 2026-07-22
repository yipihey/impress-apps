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

    /// The live editor session (registry-owned). Resolved on id change.
    @State private var session: ManuscriptEditorSession?

    public init(manuscriptID: UUID, selectedTab: Binding<DetailTab>, topInset: CGFloat = 0) {
        self.manuscriptID = manuscriptID
        self._selectedTab = selectedTab
        self.topInset = topInset
    }

    private var availableTabs: [DetailTab] { DetailTab.available(for: .manuscript) }

    public var body: some View {
        VStack(spacing: 0) {
            tabPicker
                .padding(.top, topInset)
            Divider()
            content
        }
        .onChange(of: manuscriptID, initial: true) { _, id in
            // Resolve (or load) the session for this manuscript. No `.id()` on
            // the pane — the registry preserves editor state across switches.
            session = ManuscriptSessionRegistry.shared.session(for: id)
            selectedTab = selectedTab.coerced(for: .manuscript)
        }
        .task(id: manuscriptID) {
            // Cross-process wake-up: refresh the session when this manuscript
            // mutates in another view/app.
            for await event in ImbibImpressStore.shared.events.subscribe() {
                if case .itemsMutated(_, let ids) = event, ids.contains(manuscriptID) {
                    session?.absorbExternalChange()
                }
            }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(availableTabs) { tab in
                Label(tab.label, systemImage: tab.icon).tag(tab)
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
            if let session {
                ManuscriptSourceTab(session: session)
            } else {
                unavailable
            }
        case .pdf:
            // The Preview tab shows the last compiled artifact from the live
            // session (durable-artifact switcher lands with revision PDFs).
            if let session, session.latexPreviewUnavailable {
                ManuscriptLaTeXImprintPrompt(session: session)
            } else if let data = session?.vm.pdfData {
                // Preview tab: a click both jumps the caret AND switches to the
                // Source tab so the jump is visible.
                ManuscriptPDFPreview(data: data, onInverseSync: { page, x, y in
                    guard let session = self.session else { return }
                    Task {
                        if let offset = await ManuscriptInverseSync.resolveOffset(
                            session: session, page: page, x: x, y: y) {
                            session.cursorPosition = offset
                            selectedTab = .source
                        }
                    }
                })
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.richtext").font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Nothing compiled yet")
                        .foregroundStyle(.secondary)
                    Text("Edit in the Source tab to compile a preview.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
