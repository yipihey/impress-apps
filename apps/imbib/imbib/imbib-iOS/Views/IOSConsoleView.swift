//
//  IOSConsoleView.swift
//  imbib-iOS
//
//  Stage 5b (2026-07-30): the 310-line second console is GONE. This is the
//  entry point, and nothing else.
//
//  `ImpressLogging.ConsoleView` — the console every impress app is supposed to
//  share (root CLAUDE.md, "Shared UI Patterns") — was cross-platform except
//  for two `#if os(macOS)` action bodies and a 600pt minimum width, so
//  imbib-iOS carried its own: its own filter chips, its own row view, its own
//  export, a hardcoded `"imbib-log-…"` filename, and no Performance tab. The
//  shared view now renders on both platforms and `ConsoleScreen` is its iOS
//  presentation.
//
//  The TYPE NAME stays, so `IOSSettingsView`'s `console` section factory (a
//  file another agent owns this wave) needs no edit — the same courtesy the
//  settings migration paid `IOSContentView` by keeping `IOSSettingsView`.
//

import SwiftUI
import PublicationManagerCore

/// imbib-iOS's debug console: the shared `ConsoleScreen`, with imbib's export
/// filename.
struct IOSConsoleView: View {
    var body: some View {
        ConsoleScreen(appName: "imbib")
    }
}

#Preview {
    IOSConsoleView()
}
