//
//  ModeIndicator.swift
//  ImpressFTUI
//

import SwiftUI

/// A small badge showing the current input mode (e.g., "FLAG", "TAG").
public struct ModeIndicator: View {

    public let label: String
    public var color: Color = .accentColor

    public init(_ label: String, color: Color = .accentColor) {
        self.label = label
        self.color = color
    }

    public var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 3))
    }
}
