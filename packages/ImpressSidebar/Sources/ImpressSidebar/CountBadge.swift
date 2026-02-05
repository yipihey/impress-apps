//
//  CountBadge.swift
//  ImpressSidebar
//
//  A pill-shaped badge displaying a count, used in sidebar rows.
//

import SwiftUI

/// A compact pill-shaped badge displaying a count.
///
/// Used in sidebar rows to show the number of items (publications, collections, etc.)
/// with consistent styling across the impress app suite.
public struct CountBadge: View {
    /// The count to display
    public let count: Int

    /// The badge color (default: secondary)
    public var color: Color

    public init(count: Int, color: Color = .secondary) {
        self.count = count
        self.color = color
    }

    public var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Preview

#Preview("Count Badges") {
    HStack(spacing: 12) {
        CountBadge(count: 5)
        CountBadge(count: 42)
        CountBadge(count: 1234)
        CountBadge(count: 7, color: .blue)
        CountBadge(count: 3, color: .red)
    }
    .padding()
}
