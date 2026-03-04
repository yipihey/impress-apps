import Testing
@testable import ImpressEmbeddings
import Foundation

/// A mock embedding provider for testing.
actor MockEmbeddingProvider: EmbeddingProvider {
    nonisolated let id: String
    nonisolated let embeddingDimension: Int
    nonisolated let supportsLocal: Bool
    nonisolated let estimatedMsPerEmbedding: Double

    var embedCallCount = 0

    init(id: String = "mock", dimension: Int = 384) {
        self.id = id
        self.embeddingDimension = dimension
        self.supportsLocal = true
        self.estimatedMsPerEmbedding = 1.0
    }

    func embed(_ text: String) async throws -> [Float] {
        await incrementCallCount()
        // Deterministic mock: hash the text into a vector
        var vector = [Float](repeating: 0, count: embeddingDimension)
        for (i, char) in text.unicodeScalars.enumerated() {
            vector[i % embeddingDimension] += Float(char.value) / 10000.0
        }
        // Normalize
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            vector = vector.map { $0 / norm }
        }
        return vector
    }

    private func incrementCallCount() {
        embedCallCount += 1
    }
}

@Suite("EmbeddingProviderRegistry")
struct ProviderRegistryTests {

    @Test("First registered provider becomes active")
    func firstIsActive() async {
        let registry = EmbeddingProviderRegistry()
        let provider = MockEmbeddingProvider(id: "test-a")
        await registry.register(provider)

        let active = await registry.activeProvider
        #expect(active?.id == "test-a")
    }

    @Test("Can switch active provider")
    func switchProvider() async throws {
        let registry = EmbeddingProviderRegistry()
        await registry.register(MockEmbeddingProvider(id: "a", dimension: 384))
        await registry.register(MockEmbeddingProvider(id: "b", dimension: 768))

        try await registry.setActiveProvider("b")
        let active = await registry.activeProvider
        #expect(active?.id == "b")
        let dim = await registry.activeDimension
        #expect(dim == 768)
    }

    @Test("Switching to unregistered provider throws")
    func unregisteredThrows() async {
        let registry = EmbeddingProviderRegistry()
        await registry.register(MockEmbeddingProvider(id: "a"))

        do {
            try await registry.setActiveProvider("nonexistent")
            #expect(Bool(false), "Should have thrown")
        } catch {
            #expect(error is EmbeddingError)
        }
    }

    @Test("Available providers lists all registered")
    func listProviders() async {
        let registry = EmbeddingProviderRegistry()
        await registry.register(MockEmbeddingProvider(id: "alpha"))
        await registry.register(MockEmbeddingProvider(id: "beta"))

        let providers = await registry.availableProviders()
        #expect(providers.count == 2)
        #expect(providers.map(\.id).contains("alpha"))
        #expect(providers.map(\.id).contains("beta"))
    }
}
