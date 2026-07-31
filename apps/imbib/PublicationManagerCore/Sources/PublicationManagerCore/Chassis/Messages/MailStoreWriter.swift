// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): pure row CONSTRUCTION
// (Foundation + ImpressRustCore). It performs no I/O and holds no store handle,
// so there is nothing here to gate.
//
//  MailStoreWriter.swift
//  PublicationManagerCore
//
//  ADR-0022 D9 finding 1, closed — the half of it that belongs to the chassis.
//
//  THE FINDING. `MailStoreReader`, `FigureStoreReader` and `AgentStoreReader`
//  ship with no `*StoreWriter` beside them, because every real writer in the
//  suite lives in an owning app's CORE: `ImpartStoreAdapter` in
//  MessageManagerCore writes mail, implore writes figures, impel's
//  `TaskStoreApi` writes tasks. That is correct and is not changing — a chassis
//  that could write mail would be a chassis that had opinions about IMAP.
//
//  What was NOT correct is the consequence: a host with no writer had no
//  vocabulary either, so impress's UI-test seed hand-built its payloads and
//  every field name in it — `subject`, `remote_path`, `sort_order`, … — was a
//  SECOND SPELLING of `MailMessagePayload.CodingKeys`. Nothing compared the two.
//  A rename on the reader side would have left the seed writing keys nothing
//  reads, and the failure mode is the one schema-refs.json exists for: the list
//  renders empty, which looks exactly like "no data yet".
//
//  THE FIX, and its deliberate smallness. This is a ROW BUILDER, not a store
//  writer: every function is `nonisolated static`, takes typed parameters and
//  returns a `SharedItemUpsert` the caller feeds to its own `SharedStore`
//  handle. It opens nothing, mutates nothing and posts no `StoreEvent`. The
//  chassis's read-only scope discipline (see this reader's header) is intact —
//  what it gains is a place where the field NAMES are spelled once.
//
//  And they are spelled once by CONSTRUCTION, not by agreement: each builder
//  encodes the reader's OWN payload struct. There is no key list in this file to
//  keep in step. Rename `MailMessagePayload.CodingKeys.threadID`'s raw value and
//  the writer emits the new name in the same compile.
//
//  WHO USES IT. Test seeds and fixtures — impress's `ImpressIOSUITestSeed`
//  today. impart's seed does NOT and should not: it already builds through
//  `ImpartStoreAdapter`'s production row builders, which is strictly better
//  (deterministic UUIDv5 ids, the Mac mirror's exact byte shape). A seed that
//  can reach its kind's real writer should; this exists for the three kinds
//  where the chassis is the only thing a host can reach.
//

import Foundation
import ImpressRustCore

/// Builds `mail-account` / `mail-folder` / `email-message` rows whose payload
/// field names come from `MailStoreReader`'s own decoders.
///
/// See the file header for why this is a builder rather than a writer.
public enum MailStoreWriter {

    // MARK: - Schema refs
    //
    // Re-exported from the reader rather than re-declared, so a caller names one
    // symbol for both halves of the round trip.

    public static var accountSchemaRef: String { MailStoreReader.accountSchemaRef }
    public static var folderSchemaRef: String { MailStoreReader.folderSchemaRef }
    public static var messageSchemaRef: String { MailStoreReader.messageSchemaRef }

    // MARK: - Rows

    /// A `mail-account` row. `sortOrder` is what `fetchAccounts()` sorts on.
    nonisolated public static func accountRow(
        id: String,
        name: String?,
        address: String?,
        provider: String? = nil,
        sortOrder: Int? = nil,
        createdMs: Int64? = nil
    ) -> SharedItemUpsert {
        var payload = MailAccountPayload()
        payload.name = name
        payload.address = address
        payload.provider = provider
        payload.sortOrder = sortOrder
        return ChassisPayloadRow.upsert(
            id: id, schemaRef: accountSchemaRef, parentID: nil,
            payload: payload, createdMs: createdMs)
    }

    /// A `mail-folder` row, parented to its account row.
    ///
    /// `role` is load-bearing rather than decorative: `MessageListScope
    /// .allInboxes` fans out over INBOX-ROLE folders, so a folder seeded
    /// without `role: "inbox"` is invisible to the scope `.all(.message)` maps
    /// to. Declared here so the parameter list says it.
    nonisolated public static func folderRow(
        id: String,
        accountID: String?,
        name: String?,
        role: String?,
        remotePath: String? = nil,
        sortOrder: Int? = nil,
        createdMs: Int64? = nil
    ) -> SharedItemUpsert {
        var payload = MailFolderPayload()
        payload.name = name
        payload.role = role
        payload.remotePath = remotePath
        payload.sortOrder = sortOrder
        return ChassisPayloadRow.upsert(
            id: id, schemaRef: folderSchemaRef, parentID: accountID,
            payload: payload, createdMs: createdMs)
    }

    /// An `email-message` row, parented to its folder row.
    ///
    /// `isRead` / `isStarred` are ENVELOPE facts and travel on the upsert, not
    /// in the payload — the chassis reads them off `SharedItemRow`, never out of
    /// JSON. Flags and tags are envelope facts too, but have no upsert field:
    /// set them with `SharedStore.setFlag` / `addTag` after writing the row.
    nonisolated public static func messageRow(
        id: String,
        folderID: String?,
        subject: String?,
        body: String?,
        from: String?,
        to: [String]? = nil,
        cc: [String]? = nil,
        messageID: String? = nil,
        threadID: String? = nil,
        createdMs: Int64? = nil,
        isRead: Bool? = nil,
        isStarred: Bool? = nil
    ) -> SharedItemUpsert {
        var payload = MailMessagePayload()
        payload.subject = subject
        payload.body = body
        payload.from = from
        payload.to = to
        payload.cc = cc
        payload.messageID = messageID
        payload.threadID = threadID
        return ChassisPayloadRow.upsert(
            id: id, schemaRef: messageSchemaRef, parentID: folderID,
            payload: payload, createdMs: createdMs,
            isRead: isRead, isStarred: isStarred)
    }
}
