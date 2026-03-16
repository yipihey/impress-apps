import Foundation

/// A single entry in the undo history, representing one undoable action
/// (or one batch of operations grouped as a single undo step).
public struct UndoHistoryEntry: Identifiable, Sendable {
    public let id: UUID
    /// Human-readable action name ("Star 3 Papers", "Delete Paper").
    public let actionName: String
    /// When this action occurred.
    public let timestamp: Date
    /// Number of individual operations (1 for single, N for batch).
    public let operationCount: Int
    /// Batch ID if this is a grouped operation, nil for single operations.
    public let batchId: String?
    /// Who performed this action ("user:local", "agent:impel").
    public let author: String
    /// The kind of author.
    public let authorKind: AuthorKind

    /// The kind of actor that performed the action.
    public enum AuthorKind: String, Sendable, CaseIterable {
        case human = "Human"
        case agent = "Agent"
        case system = "System"
    }

    public init(
        id: UUID = UUID(),
        actionName: String,
        timestamp: Date = Date(),
        operationCount: Int = 1,
        batchId: String? = nil,
        author: String = "user:local",
        authorKind: AuthorKind = .human
    ) {
        self.id = id
        self.actionName = actionName
        self.timestamp = timestamp
        self.operationCount = operationCount
        self.batchId = batchId
        self.author = author
        self.authorKind = authorKind
    }
}
