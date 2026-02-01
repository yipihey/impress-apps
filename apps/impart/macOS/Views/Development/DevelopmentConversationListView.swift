//
//  DevelopmentConversationListView.swift
//  impart
//
//  List of development conversations with mode indicators.
//

import SwiftUI
import MessageManagerCore

struct DevelopmentConversationListView: View {
    @Bindable var viewModel: DevelopmentConversationViewModel
    @State private var showingNewConversation = false
    @State private var newConversationTitle = ""
    @State private var newConversationMode: ConversationMode = .interactive

    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedConversation?.id },
            set: { id in
                if let id = id {
                    viewModel.selectConversation(id: id)
                } else {
                    viewModel.clearSelection()
                }
            }
        )) {
            ForEach(viewModel.conversations) { conversation in
                DevelopmentConversationRow(conversation: conversation)
                    .tag(conversation.id)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Development")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Chat") {
                        newConversationMode = .interactive
                        newConversationTitle = ""
                        showingNewConversation = true
                    }
                    Button("New Planning Session") {
                        newConversationMode = .planning
                        newConversationTitle = ""
                        showingNewConversation = true
                    }
                    Divider()
                    Button("New Review") {
                        newConversationMode = .review
                        newConversationTitle = ""
                        showingNewConversation = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }

            ToolbarItem(placement: .automatic) {
                Picker("View", selection: $viewModel.viewMode) {
                    ForEach(ConversationViewMode.allCases, id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.iconName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .task {
            await viewModel.loadConversations()
        }
        .refreshable {
            await viewModel.loadConversations()
        }
        .sheet(isPresented: $showingNewConversation) {
            NewDevelopmentConversationSheet(
                title: $newConversationTitle,
                mode: $newConversationMode,
                onCreate: { title, mode in
                    Task {
                        await viewModel.createConversation(title: title, mode: mode)
                    }
                }
            )
        }
    }
}

// MARK: - Conversation Row

struct DevelopmentConversationRow: View {
    let conversation: DevelopmentConversation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: conversation.mode.iconName)
                .foregroundStyle(modeColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .lineLimit(1)
                    .fontWeight(conversation.mode == .planning ? .medium : .regular)

                HStack(spacing: 4) {
                    Text(conversation.mode.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if conversation.artifactCount > 0 {
                        Label("\(conversation.artifactCount)", systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if conversation.messageCount > 0 {
                        Text("\(conversation.messageCount) msgs")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            Text(conversation.lastActivityAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .opacity(conversation.isArchived ? 0.6 : 1.0)
    }

    private var modeColor: Color {
        switch conversation.mode {
        case .interactive: return .blue
        case .planning: return .orange
        case .review: return .green
        case .archival: return .gray
        }
    }
}

// MARK: - New Conversation Sheet

struct NewDevelopmentConversationSheet: View {
    @Binding var title: String
    @Binding var mode: ConversationMode
    let onCreate: (String, ConversationMode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("New Conversation")
                .font(.headline)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            Picker("Mode", selection: $mode) {
                ForEach(ConversationMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.iconName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    let finalTitle = title.isEmpty ? defaultTitle : title
                    onCreate(finalTitle, mode)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty && mode != .interactive)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private var defaultTitle: String {
        switch mode {
        case .interactive: return "New Chat"
        case .planning: return "Planning Session"
        case .review: return "Code Review"
        case .archival: return "Archive"
        }
    }
}

// MARK: - Preview

#Preview {
    DevelopmentConversationListView(
        viewModel: DevelopmentConversationViewModel()
    )
    .frame(width: 280)
}
