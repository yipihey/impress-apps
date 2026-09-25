#if os(macOS)
// Chassis file — macOS-only. ADR-0033 work package S7, follow-up 5.2.
//
//  SurfaceRecordListRows.swift
//  PublicationManagerCore
//
//  A surface's `list` rows through the row-style registry.
//
//  S7 rendered `list` with the kit-grade plain `List` — a line of text per
//  row — because a surface's rows are "arbitrary agent JSON" with no mapping
//  to `KindTaggedRow`. Since then two things changed: a `query` source's rows
//  are the store's item envelopes with their payload lifted to the top (see
//  `DefaultExecutor::run_query`), so a row DOES say what kind it is
//  (`schema`), and `LayoutPaneRowMapper` already turns a `SharedItemRow` into
//  the chassis' row for exactly that shape. This file is the bridge between
//  the two: a row that carries a schema the kind manifest claims is rendered
//  by `RecordViewerRegistry.makeListRow` — the same factory the layout panes
//  and the store-search results use — and a row that does not (a verb's
//  output, a hand-written list) keeps the plain line. One list may not mix:
//  if any row is unmappable, the whole list is plain, so a surface never
//  shows two row designs at once.
//
//  Selection is published the same way the plain list publishes it — the
//  ids, sorted — so `on_select` actions see one shape either way.
//

import ImpressLogging
import ImpressMailStyle
import ImpressRustCore
import ImpressSurface
import SwiftUI

struct SurfaceRecordListRows: View {

    let rowsJSON: String
    let onSelect: ([String]) -> Void

    @Environment(\.recordViewerRegistry) private var viewerRegistry
    @State private var selection = Set<String>()
    /// The mapping, memoized by the JSON it came from (PH-L5): it decoded the
    /// rows, re-encoded every payload and decoded it again on every render.
    @State private var mapped: (json: String, rows: [KindTaggedRow]?)?

    private var mappedRows: [KindTaggedRow]? {
        mapped?.json == rowsJSON ? mapped?.rows : Self.map(rowsJSON)
    }

    var body: some View {
        content
            .onAppear { remap() }
            .onChange(of: rowsJSON) { _, _ in remap() }
    }

    private func remap() {
        guard mapped?.json != rowsJSON else { return }
        mapped = (rowsJSON, Self.map(rowsJSON))
    }

    @ViewBuilder
    private var content: some View {
        if let rows = mappedRows, !rows.isEmpty {
            // A stack, not a `List`: the column the surface lays this in is
            // already a ScrollView, and a List inside it either collapses to
            // nothing or scrolls inside a fixed floor — six rows in a 240 pt
            // box (Mac, 2026-09-23). A stack takes the height its rows need
            // and the surface scrolls as one document. Selection is one row
            // (the table's own model; a surface publishes ids, and one at a
            // time is what `on_select` → `publish` means for a detail pane).
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                        .contentShape(Rectangle())
                        .background(
                            selection.contains(row.id.uuidString)
                                ? Color.accentColor.opacity(0.18) : Color.clear)
                        .onTapGesture { select(row) }
                    Divider()
                }
            }
        } else {
            SurfaceHooks.plain.renderListRows(rowsJSON, onSelect)
        }
    }

    private func select(_ row: KindTaggedRow) {
        let id = row.id.uuidString
        selection = [id]
        onSelect([id])
    }

    @ViewBuilder
    private func rowView(_ row: KindTaggedRow) -> some View {
        if let factory = viewerRegistry[row.kind] {
            factory.makeListRow(row)
        } else {
            MailStyleRow(item: row)
        }
    }

    /// Every row as the chassis' row, or nil when any row cannot be — see
    /// the file header for why a list does not mix.
    @MainActor
    static func map(_ rowsJSON: String) -> [KindTaggedRow]? {
        guard let array = (try? LayoutJSONValue.decode(rowsJSON))?.arrayValue else {
            return nil
        }
        var rows: [KindTaggedRow] = []
        var undated = 0
        for item in array {
            guard let object = item.objectValue,
                let schema = object["schema"]?.stringValue,
                LayoutPaneRowMapper.layoutKind(forSchemaRef: schema) != nil,
                let shared = sharedItemRow(object, schema: schema, undated: &undated),
                let mapped = LayoutPaneRowMapper.kindTaggedRow(shared)
            else { return nil }
            rows.append(mapped)
        }
        if undated > 0 {
            // The mail-style row has no "no date" (its date is not optional),
            // so an undated row still shows one — say which, once per list.
            logInfo(
                "surface list: \(undated) of \(rows.count) row(s) carry no modified or created date — "
                    + "their date column shows when they were read, not a date of theirs",
                category: "surface")
        }
        return rows
    }

    /// The envelope columns `LayoutPaneRowMapper` reads, recovered from the
    /// flattened row. Anything absent takes the value a fresh item has.
    private static func sharedItemRow(
        _ object: [String: LayoutJSONValue], schema: String, undated: inout Int
    ) -> SharedItemRow? {
        guard let id = object["id"]?.stringValue else { return nil }
        let payload = LayoutJSONValue.object(object)
        guard let payloadJSON = try? payload.jsonString() else { return nil }
        let flag = object["flag"]?.objectValue?["color"]?.stringValue
            ?? object["flag"]?.stringValue
        let created = millis(object["created"])
        let modified = millis(object["modified"])
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if created == nil && modified == nil { undated += 1 }
        return SharedItemRow(
            id: id,
            schemaRef: schema,
            payloadJson: payloadJSON,
            createdMs: created ?? modified ?? now,
            modifiedMs: modified ?? created ?? now,
            parentId: object["parent"]?.stringValue,
            isRead: object["is_read"]?.boolValue ?? true,
            isStarred: object["is_starred"]?.boolValue ?? false,
            tags: object["tags"]?.stringArrayValue ?? [],
            flagColor: flag)
    }

    /// A row's ISO-8601 date in milliseconds, or nil when it has none —
    /// never "now", which dated every such row today (PH-L5).
    private static func millis(_ value: LayoutJSONValue?) -> Int64? {
        guard let text = value?.stringValue,
            let date = ISO8601DateFormatter.withFractionalSeconds.date(from: text)
                ?? ISO8601DateFormatter.plain.date(from: text)
        else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}

extension ISO8601DateFormatter {
    /// Allocated once each, not twice per row per render.
    fileprivate static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    fileprivate static let plain = ISO8601DateFormatter()
}
#endif
