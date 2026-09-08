//
//  ResizableSheetContent.swift
//  ImpressKit
//
//  The impress default for modal sheets on macOS: THE USER CAN ALWAYS
//  RESIZE THEM. A sheet whose content declares only a minimum (or a fixed)
//  frame gets a non-resizable window, so any layout bug — a long model
//  name, a wide table, an unexpected locale — leaves the user with no
//  recourse. A flexible maximum costs nothing and turns every such bug
//  from a wall into an inconvenience. Same rule, same reason, as the
//  resizable Settings windows (feedback 2026: "Settings windows resizable,
//  lists never clipped") — this is that rule for sheets.
//
//  Use it on the OUTERMOST view inside a `.sheet { }` on macOS:
//
//      .sheet(isPresented: $showing) {
//          MySheetContent()
//              .impressResizableSheet(minWidth: 500, minHeight: 500)
//      }
//
//  On iOS it is a no-op: sheets there are sized by detents, not frames.
//

import SwiftUI

public extension View {
    /// Frame a sheet's content so the sheet opens at its ideal size and the
    /// user can freely enlarge (or shrink to the minimum) the window.
    /// `idealWidth`/`idealHeight` default to the minimums, so the sheet
    /// opens at exactly the size the author considered sufficient.
    @ViewBuilder
    func impressResizableSheet(
        minWidth: CGFloat = 480,
        idealWidth: CGFloat? = nil,
        minHeight: CGFloat = 420,
        idealHeight: CGFloat? = nil
    ) -> some View {
        #if os(macOS)
        frame(
            minWidth: minWidth,
            idealWidth: idealWidth ?? minWidth,
            maxWidth: .infinity,
            minHeight: minHeight,
            idealHeight: idealHeight ?? minHeight,
            maxHeight: .infinity
        )
        #else
        self
        #endif
    }
}
