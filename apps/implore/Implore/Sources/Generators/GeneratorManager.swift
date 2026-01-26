import Foundation
import ImploreCore

/// Thread-safe actor for managing the generator registry.
///
/// This actor wraps the Rust GeneratorRegistryHandle and provides
/// a Swift-friendly async API for generator operations.
@MainActor
public final class GeneratorManager: ObservableObject {
    /// Shared instance for app-wide access
    public static let shared = GeneratorManager()

    /// The underlying Rust registry handle
    private let registry: GeneratorRegistryHandle

    /// Published list of all available generators
    @Published public private(set) var generators: [GeneratorMetadata] = []

    /// Published list of categories with generators
    @Published public private(set) var categories: [GeneratorCategory] = []

    /// Currently selected generator
    @Published public var selectedGenerator: GeneratorMetadata?

    /// Error from last operation
    @Published public var lastError: GeneratorErrorFfi?

    /// Whether a generation is in progress
    @Published public private(set) var isGenerating: Bool = false

    public init() {
        self.registry = GeneratorRegistryHandle()
        loadGenerators()
    }

    /// Load all generators from the registry
    private func loadGenerators() {
        generators = registry.listAll()
        categories = registry.categories()
    }

    /// List generators in a specific category
    public func generators(in category: GeneratorCategory) -> [GeneratorMetadata] {
        return registry.listByCategory(category: category)
    }

    /// Get metadata for a specific generator
    public func metadata(for generatorId: String) -> GeneratorMetadata? {
        return registry.getMetadata(generatorId: generatorId)
    }

    /// Search generators by name or description
    public func search(_ query: String) -> [GeneratorMetadata] {
        return registry.search(query: query)
    }

    /// Get default parameters for a generator as JSON
    public func defaultParams(for generatorId: String) -> String? {
        do {
            return try registry.defaultParamsJson(generatorId: generatorId)
        } catch {
            lastError = error as? GeneratorErrorFfi
            return nil
        }
    }

    /// Generate data using the specified generator and parameters
    public func generate(
        generatorId: String,
        paramsJson: String = "{}"
    ) async -> GeneratedDataFfi? {
        isGenerating = true
        defer { isGenerating = false }

        do {
            let data = try registry.generate(generatorId: generatorId, paramsJson: paramsJson)
            lastError = nil
            return data
        } catch {
            lastError = error as? GeneratorErrorFfi
            return nil
        }
    }

    /// Select a generator by ID
    public func select(generatorId: String) {
        selectedGenerator = metadata(for: generatorId)
    }

    /// Clear the current selection
    public func clearSelection() {
        selectedGenerator = nil
    }

    /// Get the total count of registered generators
    public var count: Int {
        return Int(registry.count())
    }
}

// MARK: - Extensions for SwiftUI binding

extension GeneratorManager {
    /// Binding for selected generator ID
    public var selectedGeneratorId: String? {
        get { selectedGenerator?.id }
        set {
            if let id = newValue {
                select(generatorId: id)
            } else {
                clearSelection()
            }
        }
    }
}
