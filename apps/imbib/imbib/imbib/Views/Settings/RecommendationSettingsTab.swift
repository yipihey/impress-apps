//
//  RecommendationSettingsTab.swift
//  imbib
//
//  Created by Claude on 2026-01-19.
//

import SwiftUI
import PublicationManagerCore

/// Settings tab for the recommendation engine.
///
/// Two-tier UX: simple mode (toggle + mode + variety slider) for 90% of users,
/// with an advanced disclosure group for per-feature weight tuning.
struct RecommendationSettingsTab: View {

    // MARK: - State

    @State private var settings = RecommendationSettingsStore.Settings()
    @State private var isLoading = true
    @State private var showingTrainingHistory = false
    @State private var trainingEventCount = 0

    // MARK: - Derived State

    /// Map serendipity frequency (3-50) to a 0-1 slider value.
    /// Lower frequency = more variety (higher slider value).
    private var varietySliderValue: Binding<Double> {
        Binding(
            get: {
                // Map 3...50 to 1.0...0.0 (inverted: lower freq = more variety)
                let clamped = Double(max(3, min(50, settings.serendipitySlotFrequency)))
                return 1.0 - (clamped - 3.0) / 47.0
            },
            set: { newValue in
                // Map 0.0...1.0 back to 50...3
                let freq = Int(round(50.0 - newValue * 47.0))
                settings.serendipitySlotFrequency = max(3, min(50, freq))
            }
        )
    }

    /// Detect which preset best matches current weights.
    private var activePreset: RecommendationPreset? {
        for preset in RecommendationPreset.allCases {
            var matches = true
            for (feature, presetWeight) in preset.weights where !feature.isMuteFilter {
                let currentWeight = settings.weight(for: feature)
                if abs(currentWeight - presetWeight) > 0.15 {
                    matches = false
                    break
                }
            }
            if matches { return preset }
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        Form {
            // Simple Mode: Enable + Mode Picker + Variety Slider
            Section {
                Toggle("Enable recommendation training", isOn: $settings.isEnabled)
                    .help("Train the engine by keeping, dismissing, and starring papers. Unlocks the 'Recommended' sort option.")
                    .accessibilityIdentifier(AccessibilityID.Settings.Recommendations.enableToggle)
            } header: {
                Text("Recommendations")
            } footer: {
                Text("When enabled, imbib learns from your keep/dismiss/star actions. A 'Recommended' sort option appears in the list view.")
            }

            if settings.isEnabled {
                // Mode Picker (3-way segmented)
                Section {
                    Picker("Mode", selection: modeBinding) {
                        ForEach(RecommendationPreset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    // Mode description
                    if let preset = activePreset {
                        Text(preset.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                    }
                } header: {
                    Text("Mode")
                }

                // Variety Slider
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Variety")
                            .font(.subheadline)
                        HStack {
                            Text("Less")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: varietySliderValue, in: 0...1, step: 0.05)
                            Text("More")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("How often to include papers from outside your usual reading")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Training History Link
                Section {
                    Button {
                        showingTrainingHistory = true
                    } label: {
                        HStack {
                            Label("View training history", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            if trainingEventCount > 0 {
                                Text("\(trainingEventCount) events")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Advanced Settings
                Section {
                    DisclosureGroup("Advanced settings") {
                        // Feature Weight Sliders
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(FeatureType.tunableFeatures, id: \.self) { feature in
                                WeightSlider(
                                    feature: feature,
                                    weight: binding(for: feature)
                                )
                            }
                        }
                        .padding(.vertical, 8)

                        Divider()

                        // Serendipity frequency (numeric)
                        Stepper(
                            "Serendipity: 1 per \(settings.serendipitySlotFrequency) papers",
                            value: $settings.serendipitySlotFrequency,
                            in: 3...50
                        )
                        .help("Insert one discovery paper every N papers")

                        // Negative decay
                        Stepper(
                            "Forget dismissals after \(settings.negativePrefDecayDays) days",
                            value: $settings.negativePrefDecayDays,
                            in: 7...365
                        )
                        .help("Negative preferences decay over time to prevent permanent filter bubbles")

                        Divider()

                        // Reset to Defaults
                        Button("Reset to Defaults", role: .destructive) {
                            Task {
                                await RecommendationSettingsStore.shared.resetToDefaults()
                                settings = await RecommendationSettingsStore.shared.settings()
                            }
                        }
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

    private var modeBinding: Binding<RecommendationPreset> {
        Binding(
            get: { activePreset ?? .balanced },
            set: { preset in
                settings.apply(preset: preset)
            }
        )
    }

    private func binding(for feature: FeatureType) -> Binding<Double> {
        Binding(
            get: { settings.weight(for: feature) },
            set: { settings.setWeight($0, for: feature) }
        )
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
                Text(String(format: "%.1f", weight))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $weight, in: 0.0...2.0, step: 0.1)

            Text(feature.featureDescription)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
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
