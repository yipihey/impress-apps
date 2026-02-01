//
//  DevelopmentChatView.swift
//  impart
//
//  Chat interface for development conversations.
//

import SwiftUI
import MessageManagerCore

struct DevelopmentChatView: View {
    @Bindable var viewModel: DevelopmentConversationViewModel
    @State private var inputText = ""
    @State private var showingDirectoryPicker = false
    @State private var selectedIntent: MessageIntent = .converse
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header with artifacts
            if !viewModel.attachedArtifacts.isEmpty {
                artifactsBar
            }

            // Messages
            messagesView

            Divider()

            // Input area
            inputArea
        }
        .navigationTitle(viewModel.selectedConversation?.title ?? "Select Conversation")
        .navigationSubtitle(viewModel.selectedConversation?.mode.displayName ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.selectedConversation != nil {
                    Button {
                        showingDirectoryPicker = true
                    } label: {
                        Label("Attach Directory", systemImage: "folder.badge.plus")
                    }

                    if viewModel.selectedConversation?.mode == .interactive {
                        Button {
                            Task {
                                await viewModel.startPlanningSession(title: "Planning Session")
                            }
                        } label: {
                            Label("Start Planning", systemImage: "doc.text.magnifyingglass")
                        }
                    }

                    Menu {
                        Button("Archive", systemImage: "archivebox") {
                            Task { await viewModel.archiveSelectedConversation() }
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await viewModel.deleteSelectedConversation() }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    await viewModel.attachDirectory(url: url)
                }
            }
        }
    }

    // MARK: - Artifacts Bar

    private var artifactsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.attachedArtifacts) { artifact in
                    ArtifactBadgeView(
                        artifact: artifact,
                        onRemove: {
                            Task { await viewModel.removeArtifact(artifact) }
                        },
                        onOpen: {
                            Task {
                                if let url = await viewModel.startAccessingArtifact(artifact) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    // MARK: - Messages View

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if viewModel.messages.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastMessage = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.selectedConversation?.mode.iconName ?? "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No messages yet")
                .font(.headline)
                .foregroundStyle(.secondary)

            if viewModel.selectedConversation?.mode == .planning {
                Text("Start by describing what you want to plan")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 8) {
            // Intent picker for non-converse messages
            if viewModel.selectedConversation?.mode == .planning {
                intentPicker
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .focused($isInputFocused)
                    .onSubmit {
                        if !inputText.isEmpty {
                            sendMessage()
                        }
                    }
                    .padding(8)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
    }

    private var intentPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach([MessageIntent.converse, .proposal, .plan, .execute], id: \.self) { intent in
                    Button {
                        selectedIntent = intent
                    } label: {
                        Label(intent.displayName, systemImage: intent.iconName)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedIntent == intent ? intentColor(intent) : .secondary)
                }
            }
            .padding(.horizontal)
        }
    }

    private func intentColor(_ intent: MessageIntent) -> Color {
        switch intent {
        case .converse: return .blue
        case .proposal: return .orange
        case .plan: return .indigo
        case .execute: return .green
        default: return .secondary
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let text = inputText
        let intent = selectedIntent
        inputText = ""
        selectedIntent = .converse

        Task {
            await viewModel.sendMessage(content: text, intent: intent)
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: DevelopmentMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .human {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.role == .human ? .trailing : .leading, spacing: 4) {
                // Intent badge for non-converse messages
                if message.intent != .converse {
                    Label(message.intent.displayName, systemImage: message.intent.iconName)
                        .font(.caption2)
                        .foregroundStyle(intentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(intentColor.opacity(0.15))
                        .clipShape(Capsule())
                }

                // Message content
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(bubbleBackground)
                    .foregroundStyle(message.role == .human ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                // Timestamp
                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if message.role != .human {
                Spacer(minLength: 60)
            }
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .human:
            return .accentColor
        case .counsel:
            return Color(.controlBackgroundColor)
        case .system:
            return Color(.windowBackgroundColor)
        }
    }

    private var intentColor: Color {
        switch message.intent {
        case .converse: return .blue
        case .execute: return .green
        case .result: return .green
        case .proposal: return .orange
        case .approval: return .purple
        case .plan: return .indigo
        case .error: return .red
        }
    }
}

// MARK: - Preview

#Preview {
    DevelopmentChatView(
        viewModel: DevelopmentConversationViewModel()
    )
    .frame(width: 600, height: 500)
}
