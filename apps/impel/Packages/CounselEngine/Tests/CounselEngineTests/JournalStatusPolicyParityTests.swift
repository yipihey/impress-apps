//
//  JournalStatusPolicyParityTests.swift
//  CounselEngineTests
//
//  The interlock between `JournalPipeline.autoSnapshotStatuses` and the
//  CANONICAL manuscript lifecycle, which is
//  `ManuscriptRecordKind.descriptor.triage` in PublicationManagerCore
//  (`Chassis/RecordKind/BuiltinRecordKinds.swift`).
//
//  Why a test and not a shared constant
//  ------------------------------------
//  `autoSnapshotStatuses` is a hand-written literal set in a headless pipeline
//  package. It stays that way for two reasons (both recorded at the declaration
//  itself):
//
//   1. CounselEngine's `Package.swift` builds two EXECUTABLES (`journal-submit`,
//      `journal-backfill`) on top of the CounselEngine library. Linking
//      PublicationManagerCore — the shared GUI chassis, which drags in ~20
//      `packages/Impress*` plus HighlightSwift, SwiftMath and
//      swift-markdown-ui — into that product graph to read three strings is a
//      bad blast-radius trade. Note this is a JUDGEMENT CALL, not a lint
//      constraint: `scripts/check-chassis-deps.sh` does NOT forbid a
//      CounselEngine -> PMC edge; it only lints PMC's own manifest for what PMC
//      itself depends on.
//
//   2. The set is not expressible as any single existing descriptor predicate.
//      `isTerminal` yields {published, archived, dismissed}: it wrongly
//      includes `dismissed` and wrongly excludes `submitted`, which is the
//      PRIMARY snapshot trigger and is declared `isTerminal: false`. Even with
//      PMC linked into production, the derivation would still be written by
//      hand.
//
//  So PMC is a TEST-TARGET-ONLY dependency and this file is the interlock: the
//  literal may live in the pipeline, but it may not disagree with the
//  descriptor. Modelled on PublicationManagerCore's own
//  `RecordKindStatusSpecTests` — specifically
//  `testDismissalAndArchiveStatusesAreDeclaredInTheLifecycle` (cross-check a
//  derived fact against the declaration) and
//  `testManuscriptIsActiveMatchesTheFormerSwitch` (freeze the shipped table
//  independently of the derivation).
//
//  RECOMMENDED FOLLOW-UP: declare this facet on `StatusSpec` itself (e.g.
//  `freezesSource: Bool`), which would put the rule at the declaration and let
//  the pipeline derive the set with one `filter`. `Chassis/**` is outside this
//  wave's boundary, so it is deliberately not done here — and until it is, this
//  test is the only thing keeping the two in step.
//
//  NOT DUPLICATED HERE: that the dispatched revision tag is the RAW status
//  (i.e. that deleting `JournalPipeline.revisionTag(for:)` — an identity switch
//  over these same three literals — changed nothing). `JournalPipelineTests`
//  already covers it end-to-end: `dispatchOnSubmittedStatusCreatesRevision`
//  asserts `revPayload["revision_tag"] == "submitted"` after a real dispatch,
//  which is exactly the post-deletion behaviour.
//
//  Style note: failure messages are built as `String` and wrapped in
//  `Comment(rawValue:)`. `#expect`'s second parameter is `Comment?`, and long
//  `"a" + "b" + …` chains against its ExpressibleByStringInterpolation
//  conformance make the type-checker give up ("unable to type-check this
//  expression in reasonable time"). A plain String local sidesteps that.
//

import Testing

@testable import CounselEngine

#if canImport(PublicationManagerCore)
import PublicationManagerCore

@Suite struct JournalStatusPolicyParityTests {

    /// The lifecycle that OWNS these status values.
    private var triage: TriageCapabilities {
        ManuscriptRecordKind.descriptor.triage
    }

    /// `autoSnapshotStatuses` is an actor-isolated instance property, so it is
    /// read through a pipeline instance. Grace seconds are irrelevant — nothing
    /// here dispatches.
    private func autoSnapshotStatuses() async -> Set<String> {
        await JournalPipeline(startupGraceSeconds: 0).autoSnapshotStatuses
    }

    // MARK: - a. Rename detector

    /// Every status the pipeline snapshots on must be one the descriptor
    /// actually DECLARES.
    ///
    /// This is the rename detector, and it is the failure this whole file
    /// exists for: if the descriptor's `archived` is ever respelled (to
    /// `archive`, `archived@2`, anything), nothing in the compiler or in
    /// `scripts/check-schema-refs.sh` notices — the pipeline's `Set.contains`
    /// simply stops matching and manuscripts entering that status stop being
    /// snapshotted. Silently, forever, looking exactly like "no manuscripts
    /// have been archived yet".
    @Test func everyAutoSnapshotStatusIsDeclaredByTheDescriptor() async {
        let policy = await autoSnapshotStatuses()
        let declared = triage.statusValues
        for raw in policy.sorted() {
            let message = """
                JournalPipeline.autoSnapshotStatuses contains '\(raw)', which \
                ManuscriptRecordKind.descriptor.triage does not declare. The \
                descriptor is the canonical lifecycle, so this status can never be \
                reached — the pipeline has silently stopped snapshotting on it. \
                Declared statuses: \(declared)
                """
            #expect(triage.status(raw) != nil, Comment(rawValue: message))
        }
    }

    // MARK: - b. Dismissal must not freeze a revision

    /// Dismissing a manuscript is a user saying "not this one" — it must not
    /// freeze a revision snapshot.
    ///
    /// `dismissed` is `isTerminal: true`, so any future refactor that reaches
    /// for `isTerminal` as the derivation would pull it in. That is the
    /// regression this pins.
    @Test func dismissalStatusDoesNotAutoSnapshot() async {
        let policy = await autoSnapshotStatuses()
        guard let dismissed = triage.dismissedStatus else {
            let premise = """
                The manuscript kind is expected to dismiss via a status change \
                (DismissalSemantics.statusChange), so `dismissedStatus` should not be \
                nil. If dismissal semantics genuinely changed, this test's premise \
                needs revisiting rather than deleting.
                """
            #expect(Bool(false), Comment(rawValue: premise))
            return
        }
        let message = """
            '\(dismissed)' is the manuscript kind's DISMISSAL status and must not be \
            in autoSnapshotStatuses. Dismissing a manuscript would freeze a \
            manuscript-revision snapshot of work the user just rejected, and because \
            dismissal is restorable the snapshot would outlive the dismissal. Note \
            `dismissed` IS isTerminal — which is exactly why the policy cannot be \
            derived from `isTerminal` alone.
            """
        #expect(!policy.contains(dismissed), Comment(rawValue: message))
    }

    // MARK: - c. A new terminal status cannot be forgotten

    /// Every non-dismissal TERMINAL status must be in the policy.
    ///
    /// This is the other direction of the interlock: adding a terminal status to
    /// the descriptor (say `retracted`) is a one-line edit in PMC by someone who
    /// has never read this package. Without this assertion the manuscript would
    /// reach an end state with no frozen source, which is the one moment a
    /// snapshot is least recoverable.
    @Test func everyNonDismissalTerminalStatusAutoSnapshots() async {
        let policy = await autoSnapshotStatuses()
        let dismissed = triage.dismissedStatus
        for spec in triage.statuses where spec.isTerminal && spec.rawValue != dismissed {
            let raw = spec.rawValue
            let message = """
                '\(raw)' is a terminal, non-dismissal manuscript status but is not in \
                JournalPipeline.autoSnapshotStatuses — a manuscript can reach a \
                lifecycle END state without its source ever being frozen into a \
                manuscript-revision. Either add it to the policy set or, if it \
                genuinely should not snapshot, say so at the declaration and narrow \
                this test deliberately.
                """
            #expect(policy.contains(raw), Comment(rawValue: message))
        }
    }

    // MARK: - d. Frozen table (shipped behaviour, pinned independently)

    /// The policy EXACTLY as it ships, in the frozen-table style of
    /// `RecordKindStatusSpecTests`.
    ///
    /// Assertions a–c check the policy against the descriptor, which means a
    /// change to BOTH still passes them. This pins the actual three values, so
    /// widening or narrowing what impel auto-snapshots on is always a visible,
    /// deliberate edit to this line — never a side effect of a chassis change.
    ///
    /// Derivation, in words: the non-dismissal terminal statuses (`published`,
    /// `archived`), plus `submitted`. Per ADR-0011 D5 these are the
    /// user-meaningful transitions that warrant freezing the source; `draft`,
    /// `internal-review` and `in-revision` are working states.
    @Test func autoSnapshotStatusesMatchTheFrozenShippedSet() async {
        let policy = await autoSnapshotStatuses()
        let frozen: Set<String> = ["submitted", "published", "archived"]
        let message = """
            JournalPipeline.autoSnapshotStatuses changed from the shipped set \
            \(frozen.sorted()) to \(policy.sorted()). Every value here is a \
            manuscript-revision that either starts or stops being written, so update \
            this table in the same commit and say why in the declaration's doc \
            comment.
            """
        #expect(policy == frozen, Comment(rawValue: message))
    }

    /// The derivation stated in prose above, executed. Documents that the rule
    /// is "non-dismissal terminal, plus `submitted`" and that `submitted` is the
    /// part no descriptor predicate supplies — it is deliberately
    /// `isTerminal: false`.
    @Test func theDerivationRuleReproducesThePolicy() async {
        let policy = await autoSnapshotStatuses()
        let dismissed = triage.dismissedStatus
        var derived = Set(
            triage.statuses
                .filter { $0.isTerminal && $0.rawValue != dismissed }
                .map(\.rawValue))
        derived.insert("submitted")

        let driftMessage = """
            The derivation rule documented on autoSnapshotStatuses ("the \
            non-dismissal terminal statuses, plus `submitted`") now yields \
            \(derived.sorted()) but the policy is \(policy.sorted()). One of the two \
            is stale — fix the set or restate the rule.
            """
        #expect(derived == policy, Comment(rawValue: driftMessage))

        let submittedMessage = """
            `submitted` is expected to be a NON-terminal status that nonetheless \
            triggers the primary snapshot. That combination is the reason this policy \
            cannot be replaced by `statuses.filter(\\.isTerminal)`, and the reason the \
            recommended fix is a declared `freezesSource` facet on StatusSpec.
            """
        let submittedIsNonTerminal = triage.status("submitted")?.isTerminal == false
        #expect(submittedIsNonTerminal, Comment(rawValue: submittedMessage))
    }
}
#endif
