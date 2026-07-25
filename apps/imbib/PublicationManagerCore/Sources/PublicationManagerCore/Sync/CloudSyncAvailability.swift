//
//  CloudSyncAvailability.swift
//  PublicationManagerCore
//
//  ADR-0007 Phase 3 (Phase D), decision 9: the ordered precondition chain that
//  every sync entry point must clear before ANY CloudKit object exists.
//
//  ## Why the order is load-bearing
//
//  `CKContainer(identifier:)` **traps** (SIGTRAP, not an error) when the
//  process carries no matching `com.apple.developer.icloud-container-identifiers`
//  entitlement. That is not hypothetical: commit 5edde41 fixed exactly this
//  crash, where an unentitled `CKContainer` init killed the app on launch under
//  XCUITest and for any iCloud-signed-in user who hit reset-to-first-run.
//
//  So the chain is: unit-test short-circuit → user flag → **entitlement probe**
//  → account status → lease. The entitlement probe is what makes it safe to
//  even mention `CKContainer` on the next line; nothing above it constructs a
//  CloudKit type. During Phase D the container is not yet in the entitlements
//  file at all (see docs/sync-phase-d-activation.md), so on today's builds this
//  gate always stops at `.notEntitled` — by design, and proven by tests.
//

import Foundation
import CloudKit
import ImpressKit
import ImpressLogging
import OSLog
#if os(macOS)
import Security
#endif

/// Why sync is (or is not) available right now. Phase E renders these
/// verbatim in Settings, so each case carries a user-facing explanation.
public enum SyncAvailability: Equatable, Sendable {

    /// Every precondition cleared — safe to construct the engine.
    case available

    /// Running inside `swift test` / xctest. Sync never starts here.
    case unitTestProcess

    /// The user has not switched sync on (the default).
    case disabledByUser

    /// This build carries no entitlement for the sync container. Constructing
    /// `CKContainer` would trap, so we stop here.
    case notEntitled

    /// Signed out of iCloud, or the account is restricted/unavailable.
    case accountUnavailable(CKAccountStatus)

    /// Another process in the suite holds the single-writer lease.
    case leaseHeldByOther(String)

    /// The account check itself failed (network/daemon error).
    case accountCheckFailed(String)

    public var isAvailable: Bool { self == .available }

    /// One-line explanation for Settings and `/api/sync/status`.
    public var explanation: String {
        switch self {
        case .available:
            return "iCloud sync is active."
        case .unitTestProcess:
            return "Sync is disabled in test processes."
        case .disabledByUser:
            return "iCloud sync is turned off."
        case .notEntitled:
            return "This build is not provisioned for iCloud sync "
                + "(missing the \(SyncSettings.containerIdentifier) container entitlement)."
        case .accountUnavailable(let status):
            switch status {
            case .noAccount:
                return "No iCloud account is signed in on this device."
            case .restricted:
                return "iCloud is restricted by device policy (Screen Time or MDM)."
            case .temporarilyUnavailable:
                return "iCloud is temporarily unavailable. Sync will retry."
            case .couldNotDetermine:
                return "Could not determine iCloud account status."
            @unknown default:
                return "iCloud account is unavailable."
            }
        case .leaseHeldByOther(let app):
            return "Another impress app (\(app)) is running the sync engine."
        case .accountCheckFailed(let message):
            return "Could not reach iCloud: \(message)"
        }
    }

    /// Short machine-readable token for the automation API (Phase E).
    public var reasonCode: String {
        switch self {
        case .available: return "available"
        case .unitTestProcess: return "unit_test_process"
        case .disabledByUser: return "disabled_by_user"
        case .notEntitled: return "not_entitled"
        case .accountUnavailable: return "account_unavailable"
        case .leaseHeldByOther: return "lease_held_by_other"
        case .accountCheckFailed: return "account_check_failed"
        }
    }
}

/// Evaluates the sync preconditions in their mandatory order.
public enum CloudSyncAvailability {

    /// Whether this process is entitled for the impress sync container.
    ///
    /// Read once, at first use, via `SecTaskCopyValueForEntitlement` — the
    /// same runtime probe `CloudKitResetService` adopted after the 5edde41
    /// crash. **Never** construct `CKContainer` before this returns true.
    ///
    /// The entitlement APIs are macOS-only. On iOS we fall back to the code
    /// signing entitlements embedded by the build: there is no supported
    /// runtime read, so we consult a build-time marker instead (see
    /// `iOSEntitlementDeclared`). Until Phase D activation adds the container
    /// to the entitlements files, both paths return false and sync stays off.
    public static let isEntitledForContainer: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil)
        else { return false }
        guard let containers = value as? [String] else { return false }
        return containers.contains(SyncSettings.containerIdentifier)
        #else
        return iOSEntitlementDeclared
        #endif
    }()

    #if !os(macOS)
    /// iOS has no `SecTask` entitlement read, so we detect provisioning by
    /// looking for the container declaration that the activation step adds to
    /// the app's `Info.plist` alongside the entitlement
    /// (`ImpressSyncContainerIdentifier`). Absent that key — the state during
    /// Phase D — sync reports `.notEntitled` and never touches CloudKit.
    static var iOSEntitlementDeclared: Bool {
        let declared = Bundle.main.object(forInfoDictionaryKey: "ImpressSyncContainerIdentifier") as? String
        return declared == SyncSettings.containerIdentifier
    }
    #endif

    /// Evaluate everything except the lease. Split out so Settings can show
    /// the reason without contending for the single-writer lease.
    ///
    /// - Parameter probeAccount: when false, stop before the (async, network-
    ///   touching) account check. Used by cheap status reads.
    public static func evaluatePreLease(probeAccount: Bool = true) async -> SyncAvailability {
        if ImpressRuntime.isUnitTestProcess { return .unitTestProcess }
        guard SyncSettings.isEnabled else { return .disabledByUser }
        guard isEntitledForContainer else { return .notEntitled }
        guard probeAccount else { return .available }

        // Only now is it safe to construct the container.
        let container = CKContainer(identifier: SyncSettings.containerIdentifier)
        do {
            let status = try await container.accountStatus()
            guard status == .available else { return .accountUnavailable(status) }
            return .available
        } catch {
            return .accountCheckFailed(error.localizedDescription)
        }
    }

    /// The full chain, lease included. A `.available` result means the caller
    /// holds the single-writer lease and MUST release it when it stops.
    public static func evaluate(lease: SyncLease = SyncLease.shared) async -> SyncAvailability {
        let preLease = await evaluatePreLease()
        guard preLease == .available else { return preLease }

        guard await lease.tryAcquire() else {
            let holder = await lease.currentLease()?.app ?? "another app"
            Logger.sync.infoCapture(
                "Sync lease held by \(holder) — not starting engine", category: "sync")
            return .leaseHeldByOther(holder)
        }
        return .available
    }

    /// Construct the sync container. **Only** call this after `evaluate()`
    /// (or at minimum `isEntitledForContainer`) has returned `.available`.
    /// Returns nil rather than trapping if the guard was skipped.
    static func makeContainerIfEntitled() -> CKContainer? {
        guard isEntitledForContainer else {
            Logger.sync.error("Refusing to construct CKContainer — not entitled")
            return nil
        }
        return CKContainer(identifier: SyncSettings.containerIdentifier)
    }
}
