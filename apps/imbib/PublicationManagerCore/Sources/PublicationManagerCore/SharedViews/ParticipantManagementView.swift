//
//  ParticipantManagementView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import SwiftUI
import CoreData
import OSLog

#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - Participant Management View

/// Manage participants of a shared library.
///
/// Shows all participants with their roles and permissions.
/// Library owner can toggle read-only/read-write and remove participants.
public struct ParticipantManagementView: View {
    let library: CDLibrary

    #if canImport(CloudKit)
    @State private var participants: [CKShare.Participant] = []
    @State private var share: CKShare?
    #endif
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    public init(library: CDLibrary) {
        self.library = library
    }

    public var body: some View {
        #if canImport(CloudKit)
        NavigationStack {
            List {
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section("Participants") {
                    ForEach(participants, id: \.participantID) { participant in
                        participantRow(participant)
                    }
                }

                Section {
                    Button {
                        copyInviteLink()
                    } label: {
                        Label("Copy Invite Link", systemImage: "link")
                    }
                }
            }
            .navigationTitle("Manage Participants")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                loadParticipants()
            }
        }
        #else
        Text("CloudKit sharing requires CloudKit framework")
        #endif
    }

    #if canImport(CloudKit)
    @ViewBuilder
    private func participantRow(_ participant: CKShare.Participant) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Name
                Text(participantName(participant))
                    .font(.body)

                // Status
                HStack(spacing: 8) {
                    Text(statusText(for: participant))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if participant.role == .owner {
                        Text("Owner")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            // Permission control (owner can change others' permissions)
            if isOwner && participant.role != .owner {
                Menu {
                    Button {
                        setPermission(.readWrite, for: participant)
                    } label: {
                        Label(
                            "Read & Write",
                            systemImage: participant.permission == .readWrite ? "checkmark" : ""
                        )
                    }

                    Button {
                        setPermission(.readOnly, for: participant)
                    } label: {
                        Label(
                            "Read Only",
                            systemImage: participant.permission == .readOnly ? "checkmark" : ""
                        )
                    }

                    Divider()

                    Button(role: .destructive) {
                        removeParticipant(participant)
                    } label: {
                        Label("Remove", systemImage: "person.badge.minus")
                    }
                } label: {
                    Image(systemName: permissionIcon(for: participant))
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: permissionIcon(for: participant))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private var isOwner: Bool {
        share?.currentUserParticipant?.role == .owner
    }

    private func loadParticipants() {
        share = PersistenceController.shared.share(for: library)
        participants = share?.participants.sorted { p1, p2 in
            // Owner first, then by name
            if p1.role == .owner { return true }
            if p2.role == .owner { return false }
            return participantName(p1) < participantName(p2)
        } ?? []
    }

    private func participantName(_ participant: CKShare.Participant) -> String {
        if let nameComponents = participant.userIdentity.nameComponents {
            let formatter = PersonNameComponentsFormatter()
            formatter.style = .default
            let name = formatter.string(from: nameComponents)
            if !name.isEmpty { return name }
        }
        return participant.userIdentity.lookupInfo?.emailAddress
            ?? participant.userIdentity.lookupInfo?.phoneNumber
            ?? "Participant"
    }

    private func statusText(for participant: CKShare.Participant) -> String {
        switch participant.acceptanceStatus {
        case .accepted: return "Accepted"
        case .pending: return "Pending"
        case .removed: return "Removed"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    private func permissionIcon(for participant: CKShare.Participant) -> String {
        switch participant.permission {
        case .readWrite: return "pencil.circle"
        case .readOnly: return "lock.circle"
        case .none: return "circle"
        case .unknown: return "questionmark.circle"
        @unknown default: return "questionmark.circle"
        }
    }

    private func setPermission(_ permission: CKShare.ParticipantPermission, for participant: CKShare.Participant) {
        Task {
            do {
                try await CloudKitSharingService.shared.setPermission(permission, for: participant, in: library)
                loadParticipants()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeParticipant(_ participant: CKShare.Participant) {
        guard let share = share else { return }
        share.removeParticipant(participant)

        Task {
            do {
                let container = PersistenceController.shared.container as? NSPersistentCloudKitContainer
                try container?.persistUpdatedShare(share, in: PersistenceController.shared.sharedStore!)
                loadParticipants()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copyInviteLink() {
        guard let share = share, let url = share.url else { return }
        let urlString = url.absoluteString
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        #else
        UIPasteboard.general.string = urlString
        #endif
    }
    #endif
}
