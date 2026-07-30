// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). Pure SwiftUI data +
// one renderer; no AppKit, no platform gate.
//
//  ChassisEmptyState.swift
//  PublicationManagerCore
//
//  The chassis's empty states, as DATA.
//
//  `SectionContentView` hand-wrote six `ContentUnavailableView`s inline, each
//  spelling its own title, SF Symbol and sentence at the point of use. Nothing
//  was wrong with any one of them; the problem is the shape. Copy that lives at
//  a call site cannot be reviewed as a set, so the six drifted into three
//  different voices for the same situation ("No registered viewer for X" vs
//  "No registered surface named X"), two spellings of "No Selection" with
//  different glyphs, and no way for a sibling shell to reuse any of it. A
//  seventh state gets added by copying the nearest one.
//
//  So the copy moves here, VERBATIM — this is a relocation, not a rewrite, and
//  `ChassisEmptyStateTests` pins every string. What changes is that the set is
//  now legible in one screen, reusable from any host (imbib-iOS's detail view
//  is the obvious next adopter), and additive: a new state is a `static let`
//  here, not another block of view code in a 900-line file.
//

import SwiftUI

/// One empty/unavailable state: its title, glyph and sentence.
///
/// `id` exists so a host can key a transition or a test can name a case
/// without matching on prose.
public struct ChassisEmptyState: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let message: String

    public init(id: String, title: String, systemImage: String, message: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }
}

public extension ChassisEmptyState {

    // MARK: Registry misses
    //
    // Both are "this build has no code for the thing the sidebar just
    // selected". They degrade quietly and SAY WHICH ONE, because the two have
    // different causes: an unregistered record kind is a missing
    // `RecordViewerRegistry` factory (ADR-0022 D4), an unregistered surface is
    // a host that forgot `withCustomSurfaces(_:)` (WP-X0).

    /// No `RecordViewerRegistry` factory for a record kind.
    static func viewerUnavailable(kind: RecordKindID) -> ChassisEmptyState {
        ChassisEmptyState(
            id: "viewer-unavailable",
            title: "Viewer Unavailable",
            systemImage: RecordKindDescriptor.unknownSymbolName,
            message: "No registered viewer for \u{201C}\(kind.rawValue)\u{201D}.")
    }

    /// No `CustomSurfaceDescriptor` registered under an id.
    static func surfaceUnavailable(id surfaceID: String) -> ChassisEmptyState {
        ChassisEmptyState(
            id: "surface-unavailable",
            title: "Surface Unavailable",
            systemImage: RecordKindDescriptor.unknownSymbolName,
            message: "No registered surface named \u{201C}\(surfaceID)\u{201D}.")
    }

    // MARK: Nothing selected / nothing there

    static let inboxEmpty = ChassisEmptyState(
        id: "inbox-empty",
        title: "Inbox Empty",
        systemImage: "tray",
        message: "Add feeds to start discovering papers")

    /// No sidebar selection at all.
    static let noSidebarSelection = ChassisEmptyState(
        id: "no-sidebar-selection",
        title: "No Selection",
        systemImage: "sidebar.left",
        message: "Select an item from the sidebar")

    /// A list is showing but no ROW is selected. Phrased per kind, because
    /// "Select a publication" in front of a list of artifacts is the kind of
    /// small lie that makes a UI feel machine-generated.
    static func noRowSelection(isArtifact: Bool) -> ChassisEmptyState {
        ChassisEmptyState(
            id: isArtifact ? "no-row-selection.artifact" : "no-row-selection.publication",
            title: "No Selection",
            systemImage: isArtifact ? "archivebox" : "doc.text",
            message: isArtifact
                ? "Select an artifact to view details"
                : "Select a publication to view details")
    }

    /// The search pane's signpost: results land in the sidebar, not here.
    static let searchResultsElsewhere = ChassisEmptyState(
        id: "search-results-elsewhere",
        title: "Search Results",
        systemImage: "magnifyingglass",
        message: "Results appear in the Exploration section of the sidebar.")

    /// Every state that does not need a parameter — what
    /// `ChassisEmptyStateTests` iterates so a new one cannot ship with an
    /// empty title, a missing glyph or no sentence.
    static let allParameterless: [ChassisEmptyState] = [
        .inboxEmpty, .noSidebarSelection, .searchResultsElsewhere,
    ]
}

// MARK: - Renderer

public extension ChassisEmptyState {
    /// The one place a `ContentUnavailableView` is built from these.
    @ViewBuilder
    var view: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(message))
    }

    /// The same state with a RECOVERY affordance under it.
    ///
    /// Added by C1 for `RecordListHost`: imprint's empty manuscript list offers
    /// "New Manuscript" and impart's empty mailbox offers nothing (it registers
    /// no create verb — there is no SMTP path anywhere in that target, so a
    /// button would be a dead control). Both are the same state with a different
    /// answer to "can the user fix this from here", which is a builder, not two
    /// empty-state types.
    @ViewBuilder
    func view<Actions: View>(@ViewBuilder actions: () -> Actions) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            actions()
        }
    }
}

public extension View {
    /// Replace this view with an empty state. Sugar for the call sites that
    /// only ever render one.
    @ViewBuilder
    func chassisEmptyState(_ state: ChassisEmptyState) -> some View {
        state.view
    }
}
