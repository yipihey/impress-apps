//
//  SuggestionListView.swift
//  impel
//
//  Proactive-suggestion list + row.
//  Moved verbatim from ContentView.swift (C0 mechanical decomposition,
//  Stage 2-C of the GUI unification) — no renames, no signature changes.
//

import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressKeyboard
import ImpressKit

// MARK: - Suggestion List View

struct SuggestionListView: View {
    let suggestions: [AgentSuggestion]

    var body: some View {
        List(suggestions) { suggestion in
            SuggestionRow(suggestion: suggestion)
        }
        .navigationTitle("Suggestions")
        .overlay {
            if suggestions.isEmpty {
                ContentUnavailableView(
                    "No Suggestions",
                    systemImage: "lightbulb",
                    description: Text("The system will suggest actions based on current activity.")
                )
            }
        }
    }
}

struct SuggestionRow: View {
    @EnvironmentObject var client: ImpelClient
    let suggestion: AgentSuggestion
    @State private var isExecuting = false
    @State private var isExecuted = false
    @State private var errorMessage: String?
    @State private var shakeCount = 0

    var body: some View {
        ZStack {
            // Success overlay
            if isExecuted {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 36))
                            .foregroundStyle(.purple)
                            .symbolEffect(.bounce, value: isExecuted)
                        Text("Running...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .transition(.scale.combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: suggestion.category.systemImage)
                        .foregroundColor(.purple)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title)
                            .font(.headline)

                        Text(suggestion.category.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Confidence badge
                    Text("\(Int(suggestion.confidence * 100))%")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(confidenceColor.opacity(0.2))
                        .foregroundColor(confidenceColor)
                        .clipShape(.rect(cornerRadius: 4))
                }

                Text(suggestion.reason)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack {
                    Button {
                        executeAction()
                    } label: {
                        HStack(spacing: 4) {
                            if isExecuting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(suggestion.action.buttonLabel)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                    .disabled(isExecuting || isExecuted)

                    Button("Dismiss") {
                        withAnimation(.easeOut(duration: 0.2)) {
                            client.dismissSuggestion(id: suggestion.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isExecuted)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .opacity(isExecuted ? 0.3 : 1)
        }
        .padding(.vertical, 4)
        .modifier(ShakeEffect(shakes: shakeCount))
        .animation(.default, value: isExecuted)
    }

    private func executeAction() {
        isExecuting = true
        errorMessage = nil

        Task {
            do {
                try await client.executeSuggestion(suggestion)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    isExecuted = true
                }
            } catch {
                errorMessage = error.localizedDescription
                withAnimation(.default) {
                    shakeCount += 1
                }
            }
            isExecuting = false
        }
    }

    private var confidenceColor: Color {
        if suggestion.confidence >= 0.8 { return .green }
        if suggestion.confidence >= 0.6 { return .orange }
        return .secondary
    }
}
