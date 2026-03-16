import SwiftUI

/// Reusable settings section for configuring undo history depth.
/// Drop into any app's settings view.
public struct UndoHistorySettingsSection: View {
    @Binding var maxUndoLevels: Int

    /// Preset options for undo depth.
    private static let presets: [(String, Int)] = [
        ("10", 10),
        ("25", 25),
        ("50", 50),
        ("100", 100),
        ("200", 200),
    ]

    public init(maxUndoLevels: Binding<Int>) {
        self._maxUndoLevels = maxUndoLevels
    }

    public var body: some View {
        Section("Undo History") {
            Picker("Maximum undo levels", selection: $maxUndoLevels) {
                ForEach(Self.presets, id: \.1) { label, value in
                    Text(label).tag(value)
                }
            }
            .onChange(of: maxUndoLevels) { _, newValue in
                UndoHistoryStore.shared.maxEntries = newValue
            }
        }
    }
}
