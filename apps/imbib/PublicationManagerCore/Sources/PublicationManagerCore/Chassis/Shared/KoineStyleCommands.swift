//
//  KoineStyleCommands.swift
//  PublicationManagerCore
//
//  View ▸ Edit Style… (⌥⌘Y). The chassis root observes the notification and
//  presents the editor. The chord is in docs/keyboard-grammar.md.
//

import SwiftUI

public extension Notification.Name {
    static let editKoineStyle = Notification.Name("impress.editKoineStyle")
}

public struct KoineStyleMenuButton: View {
    public init() {}

    public var body: some View {
        Button("Edit Style…") {
            NotificationCenter.default.post(name: .editKoineStyle, object: nil)
        }
        .keyboardShortcut("y", modifiers: [.command, .option])
    }
}
