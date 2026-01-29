//
//  AITaskCategoryManager.swift
//  ImpressAI
//
//  Manages task category assignments and model retrieval.
//

import Foundation

// MARK: - Category Manager

/// Actor that manages task category assignments and model retrieval.
public actor AITaskCategoryManager {

    /// Shared singleton instance.
    public static let shared = AITaskCategoryManager()

    private var assignments: [String: AITaskCategoryAssignment] = [:]
    private let storage: AITaskCategoryStorage

    public init(storage: AITaskCategoryStorage = .shared) {
        self.storage = storage
    }

    // MARK: - Loading & Saving

    /// Load assignments from persistent storage.
    public func loadAssignments() async {
        assignments = await storage.loadAssignments()
    }

    /// Save assignments to persistent storage.
    public func saveAssignments() async {
        await storage.saveAssignments(assignments)
    }

    // MARK: - Assignment Management

    /// Get the assignment for a category.
    ///
    /// - Parameter categoryId: The category ID.
    /// - Returns: The assignment, or a default one if not configured.
    public func assignment(for categoryId: String) -> AITaskCategoryAssignment {
        assignments[categoryId] ?? AITaskCategoryAssignment(categoryId: categoryId)
    }

    /// Set the assignment for a category.
    ///
    /// - Parameter assignment: The assignment to set.
    public func setAssignment(_ assignment: AITaskCategoryAssignment) {
        assignments[assignment.categoryId] = assignment
        Task { await saveAssignments() }
    }

    /// Set the primary model for a category.
    ///
    /// - Parameters:
    ///   - model: The model reference.
    ///   - categoryId: The category ID.
    public func setPrimaryModel(_ model: AIModelReference?, for categoryId: String) {
        var assignment = assignment(for: categoryId)
        assignment.primaryModel = model
        setAssignment(assignment)
    }

    /// Add a comparison model to a category.
    ///
    /// - Parameters:
    ///   - model: The model to add.
    ///   - categoryId: The category ID.
    public func addComparisonModel(_ model: AIModelReference, to categoryId: String) {
        guard let category = AITaskCategory.category(for: categoryId),
              category.supportsComparison else { return }

        var assignment = assignment(for: categoryId)
        if !assignment.comparisonModels.contains(model) {
            assignment.comparisonModels.append(model)
            setAssignment(assignment)
        }
    }

    /// Remove a comparison model from a category.
    ///
    /// - Parameters:
    ///   - model: The model to remove.
    ///   - categoryId: The category ID.
    public func removeComparisonModel(_ model: AIModelReference, from categoryId: String) {
        var assignment = assignment(for: categoryId)
        assignment.comparisonModels.removeAll { $0 == model }
        setAssignment(assignment)
    }

    /// Enable or disable a category.
    ///
    /// - Parameters:
    ///   - enabled: Whether the category should be enabled.
    ///   - categoryId: The category ID.
    public func setEnabled(_ enabled: Bool, for categoryId: String) {
        var assignment = assignment(for: categoryId)
        assignment.isEnabled = enabled
        setAssignment(assignment)
    }

    /// Clear all assignments.
    public func clearAllAssignments() {
        assignments.removeAll()
        Task { await saveAssignments() }
    }

    // MARK: - Model Retrieval

    /// Get all models assigned to a category (for comparison execution).
    ///
    /// - Parameter categoryId: The category ID.
    /// - Returns: Array of model references, empty if category is disabled.
    public func modelsForExecution(categoryId: String) -> [AIModelReference] {
        let assignment = assignment(for: categoryId)

        guard assignment.isEnabled else { return [] }

        return assignment.allModels
    }

    /// Get the primary model for a category.
    ///
    /// - Parameter categoryId: The category ID.
    /// - Returns: The primary model, or nil if not configured or disabled.
    public func primaryModel(for categoryId: String) -> AIModelReference? {
        let assignment = assignment(for: categoryId)

        guard assignment.isEnabled else { return nil }

        return assignment.primaryModel
    }

    /// Check if a category has comparison mode enabled.
    ///
    /// - Parameter categoryId: The category ID.
    /// - Returns: True if multiple models are assigned for comparison.
    public func hasComparison(for categoryId: String) -> Bool {
        let assignment = assignment(for: categoryId)
        return assignment.isEnabled && assignment.hasComparison
    }

    /// Check if a category is enabled and has at least one model.
    ///
    /// - Parameter categoryId: The category ID.
    /// - Returns: True if the category is ready for use.
    public func isReady(for categoryId: String) -> Bool {
        let assignment = assignment(for: categoryId)
        return assignment.isEnabled && assignment.primaryModel != nil
    }

    /// Get all enabled category IDs for an app.
    ///
    /// - Parameter appId: The app identifier.
    /// - Returns: Array of enabled category IDs.
    public func enabledCategories(for appId: String) -> [String] {
        AITaskCategory.categories(for: appId)
            .filter { isReady(for: $0.id) }
            .map { $0.id }
    }

    // MARK: - Bulk Operations

    /// Apply a default model to all categories that don't have one.
    ///
    /// - Parameter model: The default model to apply.
    public func applyDefaultModel(_ model: AIModelReference) {
        for category in AITaskCategory.leafCategories {
            var assignment = assignment(for: category.id)
            if assignment.primaryModel == nil {
                assignment.primaryModel = model
                assignments[category.id] = assignment
            }
        }
        Task { await saveAssignments() }
    }

    /// Get all assignments.
    public var allAssignments: [AITaskCategoryAssignment] {
        Array(assignments.values)
    }
}

// MARK: - Storage

/// Storage backend for task category assignments.
public actor AITaskCategoryStorage {

    /// Shared singleton instance.
    public static let shared = AITaskCategoryStorage()

    private let storageKey = "impressai.taskCategoryAssignments"

    /// Load assignments from UserDefaults.
    public func loadAssignments() -> [String: AITaskCategoryAssignment] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: AITaskCategoryAssignment].self, from: data)
        } catch {
            return [:]
        }
    }

    /// Save assignments to UserDefaults.
    public func saveAssignments(_ assignments: [String: AITaskCategoryAssignment]) {
        do {
            let data = try JSONEncoder().encode(assignments)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            // Silently fail - logging would be appropriate in production
        }
    }
}
