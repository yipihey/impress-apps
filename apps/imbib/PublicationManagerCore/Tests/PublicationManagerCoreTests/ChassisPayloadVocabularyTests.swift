//
//  ChassisPayloadVocabularyTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0022 D9 finding 1: the chassis had a READER half and no writer half, so
//  every host that needed to write a mail/figure/task row spelled the payload
//  field names a second time and nothing compared the two spellings. The
//  failure mode is the one `schema-refs.json` exists for and is worse here,
//  because a field name has no manifest: a writer that emits `messageId` where
//  the reader decodes `message_id` produces rows that decode to a payload with
//  every field nil. The list renders — it just renders blank rows, which reads
//  as "the data is bad" rather than "the code disagrees with itself".
//
//  THREE-WAY PIN. Each kind is checked on three axes, and it takes all three:
//
//   1. READER == WRITER. Encode a FULLY-POPULATED payload through the writer
//      and compare the emitted JSON keys against the reader decoder's
//      `CodingKeys.allCases`. Catches a writer that drops a field from its
//      parameter list, or forgets to assign one it accepted.
//   2. READER == FROZEN. Compare `CodingKeys.allCases` against a literal list
//      written out here. Catches a rename that moved BOTH sides in step — which
//      is a store-compatibility break (existing rows carry the old key) that
//      axis 1 by construction cannot see.
//   3. ROUND TRIP. Encode through the writer, decode through the reader, and
//      assert every value survives. Catches a key that matches but a type that
//      does not.
//
//  Axis 2 is the one that will fail on a legitimate schema change, and that is
//  the point: it fails in one place with the old and new spelling side by side,
//  where a migration decision can be made, rather than silently at runtime.
//

import Foundation
import ImpressRustCore
import XCTest

@testable import PublicationManagerCore

// `@MainActor` because the readers are: their schema-ref constants are static
// members of `@MainActor` classes, and axis 1 of the pin reads them.
@MainActor
final class ChassisPayloadVocabularyTests: XCTestCase {

    // MARK: - Helper

    /// The payload JSON keys a writer-built row actually carries.
    private func payloadKeys(of row: SharedItemUpsert) throws -> Set<String> {
        let data = try XCTUnwrap(row.payloadJson.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        return Set(dictionary.keys)
    }

    private func readerKeys<K: CodingKey & CaseIterable>(_ type: K.Type) -> Set<String> {
        Set(K.allCases.map(\.stringValue))
    }

    // MARK: - Mail: account

    func testMailAccountReaderKeysEqualWriterKeys() throws {
        let row = MailStoreWriter.accountRow(
            id: "11111111-1111-4111-8111-111111111111",
            name: "Ada Lovelace", address: "ada@analyticalengine.org",
            provider: "imap", sortOrder: 0)
        XCTAssertEqual(
            try payloadKeys(of: row),
            readerKeys(MailAccountPayload.CodingKeys.self),
            "MailStoreWriter.accountRow must emit exactly MailAccountPayload's keys")
    }

    func testMailAccountVocabularyIsFrozen() {
        XCTAssertEqual(
            readerKeys(MailAccountPayload.CodingKeys.self),
            ["name", "address", "provider", "sort_order"])
    }

    // MARK: - Mail: folder

    func testMailFolderReaderKeysEqualWriterKeys() throws {
        let row = MailStoreWriter.folderRow(
            id: "22222222-2222-4222-8222-222222222222",
            accountID: "11111111-1111-4111-8111-111111111111",
            name: "INBOX", role: "inbox", remotePath: "INBOX", sortOrder: 0)
        XCTAssertEqual(
            try payloadKeys(of: row),
            readerKeys(MailFolderPayload.CodingKeys.self),
            "MailStoreWriter.folderRow must emit exactly MailFolderPayload's keys")
    }

    func testMailFolderVocabularyIsFrozen() {
        XCTAssertEqual(
            readerKeys(MailFolderPayload.CodingKeys.self),
            ["name", "role", "remote_path", "sort_order"])
    }

    // MARK: - Mail: message

    func testMailMessageReaderKeysEqualWriterKeys() throws {
        let row = MailStoreWriter.messageRow(
            id: "33333333-3333-4333-8333-333333333331",
            folderID: "22222222-2222-4222-8222-222222222222",
            subject: "Note G, revised", body: "Eight terms.",
            from: "ada@analyticalengine.org", to: ["charles@analyticalengine.org"],
            cc: ["luigi@analyticalengine.org"], messageID: "<a@b>", threadID: "t-1")
        XCTAssertEqual(
            try payloadKeys(of: row),
            readerKeys(MailMessagePayload.CodingKeys.self),
            "MailStoreWriter.messageRow must emit exactly MailMessagePayload's keys")
    }

    func testMailMessageVocabularyIsFrozen() {
        XCTAssertEqual(
            readerKeys(MailMessagePayload.CodingKeys.self),
            ["subject", "body", "from", "to", "cc", "message_id", "thread_id"])
    }

    /// The `thread_id` field name is used TWICE in the reader — once to decode
    /// and once as a `SharedFieldEq` in `fetchThread`. A `payloadEq` that
    /// disagrees with the decoder matches zero rows forever.
    func testThreadQueryUsesTheDecodersOwnFieldName() {
        XCTAssertEqual(MailMessagePayload.CodingKeys.threadID.rawValue, "thread_id")
    }

    // MARK: - Figures

    func testFigureReaderKeysEqualWriterKeys() throws {
        let row = FigureStoreWriter.figureRow(
            id: "44444444-4444-4444-8444-444444444441",
            title: "Bernoulli convergence", caption: "Eight terms.",
            format: "png", dataHash: "abc", scriptHash: "def")
        XCTAssertEqual(
            try payloadKeys(of: row),
            readerKeys(FigurePayload.CodingKeys.self),
            "FigureStoreWriter.figureRow must emit exactly FigurePayload's keys")
    }

    func testFigureVocabularyIsFrozen() {
        XCTAssertEqual(
            readerKeys(FigurePayload.CodingKeys.self),
            ["format", "title", "caption", "data_hash", "script_hash"])
    }

    // MARK: - Agents

    func testTaskReaderKeysEqualWriterKeys() throws {
        let row = AgentStoreWriter.taskRow(
            id: "55555555-5555-4555-8555-555555555551",
            title: "Recompute the Bernoulli table", state: "queued",
            description: "Revised eighth term.", assignedTo: "counsel")
        XCTAssertEqual(
            try payloadKeys(of: row),
            readerKeys(AgentTaskPayload.CodingKeys.self),
            "AgentStoreWriter.taskRow must emit exactly AgentTaskPayload's keys")
    }

    func testTaskVocabularyIsFrozen() {
        XCTAssertEqual(
            readerKeys(AgentTaskPayload.CodingKeys.self),
            ["title", "state", "description", "assigned_to"])
    }

    func testAgentRunReaderKeysEqualWriterKeys() throws {
        let row = AgentStoreWriter.agentRunRow(
            id: "66666666-6666-4666-8666-666666666661",
            agentID: "counsel", model: "opus", promptHash: "abc",
            resultSummary: "done", tokenCount: 12, durationMs: 34)
        XCTAssertEqual(
            try payloadKeys(of: row),
            readerKeys(AgentRunPayload.CodingKeys.self),
            "AgentStoreWriter.agentRunRow must emit exactly AgentRunPayload's keys")
    }

    func testAgentRunVocabularyIsFrozen() {
        XCTAssertEqual(
            readerKeys(AgentRunPayload.CodingKeys.self),
            ["model", "agent_id", "prompt_hash", "result_summary",
             "token_count", "duration_ms"])
    }

    /// The task lifecycle field the reader QUERIES on is the decoder's own key
    /// and the descriptor's declared `payloadField` — three spellings that must
    /// be one.
    func testTaskStateFieldAgreesWithTheDescriptorLifecycle() {
        XCTAssertEqual(AgentTaskPayload.CodingKeys.state.rawValue, "state")
        XCTAssertEqual(
            TaskRecordKind.descriptor.lifecycle?.payloadField,
            AgentTaskPayload.CodingKeys.state.rawValue)
    }

    // MARK: - Round trips (axis 3)

    func testMailMessageRoundTripsThroughTheReadersDecoder() throws {
        let row = MailStoreWriter.messageRow(
            id: "33333333-3333-4333-8333-333333333331",
            folderID: "22222222-2222-4222-8222-222222222222",
            subject: "Note G, revised", body: "Eight terms.",
            from: "ada@analyticalengine.org", to: ["charles@analyticalengine.org"],
            cc: ["luigi@analyticalengine.org"], messageID: "<a@b>", threadID: "t-1")
        let data = try XCTUnwrap(row.payloadJson.data(using: .utf8))
        let decoded = try JSONDecoder().decode(MailMessagePayload.self, from: data)

        XCTAssertEqual(decoded.subject, "Note G, revised")
        XCTAssertEqual(decoded.body, "Eight terms.")
        XCTAssertEqual(decoded.from, "ada@analyticalengine.org")
        XCTAssertEqual(decoded.to, ["charles@analyticalengine.org"])
        XCTAssertEqual(decoded.cc, ["luigi@analyticalengine.org"])
        XCTAssertEqual(decoded.messageID, "<a@b>")
        XCTAssertEqual(decoded.threadID, "t-1")
    }

    func testFigureRoundTripsThroughTheReadersDecoder() throws {
        let row = FigureStoreWriter.figureRow(
            id: "44444444-4444-4444-8444-444444444441",
            title: "Bernoulli convergence", caption: "Eight terms.",
            format: "png", dataHash: "abc", scriptHash: "def")
        let data = try XCTUnwrap(row.payloadJson.data(using: .utf8))
        let decoded = try JSONDecoder().decode(FigurePayload.self, from: data)

        XCTAssertEqual(decoded.title, "Bernoulli convergence")
        XCTAssertEqual(decoded.caption, "Eight terms.")
        XCTAssertEqual(decoded.format, "png")
        XCTAssertEqual(decoded.dataHash, "abc")
        XCTAssertEqual(decoded.scriptHash, "def")
    }

    func testTaskRoundTripsThroughTheReadersDecoder() throws {
        let row = AgentStoreWriter.taskRow(
            id: "55555555-5555-4555-8555-555555555551",
            title: "Recompute the Bernoulli table", state: "queued",
            description: "Revised eighth term.", assignedTo: "counsel")
        let data = try XCTUnwrap(row.payloadJson.data(using: .utf8))
        let decoded = try JSONDecoder().decode(AgentTaskPayload.self, from: data)

        XCTAssertEqual(decoded.title, "Recompute the Bernoulli table")
        XCTAssertEqual(decoded.state, "queued")
        XCTAssertEqual(decoded.description, "Revised eighth term.")
        XCTAssertEqual(decoded.assignedTo, "counsel")
    }

    func testAgentRunRoundTripsThroughTheReadersDecoder() throws {
        let row = AgentStoreWriter.agentRunRow(
            id: "66666666-6666-4666-8666-666666666661",
            agentID: "counsel", model: "opus", promptHash: "abc",
            resultSummary: "done", tokenCount: 12, durationMs: 34)
        let data = try XCTUnwrap(row.payloadJson.data(using: .utf8))
        let decoded = try JSONDecoder().decode(AgentRunPayload.self, from: data)

        XCTAssertEqual(decoded.agentID, "counsel")
        XCTAssertEqual(decoded.model, "opus")
        XCTAssertEqual(decoded.promptHash, "abc")
        XCTAssertEqual(decoded.resultSummary, "done")
        XCTAssertEqual(decoded.tokenCount, 12)
        XCTAssertEqual(decoded.durationMs, 34)
    }

    // MARK: - Envelope rules

    /// Rule 1 of `ChassisPayloadRow`: ids are lowercased at the boundary. The
    /// store's canonical id form is lowercase and payload refs are matched by
    /// string equality, while Swift's `UUID().uuidString` is uppercase.
    func testWriterLowercasesIDsAtTheBoundary() {
        let row = MailStoreWriter.messageRow(
            id: "33333333-3333-4333-8333-33333333333A",
            folderID: "22222222-2222-4222-8222-22222222222B",
            subject: "s", body: "b", from: "f")
        XCTAssertEqual(row.id, "33333333-3333-4333-8333-33333333333a")
        XCTAssertEqual(row.parentId, "22222222-2222-4222-8222-22222222222b")
    }

    /// Rule 2: a nil field is OMITTED, never written as `null`. The readers
    /// decode defensively for rows that simply lack a key; a literal `null` is
    /// a different claim and one no production writer makes.
    func testWriterOmitsNilFieldsRatherThanWritingNull() throws {
        let row = FigureStoreWriter.figureRow(
            id: "44444444-4444-4444-8444-444444444442",
            title: "Engine timing (SVG)", format: "svg")
        XCTAssertFalse(row.payloadJson.contains("null"))
        XCTAssertEqual(try payloadKeys(of: row), ["title", "format"])
    }

    // MARK: - Schema refs

    /// The writers must not introduce a SECOND spelling of a ref — every one is
    /// re-exported from the reader that queries with it.
    func testWriterSchemaRefsAreTheReadersOwn() {
        XCTAssertEqual(MailStoreWriter.accountSchemaRef, MailStoreReader.accountSchemaRef)
        XCTAssertEqual(MailStoreWriter.folderSchemaRef, MailStoreReader.folderSchemaRef)
        XCTAssertEqual(MailStoreWriter.messageSchemaRef, MailStoreReader.messageSchemaRef)
        XCTAssertEqual(FigureStoreWriter.figureSchemaRef, FigureStoreReader.figureSchemaRef)
        XCTAssertEqual(AgentStoreWriter.taskSchemaRef, AgentStoreReader.taskSchema)
        XCTAssertEqual(AgentStoreWriter.agentRunSchemaRef, AgentStoreReader.agentRunSchema)
    }

    /// …and the refs the readers now name are the DESCRIPTORS' where a
    /// descriptor exists. `mail-account` / `mail-folder` have none — they are
    /// the message kind's containers, not presented records — which is exactly
    /// why they needed a named constant instead.
    func testReaderSchemaRefsComeFromDescriptorsWhereOneExists() {
        XCTAssertEqual(
            MailStoreReader.messageSchemaRef,
            MessageRecordKind.descriptor.primarySchemaRef)
        XCTAssertEqual(
            FigureStoreReader.figureSchemaRef,
            FigureRecordKind.descriptor.primarySchemaRef)
        XCTAssertEqual(MailStoreReader.accountSchemaRef, "mail-account")
        XCTAssertEqual(MailStoreReader.folderSchemaRef, "mail-folder")
    }
}
