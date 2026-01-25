//
//  ClipboardProvider.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Clipboard Provider Protocol

/// Protocol for clipboard operations, abstracted for cross-platform use.
///
/// macOS uses NSPasteboard, iOS uses UIPasteboard.
public protocol ClipboardProvider: Sendable {
    /// Get string content from the clipboard.
    @MainActor func getString() -> String?

    /// Set string content on the clipboard.
    @MainActor func setString(_ string: String)

    /// Clear the clipboard contents.
    @MainActor func clear()
}

// MARK: - Default Implementation

/// Shared clipboard instance for the current platform.
public enum Clipboard {
    /// The shared clipboard provider for the current platform.
    public static let shared: ClipboardProvider = PlatformClipboard()
}

// MARK: - Platform-Specific Implementation

#if os(macOS)

/// macOS implementation using NSPasteboard.
public final class PlatformClipboard: ClipboardProvider, @unchecked Sendable {
    public init() {}

    @MainActor
    public func getString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    @MainActor
    public func setString(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    @MainActor
    public func clear() {
        NSPasteboard.general.clearContents()
    }
}

#else

/// iOS implementation using UIPasteboard.
public final class PlatformClipboard: ClipboardProvider, @unchecked Sendable {
    public init() {}

    @MainActor
    public func getString() -> String? {
        UIPasteboard.general.string
    }

    @MainActor
    public func setString(_ string: String) {
        UIPasteboard.general.string = string
    }

    @MainActor
    public func clear() {
        UIPasteboard.general.items = []
    }
}

#endif
