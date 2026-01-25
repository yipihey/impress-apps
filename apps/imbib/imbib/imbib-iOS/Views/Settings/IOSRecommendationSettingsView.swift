//
//  IOSRecommendationSettingsView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-21.
//

import SwiftUI
import PublicationManagerCore

/// iOS settings view for the recommendation engine.
struct IOSRecommendationSettingsView: View {

    // MARK: - Environment

    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - State

    @State private var settings = RecommendationSettingsStore.Settings()
    @State private var isLoading = true
    @State private var isBuildingIndex = false
    @State private var indexedCount = 0
    @State private var showingTrainingHistory = false

    // MARK: - Body

    var body: some View {
        List {
            // Enable/Disable
            Section {
                Toggle("Enable Recommendations", isOn: $settings.isEnabled)
            } footer: {
                Text("Sort Inbox by 'Recommended' to see papers ranked by predicted relevance.")
            }

            // Engine Type Selection
            Section {
                Picker("Engine Type", selection: $settings.engineType) {
                    ForEach(RecommendationEngineType.allCases) { engineType in
                        Label(engineType.displayName, systemImage: engineType.icon)
                            .tag(engineType)
                    }
                }

                // Engine description
                Text(settings.engineType.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Build index button for semantic/hybrid modes
                if settings.engineType.requiresEmbeddings {
                    Button {
                        buildIndex()
                    } label: {
                        HStack {
                            if isBuildingIndex {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Building Index...")
                            } else {
                                Label("Build Similarity Index", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Spacer()
                            if indexedCount > 0 {
                                Text("\(indexedCount) papers")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isBuildingIndex)
                }
            } header: {
                Text("Engine Type")
            } footer: {
                if settings.engineType.requiresEmbeddings {
                    Text("AI-powered modes use semantic similarity to find related papers.")
                }
            }

            // Discovery Settings
            Section("Discovery") {
                Stepper(
                    "Serendipity: 1 per \(settings.serendipitySlotFrequency)",
                    value: $settings.serendipitySlotFrequency,
                    in: 3...50
                )

                Stepper(
                    "Decay: \(settings.negativePrefDecayDays) days",
                    value: $settings.negativePrefDecayDays,
                    in: 7...365
                )
            }

            // Presets
            Section("Presets") {
                ForEach([RecommendationPreset.focused, .balanced, .exploratory, .research], id: \.self) { preset in
                    Button {
                        settings.apply(preset: preset)
                    } label: {
                        HStack {
                            Image(systemName: presetIcon(preset))
                                .frame(width: 24)
                            VStack(alignment: .leading) {
                                Text(preset.displayName)
                                Text(preset.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }

            // Training History
            Section {
                Button {
                    showingTrainingHistory = true
                } label: {
                    Label("Training History", systemImage: "clock.arrow.circlepath")
                }

                Button("Reset to Defaults", role: .destructive) {
                    Task {
                        await RecommendationSettingsStore.shared.resetToDefaults()
                        settings = await RecommendationSettingsStore.shared.settings()
                    }
                }
            }
        }
        .navigationTitle("Recommendations")
        .task {
            settings = await RecommendationSettingsStore.shared.settings()
            indexedCount = await EmbeddingService.shared.indexedCount()
            isLoading = false
        }
        .onChange(of: settings) { _, newSettings in
            guard !isLoading else { return }
            Task {
                await RecommendationSettingsStore.shared.update(newSettings)
            }
        }
        .sheet(isPresented: $showingTrainingHistory) {
            IOSTrainingHistoryView()
        }
    }

    // MARK: - Helpers

    private func buildIndex() {
        Task {
            isBuildingIndex = true
            // Index all libraries except "Dismissed" and system libraries
            let librariesToIndex = libraryManager.libraries.filter { library in
                let name = library.name.lowercased()
                return name != "dismissed" && !library.isSystemLibrary
            }
            indexedCount = await RecommendationEngine.shared.buildEmbeddingIndex(from: librariesToIndex)
            isBuildingIndex = false
        }
    }

    private func presetIcon(_ preset: RecommendationPreset) -> String {
        switch preset {
        case .focused: return "scope"
        case .balanced: return "scale.3d"
        case .exploratory: return "binoculars"
        case .research: return "text.book.closed"
        case .defaults: return "arrow.counterclockwise"
        }
    }
}

// MARK: - iOS Training History View

struct IOSTrainingHistoryView: View {
    @State private var events: [TrainingEvent] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if events.isEmpty {
                    ContentUnavailableView(
                        "No Training History",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Keep and dismiss papers to train the engine.")
                    )
                } else {
                    List {
                        ForEach(groupedByDate, id: \.date) { group in
                            Section(group.date.formatted(date: .abbreviated, time: .omitted)) {
                                ForEach(group.events) { event in
                                    IOSTrainingEventRow(event: event, onUndo: undoEvent)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Training History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            events = await SignalCollector.shared.recentEvents(limit: 100)
            isLoading = false
        }
    }

    private var groupedByDate: [(date: Date, events: [TrainingEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: events) { event in
            calendar.startOfDay(for: event.date)
        }
        return grouped.sorted { $0.key > $1.key }
            .map { (date: $0.key, events: $0.value) }
    }

    private func undoEvent(_ event: TrainingEvent) {
        Task {
            await SignalCollector.shared.undoEvent(event)
            events.removeAll { $0.id == event.id }
        }
    }
}

// MARK: - iOS Training Event Row

private struct IOSTrainingEventRow: View {
    let event: TrainingEvent
    let onUndo: (TrainingEvent) -> Void

    var body: some View {
        HStack {
            Image(systemName: event.action.icon)
                .foregroundStyle(event.action.isPositive ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.publicationTitle)
                    .lineLimit(1)
                Text(event.publicationAuthors)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Undo") {
                onUndo(event)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

#Preview {
    NavigationStack {
        IOSRecommendationSettingsView()
    }
}
