// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): the ONE generic
// Related section — model, off-main reader actor and a plain-SwiftUI view.
//
//  RelatedItemsSection.swift
//  PublicationManagerCore
//
//  WP G5 (ADR-0022 D8): ONE generic Related section for every record kind.
//
//  `SharedStore.relatedItems(id:limit:)` walks the item's typed edges
//  (`Contains`, `Cites`, `InResponseTo`, `ProducedBy`, custom) in both
//  directions and answers with the OTHER end of each: id, schema ref, display
//  title, edge type, direction. Nothing here is kind-specific — the papers a
//  manuscript cites, the messages that produced a task and the figures
//  embedded in a draft are the same query and the same rows.
//
//  Design notes:
//
//  - **Hidden when empty.** Most records have no edges; an empty "Related"
//    header on every Info tab would be noise. `EmptyView`, not an empty
//    section (`CitedInManuscriptsSection` sets the precedent).
//  - **Off-main load.** `RelatedItemsReader` is an actor with its OWN
//    `SharedStore` handle (WAL, same file as every other handle in-process),
//    so the edge walk never runs on the main thread. It hands back
//    `RelatedItemRow` value types; no FFI object crosses the boundary.
//  - **Pure grouping.** Everything between "rows arrive" and "rows render"
//    lives in `RelatedItemsModel` so it is testable without a store or a
//    view (`RelatedItemsSectionTests`).
//  - **Three-point trace** (category "related"): request → count returned →
//    rendered, per the persistence-touching-feature rule in CLAUDE.md.
//

import ImpressKit
import ImpressRustCore
import OSLog
import SwiftUI

// MARK: - Model

/// Which way an edge points relative to the SUBJECT item.
public enum RelatedDirection: String, Sendable, Hashable {
    /// The subject is the edge source — this manuscript *cites* that paper.
    case outgoing
    /// The subject is the edge target — that manuscript cites *this* paper.
    case incoming

    /// Parsed from `SharedRelatedItem.direction`; anything unrecognised is
    /// treated as outgoing rather than dropping the row.
    init(ffi: String) {
        self = (ffi == RelatedDirection.incoming.rawValue) ? .incoming : .outgoing
    }

    /// Arrow shown before the title. Outgoing points away from the subject.
    public var symbolName: String {
        switch self {
        case .outgoing: return "arrow.right"
        case .incoming: return "arrow.left"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .outgoing: return "outgoing"
        case .incoming: return "incoming"
        }
    }
}

/// One related item, projected for display. Sendable so the reader actor can
/// hand it to the main actor.
public struct RelatedItemRow: Identifiable, Hashable, Sendable {
    /// The OTHER item's id — never the subject's.
    public let id: UUID
    public let schemaRef: String
    public let title: String
    /// Raw edge-type name as the store records it ("Cites", "ProducedBy", …).
    public let edgeType: String
    public let direction: RelatedDirection

    public init(
        id: UUID,
        schemaRef: String,
        title: String,
        edgeType: String,
        direction: RelatedDirection
    ) {
        self.id = id
        self.schemaRef = schemaRef
        self.title = title
        self.edgeType = edgeType
        self.direction = direction
    }

    /// Kind for the row icon; `nil` when no descriptor claims the schema.
    public var kind: RecordKindID? {
        BuiltinRecordKinds.registry.kind(forStoreSchemaRef: schemaRef)
    }

    public var symbolName: String { RecordKindIconography.symbolName(for: kind) }
}

/// Rows sharing one edge type, in the order the store returned them.
public struct RelatedItemGroup: Identifiable, Hashable, Sendable {
    public let edgeType: String
    public let items: [RelatedItemRow]

    public var id: String { edgeType }
    /// "InResponseTo" → "In Response To".
    public var displayName: String { RelatedItemsModel.displayName(forEdgeType: edgeType) }
}

/// The pure half of the section: FFI rows in, display groups out. No store,
/// no view, no main actor — the whole reason `RelatedItemsSectionTests` can
/// exist in a package with no GUI harness.
public enum RelatedItemsModel {

    /// Default fan-out cap. The kernel clamps at 500; 50 is what a detail
    /// pane can show without becoming a list surface of its own.
    public static let defaultLimit: UInt32 = 50

    /// Group by edge type, preserving FIRST-APPEARANCE order of both the
    /// groups and the rows within them.
    ///
    /// Stable order matters: `related_items` already returns edges in a
    /// deterministic order, and re-sorting alphabetically here would make the
    /// section's layout depend on edge NAMES rather than on the store's
    /// answer, so an unrelated edge rename would reshuffle the pane.
    public static func groups(_ rows: [RelatedItemRow]) -> [RelatedItemGroup] {
        var order: [String] = []
        var buckets: [String: [RelatedItemRow]] = [:]
        for row in rows {
            if buckets[row.edgeType] == nil {
                order.append(row.edgeType)
                buckets[row.edgeType] = []
            }
            buckets[row.edgeType]?.append(row)
        }
        return order.map { RelatedItemGroup(edgeType: $0, items: buckets[$0] ?? []) }
    }

    /// Humanise a CamelCase edge name for the group heading. Unknown/custom
    /// edge names pass through with the same spacing rule rather than being
    /// mapped through a table that would have to be maintained per edge type.
    public static func displayName(forEdgeType edgeType: String) -> String {
        var out = ""
        var previousWasLower = false
        for character in edgeType {
            if character.isUppercase && previousWasLower { out.append(" ") }
            out.append(character)
            previousWasLower = character.isLowercase || character.isNumber
        }
        return out.isEmpty ? edgeType : out
    }

    /// Icon for a row whose schema the descriptors may or may not claim.
    public static func symbolName(forSchemaRef schemaRef: String) -> String {
        RecordKindIconography.symbolName(forStoreSchemaRef: schemaRef)
    }
}

// MARK: - Reader

/// Off-main edge walk. One actor, one `SharedStore` handle, opened lazily on
/// first use — mirrors `FigureStoreReader` / `CollectionStoreAdapter`, except
/// isolated to an actor instead of the main actor because the whole point is
/// to keep the walk off the main thread.
public actor RelatedItemsReader {

    public static let shared = RelatedItemsReader()

    private nonisolated static let logger = Logger(
        subsystem: "com.imbib.app", category: "related")

    private var store: SharedStore?
    private var didAttemptOpen = false

    private init() {}

    private func handle() -> SharedStore? {
        if didAttemptOpen { return store }
        didAttemptOpen = true
        do {
            try SharedWorkspace.ensureDirectoryExists()
            store = try SharedStore.open(path: SharedWorkspace.databasePath)
        } catch {
            Self.logger.errorCapture(
                "RelatedItemsReader failed to open shared store: \(error)", category: "related")
        }
        return store
    }

    /// Related items for `id`, already projected to display rows.
    ///
    /// Trace points 1 and 2 (request / count returned) live here; the view
    /// logs point 3 (rendered).
    public func load(id: UUID, limit: UInt32 = RelatedItemsModel.defaultLimit) -> [RelatedItemRow] {
        let subject = id.uuidString.lowercased()
        Self.logger.infoCapture(
            "request related items for \(subject) (limit \(limit))", category: "related")
        guard let store = handle() else { return [] }
        do {
            let items = try store.relatedItems(id: subject, limit: limit)
            let rows: [RelatedItemRow] = items.compactMap { item in
                guard let itemID = UUID(uuidString: item.id) else { return nil }
                return RelatedItemRow(
                    id: itemID,
                    schemaRef: item.schemaRef,
                    title: item.title,
                    edgeType: item.edgeType,
                    direction: RelatedDirection(ffi: item.direction)
                )
            }
            Self.logger.infoCapture(
                "returned \(rows.count) related item(s) for \(subject)", category: "related")
            return rows
        } catch {
            Self.logger.errorCapture(
                "relatedItems(\(subject)) failed: \(error)", category: "related")
            return []
        }
    }
}

// MARK: - View

/// The generic Related section. Drop it into any Info tab:
///
/// ```swift
/// RelatedItemsSection(itemID: figureID)
/// ```
///
/// Renders nothing at all when the item has no edges.
public struct RelatedItemsSection: View {

    /// The subject item. Changing it reloads (`.task(id:)`).
    let itemID: UUID
    let limit: UInt32

    private static let logger = Logger(subsystem: "com.imbib.app", category: "related")

    @State private var groups: [RelatedItemGroup] = []

    public init(itemID: UUID, limit: UInt32 = RelatedItemsModel.defaultLimit) {
        self.itemID = itemID
        self.limit = limit
    }

    public var body: some View {
        Group {
            if groups.isEmpty {
                // Hidden entirely — no header, no divider, no reserved space.
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(.secondary)
                        Text("Related")
                            .font(.headline)
                        Spacer(minLength: 0)
                    }
                    ForEach(groups) { group in
                        groupView(group)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: itemID) {
            // Capture before the async hop (CLAUDE.md capture-before-Task):
            // the pane is reused across selection changes, so the id read
            // after the await could belong to a different record.
            let subject = itemID
            let cap = limit
            let rows = await RelatedItemsReader.shared.load(id: subject, limit: cap)
            guard subject == itemID else { return }   // selection moved on
            let grouped = RelatedItemsModel.groups(rows)
            groups = grouped
            // Trace point 3: what the pane actually renders.
            Self.logger.infoCapture(
                "rendered \(rows.count) related item(s) in \(grouped.count) group(s) "
                    + "for \(subject.uuidString.lowercased())",
                category: "related")
        }
    }

    private func groupView(_ group: RelatedItemGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.displayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(group.items) { item in
                rowView(item)
            }
        }
    }

    private func rowView(_ item: RelatedItemRow) -> some View {
        // G5-followup: rows are inert in v1. Opening one needs the registry's
        // open-behavior work (RecordKindDescriptor.defaultOpenBehavior +
        // per-shell overrides + a host that can switch section AND selection);
        // a tap that silently did nothing would be worse than no tap.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.direction.symbolName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(item.direction.accessibilityLabel)
            Image(systemName: item.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.title.isEmpty ? "Untitled" : item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
    }
}
