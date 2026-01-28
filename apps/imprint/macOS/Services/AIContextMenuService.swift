//
//  AIContextMenuService.swift
//  imprint
//
//  Service for managing AI context menu actions and executing prompts.
//  Loads prompt templates and coordinates with AIAssistantService.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imprint.app", category: "aiContextMenu")

// MARK: - AI Context Menu Service

/// Service for executing AI context menu actions.
///
/// Responsibilities:
/// - Load and manage prompt templates from YAML
/// - Substitute variables in prompts
/// - Execute actions via AIAssistantService
/// - Handle imbib integration for citation actions
@MainActor
public final class AIContextMenuService: ObservableObject {

    // MARK: - Singleton

    public static let shared = AIContextMenuService()

    // MARK: - Published State

    /// All available actions (built-in + custom from YAML).
    @Published public private(set) var actions: [AIAction] = AIAction.allActions

    /// Current suggestion being processed or displayed.
    @Published public var suggestionState: SuggestionState = .idle

    /// Whether an action is currently being executed.
    @Published public private(set) var isProcessing = false

    // MARK: - Dependencies

    private let aiService: AIAssistantService
    private let imbibService: ImbibIntegrationService

    // MARK: - Initialization

    private init(
        aiService: AIAssistantService = .shared,
        imbibService: ImbibIntegrationService = .shared
    ) {
        self.aiService = aiService
        self.imbibService = imbibService

        // Load custom prompts on init
        Task {
            await loadCustomPrompts()
        }
    }

    // MARK: - Action Queries

    /// Get all actions for a specific category.
    public func actions(for category: AIActionCategory) -> [AIAction] {
        actions.filter { $0.category == category }
    }

    /// Get all categories that have at least one action.
    public var availableCategories: [AIActionCategory] {
        AIActionCategory.allCases.filter { category in
            actions.contains { $0.category == category }
        }
    }

    // MARK: - Action Execution

    /// Execute an AI action on the given text.
    ///
    /// - Parameters:
    ///   - action: The action to execute
    ///   - selectedText: The text to process
    ///   - range: The range in the document where the text is located
    ///   - context: Additional document context for the prompt
    /// - Returns: A rewrite suggestion if successful
    public func executeAction(
        _ action: AIAction,
        selectedText: String,
        range: NSRange,
        context: DocumentContext = DocumentContext()
    ) async throws -> RewriteSuggestion {
        guard !selectedText.isEmpty || !action.requiresSelection else {
            throw AIContextMenuError.noTextSelected
        }

        // Handle imbib actions
        if action.opensImbib {
            try await handleImbibAction(action, selectedText: selectedText)
            throw AIContextMenuError.handledByImbib
        }

        isProcessing = true
        suggestionState = .loading(action)

        defer {
            isProcessing = false
        }

        do {
            // Build the prompt with variable substitution
            let prompt = buildPrompt(action.systemPrompt, selectedText: selectedText, context: context)

            logger.info("Executing action: \(action.id)")

            // Execute via AI service
            let result = try await aiService.rewrite(prompt, style: .clearer)

            // Create suggestion
            let suggestion = RewriteSuggestion(
                originalText: selectedText,
                suggestedText: result,
                action: action,
                range: range
            )

            suggestionState = .ready(suggestion)
            return suggestion

        } catch {
            let errorMessage = error.localizedDescription
            suggestionState = .error(errorMessage)
            logger.error("Action failed: \(errorMessage)")
            throw error
        }
    }

    /// Execute an action with streaming response.
    ///
    /// - Parameters:
    ///   - action: The action to execute
    ///   - selectedText: The text to process
    ///   - range: The range in the document
    ///   - context: Additional document context
    /// - Returns: An async stream of partial results
    public func executeActionStreaming(
        _ action: AIAction,
        selectedText: String,
        range: NSRange,
        context: DocumentContext = DocumentContext()
    ) -> AsyncThrowingStream<RewriteSuggestion, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard !selectedText.isEmpty || !action.requiresSelection else {
                        throw AIContextMenuError.noTextSelected
                    }

                    if action.opensImbib {
                        try await handleImbibAction(action, selectedText: selectedText)
                        throw AIContextMenuError.handledByImbib
                    }

                    await MainActor.run {
                        isProcessing = true
                        suggestionState = .loading(action)
                    }

                    let prompt = buildPrompt(action.systemPrompt, selectedText: selectedText, context: context)

                    // Create initial streaming suggestion
                    var suggestion = RewriteSuggestion(
                        originalText: selectedText,
                        suggestedText: "",
                        action: action,
                        range: range,
                        isStreaming: true
                    )

                    // Stream the response
                    for try await chunk in aiService.streamMessage(systemPrompt: prompt, userMessage: selectedText) {
                        suggestion.suggestedText += chunk
                        continuation.yield(suggestion)

                        await MainActor.run {
                            suggestionState = .ready(suggestion)
                        }
                    }

                    // Final suggestion
                    suggestion.isStreaming = false
                    continuation.yield(suggestion)

                    await MainActor.run {
                        isProcessing = false
                        suggestionState = .ready(suggestion)
                    }

                    continuation.finish()

                } catch {
                    await MainActor.run {
                        isProcessing = false
                        suggestionState = .error(error.localizedDescription)
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Clear the current suggestion state.
    public func clearSuggestion() {
        suggestionState = .idle
    }

    /// Accept the current suggestion.
    /// Returns the suggested text to be inserted.
    public func acceptSuggestion() -> String? {
        if case .ready(let suggestion) = suggestionState {
            suggestionState = .idle
            return suggestion.suggestedText
        }
        return nil
    }

    /// Reject the current suggestion.
    public func rejectSuggestion() {
        suggestionState = .idle
    }

    // MARK: - Imbib Integration

    private func handleImbibAction(_ action: AIAction, selectedText: String) async throws {
        guard imbibService.isAvailable else {
            throw AIContextMenuError.imbibNotAvailable
        }

        switch action.id {
        case "citations.find_supporting":
            // Extract key terms from selected text for search
            let searchQuery = extractSearchQuery(from: selectedText)
            imbibService.searchForCitation(query: searchQuery)

        default:
            logger.warning("Unknown imbib action: \(action.id)")
        }
    }

    /// Extract a search query from selected text.
    private func extractSearchQuery(from text: String) -> String {
        // Use the text as-is, but truncate if too long
        let maxLength = 100
        if text.count > maxLength {
            return String(text.prefix(maxLength))
        }
        return text
    }

    // MARK: - Prompt Building

    /// Substitute variables in a prompt template.
    private func buildPrompt(
        _ template: String,
        selectedText: String,
        context: DocumentContext
    ) -> String {
        var prompt = template

        // Substitute variables
        prompt = prompt.replacingOccurrences(of: "{{selection}}", with: selectedText)
        prompt = prompt.replacingOccurrences(of: "{{paragraph}}", with: context.surroundingParagraph ?? selectedText)
        prompt = prompt.replacingOccurrences(of: "{{document_title}}", with: context.documentTitle ?? "Untitled")
        prompt = prompt.replacingOccurrences(of: "{{section_heading}}", with: context.sectionHeading ?? "")

        return prompt
    }

    // MARK: - YAML Loading

    /// Load custom prompts from the YAML file.
    public func loadCustomPrompts() async {
        guard let url = Bundle.main.url(forResource: "ai-prompts", withExtension: "yaml") else {
            logger.info("No custom prompts YAML found, using built-in actions")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let yamlString = String(data: data, encoding: .utf8) ?? ""

            // Parse YAML (simplified parser for our known structure)
            let customActions = parsePromptsYAML(yamlString)

            if !customActions.isEmpty {
                // Merge with built-in actions (custom override built-in with same ID)
                var mergedActions = AIAction.allActions
                for customAction in customActions {
                    if let index = mergedActions.firstIndex(where: { $0.id == customAction.id }) {
                        mergedActions[index] = customAction
                    } else {
                        mergedActions.append(customAction)
                    }
                }
                actions = mergedActions
                logger.info("Loaded \(customActions.count) custom prompts")
            }

        } catch {
            logger.error("Failed to load custom prompts: \(error)")
        }
    }

    /// Simple YAML parser for our prompt structure.
    private func parsePromptsYAML(_ yaml: String) -> [AIAction] {
        // This is a simplified parser. For production, use a proper YAML library.
        // The built-in actions already contain all our prompts, so this is mainly
        // for user customization.
        var actions: [AIAction] = []

        let lines = yaml.components(separatedBy: .newlines)
        var currentCategory: AIActionCategory?
        var currentActionId: String?
        var currentTitle: String?
        var currentIcon: String?
        var currentPrompt: String = ""
        var requiresSelection = true
        var opensImbib = false
        var inPrompt = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if inPrompt && !trimmed.hasPrefix("#") {
                    currentPrompt += "\n"
                }
                continue
            }

            // Check for category (top-level key)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && line.hasSuffix(":") {
                let categoryName = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                currentCategory = AIActionCategory(rawValue: categoryName)
                continue
            }

            // Check for action ID (second-level key)
            if line.hasPrefix("  ") && !line.hasPrefix("    ") && line.contains(":") && !line.contains("\"") {
                // Save previous action if exists
                if let category = currentCategory,
                   let id = currentActionId,
                   let title = currentTitle {
                    let action = AIAction(
                        id: "\(category.rawValue).\(id)",
                        category: category,
                        title: title,
                        systemPrompt: currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                        requiresSelection: requiresSelection,
                        opensImbib: opensImbib,
                        icon: currentIcon
                    )
                    actions.append(action)
                }

                // Start new action
                currentActionId = String(line.dropLast())
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ":", with: "")
                currentTitle = nil
                currentIcon = nil
                currentPrompt = ""
                requiresSelection = true
                opensImbib = false
                inPrompt = false
                continue
            }

            // Parse action properties
            if line.hasPrefix("    ") {
                if inPrompt {
                    currentPrompt += line.trimmingCharacters(in: CharacterSet(charactersIn: " ").union(.init(charactersIn: "\t"))) + "\n"
                } else if trimmed.hasPrefix("title:") {
                    currentTitle = extractYAMLValue(trimmed, key: "title")
                } else if trimmed.hasPrefix("icon:") {
                    currentIcon = extractYAMLValue(trimmed, key: "icon")
                } else if trimmed.hasPrefix("requires_selection:") {
                    requiresSelection = extractYAMLValue(trimmed, key: "requires_selection") == "true"
                } else if trimmed.hasPrefix("opens_imbib:") {
                    opensImbib = extractYAMLValue(trimmed, key: "opens_imbib") == "true"
                } else if trimmed.hasPrefix("prompt:") {
                    inPrompt = true
                    let inline = extractYAMLValue(trimmed, key: "prompt")
                    if !inline.isEmpty && inline != "|" {
                        currentPrompt = inline
                        inPrompt = false
                    }
                }
            }
        }

        // Don't forget the last action
        if let category = currentCategory,
           let id = currentActionId,
           let title = currentTitle {
            let action = AIAction(
                id: "\(category.rawValue).\(id)",
                category: category,
                title: title,
                systemPrompt: currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                requiresSelection: requiresSelection,
                opensImbib: opensImbib,
                icon: currentIcon
            )
            actions.append(action)
        }

        return actions
    }

    private func extractYAMLValue(_ line: String, key: String) -> String {
        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2 else { return "" }
        return parts.dropFirst().joined(separator: ":")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
    }
}

// MARK: - Errors

/// Errors that can occur during AI context menu operations.
public enum AIContextMenuError: LocalizedError {
    case noTextSelected
    case handledByImbib
    case imbibNotAvailable
    case actionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noTextSelected:
            return "Please select some text first."
        case .handledByImbib:
            return "Action opened in imbib."
        case .imbibNotAvailable:
            return "imbib is not installed. Please install imbib to use citation features."
        case .actionFailed(let message):
            return "Action failed: \(message)"
        }
    }
}
