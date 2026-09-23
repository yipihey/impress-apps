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

import ImpressMailStyle
import ImpressRustCore
import ImpressSurface
import SwiftUI

struct SurfaceRecordListRows: View {

    let rowsJSON: String
    let onSelect: ([String]) -> Void

    @Environment(\.recordViewerRegistry) private var viewerRegistry
    @State private var selection = Set<String>()

    var body: some View {
        if let rows = mappedRows, !rows.isEmpty {
            List(rows, selection: $selection) { row in
                rowView(row).tag(row.id.uuidString)
            }
            .listStyle(.inset)
            .onChange(of: selection) { _, newValue in
                onSelect(Array(newValue).sorted())
            }
        } else {
            SurfaceHooks.plain.renderListRows(rowsJSON, onSelect)
        }
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
    private var mappedRows: [KindTaggedRow]? {
        guard let array = (try? LayoutJSONValue.decode(rowsJSON))?.arrayValue else {
            return nil
        }
        var rows: [KindTaggedRow] = []
        for item in array {
            guard let object = item.objectValue,
                let schema = object["schema"]?.stringValue,
                LayoutPaneRowMapper.layoutKind(forSchemaRef: schema) != nil,
                let shared = Self.sharedItemRow(object, schema: schema),
                let mapped = LayoutPaneRowMapper.kindTaggedRow(shared)
            else { return nil }
            rows.append(mapped)
        }
        return rows
    }

    /// The envelope columns `LayoutPaneRowMapper` reads, recovered from the
    /// flattened row. Anything absent takes the value a fresh item has.
    private static func sharedItemRow(
        _ object: [String: LayoutJSONValue], schema: String
    ) -> SharedItemRow? {
        guard let id = object["id"]?.stringValue else { return nil }
        let payload = LayoutJSONValue.object(object)
        guard let payloadJSON = try? payload.jsonString() else { return nil }
        let flag = object["flag"]?.objectValue?["color"]?.stringValue
            ?? object["flag"]?.stringValue
        return SharedItemRow(
            id: id,
            schemaRef: schema,
            payloadJson: payloadJSON,
            createdMs: millis(object["created"]),
            modifiedMs: millis(object["modified"]),
            parentId: object["parent"]?.stringValue,
            isRead: object["is_read"]?.boolValue ?? true,
            isStarred: object["is_starred"]?.boolValue ?? false,
            tags: object["tags"]?.stringArrayValue ?? [],
            flagColor: flag)
    }

    private static func millis(_ value: LayoutJSONValue?) -> Int64 {
        guard let text = value?.stringValue,
            let date = ISO8601DateFormatter.withFractionalSeconds.date(from: text)
                ?? ISO8601DateFormatter().date(from: text)
        else { return Int64(Date().timeIntervalSince1970 * 1000) }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}

extension ISO8601DateFormatter {
    fileprivate static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
#endif
