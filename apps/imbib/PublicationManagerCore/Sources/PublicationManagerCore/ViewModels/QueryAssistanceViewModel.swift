//
//  QueryAssistanceViewModel.swift
//  PublicationManagerCore
//
//  Observable view model for binding query assistance to SwiftUI views.
//  Handles debouncing, state management, and async preview fetching.
//

import Foundation
import OSLog
import SwiftUI
import Combine

// MARK: - Query Assistance View Model

/// View model for query assistance UI.
///
/// Provides:
/// - Immediate validation as the user types
/// - Debounced preview fetching
/// - Observable state for SwiftUI binding
@MainActor
@Observable
public final class QueryAssistanceViewModel {

    // MARK: - Published State

    /// Current state of query assistance
    public private(set) var state: QueryAssistanceState = .empty

    /// The current query being validated
    public private(set) var currentQuery: String = ""

    /// The source being used for validation
    public private(set) var source: QueryAssistanceSource = .ads

    // MARK: - Dependencies

    private let service: QueryAssistanceService

    // MARK: - Private State

    private var previewTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(service: QueryAssistanceService = .shared) {
        self.service = service
    }

    // MARK: - Configuration

    /// Set the source for validation
    public func setSource(_ source: QueryAssistanceSource) {
        guard self.source != source else { return }
        self.source = source
        // Re-validate current query for new source
        if !currentQuery.isEmpty {
            updateQuery(currentQuery)
        }
    }

    // MARK: - Query Updates

    /// Update the query and trigger validation/preview.
    ///
    /// - Validation happens immediately (synchronous)
    /// - Preview is debounced based on source rate limits
    public func updateQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        currentQuery = query

        // Cancel any pending preview fetch
        previewTask?.cancel()
        debounceTask?.cancel()

        // Handle empty query
        guard !trimmed.isEmpty else {
            state = .empty
            return
        }

        // Immediate validation (synchronous, no network)
        Task {
            let validationResult = await service.validate(query, for: source)
            state = .validated(validationResult)

            // Only fetch preview if query is valid
            if validationResult.isValid {
                schedulePreviewFetch(query: query, validationResult: validationResult)
            }
        }
    }

    /// Clear the current query and reset state
    public func clear() {
        previewTask?.cancel()
        debounceTask?.cancel()
        currentQuery = ""
        state = .empty
    }

    // MARK: - Preview Fetching

    /// Schedule a debounced preview fetch
    private func schedulePreviewFetch(query: String, validationResult: QueryValidationResult) {
        debounceTask?.cancel()

        debounceTask = Task {
            // Wait for debounce delay
            let delay = source.previewDebounceDelay
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard !Task.isCancelled else { return }

            // Update state to fetching
            state = .fetchingPreview(validationResult)

            // Fetch preview
            await fetchPreview(query: query, validationResult: validationResult)
        }
    }

    /// Fetch the preview result
    private func fetchPreview(query: String, validationResult: QueryValidationResult) async {
        previewTask?.cancel()

        previewTask = Task {
            do {
                let preview = try await service.fetchPreview(query, for: source)

                guard !Task.isCancelled else { return }

                state = .complete(validationResult, preview)
            } catch {
                guard !Task.isCancelled else { return }

                Logger.queryAssistance.error("Preview fetch failed: \(error.localizedDescription)")
                state = .previewError(validationResult, error)
            }
        }

        await previewTask?.value
    }

    // MARK: - Computed Properties

    /// Whether validation found any errors
    public var hasErrors: Bool {
        state.validationResult?.hasErrors ?? false
    }

    /// Whether validation found any warnings
    public var hasWarnings: Bool {
        state.validationResult?.hasWarnings ?? false
    }

    /// Whether the query is valid (no blocking errors)
    public var isValid: Bool {
        state.validationResult?.isValid ?? true
    }

    /// All validation issues
    public var issues: [QueryValidationIssue] {
        state.validationResult?.issues ?? []
    }

    /// Preview result count, if available
    public var previewCount: Int? {
        state.previewResult?.totalResults
    }

    /// Whether a preview fetch is in progress
    public var isFetchingPreview: Bool {
        state.isFetchingPreview
    }

    /// Whether the state is empty (no query)
    public var isEmpty: Bool {
        if case .empty = state {
            return true
        }
        return false
    }

    /// Apply a suggestion to fix the query
    public func applySuggestion(_ suggestion: QuerySuggestion) {
        updateQuery(suggestion.correctedQuery)
    }
}
