import Foundation

/// Errors from the toolbox client.
public enum ToolboxError: LocalizedError {
    case serverUnavailable
    case requestFailed(statusCode: Int, message: String)
    case networkError(Error)
    case decodingError(Error)
    case outputFileNotReturned

    public var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            "impress-toolbox server is not running. Start it with: impress-toolbox"
        case .requestFailed(let code, let message):
            "Toolbox request failed (\(code)): \(message)"
        case .networkError(let error):
            "Network error communicating with toolbox: \(error.localizedDescription)"
        case .decodingError(let error):
            "Failed to decode toolbox response: \(error.localizedDescription)"
        case .outputFileNotReturned:
            "Toolbox did not return the expected output file"
        }
    }
}
