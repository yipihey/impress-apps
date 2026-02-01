//
//  EmailListView.swift
//  impart
//
//  Traditional email list view with optional threading.
//

import SwiftUI
import MessageManagerCore

// MARK: - Email List View

struct EmailListView: View {

    // MARK: - Properties

    @Bindable var viewModel: InboxViewModel

    // MARK: - State

    @State private var sortOrder = MessageSortOrder.dateDescending
    @State private var showUnreadOnly = false
    @State private var searchText = ""

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            listToolbar

            Divider()

            // Message list
            if filteredMessages.isEmpty {
                ContentUnavailableView {
                    Label("No Messages", systemImage: "tray")
                } description: {
                    if showUnreadOnly {
                        Text("No unread messages in this folder")
                    } else if !searchText.isEmpty {
                        Text("No messages match your search")
                    } else {
                        Text("This folder is empty")
                    }
                }
            } else {
                List(selection: $viewModel.selectedMessageIds) {
                    ForEach(filteredMessages) { message in
                        EmailRow(
                            message: message,
                            isSelected: viewModel.selectedMessageIds.contains(message.id)
                        )
                        .tag(message.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - List Toolbar

    private var listToolbar: some View {
        HStack {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(.textBackgroundColor))
            .cornerRadius(8)
            .frame(maxWidth: 200)

            Spacer()

            // Unread filter
            Toggle(isOn: $showUnreadOnly) {
                Image(systemName: showUnreadOnly ? "envelope.badge" : "envelope")
            }
            .toggleStyle(.button)
            .help("Show unread only")

            // Sort menu
            Menu {
                ForEach(MessageSortOrder.allCases, id: \.self) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        HStack {
                            Text(order.displayName)
                            if sortOrder == order {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .help("Sort messages")

            // Thread toggle
            Toggle(isOn: $viewModel.showAsThreads) {
                Image(systemName: viewModel.showAsThreads ? "text.line.first.and.arrowtriangle.forward" : "list.bullet")
            }
            .toggleStyle(.button)
            .help(viewModel.showAsThreads ? "Showing threads" : "Showing messages")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Filtered Messages

    private var filteredMessages: [Message] {
        var messages = viewModel.messages

        // Filter by unread
        if showUnreadOnly {
            messages = messages.filter { !$0.isRead }
        }

        // Filter by search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            messages = messages.filter { message in
                message.subject.lowercased().contains(query) ||
                message.fromDisplayString.lowercased().contains(query) ||
                message.snippet.lowercased().contains(query)
            }
        }

        // Sort
        return sortMessages(messages)
    }

    private func sortMessages(_ messages: [Message]) -> [Message] {
        switch sortOrder {
        case .dateDescending:
            return messages.sorted { $0.date > $1.date }
        case .dateAscending:
            return messages.sorted { $0.date < $1.date }
        case .senderAZ:
            return messages.sorted { $0.fromDisplayString < $1.fromDisplayString }
        case .senderZA:
            return messages.sorted { $0.fromDisplayString > $1.fromDisplayString }
        case .subjectAZ:
            return messages.sorted { $0.subject < $1.subject }
        case .subjectZA:
            return messages.sorted { $0.subject > $1.subject }
        }
    }
}

// MARK: - Email Row

struct EmailRow: View {
    let message: Message
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Unread indicator
            Circle()
                .fill(message.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)

            // Star
            Image(systemName: message.isStarred ? "star.fill" : "star")
                .foregroundStyle(message.isStarred ? .yellow : .secondary.opacity(isHovered ? 1 : 0))
                .font(.caption)

            // Agent indicator
            if isAgentMessage {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.purple)
                    .font(.caption)
            }

            // Sender
            Text(message.fromDisplayString)
                .fontWeight(message.isRead ? .regular : .semibold)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            // Subject and snippet
            VStack(alignment: .leading, spacing: 2) {
                Text(message.subject)
                    .fontWeight(message.isRead ? .regular : .semibold)
                    .lineLimit(1)

                Text(message.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Attachment indicator
            if message.hasAttachments {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            // Date
            Text(message.displayDate)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var isAgentMessage: Bool {
        message.from.contains { AgentAddress.detect(from: $0.email) != nil }
    }
}

// MARK: - Preview

#Preview {
    EmailListView(viewModel: InboxViewModel())
        .frame(width: 600, height: 400)
}
