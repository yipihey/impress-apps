//
//  MessageRow.swift
//  impart (Shared)
//
//  Cross-platform message row for mail-style lists.
//

import SwiftUI
import ImpressMailStyle

// MARK: - Message Row

/// Cross-platform message row for displaying in lists.
/// Uses the shared MailStyleRow from ImpressMailStyle for consistent
/// visual rendering across the impress suite.
public struct MessageRow: View {
    let message: DisplayMessage

    public init(message: DisplayMessage) {
        self.message = message
    }

    public var body: some View {
        MailStyleRow(item: message)
    }
}

// MARK: - Compact Message Row

/// Compact message row for dense lists.
public struct CompactMessageRow: View {
    let message: DisplayMessage

    public init(message: DisplayMessage) {
        self.message = message
    }

    public var body: some View {
        MailStyleRow(item: message, configuration: .init(density: .compact))
    }
}

// MARK: - Preview

#Preview("Message Row") {
    List(DisplayMessage.samples) { message in
        MessageRow(message: message)
    }
    .listStyle(.plain)
}

#Preview("Compact Row") {
    List(DisplayMessage.samples) { message in
        CompactMessageRow(message: message)
    }
    .listStyle(.plain)
}
