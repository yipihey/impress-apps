//
//  ImprintIOSApp.swift
//  imprint-iOS
//
//  Created by Claude on 2026-01-27.
//

import SwiftUI

// MARK: - imprint iOS App

@main
struct ImprintIOSApp: App {

    // MARK: - Properties

    /// State for handling incoming URLs
    @State private var pendingURL: URL?

    // MARK: - Body

    var body: some Scene {
        // Document-based scene
        DocumentGroup(newDocument: ImprintDocument()) { file in
            NavigationStack {
                IOSContentView(document: file.$document)
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
        }
    }

    // MARK: - URL Handling

    private func handleIncomingURL(_ url: URL) {
        // Handle imprint:// URLs
        guard url.scheme == "imprint" else { return }

        switch url.host {
        case "open":
            handleOpenURL(url)
        default:
            break
        }
    }

    /// Handles `imprint://open?imbibManuscript={citeKey}&documentUUID={uuid}`
    private func handleOpenURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return
        }

        let imbibManuscript = queryItems.first { $0.name == "imbibManuscript" }?.value
        let documentUUID = queryItems.first { $0.name == "documentUUID" }?.value

        // TODO: Open the specific document
        print("Opening document for imbib manuscript: \(imbibManuscript ?? "unknown")")
        print("Document UUID: \(documentUUID ?? "unknown")")
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
