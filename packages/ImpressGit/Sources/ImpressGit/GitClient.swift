import Foundation
import ImpressLogging
import OSLog

/// HTTP client for the toolbox `/git/*` endpoints.
///
/// All git operations are executed by the unsandboxed impress-toolbox server,
/// which inherits the user's full auth stack (SSH agent, credential helpers, etc.).
public actor GitClient {
    public static let shared = GitClient()

    private let baseURL: String
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(port: UInt16 = 23119) {
        self.baseURL = "http://127.0.0.1:\(port)/git"
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Discovery

    /// Check if git and gh CLI are available on this machine.
    public func discoverGit() async throws -> GitDiscovery {
        try await get(path: "/discover")
    }

    // MARK: - Repository Operations

    /// Clone a remote repository.
    public func clone(url: String, to targetPath: String, branch: String? = nil) async throws -> CloneResult {
        struct Req: Encodable {
            let url: String
            let target_path: String
            let branch: String?
        }
        return try await post(path: "/clone", body: Req(url: url, target_path: targetPath, branch: branch))
    }

    /// Get the status of a repository.
    public func status(at path: String) async throws -> RepoStatus {
        try await get(path: "/status", query: ["path": path])
    }

    /// Stage files.
    public func add(at path: String, files: [String]) async throws {
        struct Req: Encodable { let path: String; let files: [String] }
        let _: SuccessResponse = try await post(path: "/add", body: Req(path: path, files: files))
    }

    /// Commit staged changes.
    public func commit(at path: String, message: String, files: [String] = []) async throws -> CommitResult {
        struct Req: Encodable { let path: String; let message: String; let files: [String] }
        return try await post(path: "/commit", body: Req(path: path, message: message, files: files))
    }

    /// Push to remote.
    public func push(at path: String, remote: String? = nil, branch: String? = nil) async throws {
        struct Req: Encodable { let path: String; let remote: String?; let branch: String? }
        let _: SuccessResponse = try await post(path: "/push", body: Req(path: path, remote: remote, branch: branch))
    }

    /// Pull from remote.
    public func pull(at path: String, remote: String? = nil, branch: String? = nil, rebase: Bool = false) async throws -> PullResult {
        struct Req: Encodable { let path: String; let remote: String?; let branch: String?; let rebase: Bool }
        return try await post(path: "/pull", body: Req(path: path, remote: remote, branch: branch, rebase: rebase))
    }

    /// Get commit log.
    public func log(at path: String, count: Int = 20) async throws -> [LogEntry] {
        try await get(path: "/log", query: ["path": path, "count": "\(count)"])
    }

    /// Get diff output.
    public func diff(at path: String, cached: Bool = false) async throws -> String {
        try await get(path: "/diff", query: ["path": path, "cached": cached ? "true" : "false"])
    }

    /// Get diff summary (numstat).
    public func diffStat(at path: String, cached: Bool = false) async throws -> DiffSummary {
        try await get(path: "/diff/stat", query: ["path": path, "cached": cached ? "true" : "false"])
    }

    /// List branches.
    public func branches(at path: String) async throws -> [GitBranch] {
        try await get(path: "/branches", query: ["path": path])
    }

    /// Checkout a branch.
    public func checkout(at path: String, branch: String) async throws {
        struct Req: Encodable { let path: String; let branch: String }
        let _: SuccessResponse = try await post(path: "/checkout", body: Req(path: path, branch: branch))
    }

    /// Initialize a new repository.
    public func initRepo(at path: String) async throws {
        struct Req: Encodable { let path: String }
        let _: SuccessResponse = try await post(path: "/init", body: Req(path: path))
    }

    /// Add a remote.
    public func addRemote(at path: String, name: String, url: String) async throws {
        struct Req: Encodable { let path: String; let name: String; let url: String }
        let _: SuccessResponse = try await post(path: "/remote/add", body: Req(path: path, name: name, url: url))
    }

    /// List remotes.
    public func remotes(at path: String) async throws -> [RemoteInfo] {
        try await get(path: "/remotes", query: ["path": path])
    }

    /// Create a new GitHub repository (uses `gh` if available, falls back to `git init`).
    public func createRepo(
        at path: String,
        name: String,
        description: String? = nil,
        isPrivate: Bool = true,
        org: String? = nil
    ) async throws -> CreateRepoResult {
        struct Req: Encodable {
            let path: String
            let name: String
            let description: String?
            let `private`: Bool
            let org: String?
        }
        return try await post(
            path: "/create-repo",
            body: Req(path: path, name: name, description: description, private: isPrivate, org: org)
        )
    }

    // MARK: - Internal HTTP

    private struct SuccessResponse: Decodable {
        let ok: Bool?
    }

    private func get<T: Decodable>(path: String, query: [String: String] = [:]) async throws -> T {
        var components = URLComponents(string: "\(baseURL)\(path)")!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else {
            throw GitClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await fetchData(for: request)
        try checkResponse(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable, Body: Encodable>(path: String, body: Body) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw GitClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await fetchData(for: request)
        try checkResponse(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw GitClientError.toolboxUnavailable(error)
        }
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GitClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if let errorResp = try? decoder.decode(GitErrorResponse.self, from: data) {
                throw GitClientError.gitError(errorResp.error, stderr: errorResp.stderr)
            }
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GitClientError.httpError(http.statusCode, body)
        }
    }
}

/// Errors from the git client.
public enum GitClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case toolboxUnavailable(Error)
    case httpError(Int, String)
    case gitError(String, stderr: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid git endpoint URL"
        case .invalidResponse:
            "Invalid response from toolbox"
        case .toolboxUnavailable(let error):
            "impress-toolbox is not running: \(error.localizedDescription)"
        case .httpError(let code, let message):
            "Git request failed (\(code)): \(message)"
        case .gitError(let message, let stderr):
            if let stderr, !stderr.isEmpty {
                "Git error: \(message)\n\(stderr)"
            } else {
                "Git error: \(message)"
            }
        }
    }
}
