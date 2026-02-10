//
//  CapturePanel.swift
//  imbib
//
//  NSPanel subclass for the floating capture window.
//

#if os(macOS)
import AppKit
import SwiftUI

/// A floating panel for quick artifact capture. Appears above all windows,
/// accepts keyboard focus, and dismisses on Escape.
final class CapturePanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        backgroundColor = .windowBackgroundColor

        // Center on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - frame.width / 2
            let y = screenFrame.midY - frame.height / 2 + 100
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    /// Allow the panel to become key window (for text field focus).
    override var canBecomeKey: Bool { true }

    /// Close on Escape key.
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Manages showing/hiding the capture panel with SwiftUI content.
@MainActor
final class CapturePanelController: ObservableObject {

    static let shared = CapturePanelController()

    private var panel: CapturePanel?

    /// Show the capture panel, creating it if needed.
    func show() {
        if let existing = panel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let panel = CapturePanel()
        let captureView = CaptureView(dismiss: { [weak panel] in
            panel?.close()
        })
        panel.contentView = NSHostingView(rootView: captureView)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// Dismiss the capture panel.
    func dismiss() {
        panel?.close()
    }

    /// Toggle visibility.
    func toggle() {
        if let panel, panel.isVisible {
            dismiss()
        } else {
            show()
        }
    }
}
#endif
