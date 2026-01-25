//
//  HelpWindowView.swift
//  imbib
//
//  macOS-specific wrapper for the Help browser window.
//

import SwiftUI
import PublicationManagerCore

/// macOS wrapper view for the help browser.
///
/// This view wraps the shared HelpBrowserView and adds
/// macOS-specific window chrome and toolbar items.
struct HelpWindowView: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        HelpBrowserView()
            .frame(minWidth: 800, idealWidth: 900, minHeight: 500, idealHeight: 700)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
    }
}

// MARK: - Preview

#Preview {
    HelpWindowView()
}
