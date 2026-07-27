#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  AnyRecordListWrapper.swift
//  PublicationManagerCore
//
//  WP G3 (ADR-0022 D4): the mixed-kind list — `[KindTaggedRow]` rendered
//  through the registry's row factories, with the selected row's KIND handed
//  back so a host can swap detail panes per selection. That is the impress
//  interaction (D9), built now and first consumed by grouped global search
//  (D6).
//
//  v1 is deliberately minimal: selection + rows. No triage grammar
//  (TriageKeyGrammar), no swipe/context builders, no drag — those are
//  per-kind capability decisions and land with the first real consumer.
//

import SwiftUI
import ImpressMailStyle

public struct AnyRecordListWrapper: View {

    public let rows: [KindTaggedRow]
    @Binding public var selection: Set<UUID>
    /// Called whenever the selection changes with the row a detail pane
    /// should follow (its `kind` is how the host picks the pane).
    private let onPrimaryRowChange: (@MainActor (KindTaggedRow?) -> Void)?

    @Environment(\.recordViewerRegistry) private var viewerRegistry

    public init(
        rows: [KindTaggedRow],
        selection: Binding<Set<UUID>>,
        onPrimaryRowChange: (@MainActor (KindTaggedRow?) -> Void)? = nil
    ) {
        self.rows = rows
        self._selection = selection
        self.onPrimaryRowChange = onPrimaryRowChange
    }

    /// The row a detail pane follows: the first SELECTED row in DISPLAY
    /// order. `Set<UUID>.first` is unordered — following it would flip the
    /// detail pane between equally-selected rows across body evaluations.
    public static func primaryRow(
        in selection: Set<UUID>, of rows: [KindTaggedRow]
    ) -> KindTaggedRow? {
        rows.first { selection.contains($0.id) }
    }

    public var primaryRow: KindTaggedRow? {
        Self.primaryRow(in: selection, of: rows)
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                rowView(row)
                    .tag(row.id)
                    .id(row.id)
            }
        }
        .listStyle(.inset)
        .onChange(of: selection) { _, _ in
            onPrimaryRowChange?(primaryRow)
        }
    }

    /// A kind's own row when it registered one, else the shared mail-style
    /// chrome — an unregistered kind renders honestly, it doesn't vanish.
    @ViewBuilder
    private func rowView(_ row: KindTaggedRow) -> some View {
        if let factory = viewerRegistry[row.kind] {
            factory.makeListRow(row)
        } else {
            MailStyleRow(item: row)
        }
    }
}
#endif
