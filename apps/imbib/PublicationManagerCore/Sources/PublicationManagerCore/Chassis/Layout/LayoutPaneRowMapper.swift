#if os(macOS)
// Chassis file — macOS-only. ADR-0031 work package L6.
//
//  LayoutPaneRowMapper.swift
//  PublicationManagerCore
//
//  One store row, as the chassis' own list row.
//
//  L6 shipped the `list` and `outline` panes with a hand-written two-line row
//  — a title and an author string, no read state, no flag, no tags, no
//  attachment marker, no date column. It rendered, which was the L6 bar, but
//  it threw away imbib's list: the mail-style chrome every other surface in
//  the suite shows (`MailStyleRow`, `ImpressMailStyle`), including the one the
//  user sees three inches away in the flagged-off build.
//
//  Nothing here is new chrome. `KindTaggedRow` is the chassis' existing
//  MailStyleItem-shaped row and `RecordViewerRegistry.makeListRow` is the
//  existing per-kind row factory; the store-search surface already builds one
//  this way (`StoreSearchSurface.kindTaggedRow`). This file is the missing
//  MAPPING for a pane row: `SharedItemRow` → `KindTaggedRow`, with the
//  per-kind payload decode that makes a publication row read like a
//  publication.
//
//  WHAT COMES FROM THE ENVELOPE, NOT THE PAYLOAD. `is_read`, `is_starred`,
//  `tags` and `flag_color` are envelope columns on every kind, so the dot, the
//  star, the tag chips and the flag colour work for a kind this file has never
//  heard of. That is the whole reason the pane can show them at all: the
//  layout query returns `SharedItemRow`, not a per-kind struct.
//
//  WHAT IS DELIBERATELY NOT RECOVERED HERE: the tag COLOURS. A tag's colour
//  lives on the tag vocabulary row, not on the item, and resolving it per row
//  is the per-node store query the sidebar ratchet test exists to forbid
//  (apps/imbib/CLAUDE.md, "Sidebar tree builders take snapshot data"). The
//  chips render in the theme's default colour until a pane-scoped tag snapshot
//  exists, which is an L8 question.
//

import Foundation
import ImpressFTUI
import ImpressLogging
import ImpressRustCore

enum LayoutPaneRowMapper {

    // MARK: The layout's OWN kind vocabulary

    /// `impress_core::pane_query::KindManifest`, as Swift reads it: schema ref
    /// → the `RecordKindId` a pane query and a `select` verb spell.
    ///
    /// This is NOT `RecordKindID`. The chassis descriptors are namespaced
    /// (`imbib/library`); the layout's ids are the manifest's short names
    /// (`library`), and a pane's parameter declares one of THOSE. Publishing a
    /// chassis id put `imbib/library` on the channel, the list pane's
    /// `library` parameter never bound, and the list sat on "Nothing Here"
    /// with a row visibly selected — one string apart, no error anywhere.
    ///
    /// Read once from the FFI so there is no second copy of the table to
    /// disagree with Rust's.
    @MainActor
    private static let kindBySchemaRef: [String: String] = {
        guard let object = try? LayoutJSONValue.decode(kindManifestJson()),
            let kinds = object["kinds"]?.objectValue
        else {
            logError(
                "layout kind manifest did not decode — panes will publish their query's "
                    + "first kind, so a mixed-kind navigator cannot bind a parameter",
                category: "layout")
            return [:]
        }
        var table: [String: String] = [:]
        for (kind, refs) in kinds {
            for ref in refs.stringArrayValue {
                table[ref] = kind
                // A versioned ref (`task@1.0.0`) is also matched unversioned,
                // the same tolerance `SchemaRefKindLookup` gives the chassis.
                table[RecordKindSchemaRef.baseName(ref)] = kind
            }
        }
        return table
    }()

    /// The layout kind id for a store row's schema ref, or nil when the
    /// manifest does not claim it (the caller then keeps the pane's default).
    @MainActor
    static func layoutKind(forSchemaRef ref: String) -> String? {
        kindBySchemaRef[ref] ?? kindBySchemaRef[RecordKindSchemaRef.baseName(ref)]
    }

    /// One pane row, ready for `RecordViewerRegistry.makeListRow`.
    ///
    /// Returns nil only for a row whose id is not a UUID — the same rule the
    /// store-search surface uses, and the same reason: a row the chassis
    /// cannot identify cannot be selected, and a row that cannot be selected
    /// in a list that publishes selection is worse than absent.
    @MainActor
    static func kindTaggedRow(_ row: SharedItemRow) -> KindTaggedRow? {
        guard let id = UUID(uuidString: row.id) else { return nil }

        let kind = BuiltinRecordKinds.registry.kind(forStoreSchemaRef: row.schemaRef)
            ?? RecordKindID(RecordKindSchemaRef.baseName(row.schemaRef))
        let payload = (try? LayoutJSONValue.decode(row.payloadJson))?.objectValue ?? [:]
        let fields = PayloadFields(payload)

        // The header is the row's LEFT-HAND identity — authors for a paper,
        // the kind's display name for anything without them, exactly as the
        // mail-style row reads in the flagged-off build.
        let authors = fields.authorString
        let title = fields.firstNonEmpty("title", "name", "subject", "label", "path")

        return KindTaggedRow(
            id: id,
            kind: kind,
            headerText: authors ?? displayName(for: kind),
            titleText: title ?? row.id,
            subtitleText: fields.firstNonEmpty("venue", "journal", "publisher", "source"),
            previewText: fields.snippet,
            yearText: fields.year,
            date: Date(timeIntervalSince1970: Double(row.modifiedMs) / 1000),
            isRead: row.isRead,
            isStarred: row.isStarred,
            hasAttachment: fields.bool("has_pdf_downloaded") || fields.bool("has_attachments"),
            flag: flag(from: row.flagColor),
            tagDisplays: row.tags.map(tagDisplay))
    }

    /// `SharedItemRow.flag_color` is the envelope's own spelling — the same
    /// four names `FlagColor` has. An unknown colour is NOT a flag: inventing
    /// one would paint a stripe the user cannot clear.
    private static func flag(from color: String?) -> PublicationFlag? {
        guard let color, let parsed = FlagColor(rawValue: color.lowercased()) else { return nil }
        return .simple(parsed)
    }

    /// A tag path as a chip. The id is derived from the path so the same tag
    /// is the same chip across rows and reloads (`TagDisplayData` is
    /// Identifiable and the list diffs on it).
    private static func tagDisplay(_ path: String) -> TagDisplayData {
        TagDisplayData(
            id: UUID(uuidString: path) ?? deterministicID(for: path),
            path: path,
            leaf: path.split(separator: "/").last.map(String.init) ?? path)
    }

    /// A stable UUID for a tag path, without a store lookup.
    private static func deterministicID(for path: String) -> UUID {
        var hasher = Hasher()
        hasher.combine(path)
        let value = UInt64(bitPattern: Int64(hasher.finalize()))
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8((value >> (8 * UInt64(index))) & 0xFF)
            bytes[index + 8] = bytes[index]
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    @MainActor
    private static func displayName(for kind: RecordKindID) -> String {
        BuiltinRecordKinds.registry[kind]?.displayName ?? kind.rawValue.capitalized
    }
}

// MARK: - Payload reading

/// The handful of payload reads a row needs, in one place so each one has a
/// single spelling. Every key here is optional by construction: a pane query
/// can return any kind, and a missing field is a row that shows less, never a
/// row that fails.
private struct PayloadFields {

    private let payload: [String: LayoutJSONValue]

    init(_ payload: [String: LayoutJSONValue]) {
        self.payload = payload
    }

    func firstNonEmpty(_ keys: String...) -> String? {
        for key in keys {
            if let value = payload[key]?.stringValue,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return value
            }
        }
        return nil
    }

    func bool(_ key: String) -> Bool {
        payload[key]?.boolValue ?? false
    }

    /// The author line.
    ///
    /// imbib's own rows spell it `author_text` — the BibTeX author string,
    /// already in the "Last, First; Last, First" form the list shows — with
    /// `authors_json` beside it as the parsed array. The schema's `authors`
    /// string array and a bare `author` cover kinds that are not imbib's.
    /// Reading only the last two is what made every pane row say
    /// "Publication" where the flagged-off list says the authors.
    var authorString: String? {
        if let text = firstNonEmpty("author_text") { return text }
        if let list = payload["authors"]?.arrayValue ?? decodedArray("authors_json") {
            let names = list.compactMap(\.stringValue).filter { !$0.isEmpty }
            if !names.isEmpty { return names.joined(separator: "; ") }
        }
        return firstNonEmpty("authors", "author")
    }

    /// A payload field that holds JSON in a STRING (imbib stores the parsed
    /// author list that way).
    private func decodedArray(_ key: String) -> [LayoutJSONValue]? {
        guard let raw = payload[key]?.stringValue,
            let value = try? LayoutJSONValue.decode(raw)
        else { return nil }
        return value.arrayValue
    }

    var year: String? {
        if let value = payload["year"]?.intValue, value > 0 { return String(value) }
        return firstNonEmpty("year")
    }

    /// The preview line. The abstract is what a paper has; `snippet` and
    /// `body` cover the kinds that do not.
    var snippet: String? {
        guard
            let text = firstNonEmpty(
                "abstract_text", "abstract", "snippet", "summary", "body", "note")
        else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
