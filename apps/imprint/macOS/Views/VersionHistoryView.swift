import SwiftUI

/// Version history "Time Machine" view for document snapshots
struct VersionHistoryView: View {
    @Binding var document: ImprintDocument
    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [DocumentSnapshot] = []
    @State private var selectedSnapshot: DocumentSnapshot?
    @State private var showingDiff = false

    var body: some View {
        HStack(spacing: 0) {
            // Timeline sidebar
            timelineSidebar
                .frame(width: 280)
                .accessibilityIdentifier("versionHistory.timeline")

            Divider()

            // Preview area
            previewArea
                .accessibilityIdentifier("versionHistory.preview")
        }
        .frame(width: 900, height: 600)
        .accessibilityIdentifier("versionHistory.container")
        .onAppear {
            loadSnapshots()
        }
    }

    private var timelineSidebar: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Version History")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            // Snapshot list
            if snapshots.isEmpty {
                noSnapshotsView
            } else {
                List(snapshots, selection: $selectedSnapshot) { snapshot in
                    SnapshotRow(snapshot: snapshot)
                        .tag(snapshot)
                }
                .listStyle(.sidebar)
            }

            Divider()

            // Actions
            HStack {
                Button("Compare...") {
                    showingDiff = true
                }
                .disabled(selectedSnapshot == nil)
                .accessibilityIdentifier("versionHistory.compareButton")

                Spacer()

                Button("Restore") {
                    restoreSnapshot()
                }
                .disabled(selectedSnapshot == nil)
                .accessibilityIdentifier("versionHistory.restoreButton")
            }
            .padding()
        }
    }

    private var previewArea: some View {
        VStack {
            if let snapshot = selectedSnapshot {
                // Show preview of selected snapshot
                ScrollView {
                    Text(snapshot.sourcePreview)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                // Metadata
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Created: \(snapshot.timestamp.formatted())")
                        Text("Words: \(snapshot.wordCount)")
                        if let label = snapshot.label {
                            Text("Label: \(label)")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)

                    Spacer()
                }
                .padding()
            } else {
                emptyPreviewState
            }
        }
    }

    private var noSnapshotsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundColor(.secondary)

            Text("No Snapshots Yet")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Snapshots are created automatically as you work")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyPreviewState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Select a Snapshot")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Choose a version from the timeline to preview")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadSnapshots() {
        // TODO: Load from CRDT history
        // For now, create sample snapshots
        let now = Date()
        snapshots = [
            DocumentSnapshot(
                id: UUID(),
                timestamp: now.addingTimeInterval(-3600),
                label: "Session start",
                wordCount: 1250,
                citationCount: 5,
                sourcePreview: "= Introduction\n\nThis version has the original introduction..."
            ),
            DocumentSnapshot(
                id: UUID(),
                timestamp: now.addingTimeInterval(-1800),
                label: nil,
                wordCount: 1450,
                citationCount: 7,
                sourcePreview: "= Introduction\n\nThis version has updated content..."
            ),
            DocumentSnapshot(
                id: UUID(),
                timestamp: now.addingTimeInterval(-600),
                label: "Before major edit",
                wordCount: 1520,
                citationCount: 8,
                sourcePreview: "= Introduction\n\nMost recent content..."
            ),
        ]
    }

    private func restoreSnapshot() {
        guard let snapshot = selectedSnapshot else { return }

        // TODO: Restore from CRDT snapshot
        // For now, just close the view
        dismiss()
    }
}

/// A document snapshot in the version history
struct DocumentSnapshot: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let label: String?
    let wordCount: Int
    let citationCount: Int
    let sourcePreview: String
}

/// Row view for a snapshot in the timeline
struct SnapshotRow: View {
    let snapshot: DocumentSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snapshot.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Spacer()
            }

            if let label = snapshot.label {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.blue)
            }

            HStack(spacing: 8) {
                Label("\(snapshot.wordCount)", systemImage: "text.word.spacing")
                Label("\(snapshot.citationCount)", systemImage: "quote.opening")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    VersionHistoryView(document: .constant(ImprintDocument()))
}
