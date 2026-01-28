//
//  AIContextMenuAction.swift
//  imprint
//
//  Models for AI context menu actions organized by category.
//  Used by AIContextMenuView and AIContextMenuService.
//

import Foundation

// MARK: - AI Action Category

/// Categories for organizing AI context menu actions.
public enum AIActionCategory: String, CaseIterable, Identifiable, Codable {
    case rewrite
    case citations
    case explain
    case structure
    case review

    public var id: String { rawValue }

    /// Display title for the category in the menu.
    public var title: String {
        switch self {
        case .rewrite: return "Rewrite"
        case .citations: return "Citations"
        case .explain: return "Explain"
        case .structure: return "Structure"
        case .review: return "Review"
        }
    }

    /// SF Symbol icon for the category.
    public var icon: String {
        switch self {
        case .rewrite: return "arrow.triangle.2.circlepath"
        case .citations: return "quote.opening"
        case .explain: return "lightbulb"
        case .structure: return "list.bullet.indent"
        case .review: return "checkmark.circle"
        }
    }
}

// MARK: - AI Action

/// An individual AI action that can be performed on selected text.
public struct AIAction: Identifiable, Hashable, Codable {
    /// Unique identifier for the action.
    public let id: String

    /// Category this action belongs to.
    public let category: AIActionCategory

    /// Display title shown in the menu.
    public let title: String

    /// System prompt template for the AI.
    /// Supports variables: {{selection}}, {{paragraph}}, {{document_title}}, {{section_heading}}
    public let systemPrompt: String

    /// Whether this action requires text to be selected.
    public let requiresSelection: Bool

    /// Whether this action opens imbib instead of using AI.
    public let opensImbib: Bool

    /// SF Symbol icon for the action (optional, uses category icon if nil).
    public let icon: String?

    public init(
        id: String,
        category: AIActionCategory,
        title: String,
        systemPrompt: String,
        requiresSelection: Bool = true,
        opensImbib: Bool = false,
        icon: String? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.systemPrompt = systemPrompt
        self.requiresSelection = requiresSelection
        self.opensImbib = opensImbib
        self.icon = icon
    }

    /// Get the effective icon (action-specific or category default).
    public var effectiveIcon: String {
        icon ?? category.icon
    }

    public static func == (lhs: AIAction, rhs: AIAction) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Document Context

/// Context information passed to AI prompts for better results.
public struct DocumentContext {
    /// Title of the current document (from heading or filename).
    public let documentTitle: String?

    /// The paragraph containing the selection.
    public let surroundingParagraph: String?

    /// Nearest section heading above the selection.
    public let sectionHeading: String?

    /// Full document source (for context-heavy operations).
    public let fullSource: String?

    public init(
        documentTitle: String? = nil,
        surroundingParagraph: String? = nil,
        sectionHeading: String? = nil,
        fullSource: String? = nil
    ) {
        self.documentTitle = documentTitle
        self.surroundingParagraph = surroundingParagraph
        self.sectionHeading = sectionHeading
        self.fullSource = fullSource
    }
}

// MARK: - Built-in Actions

extension AIAction {

    // MARK: Rewrite Actions

    public static let improveClarity = AIAction(
        id: "rewrite.improve_clarity",
        category: .rewrite,
        title: "Improve clarity",
        systemPrompt: """
            Rewrite the following text to improve clarity while preserving the meaning.
            Use active voice, shorter sentences, and precise word choices.
            Output only the rewritten text, no explanations.
            """,
        icon: "text.magnifyingglass"
    )

    public static let makeConcise = AIAction(
        id: "rewrite.make_concise",
        category: .rewrite,
        title: "Make concise",
        systemPrompt: """
            Rewrite the following text to be more concise.
            Remove redundancy, unnecessary qualifiers, and filler words.
            Preserve the core meaning. Output only the rewritten text.
            """,
        icon: "arrow.down.right.and.arrow.up.left"
    )

    public static let makeFormal = AIAction(
        id: "rewrite.make_formal",
        category: .rewrite,
        title: "Make formal",
        systemPrompt: """
            Rewrite the following text in a more formal, academic tone.
            Use appropriate scholarly language and passive voice where suitable.
            Output only the rewritten text.
            """,
        icon: "graduationcap"
    )

    public static let expandWithDetail = AIAction(
        id: "rewrite.expand_detail",
        category: .rewrite,
        title: "Expand with detail",
        systemPrompt: """
            Expand the following text by adding more detail and explanation.
            Develop the ideas more fully while maintaining the original argument.
            Output only the expanded text.
            """,
        icon: "arrow.up.left.and.arrow.down.right"
    )

    public static let fixGrammar = AIAction(
        id: "rewrite.fix_grammar",
        category: .rewrite,
        title: "Fix grammar & spelling",
        systemPrompt: """
            Fix any grammar, spelling, or punctuation errors in the following text.
            Do not change the meaning or style. Output only the corrected text.
            """,
        icon: "textformat.abc"
    )

    // MARK: Citation Actions

    public static let findSupportingCitation = AIAction(
        id: "citations.find_supporting",
        category: .citations,
        title: "Find supporting citation",
        systemPrompt: "",
        opensImbib: true,
        icon: "magnifyingglass"
    )

    public static let checkCitationNeeded = AIAction(
        id: "citations.check_needed",
        category: .citations,
        title: "Check citation needed",
        systemPrompt: """
            Analyze the following text and identify any claims that should be supported by citations.
            For each claim, explain why a citation would strengthen it and suggest what type of source would be appropriate.
            Format as a numbered list.
            """,
        icon: "exclamationmark.triangle"
    )

    public static let formatCitation = AIAction(
        id: "citations.format",
        category: .citations,
        title: "Format citation",
        systemPrompt: """
            The following text contains citation information (author names, titles, years, etc.).
            Convert it into a properly formatted citation in a standard academic format.
            If the format is ambiguous, use APA style. Output only the formatted citation.
            """,
        icon: "text.quote"
    )

    // MARK: Explain Actions

    public static let simplifyForGeneral = AIAction(
        id: "explain.simplify_general",
        category: .explain,
        title: "Simplify for general audience",
        systemPrompt: """
            Rewrite the following technical or academic text for a general audience.
            Replace jargon with plain language, add brief explanations of complex concepts.
            Maintain accuracy while improving accessibility. Output only the rewritten text.
            """,
        icon: "person.2"
    )

    public static let addTechnicalDetail = AIAction(
        id: "explain.add_technical",
        category: .explain,
        title: "Add technical detail",
        systemPrompt: """
            Expand the following text by adding more technical detail and precision.
            Include relevant terminology, specific mechanisms, or quantitative information.
            Output only the expanded text.
            """,
        icon: "gearshape.2"
    )

    public static let defineTerms = AIAction(
        id: "explain.define_terms",
        category: .explain,
        title: "Define terms",
        systemPrompt: """
            Identify technical terms, acronyms, or specialized vocabulary in the following text.
            Provide brief, clear definitions for each term.
            Format as a list with the term followed by its definition.
            """,
        icon: "character.book.closed"
    )

    // MARK: Structure Actions

    public static let convertToBulletPoints = AIAction(
        id: "structure.to_bullets",
        category: .structure,
        title: "Convert to bullet points",
        systemPrompt: """
            Convert the following prose into a clear, well-organized bullet point list.
            Each bullet should capture one distinct idea. Use sub-bullets for related details.
            Output only the bullet points, using - for bullets and indentation for hierarchy.
            """,
        icon: "list.bullet"
    )

    public static let convertToParagraph = AIAction(
        id: "structure.to_paragraph",
        category: .structure,
        title: "Convert to paragraph",
        systemPrompt: """
            Convert the following bullet points or list into flowing prose paragraphs.
            Add appropriate transitions between ideas. Maintain all the information.
            Output only the paragraph text.
            """,
        icon: "text.alignleft"
    )

    public static let addTransition = AIAction(
        id: "structure.add_transition",
        category: .structure,
        title: "Add transition sentence",
        systemPrompt: """
            Write a transition sentence that would smoothly connect the ideas in the following text.
            The transition should bridge between the preceding and following content.
            Output only the transition sentence.
            """,
        icon: "arrow.right"
    )

    public static let suggestHeading = AIAction(
        id: "structure.suggest_heading",
        category: .structure,
        title: "Suggest section heading",
        systemPrompt: """
            Based on the following text, suggest 3 appropriate section headings that accurately describe the content.
            Headings should be concise (2-6 words) and descriptive.
            Format as a numbered list.
            """,
        icon: "number"
    )

    // MARK: Review Actions

    public static let checkLogicalFlow = AIAction(
        id: "review.check_flow",
        category: .review,
        title: "Check logical flow",
        systemPrompt: """
            Analyze the logical flow and coherence of the following text.
            Identify any gaps in reasoning, unclear transitions, or logical jumps.
            Provide specific suggestions for improvement.
            """,
        icon: "arrow.triangle.branch"
    )

    public static let identifyWeakArguments = AIAction(
        id: "review.weak_arguments",
        category: .review,
        title: "Identify weak arguments",
        systemPrompt: """
            Analyze the arguments in the following text.
            Identify any weak points, unsupported claims, or potential counterarguments.
            For each issue, suggest how to strengthen the argument.
            """,
        icon: "exclamationmark.bubble"
    )

    public static let suggestImprovements = AIAction(
        id: "review.suggest_improvements",
        category: .review,
        title: "Suggest improvements",
        systemPrompt: """
            Review the following text and provide 3-5 specific suggestions for improvement.
            Consider clarity, structure, argument strength, and academic style.
            Format as a numbered list with brief explanations.
            """,
        icon: "lightbulb.max"
    )

    // MARK: All Actions

    /// All built-in actions organized by category.
    public static let allActions: [AIAction] = [
        // Rewrite
        .improveClarity,
        .makeConcise,
        .makeFormal,
        .expandWithDetail,
        .fixGrammar,
        // Citations
        .findSupportingCitation,
        .checkCitationNeeded,
        .formatCitation,
        // Explain
        .simplifyForGeneral,
        .addTechnicalDetail,
        .defineTerms,
        // Structure
        .convertToBulletPoints,
        .convertToParagraph,
        .addTransition,
        .suggestHeading,
        // Review
        .checkLogicalFlow,
        .identifyWeakArguments,
        .suggestImprovements
    ]

    /// Get all actions for a specific category.
    public static func actions(for category: AIActionCategory) -> [AIAction] {
        allActions.filter { $0.category == category }
    }
}
