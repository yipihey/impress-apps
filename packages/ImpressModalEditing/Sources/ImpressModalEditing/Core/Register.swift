import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A register that holds yanked/copied text.
public struct Register: Sendable, Equatable {
    /// The text content.
    public var content: String
    /// Whether this content was yanked line-wise (affects paste behavior).
    public var linewise: Bool

    public init(content: String = "", linewise: Bool = false) {
        self.content = content
        self.linewise = linewise
    }
}

/// Manages registers for yank/paste operations.
///
/// Supports:
/// - Unnamed (default) register
/// - Named registers (a-z)
/// - Clipboard registers (+ and *)
@MainActor
public final class RegisterManager: ObservableObject {
    /// The default (unnamed) register.
    @Published public private(set) var defaultRegister = Register()

    /// Named registers (a-z).
    @Published public private(set) var namedRegisters: [Character: Register] = [:]

    /// Currently selected register for next yank/paste operation.
    @Published public var selectedRegister: Character?

    public init() {}

    /// Yank text to the currently selected register (or default).
    public func yank(_ text: String, linewise: Bool = false) {
        let register = Register(content: text, linewise: linewise)

        if let selected = selectedRegister {
            if selected == "+" || selected == "*" {
                setClipboardContent(text)
            } else if selected.isLetter {
                namedRegisters[selected.lowercased().first!] = register
            }
            selectedRegister = nil
        } else {
            defaultRegister = register
        }
    }

    /// Get text from the currently selected register (or default).
    public func paste() -> Register {
        defer { selectedRegister = nil }

        if let selected = selectedRegister {
            if selected == "+" || selected == "*" {
                return Register(content: getClipboardContent())
            } else if selected.isLetter {
                return namedRegisters[selected.lowercased().first!] ?? Register()
            }
        }
        return defaultRegister
    }

    /// Select a register for the next yank/paste operation.
    public func selectRegister(_ register: Character) {
        selectedRegister = register
    }

    /// Clear all registers.
    public func clear() {
        defaultRegister = Register()
        namedRegisters.removeAll()
        selectedRegister = nil
    }

    // MARK: - Clipboard

    private func getClipboardContent() -> String {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string) ?? ""
        #else
        return UIPasteboard.general.string ?? ""
        #endif
    }

    private func setClipboardContent(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// Kill ring for Emacs-style editing.
///
/// The kill ring stores multiple killed (deleted) text entries
/// and allows cycling through them with yank-pop.
@MainActor
public final class KillRing: ObservableObject {
    /// Maximum number of entries in the kill ring.
    public let maxSize: Int

    /// The ring of killed text.
    @Published public private(set) var ring: [String] = []

    /// Current position in the ring (for yank-pop).
    @Published public private(set) var currentIndex: Int = 0

    /// Whether the last command was a yank (affects yank-pop behavior).
    @Published public var lastWasYank: Bool = false

    public init(maxSize: Int = 60) {
        self.maxSize = maxSize
    }

    /// Add text to the kill ring.
    public func kill(_ text: String) {
        guard !text.isEmpty else { return }

        ring.insert(text, at: 0)
        if ring.count > maxSize {
            ring.removeLast()
        }
        currentIndex = 0
        lastWasYank = false
    }

    /// Get the current entry for yanking.
    public func yank() -> String? {
        guard !ring.isEmpty else { return nil }
        lastWasYank = true
        return ring[currentIndex]
    }

    /// Cycle to the next entry (yank-pop).
    /// Returns the next entry, or nil if not available.
    public func yankPop() -> String? {
        guard lastWasYank, !ring.isEmpty else { return nil }
        currentIndex = (currentIndex + 1) % ring.count
        return ring[currentIndex]
    }

    /// Reset yank state (called when doing non-yank operations).
    public func resetYankState() {
        lastWasYank = false
        currentIndex = 0
    }

    /// Copy text to kill ring without removing (like copy vs cut).
    public func copy(_ text: String) {
        kill(text)
    }

    /// Clear the kill ring.
    public func clear() {
        ring.removeAll()
        currentIndex = 0
        lastWasYank = false
    }
}
