//
//  EInkOCRPass.swift
//  PublicationManagerCore
//
//  Reads the handwriting the tablet sent back (ADR-025 P7). The Rust import
//  clusters ink strokes into annotations and renders each cluster to a PNG
//  (`EInkOCRJob.imagePath`); Vision runs in the app, so this actor takes the
//  pending jobs (`eink-pending-ocr`), recognises each image with the
//  existing `RemarkableOCRService`, and writes the text back
//  (`eink-complete-ocr`). A job with no legible text is still completed —
//  `text: nil` with the confidence Vision reported — so it is not retried
//  on every launch.
//
//  One job at a time (Vision is heavy enough), strictly serial. Triggered by
//  the coordinator after an import that carries `inkPendingOCR > 0`, and by
//  ONE launch sweep once the shared startup gate opens (the completion is a
//  store write).
//

import CoreGraphics
import Foundation
import ImageIO
import ImpressLogging
import OSLog

// MARK: - Environment

public struct EInkOCREnvironment: Sendable {
    /// At least one enabled device exists.
    public var isConfigured: @MainActor @Sendable () -> Bool
    /// Pending jobs, optionally for one publication.
    public var pendingJobs: @MainActor @Sendable (_ publicationId: UUID?) -> [EInkOCRJob]
    /// Recognise the rendered strokes; `text` may be empty.
    public var recognize: @Sendable (_ imagePath: String) async throws -> (text: String, confidence: Double)
    /// Store the result; false = the write failed.
    public var complete: @MainActor @Sendable (_ job: EInkOCRJob, _ text: String?, _ confidence: Double) -> Bool

    public init(
        isConfigured: @escaping @MainActor @Sendable () -> Bool,
        pendingJobs: @escaping @MainActor @Sendable (UUID?) -> [EInkOCRJob],
        recognize: @escaping @Sendable (String) async throws -> (text: String, confidence: Double),
        complete: @escaping @MainActor @Sendable (EInkOCRJob, String?, Double) -> Bool
    ) {
        self.isConfigured = isConfigured
        self.pendingJobs = pendingJobs
        self.recognize = recognize
        self.complete = complete
    }

    /// Production wiring: the store's job list, Vision via `RemarkableOCRService`, the store's completion verb.
    public static let live = EInkOCREnvironment(
        isConfigured: { EInkMirrorModel.shared.isConfigured },
        pendingJobs: { RustStoreAdapter.shared.einkPendingOCR(publicationId: $0) },
        recognize: { path in
            guard let image = EInkOCRPass.loadImage(atPath: path) else {
                throw OCRError.renderingFailed
            }
            let result = try await RemarkableOCRService.shared.recognizeText(from: image)
            return (result.text, Double(result.confidence))
        },
        complete: { job, text, confidence in
            RustStoreAdapter.shared.einkCompleteOCR(
                annotationId: job.annotationId, text: text, confidence: confidence, publicationId: job.publicationId)
        }
    )
}

// MARK: - Pass

public actor EInkOCRPass {

    public let gate: EInkStartupGate
    private let environment: EInkOCREnvironment

    public private(set) var completedCount = 0
    public private(set) var isRunning = false
    private var rerunRequested: [UUID]?
    private var rerunAll = false
    private var gateTask: Task<Void, Never>?

    public init(gate: EInkStartupGate, environment: EInkOCREnvironment = .live) {
        self.gate = gate
        self.environment = environment
    }

    /// The launch sweep: one sleep for the remaining grace, then every
    /// pending job (only when a device is configured).
    public func startLaunchSweep() {
        guard gateTask == nil else { return }
        gateTask = Task { [weak self, gate] in
            guard await gate.waitUntilOpen() else { return }
            guard let self, await self.environment.isConfigured() else { return }
            await self.run()
        }
    }

    public func stop() {
        gateTask?.cancel()
        gateTask = nil
    }

    /// Read every pending job (or those of the given publications), one at a
    /// time. A call while a pass is running queues one more pass.
    @discardableResult
    public func run(publicationIds: [UUID]? = nil) async -> Int {
        if isRunning {
            if let publicationIds {
                rerunRequested = (rerunRequested ?? []) + publicationIds
            } else {
                rerunAll = true
            }
            return 0
        }
        isRunning = true
        defer { isRunning = false }

        var jobs: [EInkOCRJob] = []
        if let publicationIds {
            for id in publicationIds {
                jobs += await environment.pendingJobs(id)
            }
        } else {
            jobs = await environment.pendingJobs(nil)
        }
        guard !jobs.isEmpty else { return await finish(done: 0) }

        // Mutation: what will be read.
        Logger.library.infoCapture("eink.ocr: \(jobs.count) pending ink annotation(s)", category: "eink")
        var done = 0
        for job in jobs {
            if Task.isCancelled { break }
            var text: String?
            var confidence = 0.0
            do {
                let result = try await environment.recognize(job.imagePath)
                let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = trimmed.isEmpty ? nil : trimmed
                confidence = result.confidence
            } catch {
                Logger.library.warningCapture(
                    "eink.ocr \(job.annotationId) p.\(job.pageNumber): recognition failed (\(error.localizedDescription)); completing empty",
                    category: "eink")
            }
            // Save: the store keeps the text (or the fact that there is none).
            if await environment.complete(job, text, confidence) {
                done += 1
                Logger.library.infoCapture(
                    "eink.ocr \(job.annotationId) p.\(job.pageNumber): "
                        + (text.map { "\"\($0.prefix(60))\" (\(Int(confidence * 100))%)" } ?? "no legible text"),
                    category: "eink")
            } else {
                Logger.library.errorCapture(
                    "eink.ocr \(job.annotationId): store refused the result", category: "eink")
            }
        }
        completedCount += done
        // Display: the Notes pane reloads on the row-scoped event `einkCompleteOCR` posts.
        Logger.library.infoCapture("eink.ocr: \(done)/\(jobs.count) annotation(s) completed", category: "eink")
        return await finish(done: done)
    }

    private func finish(done: Int) async -> Int {
        if rerunAll {
            rerunAll = false
            rerunRequested = nil
            isRunning = false
            return done + (await run())
        }
        if let queued = rerunRequested, !queued.isEmpty {
            rerunRequested = nil
            isRunning = false
            return done + (await run(publicationIds: queued))
        }
        return done
    }

    /// Decode the rendered strokes (PNG) into a `CGImage` for Vision.
    nonisolated static func loadImage(atPath path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
