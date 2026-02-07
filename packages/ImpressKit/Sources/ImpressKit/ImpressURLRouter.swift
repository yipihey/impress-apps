import Foundation

/// Protocol for per-app URL routing.
///
/// Each app implements this protocol to handle incoming deep-link URLs.
/// The router is typically registered in the app's SwiftUI `App` struct
/// via `.onOpenURL { url in router.handle(url) }`.
public protocol ImpressURLRouting: Sendable {
    /// The app this router handles URLs for.
    var app: SiblingApp { get }

    /// Handle a parsed Impress URL.
    /// - Parameter url: The parsed URL to handle.
    /// - Returns: True if the URL was handled, false otherwise.
    @discardableResult
    func handle(_ url: ImpressURL) async -> Bool
}

/// Convenience extension for handling raw URLs.
extension ImpressURLRouting {
    /// Parse and route a raw URL.
    @discardableResult
    public func handle(raw url: URL) async -> Bool {
        guard let parsed = ImpressURL.parse(url) else { return false }
        return await handle(parsed)
    }
}
