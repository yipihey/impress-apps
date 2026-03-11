import Foundation

/// Request to execute a process via the toolbox server.
public struct ProcessRequest: Codable, Sendable {
    /// Optional request ID for correlation.
    public var id: String?
    /// Full path to the executable.
    public var executable: String
    /// Command-line arguments.
    public var arguments: [String]
    /// Working directory for the process.
    public var workingDirectory: String?
    /// Environment variables.
    public var environment: [String: String]
    /// Timeout in milliseconds (default 60000, max 300000).
    public var timeoutMs: Int?

    public init(
        id: String? = nil,
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeoutMs: Int? = nil
    ) {
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutMs = timeoutMs
    }

    enum CodingKeys: String, CodingKey {
        case id, executable, arguments
        case workingDirectory = "working_directory"
        case environment
        case timeoutMs = "timeout_ms"
    }
}

/// Request to discover executables.
public struct DiscoverRequest: Codable, Sendable {
    /// Names of executables to find.
    public var names: [String]
    /// Directories to search in.
    public var searchPaths: [String]

    public init(names: [String], searchPaths: [String] = []) {
        self.names = names
        self.searchPaths = searchPaths
    }

    enum CodingKeys: String, CodingKey {
        case names
        case searchPaths = "search_paths"
    }
}
