//
//  ImprintIOSApp.swift
//  imprint-iOS
//
//  Created by Claude on 2026-01-27.
//

import SwiftUI
import ImprintCore

// MARK: - imprint iOS App

@main
struct ImprintIOSApp: App {

    // MARK: - Properties

    /// State for handling incoming URLs
    @State private var pendingURL: URL?

    // MARK: - Body

    var body: some Scene {
        // Store-backed manuscripts app (GUI-meld Phase 8): a manuscript
        // library fronts the editor rather than the system document browser,
        // so imprint-iOS reads/writes the same unified store as imbib and
        // macOS imprint. URL handling + outline-snapshot upkeep live inside
        // the library view.
        WindowGroup {
            IOSManuscriptLibraryView()
        }
    }
}

// MARK: - Configuration

extension ImprintIOSApp {
    /// Configure app-wide keyboard shortcuts
    /// Note: Keyboard shortcuts are handled by SwiftUI's .keyboardShortcut() modifier
    static func configureKeyboardShortcuts() {
        // No additional configuration needed - shortcuts are declarative in SwiftUI
    }
}
