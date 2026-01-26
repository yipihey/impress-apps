import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The position of the mode indicator overlay.
public enum HelixModeIndicatorPosition: String, Sendable, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

/// A view that displays the current Helix editing mode as a floating badge.
public struct HelixModeIndicator: View {
    @ObservedObject var state: HelixState
    let position: HelixModeIndicatorPosition
    @State private var isPulsing = false

    public init(state: HelixState, position: HelixModeIndicatorPosition = .bottomLeft) {
        self.state = state
        self.position = position
    }

    public var body: some View {
        VStack(spacing: 4) {
            // Main mode indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(modeColor)
                    .frame(width: 8, height: 8)
                    .scaleEffect(state.mode == .select && isPulsing ? 1.3 : 1.0)

                Text(displayText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                // Pending key indicator
                if let pending = state.keyHandler.pendingKey {
                    Text("[\(String(pending))]")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Awaiting character indicator
                if state.keyHandler.pendingCharOp != nil {
                    Text("[?]")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.regularMaterial)
                    .overlay {
                        // Colored border in select mode
                        if state.mode == .select {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(modeColor.opacity(0.5), lineWidth: 1.5)
                        }
                    }
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            }
            .animation(.easeInOut(duration: 0.15), value: state.mode)

            // Search indicator
            if state.isSearching {
                SearchIndicator(state: state)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: state.mode) { _, newMode in
            if newMode == .select {
                startPulse()
            } else {
                isPulsing = false
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.isSearching)
    }

    private var displayText: String {
        state.mode.displayName
    }

    private var modeColor: Color {
        switch state.mode {
        case .normal:
            return .blue
        case .insert:
            return .green
        case .select:
            return .orange
        }
    }

    private func startPulse() {
        isPulsing = true
        withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) {
            isPulsing = true
        }
    }
}

/// Search input indicator shown during search mode.
struct SearchIndicator: View {
    @ObservedObject var state: HelixState

    var body: some View {
        HStack(spacing: 4) {
            Text(state.searchBackward ? "?" : "/")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(state.searchQuery.isEmpty ? "search..." : state.searchQuery)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(state.searchQuery.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.purple.opacity(0.4), lineWidth: 1)
                }
        }
    }
}

/// Provides colors for Helix mode-aware selection highlighting.
public struct HelixSelectionColors {
    /// Selection color for normal mode (standard system selection).
    public static var normal: Color {
        #if os(macOS)
        Color(nsColor: .selectedTextBackgroundColor)
        #else
        Color(uiColor: .systemBlue.withAlphaComponent(0.3))
        #endif
    }

    /// Selection color for select mode (more prominent orange).
    public static var select: Color {
        Color.orange.opacity(0.35)
    }

    /// Selection color for the current mode.
    public static func color(for mode: HelixMode) -> Color {
        switch mode {
        case .normal, .insert:
            return normal
        case .select:
            return select
        }
    }
}

/// View modifier that overlays the mode indicator on content.
public struct HelixModeIndicatorOverlay: ViewModifier {
    @ObservedObject var state: HelixState
    let position: HelixModeIndicatorPosition
    let isVisible: Bool
    let padding: CGFloat
    @State private var announcementText: String = ""

    public init(
        state: HelixState,
        position: HelixModeIndicatorPosition = .bottomLeft,
        isVisible: Bool = true,
        padding: CGFloat = 12
    ) {
        self.state = state
        self.position = position
        self.isVisible = isVisible
        self.padding = padding
    }

    public func body(content: Content) -> some View {
        content
            .overlay(alignment: position.alignment) {
                if isVisible {
                    HelixModeIndicator(state: state, position: position)
                        .padding(padding)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(accessibilityLabel)
                        .accessibilityHint("Current editing mode")
                }
            }
            .onChange(of: state.mode) { _, newMode in
                // Announce mode change to VoiceOver
                announceMode(newMode)
            }
            .accessibilityAction(named: "Show keybindings help") {
                // This would trigger showing the help view
            }
    }

    private var accessibilityLabel: String {
        var label = "\(state.mode.displayName) mode"
        if state.isSearching {
            label += ", searching"
            if !state.searchQuery.isEmpty {
                label += " for \(state.searchQuery)"
            }
        }
        if state.keyHandler.pendingKey != nil {
            label += ", waiting for next key"
        }
        return label
    }

    private func announceMode(_ mode: HelixMode) {
        #if os(macOS)
        // Post accessibility notification for mode change
        let announcement = "\(mode.displayName) mode"
        NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested, userInfo: [
            .announcement: announcement,
            .priority: NSAccessibilityPriorityLevel.high
        ])
        #endif
    }
}

public extension View {
    /// Overlay a Helix mode indicator on this view.
    func helixModeIndicator(
        state: HelixState,
        position: HelixModeIndicatorPosition = .bottomLeft,
        isVisible: Bool = true,
        padding: CGFloat = 12
    ) -> some View {
        modifier(HelixModeIndicatorOverlay(
            state: state,
            position: position,
            isVisible: isVisible,
            padding: padding
        ))
    }
}

#Preview("Mode Indicator") {
    VStack(spacing: 20) {
        ForEach(HelixMode.allCases, id: \.self) { mode in
            let state = HelixState()
            HelixModeIndicator(state: state, position: .bottomLeft)
                .onAppear {
                    state.setMode(mode)
                }
        }
    }
    .padding()
}
