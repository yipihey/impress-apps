//
//  ViewingSettingsTab.swift
//  imbib
//
//  Created by Claude on 2026-01-06.
//

import SwiftUI
import PublicationManagerCore

/// Settings tab for customizing list view appearance.
struct ViewingSettingsTab: View {

    // MARK: - State

    @State private var settings = ListViewSettings()
    @State private var isLoading = true

    // MARK: - Body

    var body: some View {
        Form {
            Section("List View") {
                // Field visibility toggles
                Toggle("Show year", isOn: $settings.showYear)
                Toggle("Show title", isOn: $settings.showTitle)
                Toggle("Show venue (journal/source)", isOn: $settings.showVenue)
                Toggle("Show citation count", isOn: $settings.showCitationCount)
                Toggle("Show date added", isOn: $settings.showDateAdded)
                    .help("Show when the paper was added (time, yesterday, or date)")
                Toggle("Show unread indicator", isOn: $settings.showUnreadIndicator)
                Toggle("Show attachment indicator", isOn: $settings.showAttachmentIndicator)

                // Abstract line limit
                Stepper(
                    "Abstract rows: \(settings.abstractLineLimit)",
                    value: $settings.abstractLineLimit,
                    in: 0...10
                )

                // Row density picker
                Picker("Row density", selection: $settings.rowDensity) {
                    Text("Compact").tag(RowDensity.compact)
                    Text("Default").tag(RowDensity.default)
                    Text("Spacious").tag(RowDensity.spacious)
                }
            }

            Section {
                Button("Reset to Defaults") {
                    Task {
                        await ListViewSettingsStore.shared.reset()
                        settings = await ListViewSettingsStore.shared.settings
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            settings = await ListViewSettingsStore.shared.settings
            isLoading = false
        }
        .onChange(of: settings) { _, newSettings in
            guard !isLoading else { return }
            Task {
                await ListViewSettingsStore.shared.update(newSettings)
            }
        }
    }
}

#Preview {
    ViewingSettingsTab()
}
