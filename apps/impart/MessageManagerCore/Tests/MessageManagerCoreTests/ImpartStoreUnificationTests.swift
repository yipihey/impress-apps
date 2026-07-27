//
//  ImpartStoreUnificationTests.swift
//  MessageManagerCoreTests
//
//  Stage 0 WP3: deterministic-ID derivation and the unified-store
//  round trip (adapter mapping → upsertItems → ImpartImpressStore reads).
//

import Foundation
import Testing
@testable import MessageManagerCore
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - Deterministic ID Tests

@Suite("Deterministic IDs")
struct DeterministicIDTests {

    @Test("UUIDv5 matches the RFC 4122 reference vector")
    func testRFCVector() {
        // Well-known UUIDv5(NAMESPACE_DNS, "www.example.com").
        let expected = UUID(uuidString: "2ED6657D-E927-568B-95E1-2665A8AEA6A2")!
        #expect(DeterministicID.uuidV5(namespace: DeterministicID.dnsNamespace, name: "www.example.com") == expected)
    }

    @Test("Namespace constant matches its documented derivation")
    func testNamespaceDerivation() {
        // impartNamespace = UUIDv5(NAMESPACE_DNS, "store.impress.impart")
        let derived = DeterministicID.uuidV5(
            namespace: DeterministicID.dnsNamespace,
            name: "store.impress.impart"
        )
        #expect(derived == DeterministicID.impartNamespace)
    }

    @Test("Message ids are stable and case-insensitive")
    func testMessageIDStability() {
        let a = DeterministicID.messageItemID(messageID: "<abc@example.com>", fallbackURI: "unused")
        let b = DeterministicID.messageItemID(messageID: "<ABC@Example.COM>", fallbackURI: "other")
        #expect(a == b)
        // Precomputed vector: UUIDv5(impartNamespace, "<abc@example.com>")
        #expect(a == "5e864f1f-462f-5eef-bbe4-bc11a744c79f")
        // Emitted lowercased
        #expect(a == a.lowercased())
        #expect(UUID(uuidString: a) != nil)
    }

    @Test("Missing or blank Message-ID falls back to the objectID URI")
    func testMessageIDFallback() {
        let uri = "x-coredata://STORE/CDMessage/p42"
        let fromNil = DeterministicID.messageItemID(messageID: nil, fallbackURI: uri)
        let fromEmpty = DeterministicID.messageItemID(messageID: "", fallbackURI: uri)
        let fromBlank = DeterministicID.messageItemID(messageID: "  \n", fallbackURI: uri)
        let direct = DeterministicID.itemID(for: uri)
        #expect(fromNil == direct)
        #expect(fromEmpty == direct)
        #expect(fromBlank == direct)
        // Distinct from a real Message-ID derivation
        #expect(fromNil != DeterministicID.messageItemID(messageID: "<abc@example.com>", fallbackURI: uri))
    }

    @Test("Account and folder ids follow the documented scheme")
    func testAccountAndFolderIDs() {
        // Precomputed: UUIDv5(impartNamespace, "user@example.com")
        #expect(DeterministicID.accountItemID(address: "user@example.com") == "a9589f49-01fe-5978-8f08-d8eb8af05f00")
        // Address falls back to name when empty
        #expect(DeterministicID.accountItemID(address: "", name: "Work") == DeterministicID.itemID(for: "work"))

        // Precomputed: UUIDv5(impartNamespace, "user@example.com/inbox")
        let folder = DeterministicID.folderItemID(accountKey: "user@example.com", remotePath: "INBOX")
        #expect(folder == "8c8b7e94-8bee-5997-874f-dac736fefc1f")
        // Remote path falls back to name when empty
        #expect(
            DeterministicID.folderItemID(accountKey: "user@example.com", remotePath: "", name: "INBOX") == folder
        )
    }
}

// MARK: - Mapping Tests

@Suite("Mail row mapping")
struct MailRowMappingTests {

    @Test("emailMessageRow carries envelope + payload correctly")
    func testEmailMessageRow() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        let row = ImpartStoreAdapter.emailMessageRow(
            messageID: "<m1@example.com>",
            fallbackURI: "unused",
            subject: "Hello",
            body: "Body text",
            from: "alice@example.com",
            to: ["user@example.com"],
            cc: ["bob@example.com"],
            threadID: "thread-1",
            channel: "INBOX",
            accountEmail: "user@example.com",
            folderPath: "INBOX",
            folderName: "INBOX",
            date: date,
            isRead: true,
            isStarred: false
        )

        #expect(row.schemaRef == "email-message")
        #expect(row.id == DeterministicID.messageItemID(messageID: "<m1@example.com>", fallbackURI: "unused"))
        #expect(row.parentId == DeterministicID.folderItemID(accountKey: "user@example.com", remotePath: "INBOX"))
        #expect(row.createdMs == 1_700_000_000_500)
        #expect(row.isRead == true)
        #expect(row.isStarred == false)

        let payloadData = try #require(row.payloadJson.data(using: .utf8))
        let payload = try #require(
            try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        )
        #expect(payload["subject"] as? String == "Hello")
        #expect(payload["body"] as? String == "Body text")
        #expect(payload["from"] as? String == "alice@example.com")
        #expect(payload["to"] as? [String] == ["user@example.com"])
        #expect(payload["cc"] as? [String] == ["bob@example.com"])
        #expect(payload["message_id"] as? String == "<m1@example.com>")
        #expect(payload["thread_id"] as? String == "thread-1")
    }

    @Test("Folder rows parent to their account row")
    func testFolderRowHierarchy() {
        let account = ImpartStoreAdapter.accountRow(email: "user@example.com", displayName: "User")
        let folder = ImpartStoreAdapter.folderRow(
            accountEmail: "user@example.com",
            name: "INBOX",
            remotePath: "INBOX",
            role: "inbox"
        )
        #expect(account.schemaRef == "mail-account")
        #expect(account.parentId == nil)
        #expect(folder.schemaRef == "mail-folder")
        #expect(folder.parentId == account.id)
    }

    @Test("Only well-known folder roles are mapped")
    func testStoreFolderRole() {
        #expect(ImpartStoreAdapter.storeFolderRole("inbox") == "inbox")
        #expect(ImpartStoreAdapter.storeFolderRole("SENT") == "sent")
        #expect(ImpartStoreAdapter.storeFolderRole("custom") == nil)
        #expect(ImpartStoreAdapter.storeFolderRole("agents") == nil)
        #expect(ImpartStoreAdapter.storeFolderRole(nil) == nil)
    }
}

// MARK: - Round-Trip Tests

#if canImport(ImpressRustCore)

@Suite("Unified store round trip")
struct UnifiedStoreRoundTripTests {

    /// Account + folder + two threaded messages through the adapter's
    /// mapping into an in-memory SharedStore, read back through the
    /// ImpartImpressStore query shapes.
    @Test("Account/folder/messages round-trip through the store")
    func testRoundTrip() throws {
        let store = try SharedStore.openInMemory()

        let accountRow = ImpartStoreAdapter.accountRow(email: "user@example.com", displayName: "User")
        let folderRow = ImpartStoreAdapter.folderRow(
            accountEmail: "user@example.com",
            name: "INBOX",
            remotePath: "INBOX",
            role: "inbox",
            sortOrder: 0
        )

        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = earlier.addingTimeInterval(3_600)

        let first = ImpartStoreAdapter.emailMessageRow(
            messageID: "<m1@example.com>",
            fallbackURI: "unused-1",
            subject: "Question",
            body: "First message in thread",
            from: "alice@example.com",
            to: ["user@example.com"],
            cc: [],
            threadID: "thread-1",
            accountEmail: "user@example.com",
            folderPath: "INBOX",
            date: earlier,
            isRead: true,
            isStarred: false
        )
        let second = ImpartStoreAdapter.emailMessageRow(
            messageID: "<m2@example.com>",
            fallbackURI: "unused-2",
            subject: "Re: Question",
            body: "Reply in thread",
            from: "user@example.com",
            to: ["alice@example.com"],
            cc: [],
            threadID: "thread-1",
            accountEmail: "user@example.com",
            folderPath: "INBOX",
            date: later,
            isRead: false,
            isStarred: true
        )

        // Parents before children, one batch.
        let rows = [accountRow, folderRow, first, second]
        let inserted = try store.upsertItems(rows: rows.map(\.shared))
        #expect(inserted.inserted == 4)
        #expect(inserted.updated == 0)

        // Idempotent re-run: deterministic ids turn every row into an update.
        let rerun = try store.upsertItems(rows: rows.map(\.shared))
        #expect(rerun.inserted == 0)
        #expect(rerun.updated == 4)

        let gateway = ImpartImpressStore(testStore: store)

        // Thread listing: both messages, oldest first by REAL message date.
        let thread = gateway.listMessagesForThread(threadID: "thread-1")
        #expect(thread.count == 2)
        #expect(thread.map(\.subject) == ["Question", "Re: Question"])
        #expect(thread.first?.date == earlier)
        #expect(thread.first?.isRead == true)
        #expect(thread.last?.isStarred == true)

        // Folder count via envelope parent.
        let folderID = try #require(UUID(uuidString: folderRow.id))
        #expect(gateway.messageCount(inFolder: folderID) == 2)
        #expect(gateway.messageCount(inFolder: UUID()) == 0)

        // Recent listing: newest first by real date.
        let recent = gateway.listRecentMessages(limit: 10)
        #expect(recent.count == 2)
        #expect(recent.first?.subject == "Re: Question")
        #expect(recent.first?.date == later)

        // Single-message load by deterministic id.
        let firstID = try #require(UUID(uuidString: first.id))
        let loaded = try #require(gateway.loadMessage(id: firstID))
        #expect(loaded.subject == "Question")
        #expect(loaded.from == "alice@example.com")
        #expect(loaded.messageID == "<m1@example.com>")
        #expect(loaded.threadID == "thread-1")
        #expect(loaded.folderItemID == folderID)

        // Thread id discovery.
        #expect(gateway.listThreadIDs() == ["thread-1"])
    }

    @Test("Unified-reads flag defaults to false")
    func testUnifiedReadsFlagDefault() {
        UserDefaults.standard.removeObject(forKey: ImpartImpressStore.unifiedReadsFlagKey)
        #expect(ImpartImpressStore.useUnifiedStoreReads == false)
    }
}

#endif
