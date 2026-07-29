// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS).
//
//  RecordTriageListRow.swift
//  PublicationManagerCore
//
//  One modifier that puts the ENTIRE shared triage grammar on a list row:
//  leading swipe, trailing swipe and long-press context menu, all built by
//  `TriageSwipe` / `TriageMenu` from the kind's `TriageCapabilities`.
//
//  It exists because the alternative — every list hand-writing
//  `.swipeActions { … }` — is how the grammars drift. imprint-iOS shipped a
//  hard `.onDelete` where macOS dismisses; that is a one-line call site
//  difference, and a one-line call site is exactly what this replaces. If the
//  descriptor gains a verb, every adopter gets it without editing a view.
//

import SwiftUI

public extension View {

    /// Attach the shared triage grammar to a record row.
    ///
    /// - Parameters:
    ///   - triage: the record kind's declared capabilities (from its
    ///     `RecordKindDescriptor`, never hand-built at the call site).
    ///   - row: this row's star/dismissed/archived state.
    ///   - targets: ids the verbs act on — Mail semantics: the selection when
    ///     the row is part of one, otherwise just this row.
    ///   - actions: the host's action bag.
    ///   - rowTagPaths: tags already on the row (drives the checkmarks).
    ///   - extraMenuItems: kind-specific items appended below the shared ones
    ///     (Open, Move to Folder, Duplicate…).
    func recordTriageRow<Extra: View>(
        triage: TriageCapabilities,
        row: TriageRowState,
        targets: Set<UUID>,
        actions: RecordTriageActions,
        rowTagPaths: Set<String> = [],
        @ViewBuilder extraMenuItems: () -> Extra
    ) -> some View {
        self
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                TriageSwipe.leading(
                    triage: triage, row: row, targets: targets, actions: actions)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                TriageSwipe.trailing(
                    triage: triage, row: row, targets: targets, actions: actions)
            }
            .contextMenu {
                extraMenuItems()
                TriageMenu.items(
                    triage: triage,
                    row: row,
                    rowTagPaths: rowTagPaths,
                    targets: targets,
                    actions: actions)
            }
    }

    /// Overload without kind-specific menu items.
    func recordTriageRow(
        triage: TriageCapabilities,
        row: TriageRowState,
        targets: Set<UUID>,
        actions: RecordTriageActions,
        rowTagPaths: Set<String> = []
    ) -> some View {
        recordTriageRow(
            triage: triage,
            row: row,
            targets: targets,
            actions: actions,
            rowTagPaths: rowTagPaths,
            extraMenuItems: { EmptyView() })
    }
}
