//
//  SciXLibraryInfoSheet.swift
//  imbib
//

import SwiftUI
import PublicationManagerCore

/// Sheet showing library details, collaborators, add-collaborator form, and (owner-only) transfer of ownership.
struct SciXLibraryInfoSheet: View {

    let library: SciXLibrary
    var viewModel: SciXLibraryViewModel

    @Environment(\.dismiss) private var dismiss

    // MARK: - Collaborators state

    @State private var permissions: [SciXPermission] = []
    @State private var loadError: String?
    @State private var isLoadingPerms = false

    // MARK: - Add collaborator

    @State private var newEmail = ""
    @State private var newLevel: SciXPermissionLevel = .read
    @State private var isAdding = false
    @State private var addError: String?

    // MARK: - Transfer ownership

    @State private var transferEmail = ""
    @State private var showTransferConfirm = false
    @State private var isTransferring = false
    @State private var transferError: String?

    // MARK: - Derived

    private var canManage: Bool {
        let level = SciXPermissionLevel(rawValue: library.permissionLevel)
        return level == .owner || level == .admin
    }

    private var isOwner: Bool {
        SciXPermissionLevel(rawValue: library.permissionLevel) == .owner
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                metadataSection
                collaboratorsSection
                if isOwner {
                    transferSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Library Info")
            #if os(macOS)
            .navigationSubtitle(library.name)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadPermissions() }
            .alert("Transfer Ownership", isPresented: $showTransferConfirm) {
                Button("Transfer", role: .destructive) { performTransfer() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Transfer ownership of \"\(library.name)\" to \(transferEmail)? You will lose owner access.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #endif
    }

    // MARK: - Sections

    private var metadataSection: some View {
        Section("Library") {
            LabeledContent("Name", value: library.name)
            if let desc = library.description, !desc.isEmpty {
                LabeledContent("Description", value: desc)
            }
            LabeledContent("Visibility", value: library.isPublic ? "Public" : "Private")
            LabeledContent("Documents", value: "\(library.documentCount)")
            if let owner = library.ownerEmail {
                LabeledContent("Owner", value: owner)
            }
            LabeledContent("Your access") {
                Label(
                    library.permissionLevel.capitalized,
                    systemImage: (SciXPermissionLevel(rawValue: library.permissionLevel) ?? .read).icon
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var collaboratorsSection: some View {
        Section("Collaborators") {
            if isLoadingPerms {
                ProgressView("Loading…")
            } else if let error = loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Retry") { Task { await loadPermissions() } }
            } else if permissions.isEmpty {
                Text("No collaborators")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(permissions) { perm in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(perm.email)
                            Label(perm.level.rawValue.capitalized, systemImage: perm.level.icon)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if canManage && perm.permission != "owner" {
                            Button(role: .destructive) {
                                Task { await removeCollaborator(perm) }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }

        if canManage {
            Section("Add Collaborator") {
                TextField("Email address", text: $newEmail)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                Picker("Permission", selection: $newLevel) {
                    ForEach(addablePermissions, id: \.self) { level in
                        Label(level.rawValue.capitalized, systemImage: level.icon).tag(level)
                    }
                }
                if let error = addError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                Button("Add") { Task { await addCollaborator() } }
                    .disabled(newEmail.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
            }
        }
    }

    private var transferSection: some View {
        Section {
            DisclosureGroup("Transfer Ownership") {
                Text("Transfer ownership of this library to another ADS user. You will lose owner privileges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("New owner email", text: $transferEmail)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                if let error = transferError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                Button("Transfer…", role: .destructive) {
                    showTransferConfirm = true
                }
                .disabled(transferEmail.trimmingCharacters(in: .whitespaces).isEmpty || isTransferring)
            }
        }
    }

    // MARK: - Permission levels available for adding

    private var addablePermissions: [SciXPermissionLevel] {
        if isOwner {
            return [.read, .write, .admin]
        }
        return [.read, .write]
    }

    // MARK: - Actions

    private func loadPermissions() async {
        isLoadingPerms = true
        loadError = nil
        do {
            permissions = try await viewModel.fetchPermissions(for: library)
        } catch {
            loadError = error.localizedDescription
        }
        isLoadingPerms = false
    }

    private func addCollaborator() async {
        let email = newEmail.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else { return }
        isAdding = true
        addError = nil
        do {
            try await viewModel.setPermission(for: library, email: email, level: newLevel)
            newEmail = ""
            await loadPermissions()
        } catch {
            addError = error.localizedDescription
        }
        isAdding = false
    }

    private func removeCollaborator(_ perm: SciXPermission) async {
        do {
            try await viewModel.removeCollaborator(email: perm.email, from: library)
            await loadPermissions()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func performTransfer() {
        let email = transferEmail.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else { return }
        isTransferring = true
        transferError = nil
        Task {
            do {
                try await viewModel.transferOwnership(for: library, toEmail: email)
                dismiss()
            } catch {
                transferError = error.localizedDescription
                isTransferring = false
            }
        }
    }
}
