import SwiftUI
import OSLog

/// A shared Settings section for Spotlight index management.
///
/// Add this to any app's Settings view to let users manually rebuild
/// the Spotlight index. Reads the coordinator from `SpotlightBridge.shared`.
///
/// ```swift
/// SpotlightSettingsSection()
/// ```
public struct SpotlightSettingsSection: View {

    @State private var isRebuilding = false
    @State private var lastResult: String?

    public init() {}

    public var body: some View {
        Section("Spotlight") {
            HStack {
                VStack(alignment: .leading) {
                    Text("Spotlight Index")
                    Text("Makes your items searchable in system Spotlight (Cmd+Space)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isRebuilding {
                    ProgressView()
                        .controlSize(.small)
                    Text("Rebuilding...")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Rebuild") {
                        rebuildIndex()
                    }
                    .disabled(SpotlightBridge.shared.coordinator == nil)
                }
            }

            if let lastResult {
                Text(lastResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rebuildIndex() {
        guard let coordinator = SpotlightBridge.shared.coordinator else { return }
        isRebuilding = true
        lastResult = nil

        Task {
            await coordinator.forceRebuild()
            isRebuilding = false
            lastResult = "Rebuild complete"
        }
    }
}
