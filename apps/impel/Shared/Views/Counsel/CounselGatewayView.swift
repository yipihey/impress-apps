//
//  CounselGatewayView.swift
//  impel
//
//  Counsel mail-gateway surface (live/history) + rows, bubbles, details.
//  Moved verbatim from ContentView.swift (C0 mechanical decomposition,
//  Stage 2-C of the GUI unification) — no renames, no signature changes.
//

import SwiftUI
import ImpelCore
import ImpelMail
import CounselEngine
import ImpressKeyboard
import ImpressKit

// MARK: - Counsel Gateway View

struct CounselGatewayView: View {
    @EnvironmentObject var mailGateway: MailGatewayState
    @State private var selectedThreadID: String?
    @State private var selectedConversationID: String?
    @State private var viewMode: CounselViewMode = .live
    @State private var searchQuery = ""

    enum CounselViewMode: String, CaseIterable {
        case live = "Live"
        case history = "History"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            counselStatusBar
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider()

            // View mode picker
            Picker("View", selection: $viewMode) {
                ForEach(CounselViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            switch viewMode {
            case .live:
                liveView
            case .history:
                historyView
            }
        }
        .navigationTitle("Counsel Gateway")
    }

    // MARK: - Live View

    @ViewBuilder
    private var liveView: some View {
        if mailGateway.counselThreads.isEmpty && mailGateway.persistentConversations.isEmpty {
            counselEmptyState
        } else if mailGateway.counselThreads.isEmpty {
            ContentUnavailableView("No Active Requests", systemImage: "envelope.open",
                description: Text("Send an email to counsel@impress.local. Check History for past conversations."))
        } else {
            HSplitView {
                counselThreadList
                    .frame(minWidth: 280, idealWidth: 320)
                counselDetailView
                    .frame(minWidth: 350)
            }
        }
    }

    // MARK: - History View

    @ViewBuilder
    private var historyView: some View {
        let conversations = mailGateway.persistentConversations
        let filtered = searchQuery.isEmpty ? conversations : conversations.filter {
            $0.subject.localizedCaseInsensitiveContains(searchQuery) ||
            $0.participantEmail.localizedCaseInsensitiveContains(searchQuery)
        }

        if conversations.isEmpty {
            ContentUnavailableView("No Conversation History", systemImage: "clock",
                description: Text("Conversations will appear here after counsel processes your first request."))
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search conversations...", text: $searchQuery)
                            .textFieldStyle(.plain)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))

                    List(filtered, id: \.id, selection: $selectedConversationID) { conv in
                        CounselConversationRow(conversation: conv)
                            .tag(conv.id)
                    }
                    .listStyle(.inset)
                }
                .frame(minWidth: 280, idealWidth: 320)

                // Detail
                if let convID = selectedConversationID,
                   let conv = conversations.first(where: { $0.id == convID }) {
                    CounselConversationDetailView(conversation: conv)
                        .environmentObject(mailGateway)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Select a conversation")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - Status Bar

    private var counselStatusBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(mailGateway.smtpRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text("SMTP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(mailGateway.imapRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text("IMAP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(mailGateway.totalMessages) messages")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !mailGateway.persistentConversations.isEmpty {
                Text("\(mailGateway.persistentConversations.count) conversations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("counsel@impress.local")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Thread List

    private var counselThreadList: some View {
        List(mailGateway.counselThreads, id: \.id, selection: $selectedThreadID) { thread in
            CounselThreadRow(thread: thread)
                .tag(thread.id)
        }
        .listStyle(.inset)
    }

    // MARK: - Detail View

    @ViewBuilder
    private var counselDetailView: some View {
        if let threadID = selectedThreadID,
           let thread = mailGateway.counselThreads.first(where: { $0.id == threadID }) {
            CounselThreadDetailView(thread: thread)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Select a request to view details")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Empty State

    private var counselEmptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ContentUnavailableView(
                    "No Requests Yet",
                    systemImage: "envelope",
                    description: Text("Send an email to counsel@impress.local to get started.")
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Mail Client Setup")
                        .font(.headline)

                    Text("You are PI@impress.local. Counsel is your research assistant. Set up a mail account to correspond:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        counselSetupRow("Account Name", value: "impress (local)")
                        counselSetupRow("Your Address", value: "PI@impress.local")
                        counselSetupRow("Incoming (IMAP)", value: "localhost, port \(mailGateway.imapPort)")
                        counselSetupRow("Outgoing (SMTP)", value: "localhost, port \(mailGateway.smtpPort)")
                        counselSetupRow("Security", value: "None (localhost only)")
                        counselSetupRow("Authentication", value: "Any username/password")
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(.rect(cornerRadius: 8))

                    Text("Then compose a new message to **counsel@impress.local** — just like emailing a colleague.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Test")
                        .font(.headline)

                    Text("Send a test email via command line:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("""
                    python3 -c "
                    import smtplib
                    from email.message import EmailMessage
                    msg = EmailMessage()
                    msg['From'] = 'PI@impress.local'
                    msg['To'] = 'counsel@impress.local'
                    msg['Subject'] = 'Find papers on dark matter halos'
                    msg.set_content('Find the 3 most cited papers from 2024.')
                    with smtplib.SMTP('localhost', \(mailGateway.smtpPort)) as s:
                        s.send_message(msg)
                        print('Sent!')
                    "
                    """)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(.rect(cornerRadius: 8))
                    .textSelection(.enabled)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    private func counselSetupRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 160, alignment: .trailing)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

// MARK: - Counsel Conversation Row (History)

struct CounselConversationRow: View {
    let conversation: CounselConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.subject)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text(conversation.status.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .foregroundStyle(statusColor)
                    .clipShape(.rect(cornerRadius: 3))
            }

            HStack(spacing: 8) {
                Text(conversation.participantEmail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if conversation.totalTokensUsed > 0 {
                    Text("\(conversation.totalTokensUsed) tokens")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text("\(conversation.messageCount) msgs")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text(conversation.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch conversation.status {
        case .active: return .green
        case .archived: return .secondary
        case .failed: return .red
        }
    }
}

// MARK: - Counsel Conversation Detail View (History)

struct CounselConversationDetailView: View {
    let conversation: CounselConversation
    @EnvironmentObject var mailGateway: MailGatewayState
    @State private var messages: [CounselMessage] = []
    @State private var toolExecutions: [CounselToolExecution] = []
    @State private var showTools = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(conversation.subject)
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 12) {
                        Label(conversation.participantEmail, systemImage: "person")
                        Label {
                            Text(conversation.createdAt, style: .date)
                        } icon: {
                            Image(systemName: "calendar")
                        }

                        Spacer()

                        if conversation.totalTokensUsed > 0 {
                            Label("\(conversation.totalTokensUsed) tokens", systemImage: "number")
                                .foregroundStyle(.secondary)
                        }

                        Text("\(conversation.messageCount) messages")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Divider()

                // Tool execution toggle
                if !toolExecutions.isEmpty {
                    DisclosureGroup("Tool Executions (\(toolExecutions.count))", isExpanded: $showTools) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(toolExecutions, id: \.id) { exec in
                                CounselToolExecutionRow(execution: exec)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.04))
                    .clipShape(.rect(cornerRadius: 8))
                }

                // Messages
                ForEach(messages, id: \.id) { message in
                    CounselMessageBubble(message: message)
                }
            }
            .padding()
        }
        .onAppear { loadData() }
        .onChange(of: conversation.id) { _, _ in loadData() }
    }

    private func loadData() {
        guard let engine = mailGateway.counselEngine else { return }
        messages = (try? engine.messages(for: conversation.id)) ?? []
        toolExecutions = (try? engine.toolExecutions(for: conversation.id)) ?? []
    }
}

// MARK: - Counsel Message Bubble

struct CounselMessageBubble: View {
    let message: CounselMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.role == .user { Spacer() }

                Label(roleLabel, systemImage: roleIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if message.role != .user { Spacer() }
            }

            if message.role == .toolUse || message.role == .toolResult {
                Text(message.content.prefix(200))
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(backgroundColor)
                    .clipShape(.rect(cornerRadius: 8))
            }

            if message.tokenCount > 0 {
                Text("\(message.tokenCount) tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "PI"
        case .assistant: return "Counsel"
        case .system: return "System"
        case .toolUse: return "Tool Call"
        case .toolResult: return "Tool Result"
        }
    }

    private var roleIcon: String {
        switch message.role {
        case .user: return "person"
        case .assistant: return "brain"
        case .system: return "gearshape"
        case .toolUse: return "wrench"
        case .toolResult: return "arrow.turn.down.left"
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: return Color.blue.opacity(0.08)
        case .assistant: return Color.green.opacity(0.08)
        case .system: return Color.secondary.opacity(0.06)
        case .toolUse, .toolResult: return Color.secondary.opacity(0.06)
        }
    }
}

// MARK: - Counsel Tool Execution Row

struct CounselToolExecutionRow: View {
    let execution: CounselToolExecution

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: execution.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(execution.isError ? .red : .green)
                    .font(.caption)

                Text(execution.toolName)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))

                Spacer()

                Text("\(execution.durationMs)ms")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !execution.toolInput.isEmpty && execution.toolInput != "{}" {
                Text(execution.toolInput.prefix(100))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(6)
        .background(execution.isError ? Color.red.opacity(0.04) : Color.clear)
        .clipShape(.rect(cornerRadius: 4))
    }
}

// MARK: - Counsel Thread Row

struct CounselThreadRow: View {
    let thread: CounselThread

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(thread.request.subject)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(thread.request.intent.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15))
                        .clipShape(.rect(cornerRadius: 3))

                    Text(thread.request.from)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(thread.status.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(thread.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch thread.status {
        case .received: return "envelope.badge"
        case .acknowledged: return "checkmark.circle"
        case .working: return "gearshape.2"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch thread.status {
        case .received: return .blue
        case .acknowledged: return .orange
        case .working: return .purple
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Counsel Thread Detail

struct CounselThreadDetailView: View {
    let thread: CounselThread

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(thread.request.subject)
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 12) {
                        Label(thread.request.from, systemImage: "person")
                        Label {
                            Text(thread.request.date, style: .date)
                        } icon: {
                            Image(systemName: "calendar")
                        }
                        Label(thread.request.intent.rawValue, systemImage: "tag")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.15))
                            .clipShape(.rect(cornerRadius: 4))

                        Spacer()

                        Text(thread.status.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(statusColor.opacity(0.15))
                            .foregroundStyle(statusColor)
                            .clipShape(.rect(cornerRadius: 4))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Label("Request", systemImage: "envelope")
                        .font(.headline)
                    Text(thread.request.body)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(.rect(cornerRadius: 8))
                }

                if thread.status != .received {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Acknowledged", systemImage: "checkmark.circle")
                            .font(.headline)
                        Text("Received your request. Working on it now.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.06))
                            .clipShape(.rect(cornerRadius: 8))
                    }
                }

                if let response = thread.response {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Response", systemImage: "text.bubble")
                            .font(.headline)
                        Text(response.body)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.06))
                            .clipShape(.rect(cornerRadius: 8))
                    }
                }

                if thread.status == .working {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Processing request...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if thread.status == .failed {
                    Label("This request failed to process.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
    }

    private var statusColor: Color {
        switch thread.status {
        case .received: return .blue
        case .acknowledged: return .orange
        case .working: return .purple
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Counsel Defaults

/// Non-isolated constants for the counsel persona, accessible from @Sendable contexts.
enum CounselDefaults {
    static let systemPrompt = """
        You are counsel, a research assistant integrated into the impress research environment. \
        You communicate with the user via email. Respond helpfully and concisely. \
        Format your response as a plain-text email reply.
        """

    static let defaultModel = "sonnet"
}

/// Available models for the counsel persona.
enum CounselModel: String, CaseIterable, Identifiable {
    case haiku = "haiku"
    case sonnet = "sonnet"
    case opus = "opus"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .haiku: return "Claude Haiku"
        case .sonnet: return "Claude Sonnet"
        case .opus: return "Claude Opus"
        }
    }

    var description: String {
        switch self {
        case .haiku: return "Fastest, most cost-efficient"
        case .sonnet: return "Balanced speed and intelligence"
        case .opus: return "Most capable, deepest reasoning"
        }
    }
}
