//
//  ThreadListView.swift
//  impel
//
//  Research-thread list + row.
//  Moved verbatim from ContentView.swift (C0 mechanical decomposition,
//  Stage 2-C of the GUI unification) — no renames, no signature changes.
//

import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressKeyboard
import ImpressKit

// MARK: - Thread List View

struct ThreadListView: View {
    let threads: [ResearchThread]
    @Binding var selectedThread: ResearchThread?

    var body: some View {
        List(threads, selection: $selectedThread) { thread in
            ThreadRow(thread: thread)
                .tag(thread)
        }
        .navigationTitle("Threads")
    }
}

struct ThreadRow: View {
    let thread: ResearchThread

    var body: some View {
        HStack {
            Image(systemName: thread.state.systemImage)
                .foregroundColor(stateColor)
                .symbolEffect(.pulse, isActive: thread.state == .active)

            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .font(.headline)

                HStack(spacing: 8) {
                    Text(thread.state.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let agent = thread.claimedBy {
                        Text("• \(agent)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Temperature indicator with glow for hot threads
            Circle()
                .fill(temperatureColor)
                .frame(width: 12, height: 12)
                .overlay {
                    if thread.temperatureLevel == .hot {
                        Circle()
                            .fill(temperatureColor.opacity(0.5))
                            .frame(width: 18, height: 18)
                            .blur(radius: 4)
                    }
                }
                .help("Temperature: \(String(format: "%.1f", thread.temperature))")
                .animation(.easeInOut(duration: 0.3), value: thread.temperatureLevel)
        }
        .padding(.vertical, 4)
    }

    private var stateColor: Color {
        switch thread.state {
        case .active: return .green
        case .blocked: return .orange
        case .review: return .blue
        case .complete: return .gray
        case .killed: return .red
        case .embryo: return .secondary
        }
    }

    private var temperatureColor: Color {
        switch thread.temperatureLevel {
        case .hot: return .red
        case .warm: return .orange
        case .cold: return .blue
        }
    }
}
