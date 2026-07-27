#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  MessageSectionView.swift
//  PublicationManagerCore
//
//  Composes the Mail section as the STANDARD chassis list|detail split
//  (Stage 2-A) — the FigureSectionView pattern minus delete/dismiss (mail's
//  lifecycle is IMAP-owned; the store surface is star/flag/tag only).
//

import SwiftUI
import AppKit
import ImpressFTUI
import ImpressSidebar
import OSLog

public struct MessageSectionView: View {

    let scope: MessageListScope
    @Environment(\.appShellConfiguration) private var shellConfiguration
    @State private var selectedID: UUID?
    // Messages land on the Info tab; Source and View are one keystroke away.
    @State private var selectedTab: DetailTab = .info

    public init(scope: MessageListScope) {
        self.scope = scope
    }

    public var body: some View {
        // Declarative pane layout (mirrors SectionContentView.contentBody):
        // ⌥⌘0 hides the list, ⌘0 hides the detail; both hidden falls back to
        // the list so the route is never empty.
        Group {
            let layout = PaneLayoutStore.shared.current
            if layout.listPaneVisible && layout.detailPaneVisible {
                ImpressSplitView(
                    listMinWidth: 220,
                    listIdealFraction: 1.0 / 3.0,
                    detailMinWidth: 320
                ) {
                    listPane
                } detail: {
                    detailPane
                        .ignoresSafeArea(.container, edges: .top)
                }
            } else if layout.detailPaneVisible {
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
            } else {
                listPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var listPane: some View {
        MessageListWrapper(
            scope: scope,
            selectedID: $selectedID,
            actions: makeActions()
        )
    }

    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedID {
            // topInset: 40 clears the toolbar band this pane reclaims via
            // `.ignoresSafeArea(.top)` (same rule as FigureDetailPane).
            MessageDetailPane(messageID: id, selectedTab: $selectedTab, topInset: 40)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Select a message")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    /// The shared store-backed triage defaults (ADR-0021) are the WHOLE
    /// action surface for mail v1: star/flag/tag through the generic Rust
    /// ops. No onDelete/onDismiss (descriptor: .none — IMAP owns them), and
    /// open is the detail pane (selection already shows it), so onOpen stays
    /// the default no-op.
    private func makeActions() -> RecordTriageActions {
        RecordTriageActions.storeBacked(descriptor: MessageRecordKind.descriptor)
    }
}
#endif
