// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): pure row CONSTRUCTION
// (Foundation + ImpressRustCore). No store handle, no I/O.
//
//  FigureStoreWriter.swift
//  PublicationManagerCore
//
//  ADR-0022 D9 finding 1, closed for the figure kind. See
//  `MailStoreWriter.swift`'s header for the full argument; the short version is
//  that `FigureStoreReader` shipped a `FigurePayload` decoder and no encoder, so
//  a host that needed to WRITE a figure row (impress's UI-test seed) re-typed
//  `title` / `caption` / `format` / `data_hash` as literals and nothing
//  compared the two lists.
//
//  The real figure writer is implore's and stays implore's. This builds rows;
//  it does not own figures.
//

import Foundation
import ImpressRustCore

/// Builds `figure` rows whose payload field names come from
/// `FigureStoreReader`'s own `FigurePayload` decoder.
public enum FigureStoreWriter {

    /// Re-exported from the reader, so one symbol names both halves.
    public static var figureSchemaRef: String { FigureStoreReader.figureSchemaRef }

    /// A `figure` row.
    ///
    /// `dataHash` is the sha256 of the CAS artifact under
    /// `FigureStoreReader.contentStoreDirectory` — the View tab decodes
    /// whatever is filed there. A figure with no raster preview (SVG, a script
    /// that has not run) legitimately omits it, which is why it is optional and
    /// why omitting it must not write a `null`.
    nonisolated public static func figureRow(
        id: String,
        folderID: String? = nil,
        title: String?,
        caption: String? = nil,
        format: String?,
        dataHash: String? = nil,
        scriptHash: String? = nil,
        createdMs: Int64? = nil,
        isStarred: Bool? = nil
    ) -> SharedItemUpsert {
        var payload = FigurePayload()
        payload.title = title
        payload.caption = caption
        payload.format = format
        payload.dataHash = dataHash
        payload.scriptHash = scriptHash
        return ChassisPayloadRow.upsert(
            id: id, schemaRef: figureSchemaRef, parentID: folderID,
            payload: payload, createdMs: createdMs, isStarred: isStarred)
    }
}
