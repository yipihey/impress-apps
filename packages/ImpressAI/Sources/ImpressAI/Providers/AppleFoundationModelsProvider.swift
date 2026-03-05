//
//  AppleFoundationModelsProvider.swift
//  ImpressAI
//
//  AI provider using Apple Intelligence (FoundationModels framework, macOS 26+).
//  Provides on-device text generation with no API keys, no network, and no cost.
//

import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.impress.ai", category: "AppleFoundationModels")

// MARK: - Apple Foundation Models Provider

/// AI provider backed by Apple Intelligence (on-device language model).
///
/// Uses the `FoundationModels` framework introduced in macOS 26 / iOS 26.
/// Requires Apple Intelligence to be enabled on the device.
///
/// - No API keys needed
/// - No network required
/// - Private: all inference runs on-device
@available(macOS 26, iOS 26, *)
public actor AppleFoundationModelsProvider: AIProvider {

    // MARK: - AIProvider conformance

    public nonisolated var metadata: AIProviderMetadata {
        AIProviderMetadata(
            id: "apple-foundation-models",
            name: "Apple Intelligence",
            description: "On-device AI powered by Apple Intelligence. No API key required.",
            models: [
                AIModel(
                    id: "apple-on-device",
                    name: "On-Device Model",
                    description: "Apple's on-device language model",
                    contextWindow: 4096,
                    maxOutputTokens: 1024,
                    isDefault: true
                )
            ],
            capabilities: [.systemPrompt],
            credentialRequirement: .none,
            category: .local,
            iconName: "apple.logo"
        )
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - AIProvider

    public func complete(_ request: AICompletionRequest) async throws -> AICompletionResponse {
        let prompt = buildPrompt(from: request)
        let responseText = try await generateOnDevice(prompt: prompt)
        return AICompletionResponse(
            id: UUID().uuidString,
            content: [.text(responseText)],
            model: "apple-on-device",
            finishReason: .stop
        )
    }

    public func validate() async throws -> AIProviderStatus {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else {
            return .unavailable(reason: "Apple Intelligence is not available on this device or region")
        }
        return .ready
        #else
        return .unavailable(reason: "FoundationModels framework not available on this SDK")
        #endif
    }

    // MARK: - Availability

    /// Whether Apple Intelligence is available on this device.
    public static var isAppleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.isAvailable
        #else
        return false
        #endif
    }

    // MARK: - Private

    private func generateOnDevice(prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        let session = LanguageModelSession()
        let response = try await session.respond(to: Prompt(prompt))
        return response.content
        #else
        throw AIError.providerNotConfigured("FoundationModels framework is not available")
        #endif
    }

    private func buildPrompt(from request: AICompletionRequest) -> String {
        var parts: [String] = []

        if let system = request.systemPrompt, !system.isEmpty {
            parts.append(system)
        }

        for message in request.messages {
            let text = message.text
            if !text.isEmpty {
                parts.append(text)
            }
        }

        return parts.joined(separator: "\n\n")
    }
}
