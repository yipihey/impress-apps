import Foundation

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

    public init() {}

    /// Yank text into the default register.
    public func yank(_ text: String, linewise: Bool = false) {
        defaultRegister = HelixRegister(content: text, isLinewise: linewise)
    }

    /// Get content from the default register.
    public func paste() -> HelixRegister {
        defaultRegister
    }

    /// Clear the default register.
    public func clear() {
        defaultRegister = HelixRegister()
    }
}
