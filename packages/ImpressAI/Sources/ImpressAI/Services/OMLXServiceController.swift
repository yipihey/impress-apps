import Foundation
import ImpressLogging

#if os(macOS)
import AppKit
import Darwin
#endif

/// A service capable of asking the installed oMLX companion app to start its
/// managed inference server.
public protocol OMLXServiceStarting: Sendable {
    func startOMLX() async throws
}

/// Errors produced while handing local inference startup to oMLX.app.
public enum OMLXServiceControllerError: LocalizedError, Sendable {
    case applicationNotInstalled
    case controlUnavailable(String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .applicationNotInstalled:
            return "oMLX.app is not installed or registered with Launch Services"
        case .controlUnavailable(let detail):
            return "Could not ask oMLX.app to start its managed server: \(detail)"
        case .unsupportedPlatform:
            return "oMLX can only be started automatically on macOS"
        }
    }
}

/// Uses the same newline-delimited local control protocol as oMLX's bundled
/// `omlx start` command, without spawning a command-line process. If the menu
/// bar app is not running, the controller launches it through Launch Services
/// and then sends the start command. oMLX remains responsible for supervising
/// its Python server.
///
/// Concurrent requests in one Impress app process share a single launch. Each
/// app has its own instance of this actor; Launch Services and oMLX make repeat
/// launches across sibling app processes idempotent.
public actor OMLXServiceController: OMLXServiceStarting {
    public static let shared = OMLXServiceController()

    public typealias LaunchAction = @Sendable () async throws -> Void

    private let launchAction: LaunchAction
    private var launchTask: Task<Void, Error>?

    /// Creates the production controller backed by Launch Services.
    public init() {
        launchAction = { @Sendable in
            try await Self.startManagedServer()
        }
    }

    /// Creates a controller with an injected launcher, primarily for tests.
    public init(launchAction: @escaping LaunchAction) {
        self.launchAction = launchAction
    }

    public func startOMLX() async throws {
        if let launchTask {
            logInfo("Joining an in-flight oMLX launch request", category: "ai.local-service")
            try await launchTask.value
            return
        }

        let launchAction = self.launchAction
        let task = Task {
            try await launchAction()
        }
        launchTask = task

        do {
            logInfo("Requesting oMLX startup through Launch Services", category: "ai.local-service")
            try await task.value
            launchTask = nil
            logInfo("Launch Services accepted the oMLX startup request", category: "ai.local-service")
        } catch {
            launchTask = nil
            logError("oMLX launch failed: \(error.localizedDescription)", category: "ai.local-service")
            throw error
        }
    }

    private static func startManagedServer() async throws {
        #if os(macOS)
        do {
            let response = try await sendStartCommand()
            try validate(response)
            logInfo("oMLX accepted the managed server start command", category: "ai.local-service")
            return
        } catch {
            logInfo(
                "oMLX control socket is not ready; launching the companion app",
                category: "ai.local-service"
            )
        }

        try await launchInstalledApplication()

        let deadline = Date().addingTimeInterval(10)
        var lastError: Error?
        while Date() < deadline {
            do {
                let response = try await sendStartCommand()
                try validate(response)
                logInfo("oMLX accepted the managed server start command", category: "ai.local-service")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw OMLXServiceControllerError.controlUnavailable(
            lastError?.localizedDescription ?? "The control socket did not appear"
        )
        #else
        throw OMLXServiceControllerError.unsupportedPlatform
        #endif
    }

    #if os(macOS)
    private struct ControlResponse: Decodable, Sendable {
        let ok: Bool
        let message: String?
        let state: String?
        let port: Int?
    }

    private enum ControlError: LocalizedError, Sendable {
        case pathTooLong
        case socket(Int32)
        case connect(Int32)
        case write(Int32)
        case read(Int32)
        case emptyResponse
        case invalidResponse
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .pathTooLong: return "The oMLX control socket path is too long"
            case .socket(let code): return "Could not create a local socket (errno \(code))"
            case .connect(let code): return "Could not connect to oMLX (errno \(code))"
            case .write(let code): return "Could not send the oMLX command (errno \(code))"
            case .read(let code): return "Could not read the oMLX response (errno \(code))"
            case .emptyResponse: return "oMLX closed the control socket without a response"
            case .invalidResponse: return "oMLX returned an invalid control response"
            case .rejected(let message): return message
            }
        }
    }

    private static func sendStartCommand() async throws -> ControlResponse {
        try await Task.detached(priority: .userInitiated) {
            try sendControlCommand("start")
        }.value
    }

    private static func validate(_ response: ControlResponse) throws {
        guard response.ok else {
            throw ControlError.rejected(response.message ?? "oMLX rejected the start command")
        }
    }

    private nonisolated static func sendControlCommand(_ command: String) throws -> ControlResponse {
        let socketPath = try controlSocketPath()
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw ControlError.pathTooLong
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlError.socket(errno) }
        defer { Darwin.close(descriptor) }

        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let addressLength = socklen_t(
            MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count
        )
        address.sun_len = UInt8(addressLength)

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        guard connectResult == 0 else { throw ControlError.connect(errno) }

        let payload = Data("{\"command\":\"\(command)\"}\n".utf8)
        try payload.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let result = Darwin.send(
                    descriptor,
                    bytes.baseAddress!.advanced(by: sent),
                    bytes.count - sent,
                    0
                )
                guard result > 0 else { throw ControlError.write(errno) }
                sent += result
            }
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while responseData.count < 64 * 1024 {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw ControlError.read(errno) }
            responseData.append(contentsOf: buffer.prefix(count))
            if buffer.prefix(count).contains(0x0A) { break }
        }

        guard !responseData.isEmpty else { throw ControlError.emptyResponse }
        let line = responseData.split(separator: 0x0A, maxSplits: 1).first ?? responseData[...]
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: Data(line)) else {
            throw ControlError.invalidResponse
        }
        return response
    }

    private nonisolated static func controlSocketPath() throws -> String {
        guard let passwordEntry = getpwuid(getuid()),
              let homePointer = passwordEntry.pointee.pw_dir
        else {
            throw ControlError.invalidResponse
        }
        let homeDirectory = String(cString: homePointer)
        return homeDirectory + "/Library/Application Support/oMLX/control.sock"
    }
    #endif

    @MainActor
    private static func launchInstalledApplication() async throws {
        #if os(macOS)
        let registeredURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.omlx")
        let applicationURL = registeredURL ?? fallbackApplicationURLs().first(where: isOMLXApplication)
        guard let applicationURL else {
            throw OMLXServiceControllerError.applicationNotInstalled
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        )
        #else
        throw OMLXServiceControllerError.unsupportedPlatform
        #endif
    }

    #if os(macOS)
    private nonisolated static func fallbackApplicationURLs() -> [URL] {
        guard let passwordEntry = getpwuid(getuid()),
              let homePointer = passwordEntry.pointee.pw_dir
        else { return [URL(fileURLWithPath: "/Applications/oMLX.app")] }

        let home = URL(fileURLWithPath: String(cString: homePointer), isDirectory: true)
        return [
            URL(fileURLWithPath: "/Applications/oMLX.app", isDirectory: true),
            home.appendingPathComponent("Applications/oMLX.app", isDirectory: true),
            home.appendingPathComponent("MyApplications/oMLX.app", isDirectory: true),
        ]
    }

    private nonisolated static func isOMLXApplication(_ url: URL) -> Bool {
        Bundle(url: url)?.bundleIdentifier == "app.omlx"
    }
    #endif
}
