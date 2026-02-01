//
//  CategoryView.swift
//  impart
//
//  Category view showing split between conversations and broadcasts.
//

import SwiftUI
import MessageManagerCore

// MARK: - Category View

struct CategoryView: View {

    // MARK: - Properties

    @Bindable var viewModel: InboxViewModel

    // MARK: - State

    @State private var categoryFilter: CategoryFilter = .all
    @State private var selectedMessageId: UUID?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Category picker
            categoryPicker

            Divider()

            // Content based on filter
            if categoryFilter == .all {
                splitView
            } else {
                filteredListView
            }
        }
    }

    // MARK: - Category Picker

    private var categoryPicker: some View {
        HStack {
            Picker("Category", selection: $categoryFilter) {
                ForEach(CategoryFilter.allCases, id: \.self) { filter in
                    Label(filter.displayName, systemImage: filter.iconName)
                        .tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)

            Spacer()

            // Stats
            HStack(spacing: 16) {
                statBadge(
                    title: "Conversations",
                    count: conversationMessages.count,
                    color: .blue
                )
                statBadge(
                    title: "Broadcasts",
                    count: broadcastMessages.count,
                    color: .orange
                )
            }
        }
        .padding()
        .background(Color(.windowBackgroundColor))
    }

    @ViewBuilder
    private func statBadge(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    // MARK: - Split View

    private var splitView: some View {
        HSplitView {
            // Conversations column
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Conversations", icon: "person.2", color: .blue)
                messageList(conversationMessages)
            }
            .frame(minWidth: 300)

            // Broadcasts column
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Broadcasts", icon: "megaphone", color: .orange)
                messageList(broadcastMessages)
            }
            .frame(minWidth: 300)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.windowBackgroundColor).opacity(0.5))
    }

    // MARK: - Filtered List View

    private var filteredListView: some View {
        let messages = categoryFilter == .conversations ? conversationMessages : broadcastMessages

        return messageList(messages)
    }

    // MARK: - Message List

    @ViewBuilder
    private func messageList(_ messages: [Message]) -> some View {
        if messages.isEmpty {
            ContentUnavailableView(
                "No Messages",
                systemImage: "tray",
                description: Text("No messages in this category")
            )
        } else {
            List(selection: $selectedMessageId) {
                ForEach(messages) { message in
                    CategoryMessageRow(
                        message: message,
                        category: detectCategory(for: message)
                    )
                    .tag(message.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Message Categorization

    private var conversationMessages: [Message] {
        viewModel.messages.filter { message in
            detectCategory(for: message) == .conversation
        }
    }

    private var broadcastMessages: [Message] {
        viewModel.messages.filter { message in
            detectCategory(for: message) == .broadcast
        }
    }

    private func detectCategory(for message: Message) -> MessageCategory {
        // Check for agent messages first
        if message.from.contains(where: { AgentAddress.detect(from: $0.email) != nil }) ||
           message.to.contains(where: { AgentAddress.detect(from: $0.email) != nil }) {
            return .agent
        }

        // Check recipient count
        let totalRecipients = message.to.count + message.cc.count + message.bcc.count
        if totalRecipients > 5 {
            return .broadcast
        }

        // Check for broadcast patterns in from address
        let broadcastPatterns = ["noreply", "no-reply", "newsletter", "notifications", "marketing"]
        let fromEmail = message.from.first?.email.lowercased() ?? ""
        if broadcastPatterns.contains(where: { fromEmail.contains($0) }) {
            return .broadcast
        }

        return .conversation
    }
}

// MARK: - Category Message Row

struct CategoryMessageRow: View {
    let message: Message
    let category: MessageCategory

    var body: some View {
        HStack(spacing: 12) {
            // Category indicator
            categoryIndicator

            // Unread indicator
            Circle()
                .fill(message.isRead ? Color.clear : Color.accentColor)
                .frame(width: 6, height: 6)

            // Sender
            Text(message.fromDisplayString)
                .fontWeight(message.isRead ? .regular : .semibold)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            // Subject
            Text(message.subject)
                .lineLimit(1)

            Spacer()

            // Date
            Text(message.displayDate)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var categoryIndicator: some View {
        switch category {
        case .conversation:
            Image(systemName: "person.2.fill")
                .foregroundStyle(.blue)
                .font(.caption)
        case .broadcast:
            Image(systemName: "megaphone.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .agent:
            Image(systemName: "brain.head.profile")
                .foregroundStyle(.purple)
                .font(.caption)
        }
    }
}

// MARK: - Preview

#Preview {
    CategoryView(viewModel: InboxViewModel())
        .frame(width: 800, height: 500)
}
