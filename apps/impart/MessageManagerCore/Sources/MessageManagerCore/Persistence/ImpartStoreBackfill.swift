//
//  ImpartStoreBackfill.swift
//  MessageManagerCore
//
//  Resumable Core Data → unified store backfill (GUI unification
//  Stage 0 WP3).
//
//  On first run after this build ships, every existing CDMessage is
//  mirrored into the shared impress-core store as an `email-message` row
//  (with its account/folder parent chain), oldest first, in batches of
//  500. Progress is checkpointed in sync metadata after every batch so
//  a relaunch resumes from the last watermark instead of starting over.
//  Deterministic ids make re-runs idempotent — boundary rows re-written
//  after a resume simply become updates.
//
//  ## Startup invariant (CLAUDE.md)
//
//  The backfill sleeps ≥90 seconds after launch before touching the
//  store — background services must not mutate data while the UI settles.
//
//  ## Metadata keys
//
//  The store's metadata table only accepts `sync.`-prefixed keys, so the
//  WP3 keys live under the `sync.` namespace:
//
//  - `sync.impart.backfill.lastMessageDate` — ISO8601 watermark of the
//    newest message date written so far.
//  - `sync.impart.backfill.completed` — set (ISO8601 completion time)
//    once the full pass has finished; presence short-circuits relaunches.
//

import CoreData
import Foundation
import ImpressLogging
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

/// One-shot, resumable migration of impart's Core Data mail into the
/// shared impress-core store.
public actor ImpartStoreBackfill {

    // MARK: - Singleton

    public static let shared = ImpartStoreBackfill()

    // MARK: - Constants

    /// Sync-metadata key for the resume watermark (ISO8601 message date).
    public static let watermarkKey = "sync.impart.backfill.lastMessageDate"
    /// Sync-metadata key set when the backfill has completed.
    public static let completedKey = "sync.impart.backfill.completed"
    /// Messages per store transaction.
    public static let batchSize = 500
    /// Startup delay before the first store mutation (CLAUDE.md invariant).
    public static let startupDelaySeconds: TimeInterval = 90

    // MARK: - State

    private var started = false

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Init

    public init() {}

    // MARK: - Entry point

    /// Kick off the backfill. Safe to call more than once per process —
    /// only the first call runs. Waits out the 90 s startup grace before
    /// touching the store, then pages CDMessages oldest-first.
    public func startIfNeeded(persistence: PersistenceController) async {
        guard !started else { return }
        started = true

        // CLAUDE.md startup invariant: no store mutations in the first
        // 90 seconds after launch. Single sleep — cancellation-correct.
        try? await Task.sleep(for: .seconds(Self.startupDelaySeconds))
        guard !Task.isCancelled else { return }

        await run(persistence: persistence)
    }

    // MARK: - Backfill pass

    private func run(persistence: PersistenceController) async {
        #if canImport(ImpressRustCore)
        guard let store = MailStoreMirror.shared.storeHandle() else {
            logWarning("Backfill: shared store not open — skipping", category: "store-backfill")
            return
        }

        if let completed = try? store.syncMetadataGet(key: Self.completedKey), completed != nil {
            logInfo("Backfill: already completed — skipping", category: "store-backfill")
            return
        }

        // 1. Parents first: mirror every account and folder so message
        //    rows land under an existing parent chain.
        do {
            let parentRows: [MailItemUpsert] = try await persistence.performBackgroundTask { context in
                var rows: [MailItemUpsert] = []
                let accounts = try context.fetch(CDAccount.fetchRequest())
                for account in accounts {
                    rows.append(ImpartStoreAdapter.accountRow(
                        email: account.email,
                        displayName: account.displayName
                    ))
                    for folder in account.folders ?? [] {
                        rows.append(ImpartStoreAdapter.folderRow(
                            accountEmail: account.email,
                            name: folder.name,
                            remotePath: folder.fullPath,
                            role: folder.roleRaw,
                            sortOrder: Int(folder.sortOrder)
                        ))
                    }
                }
                return rows
            }
            if !parentRows.isEmpty {
                let result = try store.upsertItems(rows: parentRows.map(\.shared))
                logInfo(
                    "Backfill: mirrored \(parentRows.count) account/folder rows (inserted \(result.inserted), updated \(result.updated))",
                    category: "store-backfill"
                )
            }
        } catch {
            logError("Backfill: account/folder mirror failed — \(error)", category: "store-backfill")
            return
        }

        // 2. Messages, oldest first, resumed from the ISO8601 watermark.
        //    Within a run the watermark stays fixed and paging advances by
        //    offset; the watermark is only a relaunch resume point (the
        //    `>=` predicate re-writes boundary rows — idempotent updates).
        let watermark: Date? = (try? store.syncMetadataGet(key: Self.watermarkKey))
            .flatMap { $0 }
            .flatMap { Self.iso.date(from: $0) }
        if let watermark {
            logInfo(
                "Backfill: resuming from watermark \(Self.iso.string(from: watermark))",
                category: "store-backfill"
            )
        }

        var offset = 0
        var total = 0
        while true {
            guard !Task.isCancelled else { return }

            let batch: [MailItemUpsert]
            do {
                let fetchOffset = offset
                batch = try await persistence.performBackgroundTask { context in
                    let request = CDMessage.fetchRequest()
                    if let watermark {
                        request.predicate = NSPredicate(format: "date >= %@", watermark as NSDate)
                    }
                    request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
                    request.fetchLimit = Self.batchSize
                    request.fetchOffset = fetchOffset
                    request.relationshipKeyPathsForPrefetching = ["folder", "folder.account", "content", "thread"]
                    return try context.fetch(request).map(ImpartStoreAdapter.messageRow(from:))
                }
            } catch {
                logError("Backfill: message fetch failed at offset \(offset) — \(error)", category: "store-backfill")
                return
            }

            guard !batch.isEmpty else { break }

            // Three-point trace: requested → batch result → running total.
            logInfo("Backfill batch: requested \(batch.count) messages (offset \(offset))", category: "store-backfill")
            do {
                let result = try store.upsertItems(rows: batch.map(\.shared))
                total += batch.count
                logInfo(
                    "Backfill batch: inserted \(result.inserted), updated \(result.updated); running total \(total)",
                    category: "store-backfill"
                )
            } catch {
                logError("Backfill: upsertItems failed at offset \(offset) — \(error)", category: "store-backfill")
                return
            }

            // Checkpoint the newest message date written so far.
            if let lastMs = batch.last?.createdMs {
                let lastDate = Date(timeIntervalSince1970: Double(lastMs) / 1000)
                try? store.syncMetadataSet(key: Self.watermarkKey, value: Self.iso.string(from: lastDate))
            }

            offset += batch.count
            if batch.count < Self.batchSize { break }
        }

        try? store.syncMetadataSet(key: Self.completedKey, value: Self.iso.string(from: Date()))
        logInfo("Backfill complete: \(total) messages mirrored this run", category: "store-backfill")

        if total > 0 {
            await MainActor.run {
                ImpartStoreAdapter.shared.didMutate()
            }
        }
        #else
        logInfo("Backfill: ImpressRustCore not linked — nothing to do", category: "store-backfill")
        #endif
    }
}
