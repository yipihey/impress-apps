//
//  IOSRecommendationSettingsView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-21.
//

import SwiftUI
import PublicationManagerCore

/// iOS settings view for the recommendation engine.
///
/// Two-tier UX matching the macOS version: simple mode (toggle + mode + variety)
/// with an advanced disclosure group for per-feature weight tuning.
struct IOSRecommendationSettingsView: View {

    // MARK: - State

    @State private var settings = RecommendationSettingsStore.Settings()
    @State private var isLoading = true
    @State private var showingTrainingHistory = false

    // MARK: - Derived State

    private var varietySliderValue: Binding<Double> {
        Binding(
            get: {
                let clamped = Double(max(3, min(50, settings.serendipitySlotFrequency)))
                return 1.0 - (clamped - 3.0) / 47.0
            },
            set: { newValue in
                let freq = Int(round(50.0 - newValue * 47.0))
                settings.serendipitySlotFrequency = max(3, min(50, freq))
            }
        )
    }

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
        List {
            // Enable/Disable
            Section {
                Toggle("Enable recommendation training", isOn: $settings.isEnabled)
            } footer: {
                Text("When enabled, imbib learns from your keep/dismiss/star actions. A 'Recommended' sort option appears in the list view.")
            }

            if settings.isEnabled {
                // Mode Picker
                Section {
                    Picker("Mode", selection: modeBinding) {
                        ForEach(RecommendationPreset.allCases, id: \.self) { preset in
                            Label(preset.displayName, systemImage: preset.icon)
                                .tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    if let preset = activePreset {
                        Text(preset.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Mode")
                }

                // Variety Slider
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Variety")
                        HStack {
                            Text("Less")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: varietySliderValue, in: 0...1, step: 0.05)
                            Text("More")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("How often to include papers from outside your usual reading")
                }

                // Training History
                Section {
                    Button {
                        showingTrainingHistory = true
                    } label: {
                        Label("Training History", systemImage: "clock.arrow.circlepath")
                    }
                }

                // Advanced
                Section {
                    DisclosureGroup("Advanced Settings") {
                        ForEach(FeatureType.tunableFeatures, id: \.self) { feature in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(feature.displayName)
                                        .font(.subheadline)
                                    Spacer()
                                    Text(String(format: "%.1f", settings.weight(for: feature)))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(
                                    value: Binding(
                                        get: { settings.weight(for: feature) },
                                        set: { settings.setWeight($0, for: feature) }
                                    ),
                                    in: 0.0...2.0,
                                    step: 0.1
                                )
                            }
                            .padding(.vertical, 2)
                        }

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
        .navigationTitle("Recommendations")
        .task {
            settings = await RecommendationSettingsStore.shared.settings()
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

    private var modeBinding: Binding<RecommendationPreset> {
        Binding(
            get: { activePreset ?? .balanced },
            set: { preset in
                settings.apply(preset: preset)
            }
        )
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
