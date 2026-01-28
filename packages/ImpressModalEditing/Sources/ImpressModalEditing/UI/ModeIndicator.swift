import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A generic mode indicator that works with any editor style.
///
/// The indicator shows:
/// - Current mode name with colored dot
/// - Pending key sequences
/// - Search state when active
/// - Pulsing animation for selection modes
public struct ModeIndicator<StateType: EditorState>: View {
    @ObservedObject var editorState: StateType
    let position: ModeIndicatorPosition
    let style: EditorStyleIdentifier
    @SwiftUI.State private var isPulsing = false

    public init(
        state: StateType,
        style: EditorStyleIdentifier,
        position: ModeIndicatorPosition = .bottomLeft
    ) {
        self.editorState = state
        self.style = style
        self.position = position
    }

    public var body: some View {
        VStack(spacing: 4) {
            // Main mode indicator
            mainIndicator
                .animation(.easeInOut(duration: 0.15), value: modeName)

            // Search indicator
            if editorState.isSearching {
                SearchIndicatorView(
                    query: editorState.searchQuery,
                    isBackward: editorState.searchBackward
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: editorState.isSearching)
    }

    @ViewBuilder
    private var mainIndicator: some View {
        // For Emacs, we may not show indicator in normal state
        if shouldShowIndicator {
            HStack(spacing: 6) {
                Circle()
                    .fill(modeColor)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isInSelectionMode && isPulsing ? 1.3 : 1.0)

                Text(modeName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                // Pending key indicator (handled by concrete state types)
                pendingIndicator
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.regularMaterial)
                    .overlay {
                        if isInSelectionMode {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(modeColor.opacity(0.5), lineWidth: 1.5)
                        }
                    }
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            }
            .onAppear {
                if isInSelectionMode {
                    startPulse()
                }
            }
            .onChange(of: isInSelectionMode) { _, newValue in
                if newValue {
                    startPulse()
                } else {
                    isPulsing = false
                }
            }
        }
    }

    @ViewBuilder
    private var pendingIndicator: some View {
        // This would need to be specialized per state type
        // For now, show generic "waiting" indicator
        EmptyView()
    }

    private var shouldShowIndicator: Bool {
        // Emacs doesn't need a mode indicator in normal operation
        if style == .emacs {
            return editorState.isSearching
        }
        return editorState.mode.showsIndicator
    }

    private var modeName: String {
        editorState.mode.displayName
    }

    private var modeColor: Color {
        // Color based on mode semantics
        if editorState.mode.allowsTextInput {
            return .green // Insert-like modes
        } else if isInSelectionMode {
            return .orange // Selection modes
        }
        return .blue // Normal modes
    }

    private var isInSelectionMode: Bool {
        // Check if the mode name suggests selection
        let name = modeName.lowercased()
        return name.contains("select") || name.contains("visual")
    }

    private func startPulse() {
        isPulsing = true
        withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) {
            isPulsing = true
        }
    }
}

/// Search indicator shown during search mode.
struct SearchIndicatorView: View {
    let query: String
    let isBackward: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(isBackward ? "?" : "/")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(query.isEmpty ? "search..." : query)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(query.isEmpty ? .tertiary : .primary)
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

/// View modifier for overlaying mode indicator on content.
public struct ModeIndicatorOverlay<StateType: EditorState>: ViewModifier {
    @ObservedObject var editorState: StateType
    let style: EditorStyleIdentifier
    let position: ModeIndicatorPosition
    let isVisible: Bool
    let padding: CGFloat

    public init(
        state: StateType,
        style: EditorStyleIdentifier,
        position: ModeIndicatorPosition = .bottomLeft,
        isVisible: Bool = true,
        padding: CGFloat = 12
    ) {
        self.editorState = state
        self.style = style
        self.position = position
        self.isVisible = isVisible
        self.padding = padding
    }

    public func body(content: Content) -> some View {
        content
            .overlay(alignment: position.alignment) {
                if isVisible {
                    ModeIndicator(state: editorState, style: style, position: position)
                        .padding(padding)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(accessibilityLabel)
                        .accessibilityHint("Current editing mode")
                }
            }
    }

    private var accessibilityLabel: String {
        var label = "\(editorState.mode.displayName) mode"
        if editorState.isSearching {
            label += ", searching"
            if !editorState.searchQuery.isEmpty {
                label += " for \(editorState.searchQuery)"
            }
        }
        return label
    }
}

public extension View {
    /// Overlay a mode indicator on this view.
    func modeIndicator<StateType: EditorState>(
        state: StateType,
        style: EditorStyleIdentifier,
        position: ModeIndicatorPosition = .bottomLeft,
        isVisible: Bool = true,
        padding: CGFloat = 12
    ) -> some View {
        modifier(ModeIndicatorOverlay(
            state: state,
            style: style,
            position: position,
            isVisible: isVisible,
            padding: padding
        ))
    }
}

/// Selection color utilities for different editor modes.
public struct SelectionColors {
    /// Standard selection color.
    public static var normal: Color {
        #if os(macOS)
        Color(nsColor: .selectedTextBackgroundColor)
        #else
        Color(uiColor: .systemBlue.withAlphaComponent(0.3))
        #endif
    }

    /// Selection color for visual/select modes.
    public static var selection: Color {
        Color.orange.opacity(0.35)
    }

    /// Get selection color based on whether in selection mode.
    public static func color(forSelectionMode isSelectionMode: Bool) -> Color {
        isSelectionMode ? selection : normal
    }
}
