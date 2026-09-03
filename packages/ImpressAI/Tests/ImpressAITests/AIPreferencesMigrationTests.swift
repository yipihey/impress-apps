import XCTest
@testable import ImpressAI

/// The one-time move of the Swift selection into the Rust preferences file,
/// and the Rust-backed task-category storage.
final class AIPreferencesMigrationTests: XCTestCase {

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "ImpressAITests.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    func testImportsSharedDefaultsOnceAndRemovesTheKeys() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (standard, standardName) = try isolatedDefaults()
        defer { standard.removePersistentDomain(forName: standardName) }

        // The state found on the development Mac: the generic provider with
        // oMLX's helper pseudo-model selected.
        defaults.set("openai-compatible", forKey: "impressai.selectedProviderId")
        defaults.set("MarkItDown", forKey: "impressai.selectedModelId")
        defaults.set(false, forKey: "impressai.automaticallyStartOMLX")
        standard.set("openai", forKey: "impressai.selectedProvider")

        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx, FakeCatalogue.anthropic])
        let credentials = AICredentialManager(accessGroup: nil)
        let imported = await AIPreferencesMigration.runIfNeeded(
            bridge: bridge,
            credentials: credentials,
            defaults: defaults,
            standardDefaults: standard
        )

        let preferences = try XCTUnwrap(imported)
        XCTAssertTrue(preferences.migratedFromSharedDefaults)
        XCTAssertEqual(preferences.selected?.providerId, "omlx")
        XCTAssertNil(preferences.selected?.modelId, "the helper model is dropped")
        XCTAssertFalse(preferences.autoStartOMLX)
        XCTAssertNil(defaults.string(forKey: "impressai.selectedProviderId"))
        XCTAssertNil(defaults.string(forKey: "impressai.selectedModelId"))
        XCTAssertNil(defaults.object(forKey: "impressai.automaticallyStartOMLX"))
        XCTAssertNil(standard.string(forKey: "impressai.selectedProvider"))

        // A second run is a no-op even if stale keys reappear.
        defaults.set("anthropic", forKey: "impressai.selectedProviderId")
        let again = await AIPreferencesMigration.runIfNeeded(
            bridge: bridge,
            credentials: credentials,
            defaults: defaults,
            standardDefaults: standard
        )
        XCTAssertEqual(again?.selected?.providerId, "omlx")
        XCTAssertEqual(defaults.string(forKey: "impressai.selectedProviderId"), "anthropic", "nothing is touched after the first import")
    }

    func testNothingStoredStillMarksTheImportDone() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx])
        let imported = await AIPreferencesMigration.runIfNeeded(
            bridge: bridge,
            credentials: AICredentialManager(accessGroup: nil),
            defaults: defaults,
            standardDefaults: defaults
        )
        XCTAssertEqual(imported?.migratedFromSharedDefaults, true)
        XCTAssertNil(imported?.selected)
    }

    func testRustBackedCategoryStorageRoundTrips() async throws {
        let bridge = FakeAIBridge(descriptors: [FakeCatalogue.omlx, FakeCatalogue.anthropic])
        let storage = RustAITaskCategoryStorage(bridge: bridge)
        let manager = AITaskCategoryManager(storage: storage)
        await manager.loadAssignments()
        let reference = AIModelReference(providerId: "anthropic", modelId: "claude-sonnet-5", displayName: "Claude Sonnet 5")
        await manager.setPrimaryModel(reference, for: "research.rag")
        // setAssignment saves on a detached task; flush by saving explicitly.
        await manager.saveAssignments()

        let stored = try await bridge.preferences().taskAssignments["research.rag"]
        XCTAssertEqual(stored?.primaryModel, reference)

        let fresh = AITaskCategoryManager(storage: RustAITaskCategoryStorage(bridge: bridge))
        await fresh.loadAssignments()
        let primary = await fresh.primaryModel(for: "research.rag")
        XCTAssertEqual(primary, reference)

        await fresh.setPrimaryModel(nil, for: "research.rag")
        await fresh.saveAssignments()
        let cleared = try await bridge.preferences().taskAssignments["research.rag"]
        XCTAssertNil(cleared?.primaryModel)
    }
}
