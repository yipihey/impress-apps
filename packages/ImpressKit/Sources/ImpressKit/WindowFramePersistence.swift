//
//  WindowFramePersistence.swift
//  ImpressKit
//
//  Remembering where the user put a window, suite-wide.
//
//  Nothing in the suite persisted a window frame before this: every app opened
//  at SwiftUI's default size and position on every launch, on every screen. The
//  fix belongs here rather than in six `App` files because "the window comes
//  back where I left it" is not an app-specific behaviour — it is the same
//  promise the list-pane divider makes in `ImpressSplitView`, one level up.
//
//  AppKit already implements the whole feature (`NSWindow.setFrameAutosaveName`
//  writes to UserDefaults under `NSWindow Frame <name>` and restores on the next
//  launch, including screen and multi-monitor placement). What was missing was
//  a SwiftUI-side seam to name the window. That is all this file is.
//

import SwiftUI

#if os(macOS)
import AppKit

/// Attaches AppKit's frame autosave to the hosting `NSWindow`.
///
/// Deliberately a `background` probe rather than a `WindowGroup` modifier: the
/// window does not exist when the scene body runs, so the name has to be
/// applied once the view is in a window. `frameAutosaveName` is idempotent —
/// re-applying the same name is a no-op — but assigning it is NOT free (AppKit
/// writes the current frame), so the guard matters on re-render.
private struct WindowFrameAutosave: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // The view has no window until it is in the hierarchy; one hop is
        // enough and avoids polling.
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            guard window.frameAutosaveName != autosaveName else { return }
            window.setFrameAutosaveName(autosaveName)
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        guard window.frameAutosaveName != autosaveName else { return }
        window.setFrameAutosaveName(autosaveName)
    }
}
#endif

public extension View {

    /// Remember this window's size and position across launches.
    ///
    /// `name` must be STABLE and unique per window kind — it is the UserDefaults
    /// key AppKit stores the frame under. Use the window's role, not its
    /// content: `"imprint.project-browser"` rather than a per-manuscript id, or
    /// every document the user opens leaves a frame behind forever.
    ///
    /// A no-op on iOS, where the system owns window geometry.
    func persistentWindowFrame(_ name: String) -> some View {
        #if os(macOS)
        background(WindowFrameAutosave(autosaveName: name))
        #else
        self
        #endif
    }
}
