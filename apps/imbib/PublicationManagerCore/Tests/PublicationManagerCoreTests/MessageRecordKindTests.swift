//
//  MessageRecordKindTests.swift
//  PublicationManagerCoreTests
//
//  Stage 2-A (ADR-0021): the message record kind's descriptor contract —
//  always-available tabs, IMAP-owned lifecycle (no dismiss/delete), scope
//  identity determinism, thread collapsing, and the impart shell preset —
//  mirroring FigureRecordKindTests.
//

import SwiftUI
import XCTest
import ImpressRustCore
@testable import PublicationManagerCore

#if os(macOS)
final class MessageRecordKindTests: XCTestCase {

    // MARK: - Descriptor tab contract

    /// Messages have no gating context — Info/Source/View are always
    /// available (the View tab is DetailTab.pdf relabeled: typeset body).
    func testAllTabsAlwaysAvailable() {
        for context in [
            RecordTabContext(),
            RecordTabContext(isEditable: false),
            RecordTabContext(previewKind: DocumentFormat.PreviewKind.none),
            RecordTabContext(previewKind: .compiledPDF),
        ] {
            XCTAssertEqual(
                MessageRecordKind.descriptor.availableTabs(for: context),
                [.info, .source, .pdf])
        }
    }

    func testCoercionKeepsValidTabsAndLandsOnInfoOtherwise() {
        let context = RecordTabContext()
        XCTAssertEqual(MessageRecordKind.descriptor.coercedTab(.info, for: context), .info)
        XCTAssertEqual(MessageRecordKind.descriptor.coercedTab(.source, for: context), .source)
        XCTAssertEqual(MessageRecordKind.descriptor.coercedTab(.pdf, for: context), .pdf)
        // Tabs outside the message set coerce to info.
        XCTAssertEqual(MessageRecordKind.descriptor.coercedTab(.notes, for: context), .info)
        XCTAssertEqual(MessageRecordKind.descriptor.coercedTab(.bibtex, for: context), .info)
    }

    // MARK: - Triage contract (frozen in docs/chassis-capability-matrix.md)

    func testTriageCapabilitiesMatchContract() {
        let triage = MessageRecordKind.descriptor.triage
        XCTAssertTrue(triage.canStar)
        XCTAssertTrue(triage.canFlag)
        XCTAssertTrue(triage.canTag)
        XCTAssertEqual(triage.dismissal, .none,
                       "messages have no status field; mail lifecycle is IMAP-owned")
        XCTAssertNil(triage.archiveStatus)
        XCTAssertEqual(triage.deletion, .none,
                       "mail deletion goes through IMAP flows, never the store")
        XCTAssertEqual(triage.statuses, [])
        XCTAssertTrue(MessageRecordKind.descriptor.creation.isEmpty,
                      "compose stays in impart's classic window in v1")
        XCTAssertEqual(MessageRecordKind.descriptor.defaultOpenBehavior, .detailPane)
    }

    func testRegistryLookupBySchemaRef() {
        let registry = AppShellConfiguration.impart.recordKinds
        XCTAssertEqual(registry.descriptor(forSchemaRef: "email-message")?.id, .message)
        XCTAssertEqual(registry.descriptor(forSchemaRef: "chat-message")?.id, .message)
        XCTAssertEqual(registry[.message]?.displayName, "Message")
    }

    // MARK: - Scope identity

    func testScopeStableViewIDsAreDeterministicAndDistinct() {
        let a = MessageListScope.allInboxes.stableViewID
        let b = MessageListScope.allInboxes.stableViewID
        XCTAssertEqual(a, b, "same scope must produce the same id across evaluations")
        XCTAssertNotEqual(
            MessageListScope.allInboxes.stableViewID,
            MessageListScope.flagged(nil).stableViewID)
        XCTAssertNotEqual(
            MessageListScope.flagged(nil).stableViewID,
            MessageListScope.flagged(.red).stableViewID)
        let folderID = UUID()
        XCTAssertEqual(
            MessageListScope.folder(folderID).stableViewID,
            MessageListScope.folder(folderID).stableViewID)
        XCTAssertNotEqual(
            MessageListScope.folder(folderID).stableViewID,
            MessageListScope.account(folderID).stableViewID,
            "folder and account scopes over the same UUID must not collide")
    }

    func testScopeKeysAreNamespacedAgainstOtherKinds() {
        XCTAssertTrue(MessageListScope.allInboxes.scopeKey.hasPrefix("messages-"))
        XCTAssertNotEqual(
            MessageListScope.flagged(.red).stableViewID,
            FigureListScope.flagged(.red).stableViewID)
        XCTAssertNotEqual(
            MessageListScope.flagged(.red).stableViewID,
            ManuscriptListScope.flagged(.red).stableViewID)
    }

    // MARK: - Row model

    @MainActor
    func testMessageRowDataMapsSharedItemRow() {
        let id = UUID()
        let row = SharedItemRow(
            id: id.uuidString.lowercased(),
            schemaRef: "email-message",
            payloadJson: #"{"subject":"Referee report","body":"  Dear   author,\n\nplease revise. ","from":"editor@journal.org","to":["tabel@stanford.edu"],"cc":["coauthor@univ.edu"],"message_id":"<abc@journal.org>","thread_id":"thread-1"}"#,
            createdMs: 1_700_000_000_000,
            modifiedMs: 1_700_000_100_000,
            parentId: "folder-1",
            isRead: false,
            isStarred: true,
            tags: ["projects/reionization"],
            flagColor: "red")
        guard let data = MessageRowData(from: row) else {
            return XCTFail("row should map")
        }
        XCTAssertEqual(data.id, id)
        XCTAssertEqual(data.subject, "Referee report")
        XCTAssertEqual(data.from, "editor@journal.org")
        XCTAssertEqual(data.to, ["tabel@stanford.edu"])
        XCTAssertEqual(data.cc, ["coauthor@univ.edu"])
        XCTAssertEqual(data.messageIDHeader, "<abc@journal.org>")
        XCTAssertEqual(data.threadID, "thread-1")
        XCTAssertEqual(data.parentIDString, "folder-1")
        XCTAssertTrue(data.isStarred)
        XCTAssertEqual(data.flag?.color, .red)
        XCTAssertEqual(data.tagDisplays.map(\.leaf), ["reionization"])
        XCTAssertEqual(
            data.messageDate,
            Date(timeIntervalSince1970: 1_700_000_000),
            "createdMs carries the REAL message date (Stage 0-WP3)")
        // MailStyleItem projections
        XCTAssertEqual(data.headerText, "editor@journal.org")
        XCTAssertEqual(data.titleText, "Referee report")
        XCTAssertEqual(data.previewText, "Dear author, please revise.",
                       "preview collapses whitespace runs and trims")
        XCTAssertFalse(data.isRead, "mail has REAL unread semantics — dot must show")
        XCTAssertNil(data.trailingBadgeText, "no thread badge for a single message")
        XCTAssertNil(data.subtitleText)
        XCTAssertFalse(data.hasAttachment)
    }

    @MainActor
    func testMessageRowDataDefaultsAndBadge() {
        let row = SharedItemRow(
            id: UUID().uuidString.lowercased(),
            schemaRef: "email-message",
            payloadJson: "{}",
            createdMs: 0, modifiedMs: 0,
            parentId: nil, isRead: true, isStarred: false,
            tags: [], flagColor: nil)
        guard var data = MessageRowData(from: row) else {
            return XCTFail("row should map")
        }
        XCTAssertEqual(data.titleText, "(No Subject)")
        XCTAssertEqual(data.headerText, "Unknown Sender")
        XCTAssertNil(data.previewText)
        XCTAssertNil(data.flag)
        XCTAssertTrue(data.isRead)
        // Thread badge is "(n)" once the wrapper's grouping sets the count.
        data.threadCount = 3
        XCTAssertEqual(data.trailingBadgeText, "(3)")
        // Non-UUID store ids don't map (defensive).
        let bad = SharedItemRow(
            id: "not-a-uuid", schemaRef: "email-message", payloadJson: "{}",
            createdMs: 0, modifiedMs: 0, parentId: nil,
            isRead: true, isStarred: false, tags: [], flagColor: nil)
        XCTAssertNil(MessageRowData(from: bad))
    }

    func testPreviewTextClipsToTwoHundredCharacters() {
        let long = String(repeating: "word ", count: 100)
        let preview = MessageRowData.previewText(from: long)
        XCTAssertEqual(preview.count, 200)
        XCTAssertFalse(preview.contains("\n"))
    }

    // MARK: - Thread grouping (in-list collapse, Stage 2-A v1)

    @MainActor
    func testCollapsedByThreadKeepsNewestPerThreadWithBadge() {
        func makeRow(_ id: UUID, thread: String?, dateMs: Int64) -> MessageRowData {
            let threadJSON = thread.map { #","thread_id":"\#($0)""# } ?? ""
            let row = SharedItemRow(
                id: id.uuidString.lowercased(),
                schemaRef: "email-message",
                payloadJson: #"{"subject":"s","from":"f","body":"b"\#(threadJSON)}"#,
                createdMs: dateMs, modifiedMs: dateMs,
                parentId: nil, isRead: true, isStarred: false,
                tags: [], flagColor: nil)
            return MessageRowData(from: row)!
        }
        let a1 = UUID(), a2 = UUID(), a3 = UUID(), solo = UUID()
        let messages = [
            makeRow(a1, thread: "t1", dateMs: 1_000),
            makeRow(solo, thread: nil, dateMs: 2_000),
            makeRow(a2, thread: "t1", dateMs: 3_000),
            makeRow(a3, thread: "t1", dateMs: 2_500),
        ]
        let collapsed = MessageRowData.collapsedByThread(messages)
        XCTAssertEqual(collapsed.count, 2, "3 thread members collapse to 1 row + 1 solo")
        // Newest first: the t1 representative (3000) before the solo (2000).
        XCTAssertEqual(collapsed[0].id, a2, "thread collapses to its NEWEST message")
        XCTAssertEqual(collapsed[0].threadCount, 3)
        XCTAssertEqual(collapsed[0].trailingBadgeText, "(3)")
        XCTAssertEqual(collapsed[1].id, solo)
        XCTAssertEqual(collapsed[1].threadCount, 1)
        XCTAssertNil(collapsed[1].trailingBadgeText)
    }

    // MARK: - impart shell preset

    func testImpartPresetMatchesContract() {
        let c = AppShellConfiguration.impart
        XCTAssertEqual(c.appID, "impart")
        XCTAssertEqual(c.visibleSections, [.mail], "Flagged is deliberately skipped in v1")
        XCTAssertEqual(c.defaultSection, .mail)
        XCTAssertEqual(c.defaultDetailTab, .info)
        XCTAssertEqual(c.openBehavior(for: .message), .detailPane)
        XCTAssertTrue(c.customSurfaces.isEmpty,
                      "chat/research/development register app-side via withCustomSurfaces")
        XCTAssertFalse(c.permits(.inbox))
        XCTAssertFalse(c.permits(.manuscripts))
        XCTAssertFalse(c.permits(.figures))
        XCTAssertTrue(c.permits(.mail))
    }

    /// The Mail section stays hidden outside impart: EVERY other preset now
    /// excludes it via visibleSections — imbib included, since the
    /// publications-only purification made its set explicit. The appID
    /// content gate (`shouldShowSection` appID == "impart", not testable here
    /// — private) remains as belt-and-braces for nil-visibleSections shells.
    func testMailSectionGatingAcrossPresets() {
        XCTAssertFalse(AppShellConfiguration.imprint.permits(.mail))
        XCTAssertFalse(AppShellConfiguration.implore.permits(.mail))
        XCTAssertFalse(AppShellConfiguration.imbib.permits(.mail))
        XCTAssertEqual(AppShellConfiguration.imbib.appID, "imbib")
    }

    @MainActor
    func testWithCustomSurfacesPreservesShellIdentity() {
        let surface = CustomSurfaceDescriptor(
            id: "chat", title: "Chat", systemImage: "bubble.left.and.bubble.right",
            makeView: { AnyView(EmptyView()) })
        let extended = AppShellConfiguration.impart.withCustomSurfaces([surface])
        XCTAssertEqual(extended.appID, "impart")
        XCTAssertEqual(extended.visibleSections, [.mail])
        XCTAssertEqual(extended.defaultSection, .mail)
        XCTAssertEqual(extended.customSurfaces["chat"]?.title, "Chat")
        XCTAssertNotEqual(extended, .impart, "surface ids participate in equality")
    }
}
#endif
