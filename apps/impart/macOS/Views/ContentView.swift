//
//  ContentView.swift
//  impart (macOS)
//
//  Main content view for impart on macOS.
//  Integrates view modes, keyboard navigation, and AI agent support.
//

import SwiftUI
import MessageManagerCore
import ImpressKeyboard

// MARK: - Content View

/// Main content view with three-column layout and view mode switching.
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = InboxViewModel()
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    // View mode state
    @State private var viewModeState = ViewModeState()
    @State private var selectedSection: ImpartSidebarSection?
    @State private var selectedFolder: UUID?
    @State private var developmentViewModel = DevelopmentConversationViewModel()

    // Keyboard shortcuts store
    @State private var keyboardStore = ImpartKeyboardShortcutsStore.shared

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: Accounts and Folders
            ImpartSidebarView(
                viewModel: viewModel,
                selectedSection: $selectedSection,
                selectedFolder: $selectedFolder
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            // Content: View mode-specific list
            viewModeContent
                .navigationSplitViewColumnWidth(min: 280, ideal: 350, max: 500)
        } detail: {
            // Detail: Message Content
            if let messageId = appState.selectedMessageIds.first {
                MessageDetailView(messageId: messageId)
            } else {
                ContentUnavailableView(
                    "No Message Selected",
                    systemImage: "envelope",
                    description: Text("Select a message to read it")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // View mode picker
                viewModePicker
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.isComposing = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("Compose New Message (Cmd+N)")
                .keyboardShortcut("n", modifiers: .command)

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Check for New Mail (Cmd+Shift+R)")
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        .sheet(isPresented: $appState.isComposing) {
            ComposeView(draft: appState.currentDraft)
        }
        // Keyboard navigation
        .onKeyPress { press in
            handleKeyPress(press)
        }
        // View mode keyboard shortcuts
        .keyboardShortcut("1", modifiers: .command) // Email view
        .keyboardShortcut("2", modifiers: .command) // Chat view
        .keyboardShortcut("3", modifiers: .command) // Category view
        .keyboardShortcut("4", modifiers: .command) // Research view
        .keyboardShortcut("5", modifiers: .command) // Development view
        // Notification handlers
        .onReceive(NotificationCenter.default.publisher(for: .composeMessage)) { notification in
            handleComposeNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .checkMail)) { _ in
            Task { await viewModel.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("switchToEmailView"))) { _ in
            viewModeState.mode = .email
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("switchToChatView"))) { _ in
            viewModeState.mode = .chat
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("switchToCategoryView"))) { _ in
            viewModeState.mode = .category
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("switchToResearchView"))) { _ in
            viewModeState.mode = .research
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("switchToDevelopmentView"))) { _ in
            viewModeState.mode = .development
        }
    }

    // MARK: - View Mode Content

    @ViewBuilder
    private var viewModeContent: some View {
        switch viewModeState.mode {
        case .email:
            EmailListView(viewModel: viewModel)
        case .chat:
            ChatView(
                viewModel: viewModel,
                currentUserEmail: viewModel.currentAccountEmail ?? ""
            )
        case .category:
            CategoryView(viewModel: viewModel)
        case .research:
            ResearchConversationListView()
        case .development:
            DevelopmentConversationListView(viewModel: developmentViewModel)
        }
    }

    // MARK: - View Mode Picker

    private var viewModePicker: some View {
        Picker("View Mode", selection: $viewModeState.mode) {
            ForEach(MessageViewMode.allCases, id: \.self) { mode in
                Label(mode.displayName, systemImage: mode.iconName)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .help("Switch view mode (Cmd+1/2/3/4/5)")
    }

    // MARK: - Keyboard Handling

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Check for custom shortcut match
        if let binding = keyboardStore.matchingBinding(for: press) {
            NotificationCenter.default.post(name: Notification.Name(binding.notificationName), object: nil)
            return .handled
        }

        // Handle view mode shortcuts
        if press.modifiers.contains(.command) {
            switch press.characters {
            case "1":
                viewModeState.mode = .email
                return .handled
            case "2":
                viewModeState.mode = .chat
                return .handled
            case "3":
                viewModeState.mode = .category
                return .handled
            case "4":
                viewModeState.mode = .research
                return .handled
            case "5":
                viewModeState.mode = .development
                return .handled
            default:
                break
            }
        }

        // Handle vim-style navigation (no modifiers)
        // Skip when composing or when a text field has focus
        if press.modifiers.isEmpty && !appState.isComposing && !TextFieldFocusDetection.isTextFieldFocused() {
            switch press.characters {
            case "j":
                navigateToNextMessage()
                return .handled
            case "k":
                navigateToPreviousMessage()
                return .handled
            case "h":
                cycleFocusLeft()
                return .handled
            case "l":
                cycleFocusRight()
                return .handled
            case "d":
                dismissSelectedMessages()
                return .handled
            case "s":
                saveSelectedMessages()
                return .handled
            case "r":
                markSelectedAsRead()
                return .handled
            case "u":
                markSelectedAsUnread()
                return .handled
            default:
                break
            }
        }

        // Shift+s for toggle star (skip when text field has focus)
        if press.modifiers == .shift && press.characters.lowercased() == "s" && !appState.isComposing && !TextFieldFocusDetection.isTextFieldFocused() {
            toggleStarOnSelected()
            return .handled
        }

        return .ignored
    }

    // MARK: - Navigation Actions

    private func navigateToNextMessage() {
        guard let currentId = appState.selectedMessageIds.first,
              let currentIndex = viewModel.sortedMessages.firstIndex(where: { $0.id == currentId }),
              currentIndex < viewModel.sortedMessages.count - 1 else {
            // Select first message if nothing selected
            if let firstId = viewModel.sortedMessages.first?.id {
                appState.selectedMessageIds = [firstId]
            }
            return
        }

        let nextId = viewModel.sortedMessages[currentIndex + 1].id
        appState.selectedMessageIds = [nextId]
    }

    private func navigateToPreviousMessage() {
        guard let currentId = appState.selectedMessageIds.first,
              let currentIndex = viewModel.sortedMessages.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else {
            // Select last message if nothing selected
            if let lastId = viewModel.sortedMessages.last?.id {
                appState.selectedMessageIds = [lastId]
            }
            return
        }

        let prevId = viewModel.sortedMessages[currentIndex - 1].id
        appState.selectedMessageIds = [prevId]
    }

    private func cycleFocusLeft() {
        // Switch focus to sidebar
        NotificationCenter.default.post(name: Notification.Name("focusSidebar"), object: nil)
    }

    private func cycleFocusRight() {
        // Switch focus to detail
        NotificationCenter.default.post(name: Notification.Name("focusDetail"), object: nil)
    }

    // MARK: - Triage Actions

    private func dismissSelectedMessages() {
        Task {
            let result = await viewModel.dismissMessages(
                ids: appState.selectedMessageIds,
                currentSelection: appState.selectedMessageIds.first
            )
            if let nextId = result.nextSelection {
                appState.selectedMessageIds = [nextId]
            } else {
                appState.selectedMessageIds = []
            }
        }
    }

    private func saveSelectedMessages() {
        Task {
            let result = await viewModel.saveMessages(
                ids: appState.selectedMessageIds,
                currentSelection: appState.selectedMessageIds.first
            )
            if let nextId = result.nextSelection {
                appState.selectedMessageIds = [nextId]
            } else {
                appState.selectedMessageIds = []
            }
        }
    }

    private func toggleStarOnSelected() {
        Task {
            await viewModel.toggleStar(for: appState.selectedMessageIds)
        }
    }

    private func markSelectedAsRead() {
        Task {
            await viewModel.markAsRead(ids: appState.selectedMessageIds)
        }
    }

    private func markSelectedAsUnread() {
        Task {
            await viewModel.markAsUnread(ids: appState.selectedMessageIds)
        }
    }

    // MARK: - Notification Handlers

    private func handleComposeNotification(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            let to = (userInfo["to"] as? String).map { [EmailAddress(email: $0)] } ?? []
            let subject = userInfo["subject"] as? String ?? ""
            let body = userInfo["body"] as? String ?? ""

            if let accountId = appState.selectedAccountId {
                appState.currentDraft = DraftMessage(
                    accountId: accountId,
                    to: to,
                    subject: subject,
                    body: body
                )
            }
        }
        appState.isComposing = true
    }
}

// MARK: - Message Detail View

/// Detail view for a single message.
struct MessageDetailView: View {
    let messageId: UUID
    @State private var message: Message?
    @State private var content: MessageContent?
    @State private var isLoading = true
    @State private var error: String?
    @State private var isStarred = false
    @State private var showingReplySheet = false
    @State private var showingForwardSheet = false

    private let persistence = PersistenceController.shared

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading message...")
            } else if let error {
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if let message {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header
                        messageHeader(message)

                        Divider()

                        // Body
                        if let content {
                            if let html = content.htmlBody {
                                // TODO: WebView for HTML content
                                Text("HTML content display not yet implemented")
                                    .foregroundStyle(.secondary)
                            } else if let text = content.textBody {
                                Text(text)
                                    .textSelection(.enabled)
                                    .font(.body)
                            }
                        } else {
                            Text(message.snippet)
                                .textSelection(.enabled)
                                .font(.body)
                        }

                        // Attachments
                        if message.hasAttachments, let attachments = content?.attachments, !attachments.isEmpty {
                            attachmentSection(attachments)
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView(
                    "Message Not Found",
                    systemImage: "envelope",
                    description: Text("The message could not be loaded")
                )
            }
        }
        .navigationTitle(message?.subject ?? "Message")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingReplySheet = true
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .help("Reply (Cmd+R)")

                Button {
                    showingForwardSheet = true
                } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                }
                .help("Forward")

                Button {
                    Task { await toggleStar() }
                } label: {
                    Label(isStarred ? "Unstar" : "Star", systemImage: isStarred ? "star.fill" : "star")
                }
                .help("Star (Shift+S)")

                Button {
                    Task { await toggleRead() }
                } label: {
                    Label(message?.isRead == true ? "Mark Unread" : "Mark Read", systemImage: message?.isRead == true ? "envelope.badge.fill" : "envelope.open")
                }
                .help("Toggle Read Status")
            }
        }
        .task {
            await loadMessage()
        }
        .onChange(of: messageId) {
            Task { await loadMessage() }
        }
        .sheet(isPresented: $showingReplySheet) {
            if let message, let content {
                let draft = DraftMessage.reply(to: message, accountId: message.accountId, content: content)
                ComposeView(draft: draft)
            }
        }
        .sheet(isPresented: $showingForwardSheet) {
            if let message, let content {
                let draft = DraftMessage.forward(message: message, accountId: message.accountId, content: content)
                ComposeView(draft: draft)
            }
        }
    }

    @ViewBuilder
    private func messageHeader(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.subject)
                    .font(.title2)
                    .bold()
                Spacer()
                if isStarred {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                if !message.isRead {
                    Circle()
                        .fill(.blue)
                        .frame(width: 8, height: 8)
                }
            }

            HStack {
                Text("From:")
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)
                Text(message.fromDisplayString)
                    .textSelection(.enabled)
            }

            HStack {
                Text("To:")
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)
                Text(message.to.map(\.displayString).joined(separator: ", "))
                    .textSelection(.enabled)
            }

            if !message.cc.isEmpty {
                HStack {
                    Text("Cc:")
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .leading)
                    Text(message.cc.map(\.displayString).joined(separator: ", "))
                        .textSelection(.enabled)
                }
            }

            HStack {
                Text("Date:")
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)
                Text(message.date, format: .dateTime.month().day().year().hour().minute())
            }

            if message.hasAttachments {
                HStack {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                    Text("Has attachments")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func attachmentSection(_ attachments: [Attachment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("Attachments (\(attachments.count))")
                .font(.headline)

            ForEach(attachments) { attachment in
                HStack {
                    Image(systemName: attachment.iconName)
                        .foregroundStyle(.blue)
                    Text(attachment.filename)
                    Spacer()
                    Text(attachment.displaySize)
                        .foregroundStyle(.secondary)
                    Button("Save") {
                        saveAttachment(attachment)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func loadMessage() async {
        isLoading = true
        error = nil

        do {
            let fetchedMessage = try await persistence.performBackgroundTask { context in
                let request = CDMessage.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
                request.fetchLimit = 1
                return try context.fetch(request).first?.toMessage()
            }

            await MainActor.run {
                self.message = fetchedMessage
                self.isStarred = fetchedMessage?.isStarred ?? false
            }

            // Fetch content if available
            let fetchedContent = try await persistence.performBackgroundTask { context in
                let request = CDMessage.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
                request.fetchLimit = 1

                guard let cdMessage = try context.fetch(request).first,
                      let cdContent = cdMessage.content else {
                    return nil as MessageContent?
                }

                let attachments = (cdContent.attachments ?? []).map { cdAttachment in
                    Attachment(
                        id: cdAttachment.id,
                        filename: cdAttachment.filename,
                        mimeType: cdAttachment.mimeType,
                        size: Int(cdAttachment.size),
                        contentId: cdAttachment.contentId,
                        isInline: cdAttachment.isInline
                    )
                }

                return MessageContent(
                    messageId: messageId,
                    textBody: cdContent.textBody,
                    htmlBody: cdContent.htmlBody,
                    attachments: attachments
                )
            }

            await MainActor.run {
                self.content = fetchedContent
                self.isLoading = false
            }

            // Mark as read
            if let msg = fetchedMessage, !msg.isRead {
                try await markAsRead()
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func markAsRead() async throws {
        try await persistence.performBackgroundTask { context in
            let request = CDMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
            if let cdMessage = try context.fetch(request).first {
                cdMessage.isRead = true
                try context.save()
            }
        }
    }

    private func toggleRead() async {
        guard let currentMessage = message else { return }
        let newReadState = !currentMessage.isRead

        do {
            try await persistence.performBackgroundTask { context in
                let request = CDMessage.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
                if let cdMessage = try context.fetch(request).first {
                    cdMessage.isRead = newReadState
                    try context.save()
                }
            }

            await MainActor.run {
                // Update local state (create new Message with updated isRead)
                if var updatedMessage = self.message {
                    self.message = Message(
                        id: updatedMessage.id,
                        accountId: updatedMessage.accountId,
                        mailboxId: updatedMessage.mailboxId,
                        uid: updatedMessage.uid,
                        messageId: updatedMessage.messageId,
                        inReplyTo: updatedMessage.inReplyTo,
                        references: updatedMessage.references,
                        subject: updatedMessage.subject,
                        from: updatedMessage.from,
                        to: updatedMessage.to,
                        cc: updatedMessage.cc,
                        bcc: updatedMessage.bcc,
                        date: updatedMessage.date,
                        receivedDate: updatedMessage.receivedDate,
                        snippet: updatedMessage.snippet,
                        isRead: newReadState,
                        isStarred: updatedMessage.isStarred,
                        hasAttachments: updatedMessage.hasAttachments,
                        labels: updatedMessage.labels
                    )
                }
            }
        } catch {
            // Handle error silently
        }
    }

    private func toggleStar() async {
        let newStarState = !isStarred

        do {
            try await persistence.performBackgroundTask { context in
                let request = CDMessage.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
                if let cdMessage = try context.fetch(request).first {
                    cdMessage.isStarred = newStarState
                    try context.save()
                }
            }

            await MainActor.run {
                self.isStarred = newStarState
            }
        } catch {
            // Handle error silently
        }
    }

    private func saveAttachment(_ attachment: Attachment) {
        // TODO: Implement save panel and write attachment data
    }
}

// MARK: - Compose View

/// Compose new message sheet.
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    let draft: DraftMessage?

    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var showAgentPicker = false

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField("To:", text: $to)

                    // Agent picker button
                    Button {
                        showAgentPicker = true
                    } label: {
                        Image(systemName: "brain.head.profile")
                    }
                    .help("Add AI Agent")
                    .popover(isPresented: $showAgentPicker) {
                        agentPickerPopover
                    }
                }

                TextField("Cc:", text: $cc)
                TextField("Subject:", text: $subject)

                TextEditor(text: $messageBody)
                    .frame(minHeight: 200)
            }
            .padding()
            .navigationTitle("New Message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        // TODO: Send message
                        dismiss()
                    }
                    .disabled(to.isEmpty || subject.isEmpty)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            if let draft = draft {
                to = draft.to.map(\.email).joined(separator: ", ")
                cc = draft.cc.map(\.email).joined(separator: ", ")
                subject = draft.subject
                messageBody = draft.body
            }
        }
    }

    private var agentPickerPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add AI Agent")
                .font(.headline)

            Divider()

            ForEach(AgentType.allCases, id: \.self) { type in
                if type != .custom {
                    Button {
                        addAgent(type: type, model: "opus4.5")
                        showAgentPicker = false
                    } label: {
                        Label(type.displayName, systemImage: type.iconName)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .frame(width: 200)
    }

    private func addAgent(type: AgentType, model: String) {
        let agentEmail = AgentAddress.create(type: type, model: model)
        if to.isEmpty {
            to = agentEmail
        } else {
            to += ", \(agentEmail)"
        }
    }
}

// MARK: - Settings View

/// Application settings.
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettingsView()
                .tabItem {
                    Label("Accounts", systemImage: "person.crop.circle")
                }

            AISettingsTab()
                .tabItem {
                    Label("AI", systemImage: "brain.head.profile")
                }

            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            KeyboardSettingsView()
                .tabItem {
                    Label("Keyboard", systemImage: "keyboard")
                }

            AutomationSettingsView()
                .tabItem {
                    Label("Automation", systemImage: "terminal")
                }
        }
        .frame(width: 550, height: 500)
    }
}

struct AccountsSettingsView: View {
    var body: some View {
        VStack {
            Text("Account Settings")
                .font(.headline)
            Text("Configure email accounts here.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct GeneralSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("defaultViewMode") private var defaultViewMode = "email"

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearanceMode) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)

            Picker("Default View", selection: $defaultViewMode) {
                ForEach(MessageViewMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
        }
        .padding()
    }
}

struct KeyboardSettingsView: View {
    @State private var store = ImpartKeyboardShortcutsStore.shared

    var body: some View {
        VStack(alignment: .leading) {
            Text("Keyboard Shortcuts")
                .font(.headline)

            List {
                ForEach(ImpartShortcutCategory.allCases, id: \.self) { category in
                    Section(category.displayName) {
                        ForEach(store.settings.bindings(for: category)) { binding in
                            HStack {
                                Text(binding.displayName)
                                Spacer()
                                Text(binding.displayShortcut)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    store.resetToDefaults()
                }
            }
        }
        .padding()
    }
}

struct AutomationSettingsView: View {
    @AppStorage("httpAutomationEnabled") private var httpEnabled = false
    @AppStorage("httpAutomationPort") private var httpPort = 23122

    var body: some View {
        Form {
            Toggle("Enable HTTP API", isOn: $httpEnabled)
            TextField("Port", value: $httpPort, format: .number)
                .disabled(!httpEnabled)
        }
        .padding()
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(AppState())
}
