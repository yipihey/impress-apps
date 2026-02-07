import AppIntents

/// Thread status enum for impel agent threads.
@available(macOS 14.0, iOS 17.0, *)
public enum ThreadStatus: String, AppEnum, Sendable {
    case active
    case blocked
    case completed

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Thread Status"
    }

    public static var caseDisplayRepresentations: [ThreadStatus: DisplayRepresentation] {
        [
            .active: "Active",
            .blocked: "Blocked",
            .completed: "Completed"
        ]
    }
}
