//
//  EscalationListView.swift
//  impel
//
//  Escalation list + row.
//  Moved verbatim from ContentView.swift (C0 mechanical decomposition,
//  Stage 2-C of the GUI unification) — no renames, no signature changes.
//

import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressKeyboard
import ImpressKit

// MARK: - Escalation List View

struct EscalationListView: View {
    let escalations: [Escalation]

    var body: some View {
        List(escalations) { escalation in
            EscalationRow(escalation: escalation)
        }
        .navigationTitle("Escalations")
    }
}

struct EscalationRow: View {
    @EnvironmentObject var client: ImpelClient
    let escalation: Escalation
    @State private var isResolving = false
    @State private var isResolved = false
    @State private var errorMessage: String?
    @State private var shakeCount = 0

    var body: some View {
        ZStack {
            // Success overlay
            if isResolved {
                HStack {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: isResolved)
                    Spacer()
                }
                .transition(.scale.combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: escalation.category.systemImage)
                        .foregroundColor(.orange)

                    Text(escalation.title)
                        .font(.headline)

                    Spacer()

                    Text("P\(escalation.priority)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(priorityColor.opacity(0.2))
                        .clipShape(.rect(cornerRadius: 4))
                }

                Text(escalation.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                if let options = escalation.options, !options.isEmpty {
                    HStack {
                        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                            Button(option) {
                                resolveWithOption(index: index, label: option)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isResolving || isResolved)
                        }

                        if isResolving {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .opacity(isResolved ? 0.3 : 1)
        }
        .padding(.vertical, 4)
        .modifier(ShakeEffect(shakes: shakeCount))
        .animation(.default, value: isResolved)
    }

    private func resolveWithOption(index: Int, label: String) {
        let escalationId = escalation.id
        isResolving = true
        errorMessage = nil

        Task {
            do {
                try await client.resolveEscalation(id: escalationId, optionIndex: index, optionLabel: label)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    isResolved = true
                }
            } catch {
                errorMessage = error.localizedDescription
                // Shake on error
                withAnimation(.default) {
                    shakeCount += 1
                }
            }
            isResolving = false
        }
    }

    private var priorityColor: Color {
        if escalation.priority >= 8 { return .red }
        if escalation.priority >= 5 { return .orange }
        return .yellow
    }
}
