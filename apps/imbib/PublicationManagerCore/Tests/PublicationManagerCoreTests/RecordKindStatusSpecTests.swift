//
//  RecordKindStatusSpecTests.swift
//  PublicationManagerCoreTests
//
//  The descriptor's status/lifecycle DECLARATIONS, and the frozen
//  presentation that proves widening `statuses` from `[String]` to
//  `[StatusSpec]` did not move a single pixel.
//
//  Why a frozen table and not just "labels are non-empty": the sidebar's
//  status rows were rendered from three separate sources before this change —
//  `RecordStatusPresentation.known` (iOS + the status badge),
//  `ImbibSidebarViewModel.journalChildren`'s inline literals (macOS), and
//  nothing at all for a kind that invented a status. Collapsing three sources
//  into one is only safe if the surviving one reproduces what shipped, exactly.
//

import XCTest
@testable import PublicationManagerCore

final class RecordKindStatusSpecTests: XCTestCase {

    // MARK: - Every declared status is presentable

    /// The parity gate the widening exists for: a status cannot be declared
    /// without a label and a symbol. Before `StatusSpec` this was
    /// unenforceable — `statuses` was `[String]`, so a new status silently
    /// inherited a title-cased label and a generic `circle`.
    func testEveryDeclaredStatusHasALabelAndASymbol() {
        for descriptor in BuiltinRecordKinds.all {
            for spec in descriptor.triage.statuses {
                XCTAssertFalse(
                    spec.rawValue.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(descriptor.id.rawValue): a status with an empty raw value "
                        + "matches no rows")
                XCTAssertFalse(
                    spec.label.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(descriptor.id.rawValue)/\(spec.rawValue) declares no label")
                XCTAssertFalse(
                    spec.systemImage.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(descriptor.id.rawValue)/\(spec.rawValue) declares no SF Symbol")
            }
        }
    }

    /// Same guarantee for kernel-owned lifecycles (impel's task states), which
    /// are a separate declaration precisely because the chassis must not write
    /// them.
    func testEveryDeclaredLifecycleStateHasALabelAndASymbol() {
        for descriptor in BuiltinRecordKinds.all {
            guard let lifecycle = descriptor.lifecycle else { continue }
            XCTAssertFalse(
                lifecycle.payloadField.isEmpty,
                "\(descriptor.id.rawValue): a lifecycle must name its payload field")
            XCTAssertFalse(
                lifecycle.states.isEmpty,
                "\(descriptor.id.rawValue): a lifecycle with no states is not one")
            for spec in lifecycle.states {
                XCTAssertFalse(
                    spec.label.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(descriptor.id.rawValue)/\(spec.rawValue) declares no label")
                XCTAssertFalse(
                    spec.systemImage.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(descriptor.id.rawValue)/\(spec.rawValue) declares no SF Symbol")
            }
        }
    }

    func testDeclaredStatusRawValuesAreUniquePerKind() {
        for descriptor in BuiltinRecordKinds.all {
            let values = descriptor.triage.statusValues
            XCTAssertEqual(
                values.count, Set(values).count,
                "\(descriptor.id.rawValue) declares a status twice: \(values)")
        }
    }

    // MARK: - The spec must not contradict the semantics

    /// `StatusSpec` deliberately does NOT carry "am I the dismissal status" or
    /// "am I the archive status" — `DismissalSemantics` and `archiveStatus`
    /// already say that, and two spellings of one fact drift. That decision is
    /// only safe if the two are cross-checked, which is this test.
    func testDismissalAndArchiveStatusesAreDeclaredInTheLifecycle() {
        for descriptor in BuiltinRecordKinds.all {
            let triage = descriptor.triage
            if let dismissed = triage.dismissedStatus {
                XCTAssertNotNil(
                    triage.status(dismissed),
                    "\(descriptor.id.rawValue) dismisses to '\(dismissed)', which it "
                        + "does not declare in `statuses` — the sidebar would show a "
                        + "Dismissed section for a status the kind says it has no.")
            }
            if let archived = triage.archiveStatus {
                XCTAssertNotNil(
                    triage.status(archived),
                    "\(descriptor.id.rawValue) archives to '\(archived)', which it "
                        + "does not declare in `statuses`.")
            }
        }
    }

    /// The dismissal status owns the Dismissed SECTION, so it must be
    /// `hiddenByDefault` — otherwise the same rows get two homes (one smart
    /// child of the primary section AND the Dismissed section).
    func testDismissalStatusIsHiddenByDefault() {
        for descriptor in BuiltinRecordKinds.all {
            guard let dismissed = descriptor.triage.dismissedStatus,
                  let spec = descriptor.triage.status(dismissed)
            else { continue }
            XCTAssertTrue(
                spec.hiddenByDefault,
                "\(descriptor.id.rawValue)/'\(dismissed)' is the dismissal status "
                    + "and must be hiddenByDefault, or it appears both as a primary "
                    + "smart child and as the Dismissed section")
        }
    }

    /// An archive status is a terminal state by definition. Catches a
    /// descriptor that declares `archiveStatus` and then forgets `isTerminal`,
    /// which would make `JournalManuscriptStatus.isActive` claim an archived
    /// manuscript is still in flight.
    func testArchiveAndDismissalStatusesAreTerminal() {
        for descriptor in BuiltinRecordKinds.all {
            let triage = descriptor.triage
            for value in [triage.archiveStatus, triage.dismissedStatus].compactMap({ $0 }) {
                guard let spec = triage.status(value) else { continue }
                XCTAssertTrue(
                    spec.isTerminal,
                    "\(descriptor.id.rawValue)/'\(value)' ends the lifecycle and must "
                        + "declare isTerminal")
            }
        }
    }

    // MARK: - Frozen presentation (the no-pixel-moved gate)

    /// The manuscript lifecycle's presentation, EXACTLY as it shipped before
    /// `statuses` was widened.
    ///
    /// Sources being collapsed, all three of which produced these strings:
    ///  * `RecordStatusPresentation.known` — the chassis's private table,
    ///    used by imprint-iOS's sidebar rows and status badge;
    ///  * `ImbibSidebarViewModel.journalChildren` — macOS's four inline
    ///    `displayName:`/`iconName:` literals (Drafts, Submitted, Published,
    ///    Archive);
    ///  * `docs/status-lifecycle.md`'s reserved `dismissed`/`archived` values.
    ///
    /// These are NAVIGATIONAL labels ("Drafts", "Archive"), which is why they
    /// differ from `JournalManuscriptStatus.displayName`'s singular badge
    /// spellings ("Draft", "Archived"). That second vocabulary still exists and
    /// is still hardcoded — it is macOS's detail-badge voice, and folding it in
    /// here would have changed macOS pixels.
    func testManuscriptStatusSpecsReproduceTheFrozenSidebarPresentation() {
        let expected: [(raw: String, label: String, symbol: String)] = [
            ("draft", "Drafts", "pencil"),
            ("internal-review", "Internal Review", "person.2"),
            ("submitted", "Submitted", "paperplane"),
            ("in-revision", "In Revision", "arrow.triangle.2.circlepath"),
            ("published", "Published", "checkmark.seal"),
            ("archived", "Archive", "archivebox"),
            ("dismissed", "Dismissed", "xmark.circle"),
        ]
        let specs = ManuscriptRecordKind.descriptor.triage.statuses

        XCTAssertEqual(
            specs.map(\.rawValue), expected.map(\.raw),
            "the manuscript lifecycle's VALUES and their ORDER are frozen — order "
                + "is the sidebar's row order")
        for (spec, want) in zip(specs, expected) {
            XCTAssertEqual(spec.label, want.label, "label for '\(want.raw)'")
            XCTAssertEqual(spec.systemImage, want.symbol, "symbol for '\(want.raw)'")
        }
    }

    /// macOS's four sidebar rows, resolved the way the view model now resolves
    /// them. This is the assertion that the AppKit sidebar did not change: the
    /// literals it used to carry are on the left, the declaration it now reads
    /// is on the right.
    func testMacOSJournalStatusRowsResolveToTheirFormerLiterals() {
        let frozen: [(JournalManuscriptStatus, String, String)] = [
            (.draft, "Drafts", "pencil"),
            (.submitted, "Submitted", "paperplane"),
            (.published, "Published", "checkmark.seal"),
            (.archived, "Archive", "archivebox"),
        ]
        for (status, label, symbol) in frozen {
            XCTAssertEqual(
                RecordStatusPresentation.label(for: status.rawValue), label,
                "macOS row label for \(status.rawValue)")
            XCTAssertEqual(
                RecordStatusPresentation.systemImage(for: status.rawValue), symbol,
                "macOS row icon for \(status.rawValue)")
        }
    }

    /// impel's kernel states, frozen against the `switch` + parallel array they
    /// replaced in `AgentStoreReader`.
    func testTaskLifecycleStatesReproduceTheFormerSwitch() {
        let expected: [(raw: String, label: String, symbol: String)] = [
            ("queued", "Queued", "clock"),
            ("running", "Running", "play.circle"),
            ("waiting_review", "Waiting Review", "person.crop.circle.badge.questionmark"),
            ("completed", "Completed", "checkmark.circle"),
            ("failed", "Failed", "xmark.circle"),
            ("cancelled", "Cancelled", "slash.circle"),
        ]
        guard let lifecycle = TaskRecordKind.descriptor.lifecycle else {
            return XCTFail("the task kind must declare its kernel lifecycle")
        }
        XCTAssertEqual(lifecycle.payloadField, "state",
                       "the kernel lifecycle lives in payload `state`, never `status`")
        XCTAssertTrue(lifecycle.isKernelOwned,
                      "TaskStoreApi.transition is the sole legal mutation (ADR-0015 D1)")
        XCTAssertEqual(lifecycle.stateValues, expected.map(\.raw))
        for (raw, label, symbol) in expected {
            XCTAssertEqual(AgentStoreReader.stateDisplayName(raw), label)
            XCTAssertEqual(AgentStoreReader.stateIcon(raw), symbol)
        }
    }

    /// Kernel states must NOT leak into `triage.statuses`: that list is "values
    /// the chassis's generic status writer may set", and a task's state is
    /// kernel-only. If these ever merge, `setStatus` becomes able to bypass
    /// `TaskStoreApi.transition`.
    func testKernelLifecycleStatesAreNotWritableStatuses() {
        for descriptor in BuiltinRecordKinds.all {
            guard let lifecycle = descriptor.lifecycle, lifecycle.isKernelOwned
            else { continue }
            for state in lifecycle.stateValues {
                XCTAssertNil(
                    descriptor.triage.status(state),
                    "\(descriptor.id.rawValue): kernel state '\(state)' must not also "
                        + "be a writable `status`")
            }
        }
    }

    // MARK: - Fallbacks

    /// An undeclared status still renders honestly. Pins the behaviour the
    /// private table used to provide, now that resolution goes through the
    /// descriptors.
    func testUndeclaredStatusFallsBackToATitleCasedLabel() {
        XCTAssertNil(RecordStatusPresentation.spec(for: "peer-review"))
        XCTAssertEqual(RecordStatusPresentation.label(for: "peer-review"), "Peer Review")
        XCTAssertEqual(RecordStatusPresentation.label(for: "awaiting_proof"), "Awaiting Proof")
        XCTAssertEqual(RecordStatusPresentation.systemImage(for: "whatever"), "circle")
    }

    /// `isActive` is now derived from `isTerminal`. Frozen against the switch
    /// it replaced, including the unknown-status case.
    func testManuscriptIsActiveMatchesTheFormerSwitch() {
        for status in JournalManuscriptStatus.allCases {
            let expected: Bool
            switch status {
            case .draft, .internalReview, .submitted, .inRevision: expected = true
            case .published, .archived, .dismissed: expected = false
            }
            XCTAssertEqual(
                status.isActive, expected,
                "isActive changed for \(status.rawValue)")
        }
    }
}
