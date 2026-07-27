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
//  v1 was deliberately minimal: selection + rows. No triage grammar
//  (TriageKeyGrammar), no swipe/context builders, no drag — those are
//  per-kind capability decisions and land with the first real consumer.
//
//  WP G4 added the two things that first consumer (StoreSearchSurface) needed,
//  IN the wrapper rather than beside it, because impress needs grouped mixed
//  lists too (D9):
//    - `grouping: .byKind` — one `Section` per kind, kinds in first-appearance
//      (= relevance) order, header supplied by the host so the wrapper stays
//      ignorant of where display names and icons come from.
//    - `onOpen` — Return / double-click, so a mixed list can perform the
//      per-kind OPEN verb instead of only moving selection.
//

import SwiftUI
import ImpressMailStyle

/// One kind's contiguous run of rows in a grouped mixed-kind list.
public struct KindRowGroup: Identifiable, Hashable, Sendable {
    public let kind: RecordKindID
    public let rows: [KindTaggedRow]
    public var id: String { kind.rawValue }

    public init(kind: RecordKindID, rows: [KindTaggedRow]) {
        self.kind = kind
        self.rows = rows
    }
}

/// What a grouped list puts above one kind's rows.
public struct RecordGroupHeader: Sendable, Equatable {
    public let title: String
    public let systemImage: String?

    public init(title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }
}

public struct AnyRecordListWrapper: View {

    /// Flat, or bucketed by kind with a host-supplied header.
    public enum Grouping {
        case flat
        /// One section per kind. The closure receives the kind and the number
        /// of rows in its bucket.
        case byKind(header: @MainActor @Sendable (RecordKindID, Int) -> RecordGroupHeader)
    }

    public let rows: [KindTaggedRow]
    @Binding public var selection: Set<UUID>
    private let grouping: Grouping
    /// Called whenever the selection changes with the row a detail pane
    /// should follow (its `kind` is how the host picks the pane).
    private let onPrimaryRowChange: (@MainActor (KindTaggedRow?) -> Void)?
    /// Return / double-click on a row. The host resolves the kind's
    /// `OpenBehavior`; the wrapper only reports the gesture.
    private let onOpen: (@MainActor (KindTaggedRow) -> Void)?

    @Environment(\.recordViewerRegistry) private var viewerRegistry

    public init(
        rows: [KindTaggedRow],
        selection: Binding<Set<UUID>>,
        grouping: Grouping = .flat,
        onPrimaryRowChange: (@MainActor (KindTaggedRow?) -> Void)? = nil,
        onOpen: (@MainActor (KindTaggedRow) -> Void)? = nil
    ) {
        self.rows = rows
        self._selection = selection
        self.grouping = grouping
        self.onPrimaryRowChange = onPrimaryRowChange
        self.onOpen = onOpen
    }

    // MARK: - Grouping (pure, unit-tested)

    /// Rows bucketed by kind, kinds in FIRST-APPEARANCE order and each
    /// bucket in the incoming row order.
    ///
    /// First-appearance rather than alphabetical because the only producer so
    /// far hands rows over sorted by relevance: sorting the buckets by name
    /// would bury the best match under "Agent Run".
    public static func groups(from rows: [KindTaggedRow]) -> [KindRowGroup] {
        var order: [RecordKindID] = []
        var buckets: [RecordKindID: [KindTaggedRow]] = [:]
        for row in rows {
            if buckets[row.kind] == nil {
                order.append(row.kind)
                buckets[row.kind] = []
            }
            buckets[row.kind]?.append(row)
        }
        return order.map { KindRowGroup(kind: $0, rows: buckets[$0] ?? []) }
    }

    /// Rows in the order they are actually drawn — grouping reorders them, and
    /// `primaryRow` must follow the DISPLAYED order or the detail pane flips
    /// between equally-selected rows.
    public static func displayOrderedRows(
        _ rows: [KindTaggedRow], grouped: Bool
    ) -> [KindTaggedRow] {
        grouped ? groups(from: rows).flatMap(\.rows) : rows
    }

    // MARK: - Selection

    /// The row a detail pane follows: the first SELECTED row in DISPLAY
    /// order. `Set<UUID>.first` is unordered — following it would flip the
    /// detail pane between equally-selected rows across body evaluations.
    public static func primaryRow(
        in selection: Set<UUID>, of rows: [KindTaggedRow]
    ) -> KindTaggedRow? {
        rows.first { selection.contains($0.id) }
    }

    private var isGrouped: Bool {
        if case .byKind = grouping { return true }
        return false
    }

    private var displayRows: [KindTaggedRow] {
        Self.displayOrderedRows(rows, grouped: isGrouped)
    }

    public var primaryRow: KindTaggedRow? {
        Self.primaryRow(in: selection, of: displayRows)
    }

    // MARK: - Body

    public var body: some View {
        List(selection: $selection) {
            switch grouping {
            case .flat:
                ForEach(rows) { row in
                    rowView(row)
                        .tag(row.id)
                        .id(row.id)
                }
            case .byKind(let header):
                ForEach(Self.groups(from: rows)) { group in
                    let spec = header(group.kind, group.rows.count)
                    Section {
                        ForEach(group.rows) { row in
                            rowView(row)
                                .tag(row.id)
                                .id(row.id)
                        }
                    } header: {
                        headerView(spec, count: group.rows.count)
                    }
                }
            }
        }
        .listStyle(.inset)
        .onChange(of: selection) { _, _ in
            onPrimaryRowChange?(primaryRow)
        }
        // Return is a special key — outside the `.keyboardGuarded` rule, and
        // deliberately so: the list must open on Return while a filter field
        // elsewhere in the pane keeps its own Return semantics.
        .onKeyPress(.return) {
            guard let row = primaryRow, let onOpen else { return .ignored }
            onOpen(row)
            return .handled
        }
    }

    @ViewBuilder
    private func headerView(_ spec: RecordGroupHeader, count: Int) -> some View {
        HStack(spacing: 6) {
            if let systemImage = spec.systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            Text(spec.title)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11, weight: .semibold))
        .textCase(nil)
    }

    /// A kind's own row when it registered one, else the shared mail-style
    /// chrome — an unregistered kind renders honestly, it doesn't vanish.
    @ViewBuilder
    private func rowView(_ row: KindTaggedRow) -> some View {
        Group {
            if let factory = viewerRegistry[row.kind] {
                factory.makeListRow(row)
            } else {
                MailStyleRow(item: row)
            }
        }
        .contentShape(Rectangle())
        // `simultaneousGesture`, not `onTapGesture(count: 2)`: the latter
        // installs an exclusive recognizer that swallows the single click the
        // List needs for selection.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selection = [row.id]
            onOpen?(row)
        })
    }
}
#endif
