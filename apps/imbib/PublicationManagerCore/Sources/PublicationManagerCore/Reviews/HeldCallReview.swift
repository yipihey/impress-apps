//
//  HeldCallReview.swift
//  PublicationManagerCore
//
//  Partial approval of a held verb call (koine plan-koine-trust TR-D7).
//
//  koine's `review-service` verbs act on a pending call by id:
//
//    review-service_show    {id}                      → {ok, pending: {state, targets, alternatives, …}}
//    review-service_approve {id, only?, instead?, remember?} → runs the approved call; answers the row
//    review-service_reject  {id}
//
//  `only` approves a subset of the call's targets, `instead` runs one of its
//  alternative verbs on the same arguments. Only a person (or their app) may
//  approve, so these calls go out with a person caller. Each app passes its
//  own verbs FFI as the dispatcher (imbib: ImbibVerbsFFI, imprint:
//  ImprintVerbsFFI), so the call runs in the store the app bound.
//

import Foundation
import ImbibVerbsFFI

/// What review-service_show says a held call can still do.
public struct HeldCallOptions: Equatable, Sendable {
    /// pending, running, done, failed, rejected, expired.
    public let state: String
    /// The records it acts on.
    public let targets: [ReviewCallTarget]
    /// Verbs the person may run on the same arguments instead.
    public let alternatives: [String]

    public var isPending: Bool { state == "pending" }
}

/// A review-service verb refused, or the approved call failed.
public struct HeldCallError: LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
}

public enum HeldCallReview {

    /// Dispatch one verb: `(verb, argsJSON, callerJSON)` → the answer's body JSON.
    public typealias Dispatch = @Sendable (String, String, String) async -> String

    /// The person at the app, as the verb pipeline's caller (`human`).
    public static func personCaller(app: String) -> String {
        let object: [String: Any] = [
            "kind": "person",
            "name": app,
            "trace_id": UUID().uuidString,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The held call's state, targets and alternatives.
    public static func show(pendingCallID id: String, dispatch: Dispatch) async throws -> HeldCallOptions {
        let pending = try await call("review-service_show", ["id": id], dispatch: dispatch)
        return HeldCallOptions(
            state: pending["state"] as? String ?? "",
            targets: ReviewCallContext.decodeTargets(pending["targets"]),
            alternatives: pending["alternatives"] as? [String] ?? []
        )
    }

    /// Approve the held call (all of it, `only` some targets, or an
    /// alternative verb `instead`). It runs at once; a call that ran and
    /// failed throws its failure. Answers the call's state afterwards.
    @discardableResult
    public static func approve(
        pendingCallID id: String,
        only: [String]? = nil,
        instead: String? = nil,
        dispatch: Dispatch
    ) async throws -> String {
        var args: [String: Any] = ["id": id]
        if let only { args["only"] = only }
        if let instead { args["instead"] = instead }
        let pending = try await call("review-service_approve", args, dispatch: dispatch)
        let state = pending["state"] as? String ?? ""
        if state == "failed" {
            throw HeldCallError(code: "failed", message: failureMessage(pending["result"]))
        }
        return state
    }

    /// Reject the held call; it never runs.
    public static func reject(pendingCallID id: String, dispatch: Dispatch) async throws {
        _ = try await call("review-service_reject", ["id": id], dispatch: dispatch)
    }

    /// "imbib-library-service_archive-entries" → "Archive entries".
    public static func displayName(ofVerb verb: String) -> String {
        let method = verb.split(separator: "_").last.map(String.init) ?? verb
        let words = method.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: - imbib

    /// imbib's verbs FFI, bound to the GUI store first (binding again to the
    /// same path is a no-op).
    public static let imbibDispatch: Dispatch = { verb, argsJSON, callerJSON in
        if let path = await MainActor.run(body: { RustStoreAdapter.shared.databaseLocation }) {
            try? ImbibVerbsFFI.initializeVerbStore(path: path)
        }
        return await ImbibVerbsFFI.dispatchVerbAsync(
            name: verb, argsJson: argsJSON, callerJson: callerJSON
        ).bodyJson
    }

    // MARK: - Internals

    /// One review-service call; the answer's `pending` row, or the refusal thrown.
    private static func call(
        _ verb: String,
        _ args: [String: Any],
        dispatch: Dispatch
    ) async throws -> [String: Any] {
        let argsData = try JSONSerialization.data(withJSONObject: args)
        let body = await dispatch(
            verb, String(decoding: argsData, as: UTF8.self), personCaller(app: "review-queue"))
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            throw HeldCallError(code: "bad-answer", message: "\(verb) gave an unreadable answer")
        }
        if object["ok"] as? Bool == false {
            let code = object["code"] as? String ?? "refused"
            throw HeldCallError(code: code, message: object["message"] as? String ?? code)
        }
        return object["pending"] as? [String: Any] ?? [:]
    }

    /// The message of a failed call's answer, however it was shaped.
    private static func failureMessage(_ result: Any?) -> String {
        if let object = result as? [String: Any] {
            if let message = object["message"] as? String { return message }
            if let error = object["error"] as? String { return error }
        }
        if let text = result as? String, !text.isEmpty { return text }
        return "The approved call failed"
    }
}
