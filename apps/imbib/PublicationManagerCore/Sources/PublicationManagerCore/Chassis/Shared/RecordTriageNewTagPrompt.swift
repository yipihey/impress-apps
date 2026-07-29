//
//  RecordTriageNewTagPrompt.swift
//  PublicationManagerCore
//
//  The ONE AppKit dependency of the shared triage grammar, split out of
//  `RecordTriage.swift` in the iOS foundation pass so the action bag and the
//  swipe/menu builders could go cross-platform without carrying NSAlert.
//
//  macOS body is verbatim from the old `TriageTagMenu.promptForNewTag()` —
//  same strings, same button order, same trimming, same "empty means
//  cancel". Only the `actions.onAddTag` call moved back to the caller.
//

import Foundation

#if os(macOS)
import AppKit
#endif

/// Modal prompt for a new tag path. `isAvailable == false` means the platform
/// has no modal prompt reachable from inside a `Menu`, and the menu omits the
/// affordance instead of offering a button that does nothing.
public enum RecordTriageNewTagPrompt {

    #if os(macOS)
    public static let isAvailable = true

    /// The trimmed tag path, or nil when the user cancelled / typed nothing.
    @MainActor
    public static func run() -> String? {
        let alert = NSAlert()
        alert.messageText = "New Tag"
        alert.informativeText = "Tag path (use / for hierarchy, e.g. projects/reionization)."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return path
    }
    #else
    public static let isAvailable = false

    /// iOS has no synchronous modal text prompt; tag creation belongs to the
    /// host's own sheet, which calls `RecordTriageActions.onAddTag` directly.
    @MainActor
    public static func run() -> String? { nil }
    #endif
}
