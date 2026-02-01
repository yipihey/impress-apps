//
//  ResearchConversationListView.swift
//  impart (macOS)
//
//  Sidebar list of research conversations.
//

import SwiftUI
import MessageManagerCore

/// List view for browsing research conversations.
struct ResearchConversationListView: View {
    @State private var conversations: [ResearchConversation] = []
    @State private var selectedConversationId: UUID?
    @State private var searchText = ""
    @State private var isCreatingNew = false
    @State private var newConversationTitle = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let repository = ResearchConversationRepository(
        persistenceController: .shared
    )

    var body: some View {
        VStack(spacing: 0) {
            // Header with new conversation button
            HStack {
                Text("Research")
                    .font(.headline)

                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                Button {
                    isCreatingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Conversation (Cmd+N)")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search conversations", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Error message
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            // Conversation list
            if filteredConversations.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label("No Conversations", systemImage: "brain.head.profile")
                } description: {
                    Text("Start a new conversation to discuss research with AI.")
                } actions: {
                    Button("New Conversation") {
                        isCreatingNew = true
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(filteredConversations, selection: $selectedConversationId) { conversation in
                    ConversationRow(conversation: conversation)
                        .tag(conversation.id)
                }
                .listStyle(.sidebar)
                .refreshable {
                    await loadConversations()
                }
            }
        }
        .sheet(isPresented: $isCreatingNew) {
            NewConversationSheet(
                title: $newConversationTitle,
                onCancel: {
                    isCreatingNew = false
                    newConversationTitle = ""
                },
                onCreate: { title, model in
                    Task {
                        await createConversation(title: title, model: model)
                    }
                    isCreatingNew = false
                    newConversationTitle = ""
                }
            )
        }
        .navigationDestination(for: UUID.self) { conversationId in
            ResearchChatView(conversationId: conversationId)
        }
        .task {
            await loadConversations()
        }
    }

    private var filteredConversations: [ResearchConversation] {
        if searchText.isEmpty {
            return conversations
        }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func loadConversations() async {
        isLoading = true
        errorMessage = nil

        do {
            let loaded = try await repository.fetchConversations()
            conversations = loaded
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func createConversation(title: String, model: String) async {
        let newConversation = ResearchConversation(
            title: title,
            participants: ["user@example.com", "counsel-\(model)@impart.local"]
        )

        // Persist immediately
        do {
            try await repository.save(newConversation)
            conversations.insert(newConversation, at: 0)
            selectedConversationId = newConversation.id
        } catch {
            errorMessage = "Failed to create: \(error.localizedDescription)"
        }
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let conversation: ResearchConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.title)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                if conversation.isArchived {
                    Image(systemName: "archivebox")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            HStack {
                if let snippet = conversation.latestSnippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Text(conversation.lastActivityAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - New Conversation Sheet

private struct NewConversationSheet: View {
    @Binding var title: String
    let onCancel: () -> Void
    let onCreate: (String, String) -> Void

    @State private var selectedModel = "opus4.5"

    var body: some View {
        VStack(spacing: 16) {
            Text("New Research Conversation")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Title")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("e.g., Surface Code Analysis", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Counsel Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Model", selection: $selectedModel) {
                    Text("Opus 4.5 (Most capable)").tag("opus4.5")
                    Text("Sonnet 4 (Balanced)").tag("sonnet4")
                    Text("Haiku 3.5 (Fast)").tag("haiku3.5")
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Divider()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    onCreate(title, selectedModel)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 350)
    }
}

#Preview {
    ResearchConversationListView()
        .frame(width: 300, height: 500)
}
