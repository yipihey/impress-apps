import Foundation
import ImploreCore
import SwiftUI

/// Coordinator view model for generator-related UI state.
///
/// This view model connects the GeneratorManager with the form state
/// and provides the primary interface for generator-related views.
@MainActor @Observable
public final class GeneratorViewModel {
    /// The generator manager instance
    public private(set) var manager: GeneratorManager

    /// Form state for the currently selected generator
    public private(set) var formState: GeneratorFormState

    /// The most recently generated data
    public private(set) var generatedData: GeneratedDataFfi?

    /// Whether generation is in progress - derived from manager
    public var isGenerating: Bool {
        manager.isGenerating
    }

    /// Error message to display
    public var errorMessage: String?

    /// Track last selected generator to detect changes
    private var lastSelectedGeneratorId: String?

    public init(manager: GeneratorManager = .shared) {
        self.manager = manager
        self.formState = GeneratorFormState()
    }

    /// Call this to sync form state when selected generator changes
    /// Views should call this in onChange(of: manager.selectedGenerator)
    public func syncFormStateIfNeeded() {
        let currentId = manager.selectedGenerator?.id
        if currentId != lastSelectedGeneratorId {
            lastSelectedGeneratorId = currentId
            if let metadata = manager.selectedGenerator {
                formState.configure(for: metadata)
            }
        }
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
