//
//  AppleFoundationModelsProvider.swift
//  ImpressAI
//
//  On-device Apple Intelligence provider (FoundationModels). Keyless, private,
//  free, offline. Available on macOS 26+/iOS 26+ when Apple Intelligence is
//  enabled; elsewhere `isAvailable` is false and calls throw
//  `providerNotConfigured`, so callers can fall back to a cloud provider.
//
//  The type is intentionally NOT `@available`-gated so it can be stored and
//  referenced unconditionally across the shared package; every FoundationModels
//  call is guarded by `#if canImport(FoundationModels)` + a runtime `#available`
//  check. For plain-text generation we flatten the request into a single prompt
//  (the proven imbib pattern) rather than using `@Generable` schemas.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Provider ID used across the app for the on-device Apple model.
public let appleOnDeviceProviderId = "apple-on-device"

/// On-device Apple Intelligence provider.
public struct AppleFoundationModelsProvider: AIProvider {

    public init() {}

    public let metadata = AIProviderMetadata(
        id: appleOnDeviceProviderId,
        name: "Apple Intelligence (on-device)",
        description: "Private, on-device model — no API key, works offline.",
        models: [
            AIModel(
                id: appleOnDeviceProviderId,
                name: "Apple Intelligence",
                description: "On-device Apple foundation model",
                contextWindow: 8_000,
                maxOutputTokens: 4_000,
                isDefault: true,
                capabilities: [.streaming, .systemPrompt]
            )
        ],
        capabilities: [.streaming, .systemPrompt],
        credentialRequirement: .none,
        category: .local,
        registrationURL: nil,
        rateLimit: nil,
        iconName: "apple.logo"
    )

    /// Whether Apple Intelligence is available on this device right now.
    public nonisolated var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
        #else
        return false
        #endif
    }

    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard SystemLanguageModel.default.isAvailable else { throw Self.unavailableError }
            let prompt = Self.buildPrompt(request)
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: Prompt(prompt))
                return AICompletionResponse(
                    id: UUID().uuidString,
                    content: [.text(response.content)],
                    model: appleOnDeviceProviderId,
                    finishReason: .stop,
                    usage: nil
                )
            } catch {
                throw AIError.from(error)
            }
        }
        #endif
        throw Self.unavailableError
    }

    public func validate() async throws -> AIProviderStatus {
        isAvailable ? .ready : .unavailable(reason: "Apple Intelligence is not available on this device.")
    }

    // NOTE: `stream` intentionally uses the AIProvider protocol's default
    // (wraps `complete` into a single chunk). The FoundationModels streaming
    // API can be adopted here later for token-by-token output.

    // MARK: - Private

    private static var unavailableError: AIError {
        .providerNotConfigured("Apple Intelligence is not available on this device (needs macOS 26+/iOS 26+ with Apple Intelligence enabled).")
    }

    /// Flatten a request into a single prompt: system prompt first, then the
    /// non-system message text. Matches imbib's FoundationModelsService usage.
    private static func buildPrompt(_ request: AICompletionRequest) -> String {
        var parts: [String] = []
        if let system = request.systemPrompt, !system.isEmpty {
            parts.append(system)
        } else if let systemMessage = request.messages.first(where: { $0.role == .system }) {
            parts.append(systemMessage.text)
        }
        let body = request.messages
            .filter { $0.role != .system }
            .map { $0.text }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !body.isEmpty { parts.append(body) }
        return parts.joined(separator: "\n\n")
    }
}
