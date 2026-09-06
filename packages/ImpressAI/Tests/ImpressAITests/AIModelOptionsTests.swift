import XCTest
@testable import ImpressAI

/// The rules every model picker in the suite obeys. Pure, so they hold
/// without a registry, a host or a network.
final class AIModelOptionsTests: XCTestCase {
    private func provider(
        _ id: String,
        _ name: String,
        category: AIProviderCategory = .cloud,
        models: [AIModel] = []
    ) -> AIProviderMetadata {
        AIProviderMetadata(
            id: id,
            name: name,
            models: models,
            capabilities: .chat,
            credentialRequirement: .none,
            category: category
        )
    }

    private let omlxModels = [
        AIModel(id: "mlx-community--Qwen3.5-4B-4bit", name: "Qwen3.5 4B 4bit"),
        AIModel(id: "MarkItDown", name: "MarkItDown", isHelper: true),
    ]

    func testADiscoveryOnlyHostIsListedFromWhatItServes() {
        // oMLX declares no static models; before AIModelOptions it could
        // therefore never appear in a picker.
        let groups = AIModelOptions.groups(
            providers: [provider("omlx", "oMLX", category: .local)],
            readiness: ["omlx": .ready],
            discovered: ["omlx": omlxModels]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].models.map(\.modelId), ["mlx-community--Qwen3.5-4B-4bit"])
        XCTAssertTrue(groups[0].isDiscovered)
        XCTAssertNil(groups[0].setupHint)
    }

    func testHelperModelsAreNeverOffered() {
        let groups = AIModelOptions.groups(
            providers: [provider("omlx", "oMLX", category: .local)],
            readiness: ["omlx": .ready],
            discovered: ["omlx": omlxModels]
        )
        XCTAssertFalse(groups.flatMap(\.models).contains { $0.modelId == "MarkItDown" })
    }

    func testUsableProvidersComeFirstAndUnconfiguredOnesCarryTheReason() {
        let groups = AIModelOptions.groups(
            providers: [
                provider("anthropic", "Claude (Anthropic)", models: [AIModel(id: "claude-opus-5", name: "Claude Opus 5")]),
                provider("omlx", "oMLX", category: .local),
                provider("apple-on-device", "Apple Intelligence", category: .local, models: [AIModel(id: "apple", name: "On-device")]),
            ],
            readiness: ["anthropic": .needsCredentials, "omlx": .ready, "apple-on-device": .foreign],
            discovered: ["omlx": omlxModels]
        )

        XCTAssertEqual(groups.map(\.providerId), ["omlx", "apple-on-device", "anthropic"])
        XCTAssertEqual(groups.last?.setupHint, "needs an API key")
        XCTAssertEqual(groups.last?.sectionTitle, "Claude (Anthropic) — needs an API key")
        XCTAssertTrue(groups[0].isUsable)
        XCTAssertTrue(groups[1].isUsable, "Apple on-device is executed by the host, not the registry")
    }

    func testAProviderWithNoModelsIsDropped() {
        let groups = AIModelOptions.groups(
            providers: [provider("openai-compatible", "Other OpenAI-compatible server", category: .local)],
            readiness: ["openai-compatible": .needsEndpoint]
        )
        XCTAssertTrue(groups.isEmpty, "an empty section is noise, not information")
    }

    func testAnAssignmentSurvivesItsHostGoingOffline() {
        // oMLX quit: it has no static models, so its group is gone — but the
        // category still points at one of its models.
        let assigned = AIModelReference(
            providerId: "omlx",
            modelId: "mlx-community--Qwen3.5-4B-4bit",
            displayName: "oMLX - Qwen3.5 4B 4bit"
        )
        let live = AIModelOptions.groups(
            providers: [provider("anthropic", "Claude (Anthropic)", models: [AIModel(id: "claude-opus-5", name: "Claude Opus 5")])],
            readiness: ["anthropic": .ready]
        )

        let preserved = AIModelOptions.groups(live, including: assigned)

        XCTAssertEqual(preserved.count, 2)
        XCTAssertEqual(preserved.last?.models, [assigned])
        XCTAssertEqual(preserved.last?.sectionTitle, "oMLX — not running")
        XCTAssertEqual(
            AIModelOptions.groups(live, including: nil).count, 1,
            "nothing is added when nothing is assigned")
    }

    func testAReferenceKnowsItsModelHalfForProviderGroupedPickers() {
        let reference = AIModelReference(
            providerId: "omlx",
            modelId: "mlx-community--Qwen3.5-4B-4bit",
            displayName: "oMLX - Qwen3.5 4B 4bit"
        )
        XCTAssertEqual(reference.modelName, "Qwen3.5 4B 4bit")
        let bare = AIModelReference(providerId: "x", modelId: "y", displayName: "Solo")
        XCTAssertEqual(bare.modelName, "Solo", "a name without the provider prefix is left alone")
    }

    func testAnUnknownProviderIsTreatedAsUnreachableRatherThanUsable() {
        let groups = AIModelOptions.groups(
            providers: [provider("mystery", "Mystery", models: [AIModel(id: "m", name: "M")])],
            readiness: [:]
        )
        XCTAssertEqual(groups.first?.setupHint, "not running")
        XCTAssertFalse(groups.first?.isUsable ?? true)
    }
}
