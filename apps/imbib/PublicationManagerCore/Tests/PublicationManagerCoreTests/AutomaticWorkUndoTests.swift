//
//  AutomaticWorkUndoTests.swift
//  PublicationManagerCoreTests
//
//  ⌘Z undoes the user's last action — never a feed refresh.
//
//  Feed refreshes import through the same adapter verbs ⌘I and a drag use,
//  and each of those verbs registers undo. After a refresh, ⌘Z undid
//  "Import Paper" (deleting a paper the feed brings straight back) instead of
//  what the user had just done. Automatic work now runs inside
//  `UndoCoordinator.performAutomatic`, a task-local scope in which nothing
//  registers undo; user-initiated imports are untouched.
//

import XCTest

@testable import PublicationManagerCore

@MainActor
final class AutomaticWorkUndoTests: XCTestCase {

    private var manager: UndoManager!

    /// No group is ever left open around automatic work: with
    /// `groupsByEvent = false`, a registration outside a group raises
    /// "must begin a group before registering undo", so any undo that leaks
    /// out of the scope fails the test loudly.
    private func installManager() {
        manager = UndoManager()
        manager.groupsByEvent = false
        UndoCoordinator.shared.undoManager = manager
    }

    override func tearDown() async throws {
        UndoCoordinator.shared.undoManager = nil
        manager = nil
    }

    private func registerUserAction(_ name: String) {
        manager.beginUndoGrouping()
        UndoCoordinator.shared.registerUndoClosure(actionName: name, undo: {})
        manager.endUndoGrouping()
    }

    // MARK: - The scope

    func testAutomaticWorkRegistersNothing() {
        installManager()
        let before = UndoCoordinator.shared.skippedAutomatic["unit test", default: 0]
        UndoCoordinator.performAutomatic("unit test") {
            XCTAssertEqual(UndoCoordinator.automaticWork, "unit test")
            UndoCoordinator.shared.registerUndoClosure(actionName: "Import Paper", undo: {})
        }
        XCTAssertNil(UndoCoordinator.automaticWork)
        XCTAssertEqual(UndoCoordinator.shared.skippedAutomatic["unit test"], before + 1)
        XCTAssertFalse(manager.canUndo, "automatic work put an entry on the user's undo stack")

        registerUserAction("Add Tag")
        XCTAssertTrue(manager.canUndo, "a user action outside the scope must still register")
        XCTAssertEqual(manager.undoActionName, "Add Tag")
    }

    /// The scope follows the work across `await MainActor.run` hops and into
    /// child tasks — the shape of `PaperFetchService`'s pipeline — and ends
    /// with it.
    func testTheScopeFollowsTheWorkAcrossHopsAndChildTasks() async {
        installManager()
        registerUserAction("Add Tag")

        await UndoCoordinator.performAutomatic("feed refresh (test)") {
            await Task.detached {  // off the main actor, like the actor services
                await MainActor.run {
                    // A detached task does NOT inherit task-locals; the hop
                    // back must be inside the scope to count. Assert that
                    // the scan below is honest about it.
                    XCTAssertNil(UndoCoordinator.automaticWork)
                }
            }.value
            await Self.hop {
                UndoCoordinator.shared.registerUndoClosure(actionName: "Import Paper", undo: {})
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await MainActor.run {
                        UndoCoordinator.shared.registerUndoClosure(
                            actionName: "Add to Collection", undo: {})
                    }
                }
            }
        }

        XCTAssertEqual(manager.undoActionName, "Add Tag", "⌘Z no longer undoes the user's action")
        XCTAssertNil(UndoCoordinator.automaticWork, "the scope outlived its work")
    }

    /// An actor-isolated hop onto the main actor, as `withStore` does it.
    nonisolated private static func hop(_ body: @MainActor @Sendable () -> Void) async {
        await MainActor.run(body: body)
    }

    // MARK: - Through the real store verbs

    /// The feed pipeline's own calls — import, mark unread, link to the feed,
    /// stamp `last_fetch_count` — inside the scope leave the user's last
    /// action on top of the stack, and ⌘Z undoes IT, not the import.
    func testAFeedImportThroughTheAdapterLeavesTheUsersUndoOnTop() throws {
        let adapter = RustStoreAdapter.shared
        guard let library = adapter.createLibrary(name: "Auto undo \(UUID().uuidString.prefix(6))"),
              let feed = adapter.createCollection(name: "Feed \(UUID().uuidString.prefix(6))", libraryId: library.id)
        else { throw XCTSkip("no writable store in this environment") }

        let mine = adapter.importBibTeX(
            """
            @article{AutoUndoMine2026,
              author = {User, U.}, title = {The user's own paper}, year = {2026}
            }
            """,
            libraryId: library.id)
        try XCTSkipIf(mine.isEmpty, "import produced nothing in this environment")
        let path = "tests/auto-undo-\(UUID().uuidString.prefix(8))"
        func tagged() -> Bool {
            adapter.getPublication(id: mine[0])?.tagDisplays.contains { $0.path == path } ?? false
        }

        installManager()
        manager.beginUndoGrouping()
        adapter.addTag(ids: mine, tagPath: path)
        manager.endUndoGrouping()
        let usersAction = manager.undoActionName
        XCTAssertTrue(tagged())

        // No group open: a registration leaking out of the scope raises.
        var fed: [UUID] = []
        UndoCoordinator.performAutomatic("feed refresh (test)") {
            fed = adapter.importBibTeX(
                """
                @article{AutoUndoFeed2026,
                  author = {Feed, F.}, title = {A paper a feed brought}, year = {2026}
                }
                """,
                libraryId: library.id)
            adapter.setRead(ids: fed, read: false)
            adapter.addToCollection(publicationIds: fed, collectionId: feed.id)
            adapter.updateIntField(id: feed.id, field: "last_fetch_count", value: Int64(fed.count))
        }
        XCTAssertEqual(fed.count, 1, "the feed import itself must still happen")
        XCTAssertEqual(manager.undoActionName, usersAction, "the feed's work is on top of the undo stack")

        manager.undo()
        XCTAssertFalse(tagged(), "⌘Z did not undo the user's Add Tag")
        XCTAssertNotNil(adapter.getPublication(id: fed[0]), "⌘Z deleted the feed's paper")
    }

    /// A user-initiated import keeps its undo.
    func testAUserImportIsStillUndoable() throws {
        let adapter = RustStoreAdapter.shared
        guard let library = adapter.createLibrary(name: "User undo \(UUID().uuidString.prefix(6))")
        else { throw XCTSkip("no writable store in this environment") }
        installManager()
        manager.beginUndoGrouping()
        let ids = adapter.importBibTeX(
            """
            @article{UserImport2026,
              author = {User, U.}, title = {Imported on purpose}, year = {2026}
            }
            """,
            libraryId: library.id)
        manager.endUndoGrouping()
        try XCTSkipIf(ids.isEmpty, "import produced nothing in this environment")
        XCTAssertEqual(manager.undoActionName, "Import Paper")
        manager.undo()
        XCTAssertNil(adapter.getPublication(id: ids[0]), "undo of a user import did not remove it")
    }

    // MARK: - The automatic paths are wrapped

    /// Each automatic importer runs its store work inside the scope. A source
    /// check, because driving them for real needs the network.
    func testEveryAutomaticImporterRunsInsideTheScope() throws {
        let base = "apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/"
        let expectations: [(String, [String])] = [
            ("Inbox/PaperFetchService.swift", [
                "UndoCoordinator.performAutomatic(\"feed refresh '\\(feedName)'\")",
                "UndoCoordinator.performAutomatic(\"feed refresh \\(smartSearchID)\")",
            ]),
            ("Inbox/GroupFeedRefreshService.swift", [
                "UndoCoordinator.performAutomatic(\"group feed refresh",
            ]),
            ("SmartSearch/SmartSearchProvider.swift", [
                "UndoCoordinator.performAutomatic(\"smart search",
            ]),
            ("Chassis/WatchedFolders/WatchedFolderIngestCoordinator.swift", [
                "UndoCoordinator.performAutomatic(\"watched folder\")",
            ]),
            ("Inbox/RetentionCleanupService.swift", [
                "UndoCoordinator.performAutomatic(\"retention\")",
            ]),
        ]
        for (file, needles) in expectations {
            let source = try Self.source(of: base + file)
            for needle in needles {
                XCTAssertTrue(source.contains(needle), "\(file) no longer runs \(needle)")
            }
        }
        // `sendToInbox` is the user's Send to Inbox: it must keep its undo.
        let fetch = try Self.source(of: base + "Inbox/PaperFetchService.swift")
        let send = try XCTUnwrap(fetch.range(of: "public func sendToInbox"))
        let body = fetch[send.lowerBound...].prefix(400)
        XCTAssertFalse(body.contains("performAutomatic"), "Send to Inbox is user-initiated")
    }

    // MARK: - Retention (review PH-H2)

    /// The retention cleanup deletes papers nobody chose to delete. Before
    /// PH-H2 every one of those deletes put "Delete" on the user's undo
    /// stack, so ⌘Z after launch resurrected an expired Inbox paper instead
    /// of undoing what the user had just done.
    func testRetentionDeletesWithoutTouchingTheUsersUndo() throws {
        installManager()
        let adapter = RustStoreAdapter.shared
        let inbox = UndoCoordinator.performAutomatic("test setup") {
            InboxManager.shared.getOrCreateInbox()
        }
        let key = "retention\(UUID().uuidString.prefix(8))"
        // Setup is not the user's either: keep it off the stack.
        let ids = UndoCoordinator.performAutomatic("test setup") {
            adapter.importBibTeX(
                "@article{\(key), title={Read in the Inbox}, author={Retention, A.}, year={2020}}",
                libraryId: inbox.id)
        }
        try XCTSkipIf(ids.isEmpty, "import produced nothing in this environment")
        UndoCoordinator.performAutomatic("test setup") { adapter.setRead(ids: ids, read: true) }

        let settings = InboxRetentionStore.shared
        let saved = (settings.retentionDays, settings.autoRemoveRead)
        defer { (settings.retentionDays, settings.autoRemoveRead) = saved }
        settings.retentionDays = 3650
        settings.autoRemoveRead = true

        registerUserAction("Add Tag")
        let runs = RetentionCleanupService.shared.runCount
        RetentionCleanupService.shared.performCleanup(reason: "test")

        XCTAssertEqual(RetentionCleanupService.shared.runCount, runs + 1)
        XCTAssertNil(adapter.getPublication(id: ids[0]), "a read Inbox paper is what retention removes")
        XCTAssertEqual(
            manager.undoActionName, "Add Tag",
            "the cleanup's delete reached the user's undo stack")
    }

    /// Once per process, however many callers ask — a pane that mounts again
    /// must never mean a second run.
    func testTheLaunchCleanupIsScheduledOncePerProcess() async throws {
        let service = RetentionCleanupService.shared
        let first = try XCTUnwrap(service.scheduleLaunchCleanup(gate: .open, reason: "test"))
        let second = try XCTUnwrap(service.scheduleLaunchCleanup(gate: .open, reason: "test again"))
        XCTAssertEqual(first, second, "a second schedule made a second run")
        await first.value
        XCTAssertGreaterThanOrEqual(service.runCount, 1, "the scheduled run never ran")
    }

    /// The one caller is imbib's own lifecycle. A view — the chassis sidebar
    /// lifecycle, applied by the layout tree's outline pane in every chassis
    /// app on every split — must not run it (the PH-H2 regression).
    func testOnlyImbibsLifecycleRunsRetention() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let sources = root.appendingPathComponent("Sources/PublicationManagerCore")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path))
        var callers: [String] = []
        for case let path as String in enumerator where path.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            if text.contains("RetentionCleanupService.shared.") { callers.append(path) }
        }
        XCTAssertEqual(callers, ["Inbox/InboxCoordinator.swift"], "retention has a caller besides imbib's lifecycle")
    }

    /// …/apps/imbib/PublicationManagerCore/Tests/PublicationManagerCoreTests/<this>:
    /// six components up is the repository root.
    private static func source(of relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
