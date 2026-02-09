//
//  SciXLibraryListView.swift
//  imbib
//
//  Created by Claude on 2026-01-09.
//

import SwiftUI
import PublicationManagerCore

/// Header view showing SciX library metadata (cloud icon, name, permissions, sync status).
///
/// Displayed above the `UnifiedPublicationListWrapper` when viewing a SciX library source.
/// All publication list logic (loading, actions, keyboard shortcuts) is handled by the wrapper.
struct SciXLibraryHeader: View {

    let library: CDSciXLibrary

    var body: some View {
        HStack {
            // Cloud icon
            Image(systemName: "cloud")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(library.displayName)
                    .font(.headline)

                HStack(spacing: 8) {
                    // Permission badge
                    Label(library.permissionLevelEnum.rawValue.capitalized, systemImage: library.permissionLevelEnum.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Sync status
                    syncStatusBadge
                }
            }

            Spacer()

            // Pending changes indicator
            if library.hasPendingChanges {
                Button {
                    // TODO: Show push confirmation sheet
                } label: {
                    Label("\(library.pendingChangeCount)", systemImage: "arrow.up.circle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("Pending changes to sync")
            }
        }
        .padding()
    }

    @ViewBuilder
    private var syncStatusBadge: some View {
        switch library.syncStateEnum {
        case .synced:
            Label("Synced", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .pending:
            Label("Pending", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.orange)
        case .error:
            Label("Error", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
