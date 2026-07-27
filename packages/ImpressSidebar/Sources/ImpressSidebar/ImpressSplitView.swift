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
    private let listIdealFraction: CGFloat?
    private let detailMinWidth: CGFloat

    /// User-dragged list width as a fraction of the container, persisted per
    /// `fractionStorageKey`. Only used on the `listIdealFraction` path.
    @State private var draggedFraction: CGFloat?

    private let fractionStorageKey: String

    /// `listIdealFraction`: when set, the list pane gets an EXPLICIT width of
    /// that fraction of the container (e.g. `1/3`) with a draggable divider,
    /// instead of `HSplitView`'s `idealWidth` — which AppKit treats as a hint
    /// and in practice ignored, leaving the list at ~half the window.
    /// Existing callers (no fraction) keep the plain HSplitView behavior.
    public init(
        listMinWidth: CGFloat = 200,
        listIdealWidth: CGFloat = 300,
        listIdealFraction: CGFloat? = nil,
        fractionStorageKey: String = "impress.split.listFraction",
        detailMinWidth: CGFloat = 300,
        @ViewBuilder list: () -> ListContent,
        @ViewBuilder detail: () -> DetailContent
    ) {
        self.listContent = list()
        self.detailContent = detail()
        self.listMinWidth = listMinWidth
        self.listIdealWidth = listIdealWidth
        self.listIdealFraction = listIdealFraction
        self.fractionStorageKey = fractionStorageKey
        self.detailMinWidth = detailMinWidth
    }

    public var body: some View {
        #if os(macOS)
        if let fraction = listIdealFraction {
            GeometryReader { geo in
                fractionSplit(container: geo.size.width, defaultFraction: fraction)
            }
        } else {
            splitBody(listIdeal: listIdealWidth)
        }
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

    #if os(macOS)
    /// Explicit-width two-pane split: the list gets a real width (so "one
    /// third" means one third), the detail takes the rest, and a hit-widened
    /// divider drags the boundary. The chosen fraction persists across
    /// launches under `fractionStorageKey`.
    private func fractionSplit(container: CGFloat, defaultFraction: CGFloat) -> some View {
        let stored = UserDefaults.standard.object(forKey: fractionStorageKey) as? Double
        let fraction = draggedFraction ?? stored.map { CGFloat($0) } ?? defaultFraction
        // Keep both panes usable at any window size; when the window is too
        // narrow for both minimums, the list yields.
        let upperBound = max(listMinWidth, container - detailMinWidth)
        let listWidth = min(max(container * fraction, listMinWidth), upperBound)

        return HStack(spacing: 0) {
            ZStack { listContent }
                .frame(width: listWidth)
                .frame(maxHeight: .infinity)
                .clipped()

            divider(container: container, listWidth: listWidth)

            ZStack { detailContent }
                .transaction { $0.animation = nil }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea(.container, edges: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func divider(container: CGFloat, listWidth: CGFloat) -> some View {
        Divider()
            .frame(width: 1)
            .overlay(
                // Invisible hit area — a 1pt divider is too thin to grab.
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .local)
                            .onChanged { value in
                                guard container > 0 else { return }
                                let newWidth = listWidth + value.translation.width
                                draggedFraction = min(max(newWidth / container, 0.1), 0.9)
                            }
                            .onEnded { _ in
                                if let f = draggedFraction {
                                    UserDefaults.standard.set(Double(f), forKey: fractionStorageKey)
                                }
                            }
                    )
            )
    }

    private func splitBody(listIdeal: CGFloat) -> some View {
        HSplitView {
            // ZStack provides a stable NSView container so NSSplitView never
            // sees its subview replaced when the left pane content switches.
            ZStack {
                listContent
            }
            .frame(minWidth: listMinWidth, idealWidth: listIdeal)
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
    }
    #endif
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
