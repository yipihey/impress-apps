import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// A register that stores yanked/copied text.
public struct HelixRegister: Sendable {
    /// The stored text content.
    public var content: String

    /// Whether the content represents whole lines.
    public var isLinewise: Bool

    public init(content: String = "", isLinewise: Bool = false) {
        self.content = content
        self.isLinewise = isLinewise
    }
}

/// Manages yank/paste registers for Helix-style editing.
@MainActor
public final class HelixRegisterManager: ObservableObject {
    /// The default register (unnamed).
    @Published public var defaultRegister: HelixRegister = HelixRegister()

    /// Named registers (a-z).
    @Published public var namedRegisters: [Character: HelixRegister] = [:]

    /// Get content from system clipboard.
    public func getClipboardContent() -> HelixRegister {
        #if canImport(AppKit)
        let content = NSPasteboard.general.string(forType: .string) ?? ""
        return HelixRegister(content: content, isLinewise: false)
        #elseif canImport(UIKit)
        let content = UIPasteboard.general.string ?? ""
        return HelixRegister(content: content, isLinewise: false)
        #else
        return HelixRegister()
        #endif
    }

    /// Set content to system clipboard.
    public func setClipboardContent(_ register: HelixRegister) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(register.content, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = register.content
        #endif
    }

    /// Currently selected register for next yank/paste operation.
    /// Set by "{char} prefix, cleared after use.
    @Published public var selectedRegister: Character?

    public init() {}

    /// Yank text into the appropriate register.
    /// - Parameters:
    ///   - text: The text to yank
    ///   - linewise: Whether the content represents whole lines
    ///   - register: Optional specific register to use (overrides selectedRegister)
    public func yank(_ text: String, linewise: Bool = false, register: Character? = nil) {
        let newRegister = HelixRegister(content: text, isLinewise: linewise)
        let targetRegister = register ?? self.selectedRegister

        // Use specified register, or selected register, or default
        if let target = targetRegister {
            if target == "+" || target == "*" {
                // System clipboard
                setClipboardContent(newRegister)
            } else if target.isLetter && target.isLowercase {
                // Named register a-z
                namedRegisters[target] = newRegister
            } else if target.isLetter && target.isUppercase {
                // Uppercase appends to lowercase register
                let lowerTarget = Character(target.lowercased())
                if var existing = namedRegisters[lowerTarget] {
                    existing.content += newRegister.content
                    existing.isLinewise = existing.isLinewise || newRegister.isLinewise
                    namedRegisters[lowerTarget] = existing
                } else {
                    namedRegisters[lowerTarget] = newRegister
                }
            } else {
                // Unknown register, use default
                defaultRegister = newRegister
            }
            selectedRegister = nil
        } else {
            defaultRegister = newRegister
        }
    }

    /// Get content from the appropriate register.
    /// - Parameter register: Optional specific register to use (overrides selectedRegister)
    /// - Returns: The register content
    public func paste(register: Character? = nil) -> HelixRegister {
        let target = register ?? selectedRegister

        defer { selectedRegister = nil }

        if let target = target {
            if target == "+" || target == "*" {
                return getClipboardContent()
            } else if target.isLetter {
                let lowerTarget = Character(target.lowercased())
                return namedRegisters[lowerTarget] ?? HelixRegister()
            } else if target == "\"" {
                return defaultRegister
            }
        }
        return defaultRegister
    }

    /// Select a register for the next yank/paste operation.
    /// - Parameter register: The register character (a-z, +, *, ")
    public func selectRegister(_ register: Character) {
        selectedRegister = register
    }

    /// Clear the default register.
    public func clear() {
        defaultRegister = HelixRegister()
    }

    /// Clear all registers.
    public func clearAll() {
        defaultRegister = HelixRegister()
        namedRegisters.removeAll()
    }

    /// Get all non-empty registers for display.
    public var allRegisters: [(Character, HelixRegister)] {
        var result: [(Character, HelixRegister)] = []

        // Default register
        if !defaultRegister.content.isEmpty {
            result.append(("\"", defaultRegister))
        }

        // Named registers
        for (key, value) in namedRegisters.sorted(by: { $0.key < $1.key }) {
            if !value.content.isEmpty {
                result.append((key, value))
            }
        }

        // Clipboard
        let clipboard = getClipboardContent()
        if !clipboard.content.isEmpty {
            result.append(("+", clipboard))
        }

        return result
    }
}
