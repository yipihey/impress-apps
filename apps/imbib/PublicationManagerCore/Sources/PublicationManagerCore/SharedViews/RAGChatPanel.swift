//
//  RAGChatPanel.swift
//  PublicationManagerCore
//
//  "Ask About Papers" conversational RAG sidebar panel.
//

import SwiftUI

// MARK: - RAG Chat Panel

/// Sidebar panel for asking questions about papers with cited answers.
///
/// Features:
/// - Scope selector (Library, collection, or selected papers)
/// - Chat interface with user/assistant bubbles
/// - Source cards showing cited passages with page numbers
/// - Streaming-style message display
public struct RAGChatPanel: View {

    // MARK: - Properties

    @Bindable var viewModel: RAGChatViewModel
    var onNavigateToPaper: ((UUID) -> Void)?

    // MARK: - State

    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    // MARK: - Init

    public init(viewModel: RAGChatViewModel, onNavigateToPaper: ((UUID) -> Void)? = nil) {
        self.viewModel = viewModel
        self.onNavigateToPaper = onNavigateToPaper
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Header with scope
            header

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if viewModel.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(viewModel.messages) { message in
                                messageBubble(message)
                            }
                        }

                        if viewModel.isGenerating {
                            typingIndicator
                        }

                        // Scroll anchor
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom")
                    }
                }
            }

            Divider()

            // Input area
            inputArea
        }
        .frame(width: 320)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "text.bubble")
                .foregroundStyle(.purple)
            Text("Ask Papers")
                .font(.headline)

            Spacer()

            // Scope indicator
            Text(viewModel.scope.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

            if !viewModel.messages.isEmpty {
                Button {
                    viewModel.clearChat()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Clear chat")
            }
        }
        .padding()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
                .frame(height: 40)

            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("Ask about your papers")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Ask questions and get answers with citations from your library.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)

            // Suggested questions
            VStack(alignment: .leading, spacing: 6) {
                suggestionButton("What methods are used in these papers?")
                suggestionButton("Summarize the key findings")
                suggestionButton("What are the main differences between these approaches?")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func suggestionButton(_ text: String) -> some View {
        Button {
            inputText = text
            sendMessage()
        } label: {
            Text(text)
                .font(.caption)
                .foregroundStyle(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message Bubble

    @ViewBuilder
    private func messageBubble(_ message: RAGChatViewModel.ChatMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            // Message text
            HStack {
                if message.role == .user { Spacer() }

                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.role == .user
                            ? Color.blue.opacity(0.15)
                            : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )

                if message.role == .assistant { Spacer() }
            }

            // Source cards (for assistant messages with sources)
            if !message.sources.isEmpty {
                sourceCardsSection(message.sources)
            }

            // Timestamp
            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: - Source Cards

    private func sourceCardsSection(_ sources: [RAGChatViewModel.SourceReference]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sources) { source in
                    sourceCard(source)
                }
            }
        } label: {
            Label("\(sources.count) sources", systemImage: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    private func sourceCard(_ source: RAGChatViewModel.SourceReference) -> some View {
        Button {
            onNavigateToPaper?(source.publicationId)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("[\(source.bibkey)]")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)

                    Spacer()

                    if let page = source.pageNumber {
                        Text("p.\(page + 1)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text("\(Int(source.similarity * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(source.title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text(source.chunkText.prefix(120) + (source.chunkText.count > 120 ? "..." : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.purple.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .scaleEffect(1.0)
                    .animation(
                        .easeInOut(duration: 0.6)
                        .repeatForever()
                        .delay(Double(i) * 0.2),
                        value: viewModel.isGenerating
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Input Area

    private var inputArea: some View {
        HStack(spacing: 8) {
            TextField("Ask about your papers...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(inputText.isEmpty ? .tertiary : .blue)
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty || viewModel.isGenerating)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task {
            await viewModel.ask(text)
        }
    }
}
