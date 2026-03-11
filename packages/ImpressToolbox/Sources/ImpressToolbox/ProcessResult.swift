import Foundation

/// Result from process execution.
public struct ProcessResult: Codable, Sendable {
    /// Echoed request ID.
    public var id: String?
    /// Process exit code.
    public var exitCode: Int32
    /// Captured stdout.
    public var stdout: String
    /// Captured stderr.
    public var stderr: String
    /// Wall-clock duration in milliseconds.
    public var durationMs: Int
    /// Whether the process was killed due to timeout.
    public var timedOut: Bool

    public var isSuccess: Bool { exitCode == 0 }

    enum CodingKeys: String, CodingKey {
        case id
        case exitCode = "exit_code"
        case stdout, stderr
        case durationMs = "duration_ms"
        case timedOut = "timed_out"
    }
}

/// Result from executable discovery.
public struct DiscoveryResult: Codable, Sendable {
    /// Map of name -> full path for found executables.
    public var found: [String: String]
    /// Names that were not found.
    public var notFound: [String]

    enum CodingKeys: String, CodingKey {
        case found
        case notFound = "not_found"
    }
}
