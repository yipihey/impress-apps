import Foundation

/// The persisted body of the sync lease file.
public struct SyncLeaseInfo: Codable, Sendable, Equatable {
    /// The app holding the lease (raw value of `SiblingApp`).
    public let app: String
    /// The holder's process identifier.
    public let pid: Int32
    /// When the lease was first taken by this holder.
    public let acquired: Date
    /// When the holder last renewed. Staleness is measured from here.
    public let renewed: Date

    public init(app: String, pid: Int32, acquired: Date, renewed: Date) {
        self.app = app
        self.pid = pid
        self.acquired = acquired
        self.renewed = renewed
    }
}

/// Single-writer lease for the CloudKit sync engine (ADR-0007 Phase 3, D8).
///
/// Three impress apps share one store and one App Group. Only ONE process may
/// own a `CKSyncEngine` for the shared zone at a time — two engines pushing
/// the same outbox would duplicate work, race on `sync.engine_state`, and
/// double-apply fetched batches. This lease is the arbiter: acquire before
/// constructing the engine, renew while running, release on stop.
///
/// The lease is a JSON file living beside the `SiblingDiscovery` heartbeats in
/// `SharedContainer.notificationsDirectory`, so it is visible to every app in
/// the group with no new IPC surface. It is deliberately **advisory** — a
/// crashed holder cannot release, so a lease older than `ttl` is stealable.
/// TTL 60s with a 20s renew cadence gives two missed renewals of slack before
/// a healthy holder looks dead.
///
/// This is not a mutual-exclusion primitive in the strict sense: two processes
/// that call `tryAcquire()` in the same instant can both observe a stale lease
/// and both write. That window is one file-write wide, and the consequence
/// (a duplicated fetch pass, which the Rust apply layer makes idempotent) is
/// benign. A hard lock would need a shared-container flock, which the App
/// Group sandbox makes unreliable across platforms.
public actor SyncLease {

    /// The shared lease for this process, scoped to imbib (the 3.0 host).
    public static let shared = SyncLease(app: .imbib)

    private let app: SiblingApp
    private let ttl: TimeInterval
    private let renewInterval: TimeInterval
    private let directoryOverride: URL?
    private let pid: Int32

    private var holding = false

    /// - Parameters:
    ///   - app: The app claiming the lease.
    ///   - ttl: How long a lease stays valid without renewal (default 60s).
    ///   - renewInterval: Suggested renew cadence for the holder (default 20s).
    ///   - directory: Override the lease directory (tests only — production
    ///     always uses the shared container).
    public init(
        app: SiblingApp,
        ttl: TimeInterval = 60,
        renewInterval: TimeInterval = 20,
        directory: URL? = nil
    ) {
        self.app = app
        self.ttl = ttl
        self.renewInterval = renewInterval
        self.directoryOverride = directory
        self.pid = ProcessInfo.processInfo.processIdentifier
    }

    /// Suggested renew cadence, for the holder's timer.
    public nonisolated var suggestedRenewInterval: TimeInterval { renewInterval }

    private var leaseURL: URL {
        let dir = directoryOverride ?? SharedContainer.notificationsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sync-lease.json")
    }

    /// The lease as it currently stands on disk, whoever holds it.
    public func currentLease() -> SyncLeaseInfo? {
        guard let data = try? Data(contentsOf: leaseURL) else { return nil }
        return try? JSONDecoder().decode(SyncLeaseInfo.self, from: data)
    }

    /// True when this process holds a lease that has not gone stale.
    public var isHeld: Bool {
        guard holding, let lease = currentLease() else { return false }
        return lease.pid == pid && lease.app == app.rawValue && !isStale(lease)
    }

    private func isStale(_ lease: SyncLeaseInfo, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lease.renewed) > ttl
    }

    private func write(_ lease: SyncLeaseInfo) -> Bool {
        guard let data = try? JSONEncoder().encode(lease) else { return false }
        do {
            try data.write(to: leaseURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Take the lease if it is free, ours, or stale.
    ///
    /// Returns `false` when another live process holds it — the caller must
    /// then NOT construct a sync engine.
    @discardableResult
    public func tryAcquire(now: Date = Date()) -> Bool {
        let existing = currentLease()

        if let existing {
            let mine = existing.pid == pid && existing.app == app.rawValue
            if !mine && !isStale(existing, now: now) {
                holding = false
                return false // a live holder owns it
            }
            // Ours (refresh) or stale (steal): keep the original acquisition
            // time when it is ours so `acquired` reflects a continuous hold.
            let acquired = mine ? existing.acquired : now
            let ok = write(SyncLeaseInfo(app: app.rawValue, pid: pid, acquired: acquired, renewed: now))
            holding = ok
            return ok
        }

        let ok = write(SyncLeaseInfo(app: app.rawValue, pid: pid, acquired: now, renewed: now))
        holding = ok
        return ok
    }

    /// Refresh our hold. Returns `false` if we no longer own the lease (it was
    /// stolen while we were stalled) — the caller must stop its engine.
    @discardableResult
    public func renew(now: Date = Date()) -> Bool {
        guard let existing = currentLease() else {
            // Lease file vanished (container reset). Re-take it.
            return tryAcquire(now: now)
        }
        guard existing.pid == pid, existing.app == app.rawValue else {
            holding = false
            return false // someone else owns it now
        }
        let ok = write(
            SyncLeaseInfo(app: app.rawValue, pid: pid, acquired: existing.acquired, renewed: now))
        holding = ok
        return ok
    }

    /// Give up the lease if we hold it. Never removes another holder's lease.
    public func release() {
        holding = false
        guard let existing = currentLease(),
              existing.pid == pid,
              existing.app == app.rawValue
        else { return }
        try? FileManager.default.removeItem(at: leaseURL)
    }
}
