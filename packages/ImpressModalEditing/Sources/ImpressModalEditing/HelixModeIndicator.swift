import SwiftUI

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

    public init(state: HelixState, position: HelixModeIndicatorPosition = .bottomLeft) {
        self.state = state
        self.position = position
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(modeColor)
                .frame(width: 8, height: 8)

            Text(state.mode.displayName)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        }
        .animation(.easeInOut(duration: 0.15), value: state.mode)
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
}

/// View modifier that overlays the mode indicator on content.
public struct HelixModeIndicatorOverlay: ViewModifier {
    @ObservedObject var state: HelixState
    let position: HelixModeIndicatorPosition
    let isVisible: Bool
    let padding: CGFloat

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
        content.overlay(alignment: position.alignment) {
            if isVisible {
                HelixModeIndicator(state: state, position: position)
                    .padding(padding)
            }
        }
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
