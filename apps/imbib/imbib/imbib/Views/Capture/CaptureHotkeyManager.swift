//
//  CaptureHotkeyManager.swift
//  imbib
//
//  Registers global hotkey (Cmd+Shift+Space) for quick artifact capture.
//

#if os(macOS)
import AppKit
import Carbon

/// Manages the global hotkey for quick artifact capture.
@MainActor
final class CaptureHotkeyManager {

    static let shared = CaptureHotkeyManager()

    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Start listening for Cmd+Shift+Space.
    func register() {
        // Local monitor (when app is active)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.isCaptureTrigger(event) == true {
                CapturePanelController.shared.toggle()
                return nil // consume the event
            }
            return event
        }

        // Global monitor (when app is not active — requires accessibility permissions)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.isCaptureTrigger(event) == true {
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    CapturePanelController.shared.show()
                }
            }
        }
    }

    /// Stop listening.
    func unregister() {
        if let local = localMonitor {
            NSEvent.removeMonitor(local)
            localMonitor = nil
        }
        if let global = globalMonitor {
            NSEvent.removeMonitor(global)
            globalMonitor = nil
        }
    }

    private func isCaptureTrigger(_ event: NSEvent) -> Bool {
        // Cmd+Shift+Space
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 49 // Space bar
            && flags.contains(.command)
            && flags.contains(.shift)
            && !flags.contains(.option)
            && !flags.contains(.control)
    }
}
#endif
