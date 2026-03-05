import SwiftUI
import OSLog

/// A shared Settings section for Spotlight index management.
///
/// Add this to any app's Settings > Advanced section to let users
/// manually rebuild the Spotlight index.
///
/// ```swift
/// SpotlightSettingsSection(coordinator: spotlightCoordinator)
/// ```
public struct SpotlightSettingsSection: View {

    private let coordinator: SpotlightSyncCoordinator?
    @State private var isRebuilding = false
    @State private var lastResult: String?

    public init(coordinator: SpotlightSyncCoordinator?) {
        self.coordinator = coordinator
    }

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
                    .disabled(coordinator == nil)
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
        guard let coordinator else { return }
        isRebuilding = true
        lastResult = nil

        let capturedCoordinator = coordinator
        Task {
            await capturedCoordinator.forceRebuild()
            isRebuilding = false
            lastResult = "Rebuild complete"
        }
    }
}
