//
//  ImpressSplitView.swift
//  ImpressSidebar
//
//  Canonical two-pane split layout for impress apps.
//
//  Encodes the HSplitView + ZStack + ignoresSafeArea pattern documented in CLAUDE.md.
//  Using this wrapper ensures consistent behavior across all impress apps and avoids
//  the common macOS toolbar layout pitfalls.
//

import SwiftUI

/// A two-pane split view that follows the impress layout conventions.
///
/// This wrapper handles:
/// - ZStack wrapping for both panes (stable NSView container for NSSplitView)
/// - `.ignoresSafeArea(.container, edges: .top)` on the detail pane (reclaims toolbar space)
/// - Configurable min/ideal widths
/// - `.clipped()` on both panes to prevent content overflow
///
/// Usage:
/// ```swift
/// ImpressSplitView {
///     PublicationListView(...)
/// } detail: {
///     DetailView(...)
/// }
/// ```
public struct ImpressSplitView<ListContent: View, DetailContent: View>: View {
    private let listContent: ListContent
    private let detailContent: DetailContent
    private let listMinWidth: CGFloat
    private let listIdealWidth: CGFloat
    private let detailMinWidth: CGFloat

    public init(
        listMinWidth: CGFloat = 200,
        listIdealWidth: CGFloat = 300,
        detailMinWidth: CGFloat = 300,
        @ViewBuilder list: () -> ListContent,
        @ViewBuilder detail: () -> DetailContent
    ) {
        self.listContent = list()
        self.detailContent = detail()
        self.listMinWidth = listMinWidth
        self.listIdealWidth = listIdealWidth
        self.detailMinWidth = detailMinWidth
    }

    public var body: some View {
        #if os(macOS)
        HSplitView {
            // ZStack provides a stable NSView container so NSSplitView never
            // sees its subview replaced when the left pane content switches.
            ZStack {
                listContent
            }
            .frame(minWidth: listMinWidth, idealWidth: listIdealWidth)
            .frame(maxHeight: .infinity)
            .clipped()

            ZStack {
                detailContent
            }
            .transaction { $0.animation = nil }
            .frame(minWidth: detailMinWidth)
            .frame(maxHeight: .infinity)
            .clipped()
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        // On iOS, use a simple horizontal layout or NavigationSplitView
        HStack(spacing: 0) {
            listContent
                .frame(minWidth: listMinWidth)
            detailContent
                .frame(minWidth: detailMinWidth)
        }
        #endif
    }
}

/// View modifier that adds scroll clearance for content below the toolbar in the detail pane.
///
/// Apply this to the first content element in a detail tab so content starts below the
/// toolbar icons but can be scrolled up into that space.
///
/// Usage:
/// ```swift
/// ScrollView {
///     VStack {
///         // content
///     }
///     .detailScrollClearance()
/// }
/// ```
public extension View {
    /// Adds top padding to clear the toolbar area in a detail pane.
    func detailScrollClearance(_ amount: CGFloat = 40) -> some View {
        self.padding(.top, amount)
    }
}
