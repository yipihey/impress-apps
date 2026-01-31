//
//  ResearchChatView.swift
//  impart (macOS)
//
//  Main conversation interface for research discussions.
//

import SwiftUI
import MessageManagerCore

/// Main chat view for a research conversation.
struct ResearchChatView: View {
    let conversationId: UUID
    let isNewConversation: Bool

    @StateObject private var viewModel: ResearchConversationViewModel

    @FocusState private var isInputFocused: Bool
    @State private var showingArtifactPicker = false
    @State private var showingBranchSheet = false
    @State private var showingProvenanceSheet = false
    @State private var showingExportSheet = false
    @Namespace private var scrollNamespace

    init(conversationId: UUID, isNewConversation: Bool = false) {
        self.conversationId = conversationId
        self.isNewConversation = isNewConversation
        _viewModel = StateObject(wrappedValue: ResearchConversationViewModel(
            persistenceController: .shared,
            provenanceService: ProvenanceService(),
            artifactService: ArtifactService(persistenceController: .shared),
            userId: "user@example.com"
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Artifact bar (when artifacts are referenced)
            if !viewModel.referencedArtifacts.isEmpty {
                artifactBar
            }

            // Message timeline
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.timelineItems) { item in
                            TimelineItemView(
                                item: item,
                                onBranch: { messageId in
                                    Task { await viewModel.startSideConversation(from: messageId) }
                                },
                                onExpandSide: { sideId in
                                    // Navigate to side conversation
                                }
                            )
                            .id(item.id)
                        }

                        // Streaming response bubble (shown while AI is responding)
                        if viewModel.isStreaming && !viewModel.streamingContent.isEmpty {
                            StreamingBubbleView(content: viewModel.streamingContent)
                                .id("streaming")
                        }

                        // Scroll anchor
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding()
                }
                .onChange(of: viewModel.timelineItems.count) {
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.streamingContent) {
                    // Auto-scroll as content streams in
                    if viewModel.isStreaming {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            Divider()

            // Privacy indicator
            PrivacyIndicatorBar(viewModel: viewModel)

            // Message input with artifact mention support
            MessageInputView(
                messageInput: $viewModel.messageInput,
                isSending: viewModel.isSending,
                onSend: {
                    Task {
                        await viewModel.sendMessage()
                    }
                },
                onAttachArtifact: {
                    showingArtifactPicker = true
                }
            )
            .focused($isInputFocused)
        }
        .navigationTitle(viewModel.conversation?.title ?? "New Conversation")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingArtifactPicker = true
                } label: {
                    Label("Attach Reference", systemImage: "paperclip")
                }
                .help("Attach Reference (Cmd+Shift+A)")
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Menu {
                    Button {
                        showingBranchSheet = true
                    } label: {
                        Label("Branch Conversation", systemImage: "arrow.triangle.branch")
                    }

                    Button {
                        showingProvenanceSheet = true
                    } label: {
                        Label("View Provenance", systemImage: "clock.arrow.circlepath")
                    }

                    Divider()

                    Button {
                        showingExportSheet = true
                    } label: {
                        Label("Export to Markdown", systemImage: "arrow.down.doc")
                    }

                    Button {
                        Task { await viewModel.generateSummary() }
                    } label: {
                        Label("Generate Summary", systemImage: "doc.text.magnifyingglass")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            // Load existing conversation from persistence
            await viewModel.loadConversation(id: conversationId)
        }
        .onAppear {
            isInputFocused = true
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .sheet(isPresented: $showingArtifactPicker) {
            ArtifactPickerSheet(onSelect: { artifact in
                viewModel.addArtifactMention(artifact)
                showingArtifactPicker = false
            })
        }
        .sheet(isPresented: $showingBranchSheet) {
            BranchConversationSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingProvenanceSheet) {
            ProvenanceSheet(conversationId: conversationId)
        }
    }

    // MARK: - Artifact Bar

    private var artifactBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.referencedArtifacts) { artifact in
                    ArtifactPillView(artifact: artifact) {
                        // Navigate to artifact
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

// MARK: - Timeline Item View

private struct TimelineItemView: View {
    let item: TimelineItem
    var onBranch: ((UUID) -> Void)?
    var onExpandSide: ((UUID) -> Void)?

    var body: some View {
        switch item {
        case .message(let message):
            MessageBubbleView(message: message, onBranch: {
                onBranch?(message.id)
            })
        case .sideConversationMarker(let preview):
            SideConversationMarkerView(preview: preview, onExpand: {
                onExpandSide?(preview.conversationId)
            })
        }
    }
}

// MARK: - Artifact Pill View

private struct ArtifactPillView: View {
    let artifact: ArtifactReference
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: artifact.iconName)
                    .font(.caption)
                Text(artifact.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.secondary.opacity(0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Artifact Picker Sheet

private struct ArtifactPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (ArtifactReference) -> Void
    @State private var searchQuery = ""

    var body: some View {
        NavigationStack {
            VStack {
                // Search field
                TextField("Search references...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .padding()

                // Source tabs
                List {
                    Section("Recent") {
                        Text("Recent artifacts will appear here")
                            .foregroundStyle(.secondary)
                    }

                    Section("From imbib") {
                        Text("Papers from your library")
                            .foregroundStyle(.secondary)
                    }

                    Section("From imprint") {
                        Text("Manuscript sections")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add Reference")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 500)
    }
}

// MARK: - Branch Conversation Sheet

private struct BranchConversationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ResearchConversationViewModel
    @State private var branchTitle = ""
    @State private var selectedMessageId: UUID?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Branch Title", text: $branchTitle)

                Section("Branch From") {
                    Text("Select a message to branch from, or start from the beginning.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    // Message selector would go here
                    ForEach(viewModel.messages.prefix(5)) { message in
                        HStack {
                            RadioButton(isSelected: selectedMessageId == message.id) {
                                selectedMessageId = message.id
                            }
                            Text(message.snippet)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .navigationTitle("Branch Conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Branch") {
                        if let messageId = selectedMessageId {
                            Task {
                                await viewModel.startSideConversation(from: messageId)
                                dismiss()
                            }
                        }
                    }
                    .disabled(branchTitle.isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

// MARK: - Radio Button

private struct RadioButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                .foregroundStyle(isSelected ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Provenance Sheet

private struct ProvenanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversationId: UUID

    var body: some View {
        NavigationStack {
            VStack {
                Text("Provenance tracking shows the history of this conversation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()

                List {
                    Text("Provenance events will appear here")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Provenance")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

// MARK: - Streaming Bubble View

private struct StreamingBubbleView: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Counsel avatar
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(.purple)
                .frame(width: 32, height: 32)
                .background(.purple.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 8) {
                // Header with streaming indicator
                HStack {
                    Text("Counsel")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.purple)

                    ProgressView()
                        .scaleEffect(0.6)

                    Text("streaming...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Content (streaming in) - rendered as markdown
                ChatMarkdownView(content: content)
            }

            Spacer()
        }
        .padding()
        .background(.purple.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Side Conversation Marker

private struct SideConversationMarkerView: View {
    let preview: SideConversationPreview
    var onExpand: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.purple)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(preview.title)
                    .font(.callout)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    Label("\(preview.messageCount) messages", systemImage: "bubble.left.and.bubble.right")
                    if let synthesis = preview.synthesisSnippet {
                        Text(synthesis)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onExpand?()
            } label: {
                Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.purple.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.purple.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - ArtifactReference Extension

extension ArtifactReference {
    var iconName: String {
        switch uri.type {
        case .paper: return "doc.text"
        case .repository: return "folder"
        case .dataset: return "tablecells"
        case .document: return "doc"
        case .unknown: return "link"
        }
    }
}

#Preview {
    NavigationStack {
        ResearchChatView(conversationId: UUID())
    }
    .frame(width: 600, height: 700)
}
