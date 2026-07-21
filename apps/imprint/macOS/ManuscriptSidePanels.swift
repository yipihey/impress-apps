//
//  ManuscriptSidePanels.swift
//  imprint
//
//  Panels Phase A/B/C: imprint's flanking inspector panels contributed into the
//  shared PMC Source tab via `ManuscriptEditorEnvironment.sidePanels`. Each
//  conforms to PMC's `ManuscriptSidePanel` and builds its view from the
//  `ManuscriptPanelContext` (or, for document-coupled panels, from a
//  `PanelManuscriptBridge`). imbib installs none → no inspector.
//

#if os(macOS)
import SwiftUI
import PublicationManagerCore
import ImpressPublicationUI

// MARK: - Throughline (hard — needs an ImprintDocument bridge)

struct ThroughlineSidePanel: ManuscriptSidePanel {
    let id = "throughline"
    let label = "Throughline"
    let systemImage = "text.line.first.and.arrowtriangle.forward"

    func makeView(_ context: ManuscriptPanelContext) -> AnyView {
        AnyView(ThroughlinePanelHost(context: context))
    }
}

/// Hosts `ThroughlinePaneView`, which binds `$document: ImprintDocument`.
/// A per-manuscript `PanelManuscriptBridge` supplies that document from the
/// store and keeps its `source` synced with the live editor. Navigation
/// resolves the section slug to a caret offset (mirrors ContentView).
private struct ThroughlinePanelHost: View {
    let context: ManuscriptPanelContext
    @State private var bridge: PanelManuscriptBridge

    init(context: ManuscriptPanelContext) {
        self.context = context
        _bridge = State(initialValue: PanelBridgeRegistry.shared.bridge(for: context.manuscriptID))
    }

    var body: some View {
        ThroughlinePaneView(
            document: Binding(get: { bridge.doc }, set: { bridge.doc = $0 }),
            onNavigateToSection: { slug in navigate(to: slug) }
        )
        .onAppear { bridge.syncSource(context.source.wrappedValue) }
        .onChange(of: context.source.wrappedValue) { _, latest in bridge.syncSource(latest) }
    }

    private func navigate(to slug: String) {
        for section in ThroughlineCoordinator.extractSections(of: bridge.doc)
        where section.key == slug {
            let src = bridge.doc.source
            if let range = src.range(of: "= \(section.title)") ?? src.range(of: section.title) {
                context.jumpToChar(src.distance(from: src.startIndex, to: range.lowerBound))
            }
            return
        }
    }
}

// MARK: - AI Assistant (easy — no ImprintDocument)

struct AIAssistantSidePanel: ManuscriptSidePanel {
    let id = "ai"
    let label = "AI Assistant"
    let systemImage = "sparkles"

    func makeView(_ context: ManuscriptPanelContext) -> AnyView {
        AnyView(AIAssistantPanelHost(context: context))
    }
}

/// Wraps `AIChatSidebar`, which needs a `@Binding` selectedText — seeded from
/// the context's current selection.
private struct AIAssistantPanelHost: View {
    let context: ManuscriptPanelContext
    @State private var selectedText: String

    init(context: ManuscriptPanelContext) {
        self.context = context
        _selectedText = State(initialValue: context.selectedText)
    }

    var body: some View {
        AIChatSidebar(
            selectedText: $selectedText,
            documentSource: context.source,
            onInsertText: context.insertAtCursor
        )
        // Keep the chat's "selected text" seed fresh as the editor selection
        // changes (the context is rebuilt on selection change).
        .onChange(of: context.selectedText) { _, new in selectedText = new }
    }
}

// MARK: - Paper preview (easiest — view already in a shared package)

struct PaperPreviewSidePanel: ManuscriptSidePanel {
    let id = "paper"
    let label = "Paper"
    let systemImage = "doc.text.magnifyingglass"

    func makeView(_ context: ManuscriptPanelContext) -> AnyView {
        AnyView(PaperPreviewPanelHost())
    }
}

/// Observes `.openPaperPanel` (posted by the editor's cite-key click/hover) and
/// renders `PaperDetailPanel` for that publication, or a placeholder.
private struct PaperPreviewPanelHost: View {
    @State private var publicationID: String?

    var body: some View {
        Group {
            if let publicationID {
                PaperDetailPanel(
                    publicationID: publicationID,
                    dataSource: ImprintPublicationService.shared,
                    onClose: { self.publicationID = nil }
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Click a citation to preview the paper")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPaperPanel)) { note in
            if let id = note.userInfo?["publicationID"] as? String {
                publicationID = id
            }
        }
    }
}
#endif
