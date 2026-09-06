//
//  ComposeView.swift
//  impart (macOS)
//
//  Stage 4c: EXTRACTED VERBATIM from the classic `ContentView.swift`.
//
//  Compose was the one live capability the classic three-column window had that
//  the chassis window did not — the sheet was declared on `ContentView`, so ⌘N,
//  the File-menu item and `impart://compose` all posted `.composeMessage` into a
//  window nobody was looking at once the chassis became default. It could not
//  simply move with the flag flip either: `ComposeView` was DECLARED inside the
//  1000-line classic file, so deleting that file would have deleted compose.
//
//  It now lives here, unchanged, and is presented by `MailChassisHost` (the
//  chassis window's mail host modifier). Its `Send` button is still the TODO it
//  has always been — SMTP send is not wired anywhere in impart, and pretending
//  otherwise was not part of this stage.
//

import ImpressKit
import MessageManagerCore
import SwiftUI

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
        .impressResizableSheet(minWidth: 500, minHeight: 400)
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
