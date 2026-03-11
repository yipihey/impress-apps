import Foundation
import ImpressLogging
import OSLog

/// HTTP client for communicating with the impress-toolbox server.
public actor ToolboxClient {
    public static let shared = ToolboxClient()
    public static let defaultPort: UInt16 = 23119

    private let baseURL: String
    private let session: URLSession

    public init(port: UInt16 = defaultPort) {
        self.baseURL = "http://127.0.0.1:\(port)"
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 310 // slightly above max server timeout (300s)
        config.timeoutIntervalForResource = 310
        self.session = URLSession(configuration: config)
    }

    // MARK: - Health Check

    /// Check if the toolbox server is reachable.
    public func isAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Execute

    /// Execute a process via the toolbox server.
    public func execute(_ request: ProcessRequest) async throws -> ProcessResult {
        let data = try await post(path: "/execute", body: request)
        do {
            return try JSONDecoder().decode(ProcessResult.self, from: data)
        } catch {
            throw ToolboxError.decodingError(error)
        }
    }

    /// Execute a process and retrieve an output file.
    ///
    /// If the process exits non-zero, returns the ProcessResult with nil data.
    /// If the process succeeds, returns the file data.
    public func executeAndRetrieveFile(
        _ request: ProcessRequest,
        outputFile: String
    ) async throws -> (ProcessResult, Data?) {
        // Build combined request
        struct FileRequest: Encodable {
            let id: String?
            let executable: String
            let arguments: [String]
            let working_directory: String?
            let environment: [String: String]
            let timeout_ms: Int?
            let output_file: String
        }

        let fileReq = FileRequest(
            id: request.id,
            executable: request.executable,
            arguments: request.arguments,
            working_directory: request.workingDirectory,
            environment: request.environment,
            timeout_ms: request.timeoutMs,
            output_file: outputFile
        )

        let body = try JSONEncoder().encode(fileReq)

        guard let url = URL(string: "\(baseURL)/execute/file") else {
            throw ToolboxError.serverUnavailable
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ToolboxError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolboxError.requestFailed(statusCode: 0, message: "Invalid response")
        }

        let exitCodeStr = httpResponse.value(forHTTPHeaderField: "X-Toolbox-Exit-Code") ?? "-1"
        let durationStr = httpResponse.value(forHTTPHeaderField: "X-Toolbox-Duration-Ms") ?? "0"
        let exitCode = Int32(exitCodeStr) ?? -1
        let durationMs = Int(durationStr) ?? 0

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

        if contentType.contains("application/json") {
            // Process failed — response body is the JSON result
            let result = try JSONDecoder().decode(ProcessResult.self, from: data)
            return (result, nil)
        } else {
            // Process succeeded — response body is the file data
            let result = ProcessResult(
                id: request.id,
                exitCode: exitCode,
                stdout: "",
                stderr: httpResponse.value(forHTTPHeaderField: "X-Toolbox-Stderr") ?? "",
                durationMs: durationMs,
                timedOut: false
            )
            return (result, data)
        }
    }

    // MARK: - Discover

    /// Discover executables on disk.
    public func discover(
        names: [String],
        searchPaths: [String] = []
    ) async throws -> DiscoveryResult {
        let req = DiscoverRequest(names: names, searchPaths: searchPaths)
        let data = try await post(path: "/discover", body: req)
        do {
            return try JSONDecoder().decode(DiscoveryResult.self, from: data)
        } catch {
            throw ToolboxError.decodingError(error)
        }
    }

    // MARK: - Internal HTTP

    private func post<T: Encodable>(path: String, body: T) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw ToolboxError.serverUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ToolboxError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolboxError.requestFailed(statusCode: 0, message: "Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ToolboxError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        return data
    }
}
