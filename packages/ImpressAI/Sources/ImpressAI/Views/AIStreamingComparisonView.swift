//
//  AIStreamingComparisonView.swift
//  ImpressAI
//
//  View for displaying streaming comparison results in real-time.
//

import SwiftUI

// MARK: - Streaming Model State

/// Observable state for a single model's streaming progress.
@MainActor
@Observable
public final class AIStreamingModelState: Identifiable {
    public let id: UUID
    public let modelReference: AIModelReference

    public var partialText: String = ""
    public var isComplete: Bool = false
    public var error: Error?
    public var startTime: Date = Date()
    public var completionTime: Date?

    public var duration: TimeInterval? {
        guard let endTime = completionTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    public var status: AIModelExecutionResult.ExecutionStatus {
        if let error = error {
            return .failed(error.localizedDescription)
        } else if isComplete {
            return .completed
        } else if !partialText.isEmpty {
            return .streaming
        } else {
            return .pending
        }
    }

    public init(modelReference: AIModelReference) {
        self.id = UUID()
        self.modelReference = modelReference
    }

    public func update(with progress: AIStreamingProgress) {
        partialText = progress.partialText
        isComplete = progress.isComplete
        error = progress.error
        if isComplete {
            completionTime = Date()
        }
    }
}

// MARK: - Streaming Comparison State

/// Observable state for multi-model streaming comparison.
@MainActor
@Observable
public final class AIStreamingComparisonState {
    public var modelStates: [AIStreamingModelState] = []
    public var isActive: Bool = false
    public var selectedModelId: UUID?

    /// Initialize with models.
    public func initialize(with models: [AIModelReference]) {
        modelStates = models.map { AIStreamingModelState(modelReference: $0) }
        isActive = true
        selectedModelId = nil
    }

    /// Update state from progress.
    public func update(with progress: AIStreamingProgress) {
        guard let state = modelStates.first(where: {
            $0.modelReference.id == progress.modelReference.id
        }) else { return }

        state.update(with: progress)

        // Check if all complete
        if modelStates.allSatisfy({ $0.isComplete }) {
            isActive = false
        }
    }

    /// Get selected result.
    public var selectedState: AIStreamingModelState? {
        guard let id = selectedModelId else { return nil }
        return modelStates.first { $0.id == id }
    }

    /// Whether all models have completed.
    public var allComplete: Bool {
        modelStates.allSatisfy { $0.isComplete }
    }

    /// Number of successful completions.
    public var successCount: Int {
        modelStates.filter { $0.isComplete && $0.error == nil }.count
    }
}

// MARK: - Streaming Comparison View

/// View showing real-time streaming results from multiple models.
public struct AIStreamingComparisonView: View {
    @Bindable var state: AIStreamingComparisonState
    let onSelect: (AIStreamingModelState) -> Void
    let onCancel: () -> Void

    public init(
        state: AIStreamingComparisonState,
        onSelect: @escaping (AIStreamingModelState) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Streaming cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(state.modelStates) { modelState in
                        streamingCard(modelState)
                            .frame(width: cardWidth)
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            footerView
        }
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor))
        #else
        .background(Color(.secondarySystemBackground))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var cardWidth: CGFloat {
        let count = state.modelStates.count
        switch count {
        case 1: return 400
        case 2: return 350
        default: return 300
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            if state.isActive {
                ProgressView()
                    .controlSize(.small)
                Text("Streaming responses...")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Comparison complete")
            }

            Spacer()

            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.headline)
        .padding()
    }

    // MARK: - Streaming Card

    private func streamingCard(_ modelState: AIStreamingModelState) -> some View {
        let isSelected = state.selectedModelId == modelState.id

        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(modelState.modelReference.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    statusView(modelState)
                }

                Spacer()

                if let duration = modelState.duration {
                    Text(formatDuration(duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)

            Divider()

            // Content
            contentView(modelState)
                .frame(height: 200)

            Divider()

            // Selection button
            Button {
                state.selectedModelId = modelState.id
                onSelect(modelState)
            } label: {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    Text(isSelected ? "Selected" : "Use this")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(12)
            .disabled(modelState.error != nil || (!modelState.isComplete && modelState.partialText.isEmpty))
        }
        #if os(macOS)
        .background(Color(nsColor: .textBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    @ViewBuilder
    private func statusView(_ modelState: AIStreamingModelState) -> some View {
        HStack(spacing: 4) {
            switch modelState.status {
            case .pending:
                ProgressView()
                    .controlSize(.mini)
                Text("Waiting...")
            case .streaming:
                ProgressView()
                    .controlSize(.mini)
                Text("Streaming...")
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Done")
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Failed")
            case .cancelled:
                Image(systemName: "slash.circle")
                    .foregroundStyle(.secondary)
                Text("Cancelled")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func contentView(_ modelState: AIStreamingModelState) -> some View {
        if let error = modelState.error {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.red)

                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if modelState.partialText.isEmpty {
            VStack {
                ProgressView()
                Text("Waiting for response...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(modelState.partialText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Text("\(state.successCount)/\(state.modelStates.count) completed")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if state.allComplete, let selected = state.selectedState {
                Button("Use Selected") {
                    onSelect(selected)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else {
            return String(format: "%.1fs", duration)
        }
    }
}

// MARK: - Preview

#Preview("AIStreamingComparisonView") {
    let state = AIStreamingComparisonState()

    return VStack {
        Button("Initialize") {
            state.initialize(with: [
                AIModelReference(providerId: "anthropic", modelId: "claude-sonnet-4", displayName: "Claude Sonnet 4"),
                AIModelReference(providerId: "openai", modelId: "gpt-4o", displayName: "GPT-4o")
            ])
        }

        AIStreamingComparisonView(
            state: state,
            onSelect: { _ in },
            onCancel: { }
        )
    }
    .frame(width: 800, height: 500)
    .padding()
}
