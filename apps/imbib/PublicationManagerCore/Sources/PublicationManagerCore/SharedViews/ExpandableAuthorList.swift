//
//  ExpandableAuthorList.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-18.
//

import SwiftUI

/// A view that displays authors with smart truncation for long author lists.
///
/// Display logic:
/// - 10 or fewer authors: Shows all authors separated by semicolons
/// - More than 10 authors: Shows first 9, clickable "...", and last author
/// - Clicking "..." expands to show all authors
///
/// Example collapsed (15 authors):
/// "Author1; Author2; Author3; Author4; Author5; Author6; Author7; Author8; Author9; ... ; Author15"
///
/// Example expanded:
/// "Author1; Author2; Author3; Author4; Author5; Author6; Author7; Author8; Author9; Author10; Author11; Author12; Author13; Author14; Author15"
public struct ExpandableAuthorList: View {

    // MARK: - Properties

    /// List of author names to display
    public let authors: [String]

    /// Separator between authors (default: "; ")
    public var separator: String = "; "

    /// Number of authors to show at the start when collapsed (default: 9)
    public var visibleStartCount: Int = 9

    /// Whether to always show the last author when collapsed (default: true)
    public var showLastAuthor: Bool = true

    /// Threshold for triggering collapse (default: 10)
    /// Lists with this many or fewer authors will show all
    public var collapseThreshold: Int = 10

    /// State for expansion
    @State private var isExpanded: Bool = false

    // MARK: - Initialization

    public init(
        authors: [String],
        separator: String = "; ",
        visibleStartCount: Int = 9,
        showLastAuthor: Bool = true,
        collapseThreshold: Int = 10
    ) {
        self.authors = authors
        self.separator = separator
        self.visibleStartCount = visibleStartCount
        self.showLastAuthor = showLastAuthor
        self.collapseThreshold = collapseThreshold
    }

    /// Convenience initializer from a semicolon-separated author string
    public init(authorString: String) {
        // Parse author string - could be semicolon or "and" separated
        let cleaned = authorString
            .replacingOccurrences(of: " and ", with: "; ")
            .replacingOccurrences(of: ", and ", with: "; ")
        self.authors = cleaned.components(separatedBy: "; ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.separator = "; "
        self.visibleStartCount = 9
        self.showLastAuthor = true
        self.collapseThreshold = 10
    }

    // MARK: - Computed Properties

    private var shouldCollapse: Bool {
        authors.count > collapseThreshold && !isExpanded
    }

    private var hiddenCount: Int {
        guard shouldCollapse else { return 0 }
        // Hidden = total - visibleStart - lastAuthor (if shown)
        let visibleCount = visibleStartCount + (showLastAuthor ? 1 : 0)
        return max(0, authors.count - visibleCount)
    }

    // MARK: - Body

    public var body: some View {
        if authors.isEmpty {
            Text("Unknown")
                .textSelection(.enabled)
        } else if !shouldCollapse {
            // Show all authors
            Text(authors.joined(separator: separator))
                .textSelection(.enabled)
        } else {
            // Show collapsed view with expandable "..."
            collapsedView
        }
    }

    // MARK: - Collapsed View

    @ViewBuilder
    private var collapsedView: some View {
        // Build the display as concatenated Text for proper line wrapping
        // Format: "Author1; Author2; ...; Author9; ...; LastAuthor"
        let firstAuthors = Array(authors.prefix(visibleStartCount))
        let lastAuthor = showLastAuthor ? authors.last : nil

        // Use Text concatenation (+) instead of HStack for proper text wrapping
        let combinedText: Text = {
            var result = Text(firstAuthors.joined(separator: separator))

            // Add separator and ellipsis
            result = result + Text(separator)
            result = result + Text("...")
                .foregroundStyle(.blue)
                .underline()

            // Add last author if shown
            if let last = lastAuthor {
                result = result + Text(separator)
                result = result + Text(last)
            }

            return result
        }()

        combinedText
            .textSelection(.enabled)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = true
                }
            }
            .accessibilityIdentifier(AccessibilityID.Detail.Info.authorsExpand)
            #if os(macOS)
            .help("Click to show all \(authors.count) authors (\(hiddenCount) hidden)")
            #endif
    }
}

// MARK: - Preview

#Preview("Expandable Author List") {
    VStack(alignment: .leading, spacing: 20) {
        // Few authors - no collapse
        Group {
            Text("3 authors:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ExpandableAuthorList(authors: ["Einstein, A.", "Bohr, N.", "Heisenberg, W."])
        }

        Divider()

        // Exactly 10 - no collapse
        Group {
            Text("10 authors (threshold):")
                .font(.caption)
                .foregroundStyle(.secondary)
            ExpandableAuthorList(authors: (1...10).map { "Author\($0)" })
        }

        Divider()

        // 15 authors - collapsed
        Group {
            Text("15 authors (collapsed):")
                .font(.caption)
                .foregroundStyle(.secondary)
            ExpandableAuthorList(authors: (1...15).map { "Author\($0)" })
        }

        Divider()

        // 50 authors - collapsed
        Group {
            Text("50 authors (collapsed):")
                .font(.caption)
                .foregroundStyle(.secondary)
            ExpandableAuthorList(authors: (1...50).map { "Author\($0), A." })
        }

        Divider()

        // From string
        Group {
            Text("From author string:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ExpandableAuthorList(authorString: "Einstein, A.; Bohr, N.; Heisenberg, W.")
        }
    }
    .padding()
    .frame(maxWidth: 500)
}
