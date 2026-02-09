//
//  RecommendationSettingsTab.swift
//  imbib
//
//  Created by Claude on 2026-01-19.
//

import SwiftUI
import PublicationManagerCore

/// Settings tab for the transparent recommendation engine (ADR-020).
///
/// All weights are user-adjustable and the UI explains what each feature means.
struct RecommendationSettingsTab: View {

    // MARK: - Environment

    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - State

    @State private var settings = RecommendationSettingsStore.Settings()
    @State private var isLoading = true
    @State private var showingTrainingHistory = false
    @State private var trainingEventCount = 0
    @State private var isBuildingIndex = false
    @State private var indexedCount = 0

    // MARK: - Body

    var body: some View {
        Form {
            // Enable/Disable
            Section {
                Toggle("Enable recommendation sorting", isOn: $settings.isEnabled)
                    .help("When enabled, you can sort Inbox by 'Recommended' to see papers ranked by predicted relevance")
                    .accessibilityIdentifier(AccessibilityID.Settings.Recommendations.enableToggle)
            } header: {
                Text("Enable")
            } footer: {
                Text("Recommendations use a transparent weighted formula. You can see exactly why each paper is ranked where it is.")
            }

            // Engine Type Selection
            Section {
                Picker("Recommendation Engine", selection: $settings.engineType) {
                    ForEach(RecommendationEngineType.allCases) { engineType in
                        HStack {
                            Image(systemName: engineType.icon)
                            Text(engineType.displayName)
                        }
                        .tag(engineType)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(AccessibilityID.Settings.Recommendations.algorithmPicker)

                // Engine description
                HStack(spacing: 12) {
                    Image(systemName: settings.engineType.icon)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(settings.engineType.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                // Build index button for semantic/hybrid modes
                if settings.engineType.requiresEmbeddings {
                    HStack {
                        Button {
                            Task {
                                isBuildingIndex = true
                                // Index all libraries except "Dismissed" and system libraries
                                let librariesToIndex = libraryManager.libraries.filter { library in
                                    let name = library.name.lowercased()
                                    return name != "dismissed" && name != "exploration"
                                }
                                print("🔍 Building index for \(librariesToIndex.count) libraries")
                                // TODO: Reconnect to RecommendationEngine after Rust migration
                                // RecommendationEngine.shared.buildEmbeddingIndex needs migration to use UUIDs
                                let libraryIDs = librariesToIndex.map(\.id)
                                indexedCount = 0 // Placeholder until RecommendationEngine is migrated
                                _ = libraryIDs
                                print("🔍 Index built: \(indexedCount) publications indexed")
                                isBuildingIndex = false
                            }
                        } label: {
                            if isBuildingIndex {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Build Similarity Index", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(isBuildingIndex)

                        Spacer()

                        if indexedCount > 0 {
                            Text("\(indexedCount) papers indexed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Engine Type")
            } footer: {
                if settings.engineType.requiresEmbeddings {
                    Text("AI-powered modes require building a similarity index from your library. This may take a moment for large libraries.")
                }
            }

            // Anti-Filter-Bubble Section
            Section("Discovery & Diversity") {
                Stepper(
                    "Serendipity: 1 per \(settings.serendipitySlotFrequency) papers",
                    value: $settings.serendipitySlotFrequency,
                    in: 3...50
                )
                .help("Insert one 'serendipity' paper every N papers to help discover new topics")

                Stepper(
                    "Forget dismissals after \(settings.negativePrefDecayDays) days",
                    value: $settings.negativePrefDecayDays,
                    in: 7...365
                )
                .help("Negative preferences decay over time to prevent permanent filter bubbles")
            }

            // Feature Weights Section - Grouped by Category
            Section("Feature Weights") {
                ForEach(FeatureCategory.allCases, id: \.self) { category in
                    DisclosureGroup(category.rawValue) {
                        ForEach(FeatureType.allCases.filter { $0.category == category }) { feature in
                            WeightSlider(
                                feature: feature,
                                weight: binding(for: feature)
                            )
                        }
                    }
                }
            }

            // Presets Section
            Section("Presets") {
                HStack(spacing: 12) {
                    PresetButton(preset: .focused, action: applyPreset)
                    PresetButton(preset: .balanced, action: applyPreset)
                    PresetButton(preset: .exploratory, action: applyPreset)
                    PresetButton(preset: .research, action: applyPreset)
                }
            }

            // Training History Section
            Section {
                Button {
                    showingTrainingHistory = true
                } label: {
                    HStack {
                        Label("View Training History", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        if trainingEventCount > 0 {
                            Text("\(trainingEventCount) events")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Button("Reset to Defaults", role: .destructive) {
                    Task {
                        await RecommendationSettingsStore.shared.resetToDefaults()
                        settings = await RecommendationSettingsStore.shared.settings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        .task {
            settings = await RecommendationSettingsStore.shared.settings()
            trainingEventCount = await SignalCollector.shared.recentEvents(limit: 1000).count
            isLoading = false
        }
        .onChange(of: settings) { _, newSettings in
            guard !isLoading else { return }
            Task {
                await RecommendationSettingsStore.shared.update(newSettings)
            }
        }
        .sheet(isPresented: $showingTrainingHistory) {
            TrainingHistoryView()
        }
    }

    // MARK: - Helpers

    private func binding(for feature: FeatureType) -> Binding<Double> {
        Binding(
            get: { settings.weight(for: feature) },
            set: { settings.setWeight($0, for: feature) }
        )
    }

    private func applyPreset(_ preset: RecommendationPreset) {
        settings.apply(preset: preset)
    }
}

// MARK: - Weight Slider

/// Slider for adjusting a single feature weight.
private struct WeightSlider: View {
    let feature: FeatureType
    @Binding var weight: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(feature.displayName)
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.2f", weight))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                // Negative weights for penalty features
                if feature.isNegativeFeature {
                    Slider(value: $weight, in: -2.0...0.0, step: 0.1)
                } else {
                    Slider(value: $weight, in: 0.0...2.0, step: 0.1)
                }
            }

            Text(feature.featureDescription)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preset Button

/// Button for applying a weight preset.
private struct PresetButton: View {
    let preset: RecommendationPreset
    let action: (RecommendationPreset) -> Void

    var body: some View {
        Button {
            action(preset)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title2)
                Text(preset.displayName)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .help(preset.description)
    }

    private var icon: String {
        switch preset {
        case .focused: return "scope"
        case .balanced: return "scale.3d"
        case .exploratory: return "binoculars"
        case .research: return "text.book.closed"
        case .defaults: return "arrow.counterclockwise"
        }
    }
}

// MARK: - Training History View

/// Shows recent training events with ability to undo.
struct TrainingHistoryView: View {
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
                        description: Text("Keep and dismiss papers to train the recommendation engine.")
                    )
                } else {
                    List {
                        ForEach(groupedByDate, id: \.date) { group in
                            Section(group.date.formatted(date: .abbreviated, time: .omitted)) {
                                ForEach(group.events) { event in
                                    TrainingEventRow(event: event, onUndo: undoEvent)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Training History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
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

// MARK: - Training Event Row

private struct TrainingEventRow: View {
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

            Text(event.date, style: .time)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Undo") {
                onUndo(event)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    RecommendationSettingsTab()
}
