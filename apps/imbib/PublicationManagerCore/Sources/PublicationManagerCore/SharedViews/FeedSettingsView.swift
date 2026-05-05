//
//  FeedSettingsView.swift
//  PublicationManagerCore
//
//  Sheet for editing feed-specific settings on any smart search.
//

import SwiftUI
import OSLog

#if os(macOS)

/// Sheet for configuring feed-specific settings on any smart search (inbox or library).
///
/// Editable settings:
/// - Save target library (where S key sends papers)
/// - Retention policy (auto-delete old papers)
/// - Auto-remove read papers
/// - Show dismissed papers toggle
/// - Auto-refresh toggle and interval
public struct FeedSettingsView: View {

    let feedID: UUID
    let onDismiss: () -> Void

    @State private var feed: SmartSearch?

    // Editable state
    @State private var saveTargetID: UUID?
    @State private var retentionDays: Int = 0
    @State private var autoRemoveRead: Bool = false
    @State private var showDismissed: Bool = false
    @State private var maxResults: Int = 500
    @State private var autoRefreshEnabled: Bool = true
    @State private var refreshPreset: RefreshIntervalPreset = .daily

    private let store = RustStoreAdapter.shared

    public init(feedID: UUID, onDismiss: @escaping () -> Void) {
        self.feedID = feedID
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Text("Feed Settings")
                    .font(.title3)
                    .fontWeight(.semibold)
                if let feed {
                    Text("— \(feed.name)")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            if feed != nil {
                // Save target
                FeedSaveTargetPicker(saveTargetID: $saveTargetID)

                Divider()

                // Fetch limit
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fetch Limit")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Picker("Max results per refresh", selection: $maxResults) {
                        Text("100").tag(100)
                        Text("200").tag(200)
                        Text("500").tag(500)
                        Text("1000").tag(1000)
                        Text("2000").tag(2000)
                    }
                    .frame(maxWidth: 300)

                    Text("Higher values find more new papers but take longer to fetch.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                // Retention
                VStack(alignment: .leading, spacing: 8) {
                    Text("Retention")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Picker("Auto-delete papers older than", selection: $retentionDays) {
                        Text("Never").tag(0)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    }
                    .frame(maxWidth: 300)

                    Toggle("Auto-remove read papers", isOn: $autoRemoveRead)
                        .font(.subheadline)

                    Toggle("Show previously dismissed papers", isOn: $showDismissed)
                        .font(.subheadline)
                }

                Divider()

                // Refresh settings
                VStack(alignment: .leading, spacing: 8) {
                    Text("Refresh")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Toggle("Auto-refresh", isOn: $autoRefreshEnabled)
                        .font(.subheadline)

                    if autoRefreshEnabled {
                        Picker("Refresh interval", selection: $refreshPreset) {
                            ForEach(RefreshIntervalPreset.allCases, id: \.self) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .frame(maxWidth: 200)
                    }
                }

                Spacer()

                // Actions
                HStack {
                    Spacer()
                    Button("Cancel") {
                        onDismiss()
                    }
                    .keyboardShortcut(.escape, modifiers: [])

                    Button("Save") {
                        saveSettings()
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            } else {
                Text("Feed not found")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 400, height: 580)
        .onAppear {
            loadFeed()
        }
    }

    private func loadFeed() {
        guard let ss = store.getSmartSearch(id: feedID) else { return }
        feed = ss
        saveTargetID = ss.saveTargetID
        maxResults = ss.maxResults
        retentionDays = ss.retentionDays ?? 0
        autoRemoveRead = ss.autoRemoveRead
        showDismissed = ss.showDismissed
        autoRefreshEnabled = ss.autoRefreshEnabled
        refreshPreset = RefreshIntervalPreset(rawValue: Int32(ss.refreshIntervalSeconds)) ?? .daily
    }

    private func saveSettings() {
        store.updateSmartSearchFeedSettings(
            id: feedID,
            saveTargetID: saveTargetID,
            showDismissed: showDismissed,
            retentionDays: retentionDays > 0 ? retentionDays : nil,
            autoRemoveRead: autoRemoveRead
        )

        // Update max results
        store.updateIntField(id: feedID, field: "max_results", value: Int64(maxResults))

        // Update refresh settings separately
        store.updateBoolField(id: feedID, field: "auto_refresh_enabled", value: autoRefreshEnabled)
        if autoRefreshEnabled {
            store.updateIntField(id: feedID, field: "refresh_interval_seconds", value: Int64(refreshPreset.rawValue))
        }

        Logger.library.infoCapture("Updated feed settings for \(feedID): saveTarget=\(saveTargetID?.uuidString ?? "default"), retention=\(retentionDays)d, autoRemoveRead=\(autoRemoveRead), showDismissed=\(showDismissed), autoRefresh=\(autoRefreshEnabled)", category: "feed")
    }
}

#endif
