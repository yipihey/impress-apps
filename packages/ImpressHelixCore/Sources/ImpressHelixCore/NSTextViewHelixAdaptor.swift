//
//  NSTextViewHelixAdaptor.swift
//  ImpressHelixCore
//
//  macOS NSTextView integration for Helix modal editing.
//

#if canImport(AppKit)
import AppKit

/// Adapts an NSTextView for Helix-style modal editing.
///
/// This adaptor intercepts key events and delegates them to the HelixState,
/// applying the resulting commands to the text view.
@MainActor
public final class NSTextViewHelixAdaptor: NSObject {
    /// The text view being adapted
    public weak var textView: NSTextView?

    /// The Helix state managing editing mode
    public let helixState: HelixState

    /// Whether Helix modal editing is enabled
    public var isEnabled: Bool = true

    /// Create an adaptor for the given text view and state.
    ///
    /// - Parameters:
    ///   - textView: The NSTextView to adapt
    ///   - helixState: The HelixState to use for key handling
    public init(textView: NSTextView, helixState: HelixState) {
        self.textView = textView
        self.helixState = helixState
        super.init()
    }

    /// Handle a key down event.
    ///
    /// - Parameter event: The key event
    /// - Returns: true if the event was handled, false to pass through
    public func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isEnabled, let textView = textView else { return false }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return false
        }

        let modifiers = FfiKeyModifiers(eventFlags: event.modifierFlags)
        let result = helixState.handleKey(characters, modifiers: modifiers)

        switch result {
        case .handled:
            return true

        case .passThrough:
            // In insert mode, let the text view handle the key
            return false

        case .spaceCommand(let command):
            // Execute the space command
            executeSpaceCommand(command, in: textView)
            return true

        case .spaceModePending:
            // Space mode is showing, wait for next key
            return true
        }
    }

    /// Execute a space-mode command
    private func executeSpaceCommand(_ command: FfiSpaceCommand, in textView: NSTextView) {
        // These commands are typically handled by the application.
        // Post notification for app to handle.
        switch command {
        case .fileSave:
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: textView)

        default:
            NotificationCenter.default.post(
                name: .helixSpaceCommand,
                object: textView,
                userInfo: ["command": command]
            )
        }
    }

    /// Execute a motion and return the resulting range
    public func executeMotion(_ motion: FfiMotion, in textView: NSTextView) -> NSRange? {
        let text = textView.string
        let cursorPosition = UInt64(textView.selectedRange().location)

        guard let range = calculateMotionRange(
            text: text,
            cursorPosition: cursorPosition,
            motion: motion
        ) else {
            return nil
        }

        return NSRange(location: Int(range.start), length: Int(range.end - range.start))
    }

    /// Execute a text object and return the resulting range
    public func executeTextObject(
        _ textObject: FfiTextObject,
        modifier: FfiTextObjectModifier,
        in textView: NSTextView
    ) -> NSRange? {
        let text = textView.string
        let cursorPosition = UInt64(textView.selectedRange().location)

        guard let range = calculateTextObjectRange(
            text: text,
            cursorPosition: cursorPosition,
            textObject: textObject,
            modifier: modifier
        ) else {
            return nil
        }

        return NSRange(location: Int(range.start), length: Int(range.end - range.start))
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a space-mode command is triggered.
    /// userInfo contains "command" key with FfiSpaceCommand value.
    public static let helixSpaceCommand = Notification.Name("HelixSpaceCommand")
}
#endif
