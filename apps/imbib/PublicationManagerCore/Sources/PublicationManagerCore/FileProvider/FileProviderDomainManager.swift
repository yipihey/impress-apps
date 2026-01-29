//
//  FileProviderDomainManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-25.
//

import Foundation
import FileProvider
import OSLog

/// Manages File Provider domain registration and signaling.
///
/// The File Provider Extension exposes library PDFs in Finder (macOS) and Files app (iOS).
/// This manager handles:
/// - Registering the File Provider domain on app launch
/// - Signaling the extension when library content changes
/// - Cross-process communication via Darwin notifications
@MainActor
@Observable
public final class FileProviderDomainManager {

    // MARK: - Singleton

    public static let shared = FileProviderDomainManager()

    // MARK: - Constants

    /// Domain identifier for the File Provider
    public static let domainIdentifier = NSFileProviderDomainIdentifier("com.imbib.app.fileprovider")

    /// Display name shown in Finder/Files sidebar
    public static let domainDisplayName = "imbib Papers"

    /// Darwin notification name for signaling changes
    public static let changeNotificationName = "com.imbib.app.fileprovider.changed"

    // MARK: - Properties

    public private(set) var isRegistered = false
    public private(set) var lastError: Error?

    private let logger = Logger(subsystem: "com.imbib.app", category: "fileprovider-domain")

    // MARK: - Initialization

    private init() {}

    // MARK: - Domain Registration

    /// Register the File Provider domain.
    ///
    /// Should be called on app launch. Safe to call multiple times.
    public func registerDomain() async throws {
        #if os(macOS) || os(iOS)
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )

        do {
            try await NSFileProviderManager.add(domain)
            isRegistered = true
            lastError = nil
            logger.info("File Provider domain registered: \(Self.domainDisplayName)")
        } catch {
            // Domain may already exist - check if it's an "already exists" error
            let nsError = error as NSError
            if nsError.domain == NSFileProviderErrorDomain,
               nsError.code == NSFileProviderError.serverUnreachable.rawValue {
                // Extension not running, domain still registered
                isRegistered = true
                logger.info("File Provider domain exists (extension not running)")
            } else if nsError.localizedDescription.contains("already") {
                isRegistered = true
                logger.info("File Provider domain already registered")
            } else {
                isRegistered = false
                lastError = error
                logger.error("Failed to register File Provider domain: \(error.localizedDescription)")
                throw error
            }
        }
        #endif
    }

    /// Remove the File Provider domain.
    ///
    /// Called when user disables File Provider integration.
    public func removeDomain() async throws {
        #if os(macOS) || os(iOS)
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )

        do {
            try await NSFileProviderManager.remove(domain)
            isRegistered = false
            lastError = nil
            logger.info("File Provider domain removed")
        } catch {
            lastError = error
            logger.error("Failed to remove File Provider domain: \(error.localizedDescription)")
            throw error
        }
        #endif
    }

    // MARK: - Change Signaling

    /// Signal the File Provider extension that content has changed.
    ///
    /// Call this after:
    /// - PDF import
    /// - PDF deletion
    /// - Publication deletion
    public func signalChange() {
        #if os(macOS) || os(iOS)
        // Signal via NSFileProviderManager
        Task {
            guard let manager = NSFileProviderManager(for: NSFileProviderDomain(
                identifier: Self.domainIdentifier,
                displayName: Self.domainDisplayName
            )) else {
                logger.warning("Could not get File Provider manager for signaling")
                return
            }

            do {
                try await manager.signalEnumerator(for: .workingSet)
                try await manager.signalEnumerator(for: .rootContainer)
                logger.debug("Signaled File Provider enumerator")
            } catch {
                logger.error("Failed to signal File Provider: \(error.localizedDescription)")
            }
        }

        // Also post Darwin notification for cross-process signaling
        postDarwinNotification()
        #endif
    }

    /// Signal that a specific item has changed.
    public func signalItemChange(identifier: String) {
        #if os(macOS) || os(iOS)
        Task {
            guard let manager = NSFileProviderManager(for: NSFileProviderDomain(
                identifier: Self.domainIdentifier,
                displayName: Self.domainDisplayName
            )) else {
                return
            }

            let itemID = NSFileProviderItemIdentifier(identifier)
            do {
                try await manager.signalEnumerator(for: itemID)
                logger.debug("Signaled change for item: \(identifier)")
            } catch {
                logger.error("Failed to signal item change: \(error.localizedDescription)")
            }
        }
        #endif
    }

    // MARK: - Darwin Notifications

    /// Post a Darwin notification to wake up the extension.
    private func postDarwinNotification() {
        let notifyCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(Self.changeNotificationName as CFString)

        CFNotificationCenterPostNotification(
            notifyCenter,
            name,
            nil,
            nil,
            true
        )

        logger.debug("Posted Darwin notification: \(Self.changeNotificationName)")
    }

    /// Set up observer for Darwin notifications from the extension.
    ///
    /// Used by the extension to listen for changes from the main app.
    public static func setupDarwinNotificationObserver(handler: @escaping () -> Void) {
        // Store handler for callback
        darwinNotificationHandler = handler

        let notifyCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(changeNotificationName as CFString)

        CFNotificationCenterAddObserver(
            notifyCenter,
            nil,
            darwinNotificationCallback,
            name.rawValue,
            nil,
            .deliverImmediately
        )
    }

    // Internal for access from callback function (nonisolated for C callback)
    nonisolated(unsafe) static var darwinNotificationHandler: (() -> Void)?
}

// MARK: - Darwin Notification Callback

/// C-compatible callback function for Darwin notifications.
/// Must be a top-level function to be used as a C function pointer.
private func darwinNotificationCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    // Dispatch to main actor for thread safety
    Task { @MainActor in
        FileProviderDomainManager.darwinNotificationHandler?()
    }
}
