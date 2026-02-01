//
//  IOSContentView.swift
//  impart-iOS
//
//  Main content view for impart on iOS.
//

import SwiftUI
import MessageManagerCore

// MARK: - iOS Content View

/// Main content view with tab-based navigation.
struct IOSContentView: View {
    @Environment(IOSAppState.self) private var appState
    @State private var viewModel = InboxViewModel()
    @State private var selectedTab = Tab.inbox

    var body: some View {
        @Bindable var appState = appState

        TabView(selection: $selectedTab) {
            // Inbox tab
            NavigationStack(path: $appState.navigationPath) {
                IOSMailboxListView(viewModel: viewModel)
                    .navigationDestination(for: Mailbox.self) { mailbox in
                        IOSMessageListView(viewModel: viewModel, mailbox: mailbox)
                    }
                    .navigationDestination(for: UUID.self) { messageId in
                        IOSMessageDetailView(messageId: messageId)
                    }
            }
            .tabItem {
                Label("Inbox", systemImage: "tray.fill")
            }
            .tag(Tab.inbox)

            // Compose tab
            NavigationStack {
                IOSComposeView()
            }
            .tabItem {
                Label("Compose", systemImage: "square.and.pencil")
            }
            .tag(Tab.compose)

            // Settings tab
            NavigationStack {
                IOSSettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(Tab.settings)
        }
        .sheet(isPresented: $appState.isComposing) {
            IOSComposeSheet(draft: appState.currentDraft)
        }
    }
}

// MARK: - Tabs

enum Tab: String {
    case inbox
    case compose
    case settings
}

// MARK: - Mailbox List View

struct IOSMailboxListView: View {
    @Bindable var viewModel: InboxViewModel
    @Environment(IOSAppState.self) private var appState

    var body: some View {
        List {
            // TODO: Populate with accounts and mailboxes
            Section("Accounts") {
                Text("No accounts configured")
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Mailboxes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

// MARK: - Message List View

struct IOSMessageListView: View {
    @Bindable var viewModel: InboxViewModel
    let mailbox: Mailbox
    @Environment(IOSAppState.self) private var appState

    var body: some View {
        Group {
            if viewModel.filteredMessages.isEmpty {
                if viewModel.isLoading {
                    ProgressView("Loading...")
                } else {
                    ContentUnavailableView(
                        "No Messages",
                        systemImage: "tray",
                        description: Text("This mailbox is empty")
                    )
                }
            } else {
                List(viewModel.filteredMessages) { message in
                    NavigationLink(value: message.id) {
                        IOSMessageRow(message: message)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(mailbox.name)
        .searchable(text: $viewModel.searchQuery, prompt: "Search messages")
        .refreshable {
            await viewModel.refresh()
        }
        .onAppear {
            viewModel.selectedMailbox = mailbox
            Task { await viewModel.loadMessages() }
        }
    }
}

// MARK: - Message Row

struct IOSMessageRow: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.fromDisplayString)
                    .font(.headline)
                    .fontWeight(message.isRead ? .regular : .semibold)
                    .lineLimit(1)

                Spacer()

                Text(message.displayDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !message.isRead {
                    Circle()
                        .fill(.blue)
                        .frame(width: 8, height: 8)
                }
            }

            Text(message.subject)
                .font(.subheadline)
                .lineLimit(1)

            Text(message.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Message Detail View

struct IOSMessageDetailView: View {
    let messageId: UUID

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // TODO: Fetch and display message content
                Text("Message content will appear here")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Message")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    // Archive
                } label: {
                    Image(systemName: "archivebox")
                }

                Spacer()

                Button {
                    // Delete
                } label: {
                    Image(systemName: "trash")
                }

                Spacer()

                Button {
                    // Reply
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                }

                Spacer()

                Button {
                    // Forward
                } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                }
            }
        }
    }
}

// MARK: - Compose View

struct IOSComposeView: View {
    var body: some View {
        IOSComposeSheet(draft: nil)
            .navigationTitle("Compose")
    }
}

struct IOSComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: DraftMessage?

    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var messageBody = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("To", text: $to)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)

                    TextField("Cc", text: $cc)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)

                    TextField("Subject", text: $subject)
                }

                Section {
                    TextEditor(text: $messageBody)
                        .frame(minHeight: 200)
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
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
                    .disabled(to.isEmpty)
                }
            }
        }
        .onAppear {
            if let draft = draft {
                to = draft.to.map(\.email).joined(separator: ", ")
                cc = draft.cc.map(\.email).joined(separator: ", ")
                subject = draft.subject
                messageBody = draft.body
            }
        }
    }
}

// MARK: - Settings View

struct IOSSettingsView: View {
    var body: some View {
        List {
            Section("Accounts") {
                NavigationLink {
                    IOSAccountsSettingsView()
                } label: {
                    Label("Email Accounts", systemImage: "person.crop.circle")
                }
            }

            Section("Preferences") {
                NavigationLink {
                    IOSAppearanceSettingsView()
                } label: {
                    Label("Appearance", systemImage: "paintbrush")
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
    }
}

struct IOSAccountsSettingsView: View {
    var body: some View {
        List {
            Text("No accounts configured")
                .foregroundStyle(.secondary)
                .italic()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Add account
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

struct IOSAppearanceSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    var body: some View {
        List {
            Picker("Appearance", selection: $appearanceMode) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.inline)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Appearance")
    }
}

// MARK: - Preview

#Preview {
    IOSContentView()
        .environment(IOSAppState())
}
