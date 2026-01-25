//
//  NavigationButtonBar.swift
//  imbib
//
//  Created by Claude on 2026-01-15.
//

import SwiftUI
import PublicationManagerCore

// MARK: - Navigation Button Bar

/// Compact back/forward navigation buttons for browser-style history navigation.
///
/// Displays < > chevron buttons that enable/disable based on navigation history state.
/// Integrates with `NavigationHistoryStore` for state tracking.
struct NavigationButtonBar: View {

    // MARK: - Properties

    let navigationHistory: NavigationHistoryStore
    var onBack: () -> Void
    var onForward: () -> Void

    // MARK: - Body

    var body: some View {
        HStack(spacing: 2) {
            // Back button
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .disabled(!navigationHistory.canGoBack)
            .opacity(navigationHistory.canGoBack ? 1.0 : 0.3)
            .help("Back (⌘[)")

            // Forward button
            Button(action: onForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .disabled(!navigationHistory.canGoForward)
            .opacity(navigationHistory.canGoForward ? 1.0 : 0.3)
            .help("Forward (⌘])")
        }
    }
}

// MARK: - Preview

#Preview("Navigation Buttons") {
    NavigationButtonBar(
        navigationHistory: NavigationHistoryStore.shared,
        onBack: { print("Back") },
        onForward: { print("Forward") }
    )
    .padding()
}
