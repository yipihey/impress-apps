//
//  ReviewCallContext.swift
//  PublicationManagerCore
//
//  What a held verb call asks a person to approve, decoded from its
//  `review-request@1.0.0` item.
//
//  koine's review queue (koine-tasks `review.rs`, `file_pending_in`) parks a
//  call that needs approval as a `koine/pending-call@1.0.0` item and opens a
//  review request on it. `open_review` flattens the request's context into the
//  review payload as `context_<key>`, so the request carries:
//
//    context_pending_call  the pending call's id
//    context_verb          the verb asked for
//    context_caller        who asked (author string)
//    context_safety        read_only | mutating | destructive | external
//    context_impact        the verb's impact for that safety class
//    context_reason        why the call was held (the policy verdict), optional
//    context_targets       JSON string `[{id, argument, kind, title}]`, optional
//
//  Shared by imbib's review queue and imprint's throughline proposals (via
//  imprint's PMC re-export file).
//

import Foundation

/// One record a held call acts on (an entry of `context_targets`).
public struct ReviewCallTarget: Hashable, Sendable, Identifiable {
    /// Item id as the call named it.
    public let id: String
    /// The verb argument it came from (`targets`, `ids`, …).
    public let argument: String?
    /// The item's schema (`bibliography-entry@1.0.0`, …), nil if not found.
    public let kind: String?
    /// The item's title/name/label at filing time, if it had one.
    public let title: String?

    public init(id: String, argument: String? = nil, kind: String? = nil, title: String? = nil) {
        self.id = id
        self.argument = argument
        self.kind = kind
        self.title = title
    }

    /// Title when known, otherwise a short form of the id.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return id.count > 8 ? String(id.prefix(8)) + "…" : id
    }

    /// Whether this target is a paper (bibliography entry / publication).
    public var isPaper: Bool {
        guard let kind else { return false }
        return kind.hasPrefix("bibliography-entry") || kind.hasPrefix("publication")
    }
}

/// The verb-call context of a review request, when it reviews a held call.
public struct ReviewCallContext: Hashable, Sendable {
    public let pendingCallID: String?
    public let verb: String?
    public let caller: String?
    public let safety: String?
    public let impact: String?
    public let reason: String?
    public private(set) var targets: [ReviewCallTarget]

    /// Decode from a review-request payload. Returns nil when the payload has
    /// none of the call fields (e.g. a keyword auto-tag review).
    public init?(payload: [String: Any]) {
        func str(_ key: String) -> String? {
            guard let value = payload["context_\(key)"] as? String,
                  !value.isEmpty else { return nil }
            return value
        }
        let targets = Self.decodeTargets(payload["context_targets"])
        let reason = str("reason")
        let verb = str("verb")
        guard reason != nil || verb != nil || !targets.isEmpty else { return nil }
        self.pendingCallID = str("pending_call")
        self.verb = verb
        self.caller = str("caller")
        self.safety = str("safety")
        self.impact = str("impact")
        self.reason = reason
        self.targets = targets
    }

    /// A copy whose untitled targets take their title from `lookup` (e.g. a
    /// store lookup by id), when it answers one.
    public func resolvingTitles(_ lookup: (String) -> String?) -> ReviewCallContext {
        var copy = self
        copy.targets = targets.map { target in
            guard target.title?.isEmpty ?? true, let title = lookup(target.id) else { return target }
            return ReviewCallTarget(
                id: target.id, argument: target.argument, kind: target.kind, title: title)
        }
        return copy
    }

    /// `context_targets` is a JSON string (koine stores it as text); accept an
    /// already-decoded array too.
    private static func decodeTargets(_ raw: Any?) -> [ReviewCallTarget] {
        var array: [Any]?
        if let text = raw as? String, let data = text.data(using: .utf8) {
            array = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        } else {
            array = raw as? [Any]
        }
        return (array ?? []).compactMap { entry in
            if let id = entry as? String { return ReviewCallTarget(id: id) }
            guard let dict = entry as? [String: Any],
                  let id = dict["id"] as? String else { return nil }
            return ReviewCallTarget(
                id: id,
                argument: dict["argument"] as? String,
                kind: dict["kind"] as? String,
                title: dict["title"] as? String
            )
        }
    }

    /// "safety, impact impact" — e.g. "destructive, high impact".
    public var riskSummary: String? {
        switch (safety, impact) {
        case let (s?, i?): return "\(s), \(i) impact"
        case let (s?, nil): return s
        case let (nil, i?): return "\(i) impact"
        default: return nil
        }
    }

    /// "3 papers: A, B, C" / "1 record: X" / nil when there are no targets.
    /// Lists at most `limit` names, then "+N more".
    public func targetSummary(limit: Int = 3) -> String? {
        guard !targets.isEmpty else { return nil }
        let count = targets.count
        let noun = targets.allSatisfy(\.isPaper)
            ? (count == 1 ? "paper" : "papers")
            : (count == 1 ? "record" : "records")
        var names = targets.prefix(limit).map(\.displayName).joined(separator: ", ")
        if count > limit { names += ", +\(count - limit) more" }
        return "\(count) \(noun): \(names)"
    }
}
