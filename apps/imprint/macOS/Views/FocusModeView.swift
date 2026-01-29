import SwiftUI

/// Distraction-free Focus Mode view that shows only the source editor
struct FocusModeView: View {
    @Binding var source: String
    @Binding var cursorPosition: Int
    @Binding var isActive: Bool

    @State private var showExitButton = true
    @State private var idleTimer: Timer?

    /// Maximum width for the editor to maintain readability
    private let maxEditorWidth: CGFloat = 720

    /// Time in seconds before the exit button fades
    private let idleTimeout: TimeInterval = 3.0

    var body: some View {
        ZStack {
            // Dark background
            Color(nsColor: .textBackgroundColor)
                .ignoresSafeArea()

            // Centered editor with constrained width
            SourceEditorView(
                source: $source,
                cursorPosition: $cursorPosition
            )
            .frame(maxWidth: maxEditorWidth)
            .padding(.horizontal, 40)
            .padding(.vertical, 60)

            // Exit button in top-right corner
            VStack {
                HStack {
                    Spacer()
                    exitButton
                }
                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            resetIdleTimer()
        }
        .onDisappear {
            idleTimer?.invalidate()
        }
        // Handle mouse movement to show exit button
        .onContinuousHover { phase in
            switch phase {
            case .active:
                showExitButton = true
                resetIdleTimer()
            case .ended:
                break
            }
        }
        .accessibilityIdentifier("focusMode.container")
    }

    private var exitButton: some View {
        Button(action: exitFocusMode) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                Text("Exit Focus")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .opacity(showExitButton ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: showExitButton)
        .help("Exit Focus Mode (Cmd+Shift+F)")
        .accessibilityIdentifier("focusMode.exitButton")
    }

    private func exitFocusMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isActive = false
        }
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { _ in
            withAnimation {
                showExitButton = false
            }
        }
    }
}

#Preview {
    FocusModeView(
        source: .constant("= Focus Mode Preview\n\nThis is a distraction-free writing environment."),
        cursorPosition: .constant(0),
        isActive: .constant(true)
    )
    .frame(width: 800, height: 600)
}
