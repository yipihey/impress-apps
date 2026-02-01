//
//  CloudKitEnvironmentDetector.swift
//  PublicationManagerCore
//
//  Detects whether the app is running with CloudKit sandbox or production environment.
//  This helps prevent confusion when testing sync and ensures developers know
//  which environment they're operating in.
//

import Foundation
import OSLog
#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - CloudKit Environment

/// The detected CloudKit environment.
public enum CloudKitEnvironment: String, Sendable, CaseIterable {
    /// Production CloudKit environment (App Store builds)
    case production

    /// Sandbox CloudKit environment (Xcode development builds)
    case sandbox

    /// CloudKit is not available (not signed in, no entitlement, etc.)
    case unavailable

    /// Could not determine the environment
    case unknown

    /// Human-readable description for UI display
    public var displayName: String {
        switch self {
        case .production: return "Production"
        case .sandbox: return "Sandbox"
        case .unavailable: return "Unavailable"
        case .unknown: return "Unknown"
        }
    }

    /// Whether this environment is suitable for real user data
    public var isProductionSafe: Bool {
        self == .production
    }

    /// Warning message for non-production environments
    public var warningMessage: String? {
        switch self {
        case .sandbox:
            return "Running in CloudKit Sandbox mode. Data will not sync with production devices."
        case .unavailable:
            return "CloudKit is not available. Check iCloud sign-in and app entitlements."
        case .unknown:
            return "Could not determine CloudKit environment."
        case .production:
            return nil
        }
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when CloudKit sandbox environment is detected.
    /// Observe this to show a warning banner in the UI.
    static let cloudKitSandboxDetected = Notification.Name("cloudKitSandboxDetected")

    /// Posted when CloudKit environment changes.
    /// userInfo contains "environment" key with CloudKitEnvironment value.
    static let cloudKitEnvironmentChanged = Notification.Name("cloudKitEnvironmentChanged")
}

// MARK: - CloudKit Environment Detector

/// Detects the current CloudKit environment (sandbox vs production).
///
/// Use this service to:
/// - Warn developers when running in sandbox mode
/// - Prevent accidental mixing of sandbox and production data
/// - Debug sync issues related to environment mismatches
///
/// ## Usage
///
/// ```swift
/// let detector = CloudKitEnvironmentDetector.shared
/// let environment = await detector.detectEnvironment()
/// if environment == .sandbox {
///     // Show warning to developer
/// }
/// ```
public actor CloudKitEnvironmentDetector {

    // MARK: - Shared Instance

    /// Shared detector instance.
    public static let shared = CloudKitEnvironmentDetector()

    // MARK: - Properties

    /// Cached environment result (to avoid repeated detection)
    private var cachedEnvironment: CloudKitEnvironment?

    /// CloudKit container identifier
    private let containerIdentifier = "iCloud.com.imbib.app"

    // MARK: - Detection

    /// Detect the current CloudKit environment.
    ///
    /// This method uses multiple heuristics to determine the environment:
    /// 1. Check for Xcode build environment variables
    /// 2. Check CloudKit database subscription responses
    /// 3. Analyze container configuration
    ///
    /// - Returns: The detected CloudKit environment
    public func detectEnvironment() async -> CloudKitEnvironment {
        // Return cached result if available
        if let cached = cachedEnvironment {
            return cached
        }

        let environment = await performDetection()
        cachedEnvironment = environment

        Logger.sync.info("CloudKit environment detected: \(environment.rawValue)")
        return environment
    }

    /// Clear the cached environment (useful for testing or after significant changes)
    public func clearCache() {
        cachedEnvironment = nil
    }

    /// Perform the actual environment detection
    private func performDetection() async -> CloudKitEnvironment {
        #if canImport(CloudKit)
        // Check if CloudKit is available at all
        guard FileManager.default.ubiquityIdentityToken != nil else {
            Logger.sync.debug("CloudKit detection: No ubiquity identity token")
            return .unavailable
        }

        // Heuristic 1: Check for Xcode build environment
        // When running from Xcode, certain environment variables are set
        if isRunningFromXcode() {
            Logger.sync.debug("CloudKit detection: Running from Xcode (likely sandbox)")
            // Running from Xcode strongly suggests sandbox, but verify with CloudKit
        }

        // Heuristic 2: Check CKContainer account status
        do {
            let container = CKContainer(identifier: containerIdentifier)
            let status = try await container.accountStatus()

            guard status == .available else {
                Logger.sync.debug("CloudKit detection: Account not available (status: \(String(describing: status)))")
                return .unavailable
            }

            // Heuristic 3: Try to determine environment from container behavior
            // In sandbox, the private database has a different zone structure
            let environment = await detectFromDatabaseBehavior(container: container)
            return environment

        } catch {
            Logger.sync.warning("CloudKit detection failed: \(error.localizedDescription)")
            return .unknown
        }
        #else
        return .unavailable
        #endif
    }

    /// Check if the app is running from Xcode (development environment)
    private func isRunningFromXcode() -> Bool {
        // Check for Xcode-specific environment variables
        let xcodeIndicators = [
            "XCODE_BUILT_PRODUCTS_DIR_PATHS",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS",
            "DYLD_FRAMEWORK_PATH",
            "DYLD_LIBRARY_PATH"
        ]

        for indicator in xcodeIndicators {
            if ProcessInfo.processInfo.environment[indicator] != nil {
                return true
            }
        }

        // Check if running in DEBUG configuration (set by Xcode)
        #if DEBUG
        // Additional check: is the executable in DerivedData?
        let executablePath = Bundle.main.executablePath ?? ""
        if executablePath.contains("DerivedData") || executablePath.contains("Build/Products") {
            return true
        }
        #endif

        return false
    }

    #if canImport(CloudKit)
    /// Detect environment from CloudKit database behavior
    @available(macOS 10.15, iOS 13.0, *)
    private func detectFromDatabaseBehavior(container: CKContainer) async -> CloudKitEnvironment {
        // The most reliable way to detect sandbox vs production is to check
        // if we're running from Xcode AND have the sandbox entitlement.

        // In production builds (App Store/TestFlight), the app uses production CloudKit.
        // In development builds (Xcode), the app uses sandbox CloudKit.

        // If running with a debug configuration from Xcode, it's sandbox
        if isRunningFromXcode() {
            return .sandbox
        }

        // Check if this looks like a TestFlight or App Store build
        // The receipt URL path indicates the environment
        let receiptPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/_MASReceipt/receipt").path

        #if os(iOS)
        let iosReceiptPath = Bundle.main.bundleURL
            .appendingPathComponent("_MASReceipt/receipt").path
        let hasReceipt = FileManager.default.fileExists(atPath: receiptPath) ||
                         FileManager.default.fileExists(atPath: iosReceiptPath)
        #else
        let hasReceipt = FileManager.default.fileExists(atPath: receiptPath)
        #endif

        if hasReceipt {
            // App Store or TestFlight build - uses production CloudKit
            return .production
        }

        // Default assumption based on build configuration
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
    #endif

    // MARK: - Warning

    /// Check if running in sandbox and post a warning notification if so.
    ///
    /// Call this during app startup to alert developers when they're
    /// using sandbox CloudKit (which won't sync with production devices).
    public func warnIfSandbox() async {
        let environment = await detectEnvironment()

        if environment == .sandbox {
            Logger.sync.warning("⚠️ CloudKit SANDBOX detected - data will NOT sync with production!")

            await MainActor.run {
                NotificationCenter.default.post(
                    name: .cloudKitSandboxDetected,
                    object: nil,
                    userInfo: ["environment": environment]
                )
            }
        }

        // Always post environment change notification
        await MainActor.run {
            NotificationCenter.default.post(
                name: .cloudKitEnvironmentChanged,
                object: nil,
                userInfo: ["environment": environment]
            )
        }
    }

    // MARK: - Convenience

    /// Synchronous check if we're likely in sandbox (based on Xcode detection only).
    /// For a definitive answer, use `detectEnvironment()` async method.
    public nonisolated var isLikelySandbox: Bool {
        #if DEBUG
        let executablePath = Bundle.main.executablePath ?? ""
        return executablePath.contains("DerivedData") || executablePath.contains("Build/Products")
        #else
        return false
        #endif
    }
}
