//
//  AIChatSidebar.swift
//  imprint
//
//  AI writing assistant chat sidebar with quick actions.
//

import SwiftUI

// MARK: - AI Chat Sidebar

/// Sidebar panel for AI writing assistance.
///
/// Features:
/// - Quick action buttons (rewrite, expand, summarize)
/// - Chat interface for general questions
/// - Context-aware suggestions based on selected text
struct AIChatSidebar: View {
    @Binding var selectedText: String
    @Binding var documentSource: String
    let onInsertText: (String) -> Void

    @StateObject private var aiService = AIAssistantService.shared
    @State private var chatInput = ""
    @State private var isShowingSettings = false
    @State private var actionResult: String?
    @State private var selectedAction: QuickAction?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            if !aiService.isConfigured {
                configurationPrompt
            } else {
                // Main content
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Quick actions section
                            if !selectedText.isEmpty {
                                quickActionsSection
                            }

                            // Action result (if any)
                            if let result = actionResult {
                                actionResultSection(result: result)
                            }

                            // Chat history
                            chatHistorySection

                            // Scroll anchor
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                        .padding()
                    }
                    .onChange(of: aiService.chatHistory.count) { _, _ in
                        withAnimation {
                            proxy.scrollTo("bottom")
                        }
                    }
                }

                Divider()

                // Chat input
                chatInputSection
            }
        }
        .frame(width: 320)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $isShowingSettings) {
            AISettingsSheet()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text("AI Assistant")
                .font(.headline)

            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gear")
            }
            .buttonStyle(.plain)
            .help("AI Settings")
        }
        .padding()
    }

    // MARK: - Configuration Prompt

    private var configurationPrompt: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("API Key Required")
                .font(.headline)

            Text("Add your Claude or OpenAI API key to use the AI assistant.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Configure API Key") {
                isShowingSettings = true
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected Text")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(selectedText.prefix(100) + (selectedText.count > 100 ? "..." : ""))
                .font(.caption)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)

            Text("Quick Actions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(QuickAction.allCases) { action in
                    QuickActionButton(
                        action: action,
                        isLoading: aiService.isLoading && selectedAction == action
                    ) {
                        await performAction(action)
                    }
                }
            }
        }
    }

    // MARK: - Action Result

    private func actionResultSection(result: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Result")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onInsertText(result)
                    actionResult = nil
                } label: {
                    Label("Insert", systemImage: "text.insert")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy to clipboard")

                Button {
                    actionResult = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            Text(result)
                .font(.body)
                .padding(8)
                .background(Color.purple.opacity(0.1))
                .cornerRadius(6)
                .textSelection(.enabled)
        }
    }

    // MARK: - Chat History

    private var chatHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !aiService.chatHistory.isEmpty {
                Text("Conversation")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(aiService.chatHistory) { message in
                    ChatBubble(message: message)
                }
            }
        }
    }

    // MARK: - Chat Input

    private var chatInputSection: some View {
        VStack(spacing: 8) {
            if let error = aiService.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            HStack(spacing: 8) {
                TextField("Ask about your writing...", text: $chatInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await sendChat() }
                    }

                Button {
                    Task { await sendChat() }
                } label: {
                    if aiService.isLoading && selectedAction == nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(chatInput.isEmpty || aiService.isLoading)
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func performAction(_ action: QuickAction) async {
        guard !selectedText.isEmpty else { return }

        selectedAction = action

        do {
            let result: String
            switch action {
            case .rewrite:
                result = try await aiService.rewrite(selectedText)
            case .expand:
                result = try await aiService.expand(selectedText)
            case .summarize:
                result = try await aiService.summarize(selectedText)
            case .suggestCitations:
                result = try await aiService.suggestCitations(for: selectedText)
            }
            actionResult = result
        } catch {
            // Error is shown via aiService.lastError
        }

        selectedAction = nil
    }

    private func sendChat() async {
        guard !chatInput.isEmpty else { return }

        let message = chatInput
        chatInput = ""

        // Provide context if text is selected
        let context = selectedText.isEmpty ? nil : selectedText

        do {
            _ = try await aiService.chat(message, context: context)
        } catch {
            // Error is shown via aiService.lastError
        }
    }
}

// MARK: - Quick Action Button

struct QuickActionButton: View {
    let action: QuickAction
    let isLoading: Bool
    let perform: () async -> Void

    var body: some View {
        Button {
            Task { await perform() }
        } label: {
            HStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: action.icon)
                }
                Text(action.title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .disabled(isLoading)
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .padding(10)
                    .background(backgroundColor)
                    .foregroundStyle(foregroundColor)
                    .cornerRadius(12)
                    .textSelection(.enabled)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
    }

    private var backgroundColor: Color {
        message.role == .user ? .accentColor : Color(nsColor: .controlBackgroundColor)
    }

    private var foregroundColor: Color {
        message.role == .user ? .white : .primary
    }
}

// MARK: - Quick Action Types

enum QuickAction: String, CaseIterable, Identifiable {
    case rewrite
    case expand
    case summarize
    case suggestCitations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rewrite: return "Rewrite"
        case .expand: return "Expand"
        case .summarize: return "Summarize"
        case .suggestCitations: return "Citations"
        }
    }

    var icon: String {
        switch self {
        case .rewrite: return "arrow.triangle.2.circlepath"
        case .expand: return "arrow.up.left.and.arrow.down.right"
        case .summarize: return "text.alignleft"
        case .suggestCitations: return "quote.opening"
        }
    }
}

// MARK: - AI Settings Sheet

struct AISettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var aiService = AIAssistantService.shared

    @State private var claudeKey = ""
    @State private var openaiKey = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("AI Assistant Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                Section("Provider") {
                    Picker("AI Provider", selection: $aiService.provider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }

                Section("Claude API Key") {
                    SecureField("sk-ant-...", text: $claudeKey)
                        .onAppear {
                            // Don't load actual key for security
                        }
                        .onSubmit {
                            if !claudeKey.isEmpty {
                                aiService.setAPIKey(claudeKey, for: .claude)
                            }
                        }

                    if !aiService.maskedAPIKey(for: .claude).isEmpty {
                        HStack {
                            Text("Current: \(aiService.maskedAPIKey(for: .claude))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear") {
                                aiService.setAPIKey("", for: .claude)
                            }
                            .font(.caption)
                        }
                    }

                    Link("Get Claude API Key", destination: URL(string: "https://console.anthropic.com/")!)
                        .font(.caption)
                }

                Section("OpenAI API Key") {
                    SecureField("sk-...", text: $openaiKey)
                        .onSubmit {
                            if !openaiKey.isEmpty {
                                aiService.setAPIKey(openaiKey, for: .openai)
                            }
                        }

                    if !aiService.maskedAPIKey(for: .openai).isEmpty {
                        HStack {
                            Text("Current: \(aiService.maskedAPIKey(for: .openai))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear") {
                                aiService.setAPIKey("", for: .openai)
                            }
                            .font(.caption)
                        }
                    }

                    Link("Get OpenAI API Key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.caption)
                }

                Section("Privacy") {
                    Text("Your text is sent to the selected AI provider's API. No data is stored on our servers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .frame(width: 450, height: 500)
    }
}

// MARK: - Preview

#Preview {
    AIChatSidebar(
        selectedText: .constant("This is some selected text that needs to be rewritten for clarity."),
        documentSource: .constant("= My Document\n\nSome content here."),
        onInsertText: { _ in }
    )
}
