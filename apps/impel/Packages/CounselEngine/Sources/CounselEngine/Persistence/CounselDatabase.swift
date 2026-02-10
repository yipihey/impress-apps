import Foundation
import GRDB
import OSLog

/// Manages the SQLite database for counsel conversation persistence.
public final class CounselDatabase: Sendable {
    private let dbWriter: any DatabaseWriter
    private let logger = Logger(subsystem: "com.impress.impel", category: "counsel-db")

    /// Creates or opens the counsel database at the standard location.
    public init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.impress.impel", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("counsel.sqlite").path
        dbWriter = try DatabasePool(path: dbPath)
        try migrate()
        logger.info("Counsel database opened at \(dbPath)")
    }

    /// Creates an in-memory database for testing.
    public init(inMemory: Bool) throws {
        dbWriter = try DatabaseQueue()
        try migrate()
    }

    // MARK: - Migrations

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "counselConversation") { t in
                t.primaryKey("id", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("participantEmail", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("summary", .text)
                t.column("totalTokensUsed", .integer).notNull().defaults(to: 0)
                t.column("messageCount", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "counselMessage") { t in
                t.primaryKey("id", .text).notNull()
                t.column("conversationID", .text).notNull()
                    .references("counselConversation", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("emailMessageID", .text)
                t.column("inReplyTo", .text)
                t.column("intent", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("tokenCount", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "counselToolExecution") { t in
                t.primaryKey("id", .text).notNull()
                t.column("messageID", .text)
                    .references("counselMessage", onDelete: .cascade)
                t.column("conversationID", .text).notNull()
                    .references("counselConversation", onDelete: .cascade)
                t.column("toolName", .text).notNull()
                t.column("toolInput", .text).notNull()
                t.column("toolOutput", .text).notNull()
                t.column("isError", .boolean).notNull().defaults(to: false)
                t.column("durationMs", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "standingOrder") { t in
                t.primaryKey("id", .text).notNull()
                t.column("conversationID", .text)
                    .references("counselConversation", onDelete: .setNull)
                t.column("description", .text).notNull()
                t.column("schedule", .text).notNull()
                t.column("toolChain", .text).notNull()
                t.column("lastRunAt", .datetime)
                t.column("nextRunAt", .datetime)
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
            }

            // Indices
            try db.create(indexOn: "counselMessage", columns: ["conversationID"])
            try db.create(indexOn: "counselMessage", columns: ["emailMessageID"])
            try db.create(indexOn: "counselToolExecution", columns: ["conversationID"])
            try db.create(indexOn: "counselToolExecution", columns: ["messageID"])
            try db.create(indexOn: "standingOrder", columns: ["nextRunAt"])
        }

        migrator.registerMigration("v2_tasks") { db in
            try db.create(table: "counselTask") { t in
                t.primaryKey("id", .text).notNull()
                t.column("intent", .text).notNull()
                t.column("query", .text).notNull()
                t.column("sourceApp", .text).notNull().defaults(to: "api")
                t.column("conversationID", .text)
                    .references("counselConversation", onDelete: .setNull)
                t.column("callbackURL", .text)
                t.column("status", .text).notNull().defaults(to: "queued")
                t.column("responseText", .text)
                t.column("toolExecutionCount", .integer).notNull().defaults(to: 0)
                t.column("roundsUsed", .integer).notNull().defaults(to: 0)
                t.column("totalInputTokens", .integer).notNull().defaults(to: 0)
                t.column("totalOutputTokens", .integer).notNull().defaults(to: 0)
                t.column("finishReason", .text)
                t.column("errorMessage", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("startedAt", .datetime)
                t.column("completedAt", .datetime)
            }

            try db.create(indexOn: "counselTask", columns: ["status"])
            try db.create(indexOn: "counselTask", columns: ["conversationID"])
            try db.create(indexOn: "counselTask", columns: ["createdAt"])
        }

        try migrator.migrate(dbWriter)
    }

    // MARK: - Read Access

    public var reader: DatabaseReader { dbWriter }

    // MARK: - Conversations

    public func createConversation(_ conversation: CounselConversation) throws {
        try dbWriter.write { db in
            try conversation.insert(db)
        }
    }

    public func updateConversation(_ conversation: CounselConversation) throws {
        try dbWriter.write { db in
            try conversation.update(db)
        }
    }

    public func fetchConversation(id: String) throws -> CounselConversation? {
        try dbWriter.read { db in
            try CounselConversation.fetchOne(db, key: id)
        }
    }

    public func fetchConversationByEmailMessageID(_ emailMessageID: String) throws -> CounselConversation? {
        try dbWriter.read { db in
            let message = try CounselMessage
                .filter(Column("emailMessageID") == emailMessageID)
                .fetchOne(db)
            guard let convID = message?.conversationID else { return nil }
            return try CounselConversation.fetchOne(db, key: convID)
        }
    }

    public func fetchAllConversations(limit: Int = 100) throws -> [CounselConversation] {
        try dbWriter.read { db in
            try CounselConversation
                .order(Column("updatedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Messages

    public func addMessage(_ message: CounselMessage) throws {
        try dbWriter.write { db in
            try message.insert(db)
            // Update conversation message count and timestamp
            try db.execute(
                sql: """
                    UPDATE counselConversation
                    SET messageCount = messageCount + 1,
                        totalTokensUsed = totalTokensUsed + ?,
                        updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [message.tokenCount, Date(), message.conversationID]
            )
        }
    }

    public func fetchMessages(conversationID: String) throws -> [CounselMessage] {
        try dbWriter.read { db in
            try CounselMessage
                .filter(Column("conversationID") == conversationID)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Tool Executions

    public func addToolExecution(_ execution: CounselToolExecution) throws {
        try dbWriter.write { db in
            try execution.insert(db)
        }
    }

    public func fetchToolExecutions(conversationID: String) throws -> [CounselToolExecution] {
        try dbWriter.read { db in
            try CounselToolExecution
                .filter(Column("conversationID") == conversationID)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func fetchToolExecutions(messageID: String) throws -> [CounselToolExecution] {
        try dbWriter.read { db in
            try CounselToolExecution
                .filter(Column("messageID") == messageID)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Standing Orders

    public func addStandingOrder(_ order: StandingOrder) throws {
        try dbWriter.write { db in
            try order.insert(db)
        }
    }

    public func updateStandingOrder(_ order: StandingOrder) throws {
        try dbWriter.write { db in
            try order.update(db)
        }
    }

    public func fetchActiveStandingOrders() throws -> [StandingOrder] {
        try dbWriter.read { db in
            try StandingOrder
                .filter(Column("isActive") == true)
                .order(Column("nextRunAt").asc)
                .fetchAll(db)
        }
    }

    public func fetchDueStandingOrders(before date: Date = Date()) throws -> [StandingOrder] {
        try dbWriter.read { db in
            try StandingOrder
                .filter(Column("isActive") == true)
                .filter(Column("nextRunAt") != nil)
                .filter(Column("nextRunAt") <= date)
                .order(Column("nextRunAt").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Tasks

    public func createTask(_ task: CounselTask) throws {
        try dbWriter.write { db in
            try task.insert(db)
        }
    }

    public func updateTask(_ task: CounselTask) throws {
        try dbWriter.write { db in
            try task.update(db)
        }
    }

    public func fetchTask(id: String) throws -> CounselTask? {
        try dbWriter.read { db in
            try CounselTask.fetchOne(db, key: id)
        }
    }

    public func fetchTasks(status: CounselTaskStatus? = nil, limit: Int = 100) throws -> [CounselTask] {
        try dbWriter.read { db in
            var request = CounselTask.order(Column("createdAt").desc)
            if let status {
                request = request.filter(Column("status") == status.rawValue)
            }
            return try request.limit(limit).fetchAll(db)
        }
    }

    public func fetchTasksForConversation(_ conversationID: String) throws -> [CounselTask] {
        try dbWriter.read { db in
            try CounselTask
                .filter(Column("conversationID") == conversationID)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    // MARK: - Search

    public func searchMessages(query: String, limit: Int = 50) throws -> [CounselMessage] {
        try dbWriter.read { db in
            try CounselMessage
                .filter(Column("content").like("%\(query)%"))
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}
