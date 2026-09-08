import Foundation
import XCTest
@testable import ImpressAI

/// The manager as a projection over the Rust registry (ADR-0029 S2).
final class AIProviderManagerTests: XCTestCase {
    private func makeManager(bridge: FakeAIBridge) -> AIProviderManager {
        AIProviderManager(
            bridge: bridge,
            credentialManager: AICredentialManager(accessGroup: nil),
            hostLauncher: FakeHostLauncher(),
            defaults: UserDefaults(suiteName: "impressai.manager-tests.\(UUID().uuidString)")!
        )
    }

    func testRegistersTheCatalogueInRustOrderWithAppleExecutedNatively() async {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx, FakeCatalogue.apple, FakeCatalogue.anthropic])
        let manager = makeManager(bridge: bridge)

        await manager.registerBuiltInProviders()

        let ids = await manager.allProviderMetadata.map(\.id)
        XCTAssertEqual(ids, ["omlx", "apple-on-device", "anthropic"])
        let omlx = await manager.provider(for: "omlx")
        XCTAssertTrue(omlx is RustBridgedAIProvider)
        let apple = await manager.provider(for: "apple-on-device")
        XCTAssertTrue(apple is AppleFoundationModelsProvider)
        let registryAvailable = await manager.registryAvailable
        XCTAssertTrue(registryAvailable)
    }

    func testRegistrationIsIdempotent() async {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        let manager = makeManager(bridge: bridge)

        await manager.registerBuiltInProviders()
        await manager.registerBuiltInProviders()

        let count = await manager.allProviders.count
        XCTAssertEqual(count, 1)
    }

    func testWithoutASelectionTheResolvedTargetIsTheFirstReadyProvider() async {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx, FakeCatalogue.anthropic])
        await bridge.setHealth(FakeCatalogue.omlxReady, for: "omlx")
        await bridge.setModels(FakeCatalogue.omlxModels, for: "omlx")
        let manager = makeManager(bridge: bridge)

        await manager.registerBuiltInProviders()

        let selected = await manager.defaultProviderId
        XCTAssertNil(selected, "nothing is pinned until the user picks")
        let resolved = await manager.resolvedProviderId
        XCTAssertEqual(resolved, "omlx")
        let origin = await manager.resolutionOrigin
        XCTAssertEqual(origin, "first_ready")
        let effective = await manager.effectiveDefaultProvider()
        XCTAssertEqual(effective?.metadata.id, "omlx")
        let stored = await bridge.stored
        XCTAssertNil(stored.selected, "resolution never writes the preferences file")
    }

    func testSelectionWritesThroughTheBridgeAndResolutionFollows() async {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx, FakeCatalogue.anthropic])
        await bridge.setHealth(FakeCatalogue.omlxReady, for: "omlx")
        await bridge.setModels(FakeCatalogue.omlxModels, for: "omlx")
        let manager = makeManager(bridge: bridge)
        await manager.registerBuiltInProviders()

        await manager.setDefaultProviderId("anthropic")

        let stored = await bridge.stored
        XCTAssertEqual(stored.selected?.providerId, "anthropic")
        XCTAssertNil(stored.selected?.modelId, "picking a provider resets the model to its default")
        let resolvedProvider = await manager.resolvedProviderId
        XCTAssertEqual(resolvedProvider, "anthropic")
        let origin = await manager.resolutionOrigin
        XCTAssertEqual(origin, "selected")

        await manager.setDefaultModelId("claude-sonnet-5")

        let pinned = await bridge.stored.selected
        XCTAssertEqual(pinned?.providerId, "anthropic")
        XCTAssertEqual(pinned?.modelId, "claude-sonnet-5")
        let effective = await manager.effectiveDefaultProvider()
        XCTAssertEqual(effective?.metadata.id, "anthropic")
        let model = await manager.effectiveDefaultModel()
        XCTAssertEqual(model?.id, "claude-sonnet-5")
    }

    func testAHelperModelIsRejectedAndNothingIsKeptLocally() async {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        await bridge.setHealth(FakeCatalogue.omlxReady, for: "omlx")
        await bridge.setModels(FakeCatalogue.omlxModels, for: "omlx")
        let manager = makeManager(bridge: bridge)
        await manager.registerBuiltInProviders()
        await manager.setDefaultProviderId("omlx")
        guard let helper = FakeCatalogue.omlxModels.first(where: { $0.isHelper }) else {
            return XCTFail("fixture needs a helper model")
        }

        await manager.setDefaultModelId(helper.id)

        let stored = await bridge.stored
        XCTAssertEqual(stored.selected?.providerId, "omlx")
        XCTAssertNil(stored.selected?.modelId)
        let local = await manager.defaultModelId
        XCTAssertNil(local, "a rejected pick must not survive as an in-memory selection")
    }

    func testAnUnavailableRegistryStillRegistersOnDeviceModels() async {
        let manager = AIProviderManager(
            bridge: RustAIBridge(workspaceDirectory: URL(fileURLWithPath: "/nonexistent/impress-tests")),
            credentialManager: AICredentialManager(accessGroup: nil),
            hostLauncher: FakeHostLauncher(),
            defaults: UserDefaults(suiteName: "impressai.manager-tests.\(UUID().uuidString)")!
        )

        await manager.registerBuiltInProviders()

        let ids = await manager.allProviderMetadata.map(\.id)
        XCTAssertTrue(ids.contains("apple-on-device"))
        let registryAvailable = await manager.registryAvailable
        // The stub bridge (no ImpressRustCore) and a missing workspace both
        // report unavailable; either way on-device stays registered.
        XCTAssertFalse(registryAvailable && ids.count == 1)
    }

    func testModelsForABridgedProviderComeFromDiscoveryWithoutHelpers() async throws {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        await bridge.setHealth(FakeCatalogue.omlxReady, for: "omlx")
        await bridge.setModels(FakeCatalogue.omlxModels, for: "omlx")
        let manager = makeManager(bridge: bridge)
        await manager.registerBuiltInProviders()

        let visible = try await manager.models(for: "omlx")
        let all = try await manager.models(for: "omlx", includeHelpers: true)

        XCTAssertFalse(visible.contains { $0.isHelper })
        XCTAssertEqual(all.count, FakeCatalogue.omlxModels.count)
        let health = await manager.health(for: "omlx")
        XCTAssertEqual(health?.serverVersion, "0.6.4")
    }
}

/// `AISettings` is a view of the registry: opening it changes nothing.
final class AISettingsProjectionTests: XCTestCase {
    private func makeStack() async -> (FakeAIBridge, AIProviderManager) {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx, FakeCatalogue.anthropic])
        await bridge.setHealth(FakeCatalogue.omlxReady, for: "omlx")
        await bridge.setModels(FakeCatalogue.omlxModels, for: "omlx")
        let manager = AIProviderManager(
            bridge: bridge,
            credentialManager: AICredentialManager(accessGroup: nil),
            hostLauncher: FakeHostLauncher(),
            defaults: UserDefaults(suiteName: "impressai.settings-tests.\(UUID().uuidString)")!
        )
        return (bridge, manager)
    }

    @MainActor
    func testLoadNeverPersistsASelection() async {
        let (bridge, manager) = await makeStack()
        let settings = AISettings(providerManager: manager, credentialManager: AICredentialManager(accessGroup: nil))

        await settings.load()

        XCTAssertNil(settings.selectedProviderId)
        XCTAssertEqual(settings.displayedProviderId, "omlx")
        XCTAssertEqual(settings.resolutionOrigin, "first_ready")
        XCTAssertFalse(settings.availableModels.contains { $0.isHelper })
        XCTAssertGreaterThan(settings.allModels.count, settings.availableModels.count, "helpers are listed but separated")
        XCTAssertTrue(settings.isProviderReady)
        let stored = await bridge.stored
        XCTAssertNil(stored.selected, "opening the pane wrote nothing")
        XCTAssertFalse(settings.selectionSummary.isEmpty)
        XCTAssertFalse(settings.selectionSummary.contains("MarkItDown"))
    }

    @MainActor
    func testPickingAProviderInTheUIWritesThroughTheBridge() async throws {
        let (bridge, manager) = await makeStack()
        let settings = AISettings(providerManager: manager, credentialManager: AICredentialManager(accessGroup: nil))
        await settings.load()

        settings.selectedProviderId = "anthropic"

        var written: AIModelSelection?
        for _ in 0..<100 {
            written = await bridge.stored.selected
            if written != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(written?.providerId, "anthropic")
        XCTAssertEqual(settings.selectedProviderId, "anthropic")
        XCTAssertEqual(settings.displayedProviderId, "anthropic")
    }
}
