//
//  DashboardView.swift
//  impel
//
//  Dashboard grid + stat cards.
//  Moved verbatim from ContentView.swift (C0 mechanical decomposition,
//  Stage 2-C of the GUI unification) — no renames, no signature changes.
//

import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressKeyboard
import ImpressKit

// MARK: - Dashboard View

struct DashboardView: View {
    @EnvironmentObject var client: ImpelClient

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                // Thread stats
                StatCard(
                    title: "Active Threads",
                    value: "\(client.state.activeThreads.count)",
                    icon: "play.circle.fill",
                    color: .green
                )

                StatCard(
                    title: "Working Agents",
                    value: "\(client.state.workingAgents.count)",
                    icon: "person.fill",
                    color: .blue
                )

                StatCard(
                    title: "Pending Escalations",
                    value: "\(client.state.pendingEscalations.count)",
                    icon: "exclamationmark.circle.fill",
                    color: .orange
                )

                StatCard(
                    title: "Suggestions",
                    value: "\(client.state.activeSuggestions.count)",
                    icon: "lightbulb.fill",
                    color: .purple
                )
            }
            .padding()

            // Proactive suggestions (show important ones on dashboard)
            if !client.state.importantSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Proactive Suggestions")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "sparkles")
                            .foregroundColor(.purple)
                    }
                    .padding(.horizontal)

                    ForEach(client.state.importantSuggestions.prefix(3)) { suggestion in
                        SuggestionRow(suggestion: suggestion)
                            .padding(.horizontal)
                    }
                }
                .padding(.bottom, 8)
            }

            // Recent escalations
            if !client.state.pendingEscalations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pending Escalations")
                        .font(.headline)
                        .padding(.horizontal)

                    ForEach(client.state.pendingEscalations.prefix(3)) { escalation in
                        EscalationRow(escalation: escalation)
                            .padding(.horizontal)
                    }
                }
            }

            // Hot threads
            let hotThreads = client.state.threads
                .filter { $0.temperatureLevel == .hot }
                .sorted { $0.temperature > $1.temperature }

            if !hotThreads.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hot Threads")
                        .font(.headline)
                        .padding(.horizontal)

                    ForEach(hotThreads.prefix(5)) { thread in
                        ThreadRow(thread: thread)
                            .padding(.horizontal)
                    }
                }
            }
        }
        .navigationTitle("Dashboard")
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundColor(color)
                .symbolEffect(.bounce, value: value)

            Text(value)
                .font(.system(size: 36, weight: .bold))
                .contentTransition(.numericText())

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(.rect(cornerRadius: 12))
        .scaleEffect(appeared ? 1 : 0.9)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                appeared = true
            }
        }
    }
}
