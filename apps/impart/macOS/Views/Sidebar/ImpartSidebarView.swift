//
//  ImpartSidebarView.swift
//  impart
//
//  Main sidebar view showing accounts and folder hierarchy.
//  Uses ImpressSidebar for tree rendering infrastructure.
//

import SwiftUI
import MessageManagerCore
import ImpressSidebar
import UniformTypeIdentifiers

// MARK: - Sidebar Section

/// Sections in the sidebar
enum ImpartSidebarSection: Hashable {
    case allInboxes
    case account(UUID)
    case folder(UUID)
    case smartFolder(UUID)
}

// MARK: - Impart Sidebar View

struct ImpartSidebarView: View {

    // MARK: - Properties

    @Bindable var viewModel: InboxViewModel
    @Binding var selectedSection: ImpartSidebarSection?
    @Binding var selectedFolder: UUID?

    // MARK: - State

    @State private var expandedAccounts: Set<UUID> = []
    @State private var folderExpansion = TreeExpansionState()
    @State private var renamingFolder: CDFolder?
    @State private var showNewFolderSheet = false
    @State private var newFolderParent: CDFolder?

    // MARK: - Environment

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Body

    var body: some View {
        List(selection: $selectedSection) {
            // All Inboxes section (aggregate)
            Section {
                HStack {
                    Image(systemName: "tray.2")
                        .foregroundStyle(.tint)
                    Text("All Inboxes")
                    Spacer()
                    if viewModel.totalUnreadCount > 0 {
                        Text("\(viewModel.totalUnreadCount)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                .tag(ImpartSidebarSection.allInboxes)
            }

            // Per-account sections
            ForEach(viewModel.accounts) { account in
                accountSection(account)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem {
                Button {
                    showNewFolderSheet = true
                    newFolderParent = nil
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showNewFolderSheet) {
            NewFolderSheet(
                parent: newFolderParent,
                accountId: viewModel.selectedAccountId,
                onComplete: { name, parentId in
                    Task {
                        await viewModel.createFolder(name: name, parent: parentId)
                    }
                }
            )
        }
        .onAppear {
            // Expand all accounts by default
            expandedAccounts = Set(viewModel.accounts.map(\.id))
        }
    }

    // MARK: - Account Section

    @ViewBuilder
    private func accountSection(_ account: Account) -> some View {
        let isExpanded = expandedAccounts.contains(account.id)

        Section(isExpanded: Binding(
            get: { isExpanded },
            set: { newValue in
                if newValue {
                    expandedAccounts.insert(account.id)
                } else {
                    expandedAccounts.remove(account.id)
                }
            }
        )) {
            let accountFolders = viewModel.folders(for: account.id)
            let adapters = rootAdapters(from: accountFolders)
            let flattened = TreeFlattener.flatten(
                roots: adapters,
                children: { node in
                    node.underlyingFolder.sortedChildren.asFolderAdapters()
                },
                isExpanded: { node in
                    folderExpansion.isExpanded(node.id)
                }
            )
            ForEach(flattened) { flattenedNode in
                folderRow(flattenedNode, allFolders: accountFolders)
            }
        } header: {
            accountHeader(account)
        }
    }

    @ViewBuilder
    private func accountHeader(_ account: Account) -> some View {
        HStack {
            Image(systemName: "person.circle")
                .foregroundStyle(.secondary)
            Text(account.displayName.isEmpty ? account.email : account.displayName)
                .fontWeight(.semibold)
            Spacer()
            if let unread = viewModel.unreadCount(for: account.id), unread > 0 {
                Text("\(unread)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(ImpartSidebarSection.account(account.id))
    }

    // MARK: - Folder Row

    @ViewBuilder
    private func folderRow(_ flattenedNode: FlattenedTreeNode<FolderNodeAdapter>, allFolders: [CDFolder]) -> some View {
        let folder = flattenedNode.node.underlyingFolder
        FolderTreeRow(
            flattenedNode: flattenedNode,
            allFolders: allFolders,
            isExpanded: folderExpansion.binding(for: folder.id),
            onRename: { folder in
                renamingFolder = folder
            },
            onEdit: folder.isVirtualFolder ? { folder in
                // Show smart folder editor
            } : nil,
            onDelete: { folder in
                Task {
                    await viewModel.deleteFolder(folder.id)
                }
            },
            onCreateSubfolder: { folder in
                newFolderParent = folder
                showNewFolderSheet = true
            },
            onDropMessages: { messageIds, folder in
                await viewModel.moveMessages(messageIds, to: folder.id)
            },
            onMoveFolder: { sourceFolder, targetFolder in
                Task {
                    await viewModel.moveFolder(sourceFolder.id, to: targetFolder?.id)
                }
            },
            isEditing: renamingFolder?.id == folder.id,
            onRenameComplete: { newName in
                if let folder = renamingFolder {
                    Task {
                        await viewModel.renameFolder(folder.id, to: newName)
                    }
                }
                renamingFolder = nil
            }
        )
    }

    // MARK: - Helpers

    /// Get root-level folder adapters sorted by sortOrder then name.
    private func rootAdapters(from folders: [CDFolder]) -> [FolderNodeAdapter] {
        folders
            .filter { $0.parentFolder == nil }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            .asFolderAdapters()
    }
}

// MARK: - New Folder Sheet

struct NewFolderSheet: View {
    let parent: CDFolder?
    let accountId: UUID?
    let onComplete: (String, UUID?) -> Void

    @State private var folderName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("New Folder")
                .font(.headline)

            if let parent = parent {
                Text("Inside: \(parent.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Folder Name", text: $folderName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    onComplete(folderName, parent?.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Preview

#Preview {
    ImpartSidebarView(
        viewModel: InboxViewModel(),
        selectedSection: .constant(nil),
        selectedFolder: .constant(nil)
    )
}
