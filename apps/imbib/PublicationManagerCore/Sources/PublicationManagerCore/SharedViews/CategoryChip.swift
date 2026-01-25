//
//  CategoryChip.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI

/// A small chip displaying an arXiv category.
///
/// Used in paper rows to show arXiv categories at a glance.
/// Tapping a chip can optionally trigger an action (e.g., search by category).
public struct CategoryChip: View {

    // MARK: - Properties

    /// The category ID to display (e.g., "cs.LG", "astro-ph.GA")
    public let category: String

    /// Whether this is the primary category (styled slightly differently)
    public var isPrimary: Bool = false

    /// Optional action when the chip is tapped
    public var onTap: (() -> Void)?

    // MARK: - Initialization

    public init(
        category: String,
        isPrimary: Bool = false,
        onTap: (() -> Void)? = nil
    ) {
        self.category = category
        self.isPrimary = isPrimary
        self.onTap = onTap
    }

    // MARK: - Body

    public var body: some View {
        if let onTap = onTap {
            Button(action: onTap) {
                chipContent
            }
            .buttonStyle(.plain)
        } else {
            chipContent
        }
    }

    private var chipContent: some View {
        Text(category)
            .font(.caption2)
            .fontWeight(isPrimary ? .semibold : .medium)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Colors

    private var foregroundColor: Color {
        colorForCategory(category)
    }

    private var backgroundColor: Color {
        colorForCategory(category)
    }

    /// Determine color based on category group.
    private func colorForCategory(_ category: String) -> Color {
        let groupID = category.lowercased().split(separator: ".").first.map(String.init) ?? category

        switch groupID {
        case "cs":
            return .blue
        case "stat":
            return .purple
        case "math":
            return .green
        case "astro-ph":
            return .orange
        case "physics", "cond-mat", "hep-th", "hep-ph", "hep-lat", "hep-ex",
             "gr-qc", "quant-ph", "nucl-th", "nucl-ex", "math-ph", "nlin":
            return .cyan
        case "q-bio":
            return .pink
        case "q-fin":
            return .indigo
        case "eess":
            return .yellow
        case "econ":
            return .mint
        default:
            return .secondary
        }
    }
}

// MARK: - Category Chips Row

/// A horizontal row of category chips for displaying multiple categories.
public struct CategoryChipsRow: View {

    // MARK: - Properties

    /// All categories to display
    public let categories: [String]

    /// The primary category (if known)
    public let primaryCategory: String?

    /// Optional action when a chip is tapped
    public var onCategoryTap: ((String) -> Void)?

    /// Maximum number of chips to display (others shown as "+N")
    public var maxVisible: Int = 3

    // MARK: - Initialization

    public init(
        categories: [String],
        primaryCategory: String? = nil,
        maxVisible: Int = 3,
        onCategoryTap: ((String) -> Void)? = nil
    ) {
        self.categories = categories
        self.primaryCategory = primaryCategory
        self.maxVisible = maxVisible
        self.onCategoryTap = onCategoryTap
    }

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(visibleCategories, id: \.self) { category in
                CategoryChip(
                    category: category,
                    isPrimary: category == primaryCategory,
                    onTap: onCategoryTap.map { tap in { tap(category) } }
                )
            }

            if hiddenCount > 0 {
                Text("+\(hiddenCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Computed

    private var visibleCategories: [String] {
        Array(categories.prefix(maxVisible))
    }

    private var hiddenCount: Int {
        max(0, categories.count - maxVisible)
    }
}

// MARK: - Preview

#Preview("Category Chips") {
    VStack(alignment: .leading, spacing: 16) {
        // Individual chips
        HStack {
            CategoryChip(category: "cs.LG", isPrimary: true)
            CategoryChip(category: "stat.ML")
            CategoryChip(category: "astro-ph.GA")
        }

        // Chips row with multiple categories
        CategoryChipsRow(
            categories: ["cs.LG", "stat.ML", "cs.AI", "cs.CL"],
            primaryCategory: "cs.LG"
        )

        // Physics categories
        HStack {
            CategoryChip(category: "hep-th")
            CategoryChip(category: "gr-qc")
            CategoryChip(category: "quant-ph")
        }
    }
    .padding()
}
