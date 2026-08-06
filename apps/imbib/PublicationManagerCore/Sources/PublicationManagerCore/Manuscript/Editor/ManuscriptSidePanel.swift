#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  ManuscriptSidePanel.swift
//  PublicationManagerCore
//
//  The view-provider seam for the Source tab's flanking inspector (imprint's
//  AI Assistant / Throughline / Veusz / Paper-preview panels). PMC owns this
//  protocol + context so imprint can contribute panel VIEWS into the shared
//  chassis without PMC ever importing the imprint app target — the same
//  one-directional injection ManuscriptEditorEnvironment already uses for the
//  editor's other capabilities, extended to return an `AnyView`.
//
//  imbib installs no panels → the inspector is hidden (graceful degradation).

import SwiftUI
import AppKit

/// What a flanking panel receives from the chassis. Everything is derived from
/// the live `ManuscriptEditorSession`; the editor remains the source of truth
/// for `source`. Panels that need the legacy `ImprintDocument` shape build it
/// host-side (imprint's PanelManuscriptBridge) from these primitives.
@MainActor
public struct ManuscriptPanelContext {
    public let manuscriptID: UUID
    /// The editor buffer (two-way; the editor owns it).
    public let source: Binding<String>
    /// Current editor selection (UTF-16 NSRange offsets).
    public let selectedRange: NSRange
    /// The selected substring, or "" — convenience over `source`/`selectedRange`.
    public let selectedText: String
    /// The caret position (two-way; set it to move the caret).
    public let cursorPosition: Binding<Int>
    public let format: DocumentFormat
    /// Live compiled SVG pages. A presentation storyboard can pair explicit
    /// slide blocks with rendered pages without starting a second compiler.
    public let svgPages: [String]
    /// Insert text at the caret (used by AI insert, plot/citation insert).
    public let insertAtCursor: (String) -> Void
    /// Move the caret to a character offset and scroll to it (outline-style nav).
    public let jumpToChar: (Int) -> Void

    public init(
        manuscriptID: UUID,
        source: Binding<String>,
        selectedRange: NSRange,
        selectedText: String,
        cursorPosition: Binding<Int>,
        format: DocumentFormat,
        svgPages: [String] = [],
        insertAtCursor: @escaping (String) -> Void,
        jumpToChar: @escaping (Int) -> Void
    ) {
        self.manuscriptID = manuscriptID
        self.source = source
        self.selectedRange = selectedRange
        self.selectedText = selectedText
        self.cursorPosition = cursorPosition
        self.format = format
        self.svgPages = svgPages
        self.insertAtCursor = insertAtCursor
        self.jumpToChar = jumpToChar
    }
}

/// A flanking inspector panel the host app contributes to the manuscript Source
/// tab. imprint conforms with concrete views; PMC only ever sees the `AnyView`.
@MainActor
public protocol ManuscriptSidePanel {
    /// Stable identifier — used to persist the last-picked panel.
    var id: String { get }
    /// Segmented-picker label.
    var label: String { get }
    /// Segmented-picker SF Symbol.
    var systemImage: String { get }
    /// Build the panel's view for the given manuscript context.
    func makeView(_ context: ManuscriptPanelContext) -> AnyView
}
#endif
