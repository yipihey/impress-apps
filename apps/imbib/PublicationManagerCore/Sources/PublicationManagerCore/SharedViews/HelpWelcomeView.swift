//
//  HelpWelcomeView.swift
//  PublicationManagerCore
//
//  Welcome/empty state view for the help browser.
//

import SwiftUI

/// Welcome view shown when no help document is selected.
public struct HelpWelcomeView: View {

    // MARK: - Properties

    var onSelectGettingStarted: () -> Void

    // MARK: - Initialization

    public init(onSelectGettingStarted: @escaping () -> Void = {}) {
        self.onSelectGettingStarted = onSelectGettingStarted
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: "book.pages")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            // Title
            Text("imbib Help")
                .font(.largeTitle)
                .fontWeight(.bold)

            // Subtitle
            Text("Browse the sidebar to explore help topics,\nor search for specific information.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Quick start button
            Button {
                onSelectGettingStarted()
            } label: {
                Label("Getting Started", systemImage: "play.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)

            // Keyboard hints
            VStack(spacing: 8) {
                keyboardHint(key: "?", description: "Search help")
                keyboardHint(key: "Esc", description: "Close help")
            }
            .padding(.top, 16)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(welcomeBackground)
    }

    // MARK: - Keyboard Hint

    private func keyboardHint(key: String, description: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                )

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Styling

    private var welcomeBackground: some ShapeStyle {
        #if os(macOS)
        return AnyShapeStyle(Color(nsColor: .textBackgroundColor))
        #else
        return AnyShapeStyle(Color(.systemBackground))
        #endif
    }
}

// MARK: - Preview

#Preview {
    HelpWelcomeView()
        .frame(width: 600, height: 500)
}
