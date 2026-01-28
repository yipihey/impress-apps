import Foundation
import ImploreCore
import SwiftUI
import Combine

/// Coordinator view model for generator-related UI state.
///
/// This view model connects the GeneratorManager with the form state
/// and provides the primary interface for generator-related views.
@MainActor
public final class GeneratorViewModel: ObservableObject {
    /// The generator manager instance
    @Published public private(set) var manager: GeneratorManager

    /// Form state for the currently selected generator
    @Published public private(set) var formState: GeneratorFormState

    /// The most recently generated data
    @Published public private(set) var generatedData: GeneratedDataFfi?

    /// Whether generation is in progress
    @Published public private(set) var isGenerating: Bool = false

    /// Error message to display
    @Published public var errorMessage: String?

    /// Cancellation token for ongoing operations
    private var cancellables = Set<AnyCancellable>()

    public init(manager: GeneratorManager = .shared) {
        self.manager = manager
        self.formState = GeneratorFormState()

        // Observe manager's selected generator
        manager.$selectedGenerator
            .sink { [weak self] metadata in
                if let metadata = metadata {
                    self?.formState.configure(for: metadata)
                }
            }
            .store(in: &cancellables)

        // Forward isGenerating state
        manager.$isGenerating
            .assign(to: &$isGenerating)
    }

    /// Select a generator by ID
    public func selectGenerator(_ id: String) {
        manager.select(generatorId: id)
    }

    /// Generate data with current parameters
    public func generate() async {
        guard let generatorId = manager.selectedGenerator?.id else {
            errorMessage = "No generator selected"
            return
        }

        guard !formState.hasErrors else {
            errorMessage = "Please fix parameter errors before generating"
            return
        }

        errorMessage = nil
        let paramsJson = formState.toJson()

        if let data = await manager.generate(generatorId: generatorId, paramsJson: paramsJson) {
            generatedData = data
        } else if let error = manager.lastError {
            errorMessage = errorDescription(for: error)
        }
    }

    /// Generate data with default parameters
    public func generateWithDefaults() async {
        guard let generatorId = manager.selectedGenerator?.id else {
            errorMessage = "No generator selected"
            return
        }

        errorMessage = nil

        if let data = await manager.generate(generatorId: generatorId, paramsJson: "{}") {
            generatedData = data
        } else if let error = manager.lastError {
            errorMessage = errorDescription(for: error)
        }
    }

    /// Reset form to default values
    public func resetParameters() {
        formState.resetToDefaults()
    }

    /// Clear the generated data
    public func clearData() {
        generatedData = nil
    }

    /// Get a human-readable error description
    private func errorDescription(for error: GeneratorErrorFfi) -> String {
        switch error {
        case .NotFound(let generatorId):
            return "Generator '\(generatorId)' not found"
        case .InvalidParameter(let name, let reason):
            return "Invalid parameter '\(name)': \(reason)"
        case .MissingParameter(let name):
            return "Missing required parameter: \(name)"
        case .TypeMismatch(let name, let expected):
            return "Type mismatch for '\(name)': expected \(expected)"
        case .GenerationFailed(let message):
            return "Generation failed: \(message)"
        case .ExpressionError(let message):
            return "Expression error: \(message)"
        case .NotGenerated:
            return "Data was not generated"
        case .JsonError(let message):
            return "JSON error: \(message)"
        case .LockError(let message):
            return "Lock error: \(message)"
        }
    }
}

// MARK: - Data Summary

extension GeneratorViewModel {
    /// Summary of the generated data for display
    public var dataSummary: DataSummary? {
        guard let data = generatedData else { return nil }

        return DataSummary(
            columnCount: data.columnNames.count,
            rowCount: Int(data.rowCount),
            columnNames: data.columnNames,
            hasBounds: data.boundsMin != nil && data.boundsMax != nil
        )
    }
}

/// Summary information about generated data
public struct DataSummary {
    public let columnCount: Int
    public let rowCount: Int
    public let columnNames: [String]
    public let hasBounds: Bool

    public var totalPoints: Int { rowCount }
    public var formattedPointCount: String {
        if rowCount >= 1_000_000 {
            return String(format: "%.1fM", Double(rowCount) / 1_000_000)
        } else if rowCount >= 1_000 {
            return String(format: "%.1fK", Double(rowCount) / 1_000)
        } else {
            return "\(rowCount)"
        }
    }
}
