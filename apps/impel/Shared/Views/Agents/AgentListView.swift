//
//  AgentListView.swift
//  impel
//
//  Agent roster list.
//  Moved verbatim from ContentView.swift (C0 mechanical decomposition,
//  Stage 2-C of the GUI unification) — no renames, no signature changes.
//

import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressKeyboard
import ImpressKit

// MARK: - Agent List View

struct AgentListView: View {
    let agents: [Agent]

    var body: some View {
        List(agents) { agent in
            HStack {
                Image(systemName: agent.agentType.systemImage)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.id)
                        .font(.headline)

                    Text(agent.agentType.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(agent.status.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(statusColor(agent.status).opacity(0.2))
                    .cornerRadius(4)

                Text("\(agent.threadsCompleted)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Agents")
    }

    private func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .working: return .green
        case .idle: return .blue
        case .paused: return .orange
        case .terminated: return .red
        }
    }
}
