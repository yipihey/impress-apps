#if os(macOS)
import AppKit
import SwiftUI

/// Floating NSPanel for the undo history timeline.
final class UndoHistoryPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        titlebarAppearsTransparent = true
        title = "Undo History"
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        backgroundColor = .windowBackgroundColor
        minSize = NSSize(width: 260, height: 200)

        // Position near top-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - frame.width - 24
            let y = screenFrame.maxY - frame.height - 24
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Singleton controller that manages the undo history panel lifecycle.
@MainActor
public final class UndoHistoryPanelController {
    public static let shared = UndoHistoryPanelController()

    private var panel: UndoHistoryPanel?

    /// The undo/redo callbacks wired by the app.
    public var onUndo: () -> Void = {}
    public var onRedo: () -> Void = {}

    public func show() {
        if let existing = panel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let panel = UndoHistoryPanel()
        let historyView = UndoHistoryView(
            store: .shared,
            onUndo: { [weak self] in self?.onUndo() },
            onRedo: { [weak self] in self?.onRedo() }
        )
        panel.contentView = NSHostingView(rootView: historyView)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    public func dismiss() {
        panel?.close()
    }

    public func toggle() {
        if let panel, panel.isVisible {
            dismiss()
        } else {
            show()
        }
    }

    public var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private init() {}
}
#endif
