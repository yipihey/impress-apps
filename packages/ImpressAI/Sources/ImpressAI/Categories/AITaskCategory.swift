//
//  AITaskCategory.swift
//  ImpressAI
//
//  Task category data model for organizing AI actions.
//

import Foundation

// MARK: - Task Category

/// Defines a category of AI tasks with associated metadata.
public struct AITaskCategory: Identifiable, Codable, Sendable, Hashable {
    /// Unique identifier for the category (e.g., "writing.rewrite").
    public let id: String

    /// Human-readable name for the category.
    public let name: String

    /// SF Symbol icon name.
    public let icon: String

    /// Description of what this category handles.
    public let description: String

    /// Parent category ID for hierarchical organization.
    public let parentId: String?

    /// Apps that support this category.
    public let supportedApps: Set<String>

    /// Whether this category supports multi-model comparison.
    public let supportsComparison: Bool

    public init(
        id: String,
        name: String,
        icon: String,
        description: String,
        parentId: String? = nil,
        supportedApps: Set<String>,
        supportsComparison: Bool = true
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.description = description
        self.parentId = parentId
        self.supportedApps = supportedApps
        self.supportsComparison = supportsComparison
    }

    /// The root category ID (first segment before the dot).
    public var rootCategoryId: String {
        id.components(separatedBy: ".").first ?? id
    }

    /// Whether this is a top-level category.
    public var isRootCategory: Bool {
        parentId == nil
    }
}

// MARK: - Model Reference

/// Reference to a specific AI model for task assignment.
public struct AIModelReference: Codable, Sendable, Hashable, Identifiable {
    /// Provider ID (e.g., "anthropic", "openai").
    public let providerId: String

    /// Model ID within the provider.
    public let modelId: String

    /// Display name for UI.
    public let displayName: String

    public var id: String { "\(providerId):\(modelId)" }

    public init(providerId: String, modelId: String, displayName: String) {
        self.providerId = providerId
        self.modelId = modelId
        self.displayName = displayName
    }

    /// Creates a reference from provider and model metadata.
    public static func from(provider: AIProviderMetadata, model: AIModel) -> AIModelReference {
        AIModelReference(
            providerId: provider.id,
            modelId: model.id,
            displayName: "\(provider.name) - \(model.name)"
        )
    }
}

// MARK: - Category Assignment

/// Assignment of models to a task category.
public struct AITaskCategoryAssignment: Codable, Sendable, Identifiable {
    /// The category ID this assignment is for.
    public let categoryId: String

    /// Primary model for this category.
    public var primaryModel: AIModelReference?

    /// Additional models for comparison (if category supports it).
    public var comparisonModels: [AIModelReference]

    /// Whether this category is enabled.
    public var isEnabled: Bool

    public var id: String { categoryId }

    /// All assigned models (primary + comparison).
    public var allModels: [AIModelReference] {
        var models: [AIModelReference] = []
        if let primary = primaryModel {
            models.append(primary)
        }
        models.append(contentsOf: comparisonModels)
        return models
    }

    /// Whether comparison mode is active (multiple models assigned).
    public var hasComparison: Bool {
        !comparisonModels.isEmpty && primaryModel != nil
    }

    public init(
        categoryId: String,
        primaryModel: AIModelReference? = nil,
        comparisonModels: [AIModelReference] = [],
        isEnabled: Bool = true
    ) {
        self.categoryId = categoryId
        self.primaryModel = primaryModel
        self.comparisonModels = comparisonModels
        self.isEnabled = isEnabled
    }
}

// MARK: - Built-in Categories

public extension AITaskCategory {

    // MARK: Root Categories

    static let writing = AITaskCategory(
        id: "writing",
        name: "Writing",
        icon: "pencil.and.outline",
        description: "Text editing and improvement tasks",
        supportedApps: ["imprint"],
        supportsComparison: false
    )

    static let research = AITaskCategory(
        id: "research",
        name: "Research",
        icon: "magnifyingglass",
        description: "Academic research assistance and AI counsel conversations",
        supportedApps: ["imbib", "imprint", "impart"],
        supportsComparison: false
    )

    static let citation = AITaskCategory(
        id: "citation",
        name: "Citations",
        icon: "quote.opening",
        description: "Citation finding and formatting",
        supportedApps: ["imprint", "imbib"],
        supportsComparison: false
    )

    static let analysis = AITaskCategory(
        id: "analysis",
        name: "Analysis",
        icon: "chart.bar.doc.horizontal",
        description: "Content analysis and review",
        supportedApps: ["imprint"],
        supportsComparison: false
    )

    static let data = AITaskCategory(
        id: "data",
        name: "Data",
        icon: "tablecells",
        description: "Data generation and interpretation",
        supportedApps: ["implore"],
        supportsComparison: false
    )

    // MARK: Writing Subcategories

    static let writingRewrite = AITaskCategory(
        id: "writing.rewrite",
        name: "Text Rewriting",
        icon: "arrow.2.squarepath",
        description: "Improve clarity, concision, and tone",
        parentId: "writing",
        supportedApps: ["imprint"],
        supportsComparison: true
    )

    static let writingGrammar = AITaskCategory(
        id: "writing.grammar",
        name: "Grammar & Style",
        icon: "textformat.abc",
        description: "Spelling and grammar fixes",
        parentId: "writing",
        supportedApps: ["imprint"],
        supportsComparison: true
    )

    // MARK: Research Subcategories

    static let researchSearch = AITaskCategory(
        id: "research.search",
        name: "Query Expansion",
        icon: "text.magnifyingglass",
        description: "Expand search queries with synonyms and related concepts",
        parentId: "research",
        supportedApps: ["imbib"],
        supportsComparison: true
    )

    static let researchSummarize = AITaskCategory(
        id: "research.summarize",
        name: "Summarization",
        icon: "doc.text.magnifyingglass",
        description: "Generate abstract and document summaries",
        parentId: "research",
        supportedApps: ["imbib", "imprint"],
        supportsComparison: true
    )

    static let researchDiscover = AITaskCategory(
        id: "research.discover",
        name: "Paper Discovery",
        icon: "sparkle.magnifyingglass",
        description: "Find related papers and suggestions",
        parentId: "research",
        supportedApps: ["imbib"],
        supportsComparison: true
    )

    // MARK: Citation Subcategories

    static let citationFind = AITaskCategory(
        id: "citation.find",
        name: "Citation Finding",
        icon: "doc.text.magnifyingglass",
        description: "Identify citations needed for claims",
        parentId: "citation",
        supportedApps: ["imprint", "imbib"],
        supportsComparison: true
    )

    static let citationFormat = AITaskCategory(
        id: "citation.format",
        name: "Citation Formatting",
        icon: "list.bullet.indent",
        description: "Generate and format BibTeX entries",
        parentId: "citation",
        supportedApps: ["imbib"],
        supportsComparison: false
    )

    // MARK: Analysis Subcategories

    static let analysisReview = AITaskCategory(
        id: "analysis.review",
        name: "Content Review",
        icon: "checkmark.circle",
        description: "Review logical flow and arguments",
        parentId: "analysis",
        supportedApps: ["imprint"],
        supportsComparison: true
    )

    static let analysisExplain = AITaskCategory(
        id: "analysis.explain",
        name: "Explanation",
        icon: "lightbulb",
        description: "Simplify or add detail to explanations",
        parentId: "analysis",
        supportedApps: ["imprint"],
        supportsComparison: true
    )

    // MARK: Data Subcategories

    static let dataGenerate = AITaskCategory(
        id: "data.generate",
        name: "Formula Generation",
        icon: "function",
        description: "Generate mathematical formulas from descriptions",
        parentId: "data",
        supportedApps: ["implore"],
        supportsComparison: true
    )

    static let dataInterpret = AITaskCategory(
        id: "data.interpret",
        name: "Data Interpretation",
        icon: "chart.xyaxis.line",
        description: "Describe statistical patterns and insights",
        parentId: "data",
        supportedApps: ["implore"],
        supportsComparison: true
    )

    // MARK: All Categories

    /// All root categories.
    static let rootCategories: [AITaskCategory] = [
        .writing, .research, .citation, .analysis, .data
    ]

    /// All leaf categories (the ones that can have models assigned).
    static let leafCategories: [AITaskCategory] = [
        .writingRewrite, .writingGrammar,
        .researchSearch, .researchSummarize, .researchDiscover,
        .citationFind, .citationFormat,
        .analysisReview, .analysisExplain,
        .dataGenerate, .dataInterpret
    ]

    /// All categories.
    static let all: [AITaskCategory] = rootCategories + leafCategories

    /// Categories organized by root.
    static var categoriesByRoot: [String: [AITaskCategory]] {
        var result: [String: [AITaskCategory]] = [:]
        for category in leafCategories {
            let root = category.rootCategoryId
            result[root, default: []].append(category)
        }
        return result
    }

    /// Get a category by ID.
    static func category(for id: String) -> AITaskCategory? {
        all.first { $0.id == id }
    }

    /// Get categories for a specific app.
    static func categories(for appId: String) -> [AITaskCategory] {
        leafCategories.filter { $0.supportedApps.contains(appId) }
    }
}
