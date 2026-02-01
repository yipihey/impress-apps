//
//  ChatView.swift
//  impart
//
//  Chat-style view for displaying messages in conversation bubbles.
//

import SwiftUI
import MessageManagerCore

// MARK: - Chat View

struct ChatView: View {

    // MARK: - Properties

    @Bindable var viewModel: InboxViewModel
    let currentUserEmail: String

    // MARK: - State

    @State private var scrollToBottom = false
    @State private var replyText = ""
    @FocusState private var isReplyFocused: Bool

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Conversation selector
            conversationHeader

            Divider()

            // Messages
            if let conversation = viewModel.selectedConversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(groupedMessages) { group in
                                MessageGroupHeader(date: group.date)

                                ForEach(group.messages) { message in
                                    chatBubble(for: message)
                                        .id(message.id)
                                }
                            }

                            // Typing indicator if agent is processing
                            if viewModel.isAgentProcessing {
                                HStack {
                                    TypingIndicator()
                                    Spacer()
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.messages.count) { _, _ in
                        scrollToLatest(proxy: proxy)
                    }
                    .onAppear {
                        scrollToLatest(proxy: proxy)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Select a conversation from the sidebar")
                )
            }

            Divider()

            // Reply bar
            if viewModel.selectedConversation != nil {
                replyBar
            }
        }
    }

    // MARK: - Conversation Header

    private var conversationHeader: some View {
        HStack {
            if let conversation = viewModel.selectedConversation {
                // Participant info
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.displayName(excludingEmail: currentUserEmail))
                        .font(.headline)

                    if conversation.isAgentConversation {
                        Label("AI Agent", systemImage: "brain.head.profile")
                            .font(.caption)
                            .foregroundStyle(.purple)
                    } else {
                        Text("\(conversation.messageCount) messages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // View mode toggle
            Button {
                viewModel.toggleViewMode()
            } label: {
                Image(systemName: "envelope")
            }
            .help("Switch to Email View")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Reply Bar

    private var replyBar: some View {
        HStack(spacing: 12) {
            TextField("Message", text: $replyText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($isReplyFocused)
                .onSubmit {
                    sendReply()
                }

            Button {
                sendReply()
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(replyText.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Chat Bubble

    @ViewBuilder
    private func chatBubble(for message: Message) -> some View {
        let isSent = message.from.contains { $0.email.lowercased() == currentUserEmail.lowercased() }
        let isAgent = message.from.contains { AgentAddress.detect(from: $0.email) != nil }

        ChatBubble(
            isSent: isSent,
            content: message.snippet,  // Use full body when available
            senderName: isSent ? nil : message.fromDisplayString,
            timestamp: message.date,
            isAgentMessage: isAgent
        )
        .contextMenu {
            Button("Reply") {
                // Set reply context
            }

            Button("Forward") {
                // Forward message
            }

            Divider()

            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.snippet, forType: .string)
            }

            if message.isStarred {
                Button("Remove Star") {
                    Task {
                        await viewModel.toggleStar(for: message.id)
                    }
                }
            } else {
                Button("Add Star") {
                    Task {
                        await viewModel.toggleStar(for: message.id)
                    }
                }
            }
        }
    }

    // MARK: - Message Grouping

    struct MessageGroup: Identifiable {
        let id: Date
        var date: Date { id }
        let messages: [Message]
    }

    private var groupedMessages: [MessageGroup] {
        let calendar = Calendar.current

        var groups: [Date: [Message]] = [:]

        for message in viewModel.sortedMessages {
            let dayStart = calendar.startOfDay(for: message.date)
            groups[dayStart, default: []].append(message)
        }

        return groups
            .map { MessageGroup(id: $0.key, messages: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Actions

    private func sendReply() {
        guard !replyText.isEmpty else { return }

        Task {
            await viewModel.sendReply(replyText)
            replyText = ""
        }
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        guard let lastMessage = viewModel.sortedMessages.last else { return }
        withAnimation {
            proxy.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }
}

// MARK: - Preview

#Preview {
    ChatView(
        viewModel: InboxViewModel(),
        currentUserEmail: "user@example.com"
    )
    .frame(width: 500, height: 600)
}
