//
//  HelixTextView.swift
//  ImpelHelixCore
//
//  NSTextView subclass with built-in Helix adaptor support.
//

#if canImport(AppKit)
import AppKit

/// NSTextView subclass that integrates Helix modal editing.
///
/// This view automatically intercepts key events and routes them through
/// the Helix adaptor when enabled.
open class HelixTextView: NSTextView {
    /// The Helix adaptor for modal editing
    public var helixAdaptor: NSTextViewHelixAdaptor?

    /// Override key handling to route through Helix
    open override func keyDown(with event: NSEvent) {
        // Try Helix first
        if let adaptor = helixAdaptor, adaptor.isEnabled {
            if adaptor.handleKeyDown(event) {
                return
            }
        }
        // Fall back to normal handling
        super.keyDown(with: event)
    }

    /// Update collaboration cursor position (for multi-user editing)
    open func updateCollaborationCursor() {
        // Override in subclass for collaboration support
    }
}
#endif
