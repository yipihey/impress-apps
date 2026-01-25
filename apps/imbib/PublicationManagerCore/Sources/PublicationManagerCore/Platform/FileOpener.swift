//
//  FileOpener.swift
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

// MARK: - File Opener Protocol

/// Protocol for opening files and URLs, abstracted for cross-platform use.
///
/// macOS uses NSWorkspace, iOS uses UIApplication.
public protocol FileOpener: Sendable {
    /// Open a file at the specified URL in the default application.
    @MainActor func openFile(_ url: URL) -> Bool

    /// Open a URL (can be file:// or https://).
    @MainActor func openURL(_ url: URL) -> Bool

    /// Reveal a file in the file browser (Finder on macOS, Files on iOS).
    @MainActor func revealInFileBrowser(_ url: URL)
}

// MARK: - Default Implementation

/// Shared file opener instance for the current platform.
public enum FileManager_Opener {
    /// The shared file opener for the current platform.
    public static let shared: FileOpener = PlatformFileOpener()
}

// MARK: - Platform-Specific Implementation

#if os(macOS)

/// macOS implementation using NSWorkspace.
public final class PlatformFileOpener: FileOpener, @unchecked Sendable {
    public init() {}

    @MainActor
    public func openFile(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    @MainActor
    public func openURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    @MainActor
    public func revealInFileBrowser(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

#else

/// iOS implementation using UIApplication.
public final class PlatformFileOpener: FileOpener, @unchecked Sendable {
    public init() {}

    @MainActor
    public func openFile(_ url: URL) -> Bool {
        // On iOS, we can open files via UIApplication if they have a registered handler
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }

    @MainActor
    public func openURL(_ url: URL) -> Bool {
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }

    @MainActor
    public func revealInFileBrowser(_ url: URL) {
        // On iOS, we can't directly reveal files in Files app.
        // Instead, we'd use UIDocumentInteractionController or share sheet.
        // For now, this is a no-op - actual implementation would be in the app layer.
    }
}

#endif
