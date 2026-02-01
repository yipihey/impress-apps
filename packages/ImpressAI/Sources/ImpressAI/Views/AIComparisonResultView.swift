//
//  AIComparisonResultView.swift
//  ImpressAI
//
//  View for displaying and selecting from multi-model comparison results.
//

import SwiftUI

// MARK: - Comparison Result View

/// View displaying comparison results from multiple AI models.
public struct AIComparisonResultView: View {
    let result: AIComparisonResult
    let onSelect: (AIModelExecutionResult) -> Void
    let onRetry: ((AIModelReference) -> Void)?
    let onCancel: (() -> Void)?

    @State private var selectedResultId: UUID?
    @State private var viewMode: ViewMode = .sideBySide

    public enum ViewMode {
        case sideBySide
        case carousel
    }

    /// Creates a comparison result view.
    ///
    /// - Parameters:
    ///   - result: The comparison result to display.
    ///   - onSelect: Called when user selects a result.
    ///   - onRetry: Called when user wants to retry a failed model.
    ///   - onCancel: Called when user cancels the comparison.
    public init(
        result: AIComparisonResult,
        onSelect: @escaping (AIModelExecutionResult) -> Void,
        onRetry: ((AIModelReference) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.result = result
        self.onSelect = onSelect
        self.onRetry = onRetry
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Results
            if viewMode == .sideBySide {
                sideBySideView
            } else {
                carouselView
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

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Compare Results")
                .font(.headline)

            Spacer()

            // View mode picker
            Picker("View", selection: $viewMode) {
                Image(systemName: "rectangle.split.3x1")
                    .tag(ViewMode.sideBySide)
                Image(systemName: "rectangle.stack")
                    .tag(ViewMode.carousel)
            }
            .pickerStyle(.segmented)
            .frame(width: 80)

            if let onCancel = onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }

    // MARK: - Side by Side View

    private var sideBySideView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(result.results) { modelResult in
                    resultCard(modelResult)
                        .frame(width: cardWidth)
                }
            }
            .padding()
        }
    }

    private var cardWidth: CGFloat {
        let count = result.results.count
        switch count {
        case 1: return 400
        case 2: return 350
        default: return 300
        }
    }

    // MARK: - Carousel View

    @State private var carouselIndex = 0

    private var carouselView: some View {
        VStack(spacing: 12) {
            // Page indicators
            HStack(spacing: 8) {
                ForEach(Array(result.results.enumerated()), id: \.offset) { index, modelResult in
                    Button {
                        withAnimation { carouselIndex = index }
                    } label: {
                        Circle()
                            .fill(carouselIndex == index ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)

            // Current card
            if carouselIndex < result.results.count {
                resultCard(result.results[carouselIndex])
                    .frame(maxWidth: 500)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom)
    }

    // MARK: - Result Card

    private func resultCard(_ modelResult: AIModelExecutionResult) -> some View {
        let isSelected = selectedResultId == modelResult.id

        return VStack(alignment: .leading, spacing: 0) {
            // Card header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(modelResult.modelReference.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    statusBadge(modelResult.status)
                }

                Spacer()

                if modelResult.isSuccess {
                    Text(formatDuration(modelResult.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)

            Divider()

            // Content
            if modelResult.isSuccess, let text = modelResult.text {
                ScrollView {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 200)
            } else if case .failed(let reason) = modelResult.status {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.red)

                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let onRetry = onRetry {
                        Button("Retry") {
                            onRetry(modelResult.modelReference)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
            } else {
                Color.clear.frame(height: 200)
            }

            Divider()

            // Selection button
            Button {
                selectedResultId = modelResult.id
                onSelect(modelResult)
            } label: {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    Text(isSelected ? "Selected" : "Use this")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(12)
            .disabled(!modelResult.isSuccess)
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

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            // Statistics
            VStack(alignment: .leading, spacing: 2) {
                Text("\(result.successfulResults.count)/\(result.results.count) completed")
                    .font(.caption)

                Text("Total: \(formatDuration(result.totalDuration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Retry all failed button
            if !result.failedResults.isEmpty, let onRetry = onRetry {
                Button("Retry Failed") {
                    for failed in result.failedResults {
                        onRetry(failed.modelReference)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private func statusBadge(_ status: AIModelExecutionResult.ExecutionStatus) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .pending:
                ProgressView()
                    .controlSize(.mini)
                Text("Pending")
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else {
            return String(format: "%.1fs", duration)
        }
    }
}

// MARK: - Preview

#Preview("AIComparisonResultView") {
    let mockResult = AIComparisonResult(
        categoryId: "writing.rewrite",
        request: AICompletionRequest(messages: []),
        results: [
            AIModelExecutionResult(
                modelReference: AIModelReference(providerId: "anthropic", modelId: "claude-sonnet-4", displayName: "Claude Sonnet 4"),
                status: .completed,
                response: AICompletionResponse(
                    id: "1",
                    content: [.text("This is the rewritten text from Claude. It has been improved for clarity and concision.")],
                    model: "claude-sonnet-4",
                    finishReason: .stop
                ),
                duration: 2.3
            ),
            AIModelExecutionResult(
                modelReference: AIModelReference(providerId: "openai", modelId: "gpt-4o", displayName: "GPT-4o"),
                status: .completed,
                response: AICompletionResponse(
                    id: "2",
                    content: [.text("Here is the GPT-4o version of the text, rewritten for better readability.")],
                    model: "gpt-4o",
                    finishReason: .stop
                ),
                duration: 1.8
            ),
            AIModelExecutionResult(
                modelReference: AIModelReference(providerId: "google", modelId: "gemini-pro", displayName: "Gemini Pro"),
                status: .failed("Rate limit exceeded"),
                duration: 0.5
            )
        ],
        startTime: Date(),
        endTime: Date()
    )

    AIComparisonResultView(
        result: mockResult,
        onSelect: { _ in },
        onRetry: { _ in },
        onCancel: { }
    )
    .frame(width: 900, height: 500)
    .padding()
}
