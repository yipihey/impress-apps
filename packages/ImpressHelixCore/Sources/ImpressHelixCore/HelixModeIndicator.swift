//
//  HelixModeIndicator.swift
//  ImpressHelixCore
//
//  SwiftUI view displaying the current Helix mode.
//

import SwiftUI

/// Position for the mode indicator
public enum ModeIndicatorPosition {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

/// A SwiftUI view that displays the current Helix editing mode.
public struct HelixModeIndicator: View {
    @ObservedObject var state: HelixState
    let position: ModeIndicatorPosition

    public init(state: HelixState, position: ModeIndicatorPosition = .bottomLeft) {
        self.state = state
        self.position = position
    }

    public var body: some View {
        Text(state.mode.displayName)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
    }

    private var backgroundColor: Color {
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

/// View modifier for adding a mode indicator to any view
public struct HelixModeIndicatorModifier: ViewModifier {
    @ObservedObject var state: HelixState
    let position: ModeIndicatorPosition
    let isVisible: Bool
    let padding: CGFloat

    public func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            if isVisible {
                HelixModeIndicator(state: state, position: position)
                    .padding(padding)
            }
        }
    }

    private var alignment: Alignment {
        switch position {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

extension View {
    /// Add a Helix mode indicator overlay to this view.
    ///
    /// - Parameters:
    ///   - state: The HelixState to observe
    ///   - position: Where to position the indicator
    ///   - isVisible: Whether the indicator is visible
    ///   - padding: Padding from the edge
    /// - Returns: The modified view
    public func helixModeIndicator(
        state: HelixState,
        position: ModeIndicatorPosition = .bottomLeft,
        isVisible: Bool = true,
        padding: CGFloat = 8
    ) -> some View {
        modifier(HelixModeIndicatorModifier(
            state: state,
            position: position,
            isVisible: isVisible,
            padding: padding
        ))
    }
}
