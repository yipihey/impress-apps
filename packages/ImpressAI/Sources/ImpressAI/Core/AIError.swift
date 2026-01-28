import Foundation

/// Errors that can occur when using AI providers.
public enum AIError: LocalizedError, Sendable {
    /// Network connectivity or communication failure.
    case networkError(underlying: Error)

    /// API returned an error response.
    case apiError(statusCode: Int, message: String)

    /// Request was rejected due to rate limiting.
    case rateLimited(retryAfter: TimeInterval?)

    /// Authentication failed (invalid or missing credentials).
    case unauthorized(message: String)

    /// The requested provider was not found.
    case providerNotFound(String)

    /// The requested model was not found or not available.
    case modelNotFound(String)

    /// The provider is not configured properly.
    case providerNotConfigured(String)

    /// The request was invalid.
    case invalidRequest(String)

    /// Response parsing failed.
    case parseError(String)

    /// Content was filtered by safety systems.
    case contentFiltered(String)

    /// The operation was cancelled.
    case cancelled

    /// The context window was exceeded.
    case contextLengthExceeded(limit: Int, requested: Int)

    /// Credential storage or retrieval failed.
    case credentialError(String)

    /// An unknown error occurred.
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .apiError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        case .rateLimited(let retryAfter):
            if let retryAfter = retryAfter {
                return "Rate limited. Please retry after \(Int(retryAfter)) seconds."
            }
            return "Rate limited. Please try again later."
        case .unauthorized(let message):
            return "Authentication failed: \(message)"
        case .providerNotFound(let id):
            return "Provider not found: \(id)"
        case .modelNotFound(let id):
            return "Model not found: \(id)"
        case .providerNotConfigured(let message):
            return "Provider not configured: \(message)"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        case .parseError(let message):
            return "Failed to parse response: \(message)"
        case .contentFiltered(let message):
            return "Content filtered: \(message)"
        case .cancelled:
            return "Operation was cancelled"
        case .contextLengthExceeded(let limit, let requested):
            return "Context length exceeded (limit: \(limit), requested: \(requested))"
        case .credentialError(let message):
            return "Credential error: \(message)"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .networkError:
            return "Check your internet connection and try again."
        case .apiError:
            return "Check the API documentation for this error code."
        case .rateLimited:
            return "Wait before making additional requests."
        case .unauthorized:
            return "Verify your API key is correct in Settings."
        case .providerNotFound:
            return "Ensure the provider is registered with AIProviderManager."
        case .modelNotFound:
            return "Select a valid model from the provider's available models."
        case .providerNotConfigured:
            return "Configure the provider's credentials in Settings."
        case .invalidRequest:
            return "Check your request parameters."
        case .parseError:
            return "This may be a temporary issue. Try again."
        case .contentFiltered:
            return "Modify your request to comply with content policies."
        case .cancelled:
            return nil
        case .contextLengthExceeded:
            return "Reduce the length of your messages or start a new conversation."
        case .credentialError:
            return "Re-enter your credentials in Settings."
        case .unknown:
            return "Try again or contact support if the issue persists."
        }
    }

    /// Whether this error is retryable.
    public var isRetryable: Bool {
        switch self {
        case .networkError, .rateLimited, .parseError:
            return true
        case .apiError(let statusCode, _):
            return statusCode >= 500 || statusCode == 429
        default:
            return false
        }
    }

    /// Suggested retry delay if the error is retryable.
    public var suggestedRetryDelay: TimeInterval? {
        switch self {
        case .rateLimited(let retryAfter):
            return retryAfter ?? 60
        case .networkError:
            return 5
        case .apiError(let statusCode, _) where statusCode >= 500:
            return 10
        default:
            return nil
        }
    }
}

/// Extension to wrap any Error into an AIError.
public extension AIError {
    /// Creates an AIError from any Error.
    static func from(_ error: Error) -> AIError {
        if let aiError = error as? AIError {
            return aiError
        }
        if let urlError = error as? URLError {
            return .networkError(underlying: urlError)
        }
        return .unknown(error.localizedDescription)
    }
}
