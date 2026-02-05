//
//  CollapsibleSection.swift
//  ImpressSidebar
//
//  A reusable collapsible section header for sidebars.
//

import SwiftUI

/// A collapsible section with a chevron toggle and optional header extras.
///
/// Provides consistent section styling across the impress app suite with
/// customizable header content and collapsible body.
public struct CollapsibleSection<Content: View, HeaderExtras: View>: View {
    /// The section title
    let title: String

    /// Whether the section is collapsed
    @Binding var isCollapsed: Bool

    /// Additional content in the header (e.g., add button)
    let headerExtras: () -> HeaderExtras

    /// The section content
    let content: () -> Content

    public init(
        title: String,
        isCollapsed: Binding<Bool>,
        @ViewBuilder headerExtras: @escaping () -> HeaderExtras = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self._isCollapsed = isCollapsed
        self.headerExtras = headerExtras
        self.content = content
    }

    public var body: some View {
        Section {
            if !isCollapsed {
                content()
            }
        } header: {
            HStack(spacing: 4) {
                // Collapse/expand button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                // Section title
                Text(title)

                Spacer()

                // Additional header content
                headerExtras()
            }
        }
    }
}

// MARK: - Convenience Initializer (No Header Extras)

extension CollapsibleSection where HeaderExtras == EmptyView {
    public init(
        title: String,
        isCollapsed: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            isCollapsed: isCollapsed,
            headerExtras: { EmptyView() },
            content: content
        )
    }
}

// MARK: - Set-Based Binding Helper

extension Binding where Value == Bool {
    /// Creates a binding that reflects membership in a Set.
    ///
    /// Useful for collapsible sections where state is stored in a Set.
    /// - Parameters:
    ///   - set: Binding to the Set of collapsed item IDs
    ///   - element: The element to check membership for
    ///   - onPersist: Optional closure called after the Set changes
    public static func membershipBinding<Element: Hashable>(
        in set: Binding<Set<Element>>,
        for element: Element,
        onPersist: (() -> Void)? = nil
    ) -> Binding<Bool> {
        Binding<Bool>(
            get: { set.wrappedValue.contains(element) },
            set: { isMember in
                if isMember {
                    set.wrappedValue.insert(element)
                } else {
                    set.wrappedValue.remove(element)
                }
                onPersist?()
            }
        )
    }
}

// MARK: - Preview

#Preview("Collapsible Section") {
    List {
        CollapsibleSection(
            title: "Libraries",
            isCollapsed: .constant(false),
            headerExtras: {
                Button {
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        ) {
            Text("Library 1")
            Text("Library 2")
            Text("Library 3")
        }

        CollapsibleSection(
            title: "Collapsed Section",
            isCollapsed: .constant(true)
        ) {
            Text("You won't see this")
        }
    }
    .frame(width: 250, height: 300)
}
