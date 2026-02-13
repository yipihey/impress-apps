//
//  ShareManagementView.swift
//  PublicationManagerCore
//
//  Manage CloudKit share participants for a library.
//

import SwiftUI
import OSLog

// MARK: - Share Management View

/// Displays and manages participants for a shared library.
///
/// Shows current participants with their permissions, and provides
/// controls for the share owner to add/remove participants and change permissions.
public struct ShareManagementView: View {

    let libraryID: UUID

    @State private var participants: [ShareParticipant] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showStopSharingConfirmation = false
    @Environment(\.dismiss) private var dismiss

    public init(libraryID: UUID) {
        self.libraryID = libraryID
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sharing")
                #if os(macOS)
                .frame(minWidth: 400, minHeight: 300)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task {
            await loadParticipants()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading participants...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage {
            ContentUnavailableView {
                Label("Unable to Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") {
                    Task { await loadParticipants() }
                }
            }
        } else {
            participantList
        }
    }

    private var participantList: some View {
        List {
            Section("Participants") {
                ForEach(participants) { participant in
                    participantRow(participant)
                }
            }

            if isOwner {
                Section {
                    Button("Stop Sharing", role: .destructive) {
                        showStopSharingConfirmation = true
                    }
                } footer: {
                    Text("Revoking access will remove all participants and stop syncing comments with collaborators.")
                }
            }
        }
        .confirmationDialog(
            "Stop Sharing?",
            isPresented: $showStopSharingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Sharing", role: .destructive) {
                Task { await stopSharing() }
            }
        } message: {
            Text("All participants will lose access to shared comments. Your local comments will be preserved.")
        }
    }

    @ViewBuilder
    private func participantRow(_ participant: ShareParticipant) -> some View {
        HStack(spacing: 12) {
            // Avatar
            Text(participant.initials)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(participant.isCurrentUser ? .blue : .gray)
                .clipShape(Circle())

            // Name & status
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(participant.displayLabel)
                        .font(.body)
                    if participant.isOwner {
                        Text("Owner")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.blue)
                            .clipShape(Capsule())
                    }
                    if participant.isCurrentUser {
                        Text("You")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if participant.acceptanceStatus == .pending {
                    Text("Invitation pending")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let email = participant.emailAddress {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Permission badge
            if !participant.isOwner {
                permissionBadge(participant)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func permissionBadge(_ participant: ShareParticipant) -> some View {
        if isOwner {
            Menu {
                Button {
                    Task {
                        await setPermission(.readOnly, for: participant)
                    }
                } label: {
                    Label("Read Only", systemImage: participant.permission == .readOnly ? "checkmark" : "")
                }

                Button {
                    Task {
                        await setPermission(.readWrite, for: participant)
                    }
                } label: {
                    Label("Read & Write", systemImage: participant.permission == .readWrite ? "checkmark" : "")
                }
            } label: {
                Text(participant.permission == .readWrite ? "Read & Write" : "Read Only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(participant.permission == .readWrite ? "Read & Write" : "Read Only")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - State

    private var isOwner: Bool {
        participants.first(where: \.isCurrentUser)?.isOwner ?? false
    }

    // MARK: - Actions

    private func loadParticipants() async {
        isLoading = true
        errorMessage = nil
        do {
            participants = try await LibrarySharingService.shared.participants(for: libraryID)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func setPermission(_ permission: ShareParticipant.Permission, for participant: ShareParticipant) async {
        do {
            try await LibrarySharingService.shared.setPermission(
                permission,
                for: participant.id,
                in: libraryID
            )
            await loadParticipants()
        } catch {
            Logger.sync.error("[ShareManagement] Failed to set permission: \(error)")
        }
    }

    private func stopSharing() async {
        do {
            try await LibrarySharingService.shared.stopSharing(libraryID: libraryID)
            dismiss()
        } catch {
            Logger.sync.error("[ShareManagement] Failed to stop sharing: \(error)")
            errorMessage = error.localizedDescription
        }
    }
}
