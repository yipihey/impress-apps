//
//  AITaskCategorySettings.swift
//  ImpressAI
//
//  Observable settings model for task category configuration.
//

import Foundation

// MARK: - Settings Model

/// Observable settings model for task category configuration.
@MainActor
@Observable
public final class AITaskCategorySettings {

    /// Shared singleton instance.
    public static let shared = AITaskCategorySettings()

    private let categoryManager: AITaskCategoryManager
    private let providerManager: AIProviderManager

    /// All available root categories.
    public let rootCategories = AITaskCategory.rootCategories

    /// All leaf categories (assignable).
    public let leafCategories = AITaskCategory.leafCategories

    /// Current assignments indexed by category ID.
    public private(set) var assignments: [String: AITaskCategoryAssignment] = [:]

    /// Available models for selection.
    public private(set) var availableModels: [AIModelReference] = []

    /// Whether settings are currently loading.
    public private(set) var isLoading = false

    /// Last error message, if any.
    public var errorMessage: String?

    /// The currently selected app filter.
    public var selectedAppFilter: String? = nil

    public init(
        categoryManager: AITaskCategoryManager = .shared,
        providerManager: AIProviderManager = .shared
    ) {
        self.categoryManager = categoryManager
        self.providerManager = providerManager
    }

    // MARK: - Loading

    /// Load settings from storage.
    public func load() async {
        isLoading = true
        defer { isLoading = false }

        await categoryManager.loadAssignments()

        // Build available models list from registered providers
        var models: [AIModelReference] = []
        for provider in await providerManager.allProviders {
            let metadata = provider.metadata
            for model in metadata.models {
                models.append(AIModelReference.from(provider: metadata, model: model))
            }
        }
        availableModels = models

        // Load current assignments
        for category in leafCategories {
            assignments[category.id] = await categoryManager.assignment(for: category.id)
        }
    }

    // MARK: - Category Access

    /// Get categories for a root category.
    public func subcategories(for rootId: String) -> [AITaskCategory] {
        leafCategories.filter { $0.parentId == rootId }
    }

    /// Get filtered leaf categories.
    public var filteredCategories: [AITaskCategory] {
        if let appFilter = selectedAppFilter {
            return leafCategories.filter { $0.supportedApps.contains(appFilter) }
        }
        return leafCategories
    }

    /// Get assignment for a category.
    public func assignment(for categoryId: String) -> AITaskCategoryAssignment {
        assignments[categoryId] ?? AITaskCategoryAssignment(categoryId: categoryId)
    }

    // MARK: - Model Assignment

    /// Set the primary model for a category.
    public func setPrimaryModel(_ model: AIModelReference?, for categoryId: String) async {
        await categoryManager.setPrimaryModel(model, for: categoryId)
        assignments[categoryId] = await categoryManager.assignment(for: categoryId)
    }

    /// Add a comparison model to a category.
    public func addComparisonModel(_ model: AIModelReference, to categoryId: String) async {
        await categoryManager.addComparisonModel(model, to: categoryId)
        assignments[categoryId] = await categoryManager.assignment(for: categoryId)
    }

    /// Remove a comparison model from a category.
    public func removeComparisonModel(_ model: AIModelReference, from categoryId: String) async {
        await categoryManager.removeComparisonModel(model, from: categoryId)
        assignments[categoryId] = await categoryManager.assignment(for: categoryId)
    }

    /// Set enabled state for a category.
    public func setEnabled(_ enabled: Bool, for categoryId: String) async {
        await categoryManager.setEnabled(enabled, for: categoryId)
        assignments[categoryId] = await categoryManager.assignment(for: categoryId)
    }

    // MARK: - Bulk Operations

    /// Apply a model to all unconfigured categories.
    public func applyDefaultModel(_ model: AIModelReference) async {
        await categoryManager.applyDefaultModel(model)
        await load()
    }

    /// Reset all assignments to defaults.
    public func resetToDefaults() async {
        await categoryManager.clearAllAssignments()
        await load()
    }

    // MARK: - Helpers

    /// Check if a category supports comparison.
    public func supportsComparison(_ categoryId: String) -> Bool {
        AITaskCategory.category(for: categoryId)?.supportsComparison ?? false
    }

    /// Get the root category for a leaf category.
    public func rootCategory(for leafId: String) -> AITaskCategory? {
        guard let leaf = AITaskCategory.category(for: leafId),
              let parentId = leaf.parentId else { return nil }
        return AITaskCategory.category(for: parentId)
    }

    /// Get categories organized by root.
    public var categoriesByRoot: [(root: AITaskCategory, children: [AITaskCategory])] {
        rootCategories.compactMap { root in
            let children = subcategories(for: root.id)
            guard !children.isEmpty else { return nil }
            return (root: root, children: children)
        }
    }

    /// Filter categories by app.
    public func categories(for appId: String) -> [AITaskCategory] {
        leafCategories.filter { $0.supportedApps.contains(appId) }
    }
}
