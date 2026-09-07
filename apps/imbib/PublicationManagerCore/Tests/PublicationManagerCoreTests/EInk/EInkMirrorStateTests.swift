//
//  EInkMirrorStateTests.swift
//  PublicationManagerCoreTests
//
//  The list-row marker for the reMarkable USB mirror (ADR-025, P6). Pins:
//  the raw values are Rust's `MirrorState` spellings; the two bookkeeping
//  states have no marker; every visible state maps onto a
//  `MailStyleLeadingMarker`; and the marker travels through
//  `PublicationRowData` equality, which is what refreshes the row.
//

import XCTest
import ImpressMailStyle
@testable import PublicationManagerCore

// `MailStyleItem` is a `@MainActor` protocol, so `leadingMarker` is main-actor
// isolated on the conformance; the whole suite runs there.
@MainActor
final class EInkMirrorStateTests: XCTestCase {

    // MARK: Raw values

    /// Every case round-trips through its raw value, and the raw values are
    /// the seven visible `MirrorState` spellings — not `superseded` /
    /// `unmarked`, which Rust never writes into `BibliographyRow.eink_state`.
    func testRawValuesRoundTripAndMatchRust() {
        for state in EInkMirrorState.allCases {
            XCTAssertEqual(EInkMirrorState(rawValue: state.rawValue), state)
        }
        XCTAssertEqual(
            Set(EInkMirrorState.allCases.map(\.rawValue)),
            ["queued", "awaiting_source", "awaiting_folder", "uploaded", "stale", "removed_on_device", "failed"])
        XCTAssertNil(EInkMirrorState(rawValue: "superseded"))
        XCTAssertNil(EInkMirrorState(rawValue: "unmarked"))
        XCTAssertNil(EInkMirrorState(rawValue: ""))
    }

    // MARK: Marker mapping

    func testEveryStateHasAMarkerWithItsLabelAndGlyph() {
        for state in EInkMirrorState.allCases {
            let marker = state.marker
            XCTAssertEqual(marker.systemImage, state.systemImage, "\(state)")
            XCTAssertEqual(marker.tint, state.tint, "\(state)")
            XCTAssertEqual(marker.accessibilityLabel, state.label, "\(state)")
            XCTAssertFalse(state.label.isEmpty, "\(state)")
            XCTAssertFalse(state.explanation.isEmpty, "\(state)")
            XCTAssertFalse(state.systemImage.isEmpty, "\(state)")
        }
        // Distinct states must be distinguishable at a glance.
        XCTAssertEqual(Set(EInkMirrorState.allCases.map(\.systemImage)).count, EInkMirrorState.allCases.count)
    }

    func testFailureIsRedAndACopyOnTheTabletIsGreen() {
        XCTAssertEqual(EInkMirrorState.failed.tint, .red)
        XCTAssertEqual(EInkMirrorState.uploaded.tint, .green)
        XCTAssertTrue(EInkMirrorState.uploaded.isOnDevice)
        XCTAssertTrue(EInkMirrorState.stale.isOnDevice)
        for state in [EInkMirrorState.queued, .awaitingSource, .awaitingFolder, .removedOnDevice, .failed] {
            XCTAssertFalse(state.isOnDevice, "\(state)")
        }
    }

    /// The menu verb removes a copy that exists and stops mirroring one that
    /// never got that far; the unmarked verb is the one static string.
    func testMenuVerbs() {
        XCTAssertEqual(EInkMirrorState.mirrorVerb, "Mirror to reMarkable")
        XCTAssertEqual(EInkMirrorState.uploaded.menuVerb, "Remove from reMarkable")
        XCTAssertEqual(EInkMirrorState.stale.menuVerb, "Remove from reMarkable")
        for state in [EInkMirrorState.queued, .awaitingSource, .awaitingFolder, .removedOnDevice, .failed] {
            XCTAssertEqual(state.menuVerb, "Stop Mirroring to reMarkable", "\(state)")
        }
    }

    // MARK: Row data

    func testRowDataExposesTheMarkerAndDefaultsToNone() {
        let id = UUID()
        let plain = PublicationRowData(id: id, citeKey: "Key2026")
        XCTAssertNil(plain.einkState)
        XCTAssertNil(plain.leadingMarker)

        let queued = PublicationRowData(id: id, citeKey: "Key2026", einkState: .queued)
        XCTAssertEqual(queued.leadingMarker, EInkMirrorState.queued.marker)
        XCTAssertEqual(queued.leadingMarker?.accessibilityLabel, "Queued for reMarkable")
    }

    /// Two rows that differ ONLY in `einkState` are unequal — the row diff
    /// is what refreshes the marker after a mark/unmark or a sync.
    func testRowsDifferingOnlyInMirrorStateAreUnequal() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = PublicationRowData(id: id, citeKey: "Key2026", title: "T", dateAdded: date, dateModified: date)
        let b = PublicationRowData(id: id, citeKey: "Key2026", title: "T", dateAdded: date, dateModified: date, einkState: .uploaded)
        let c = PublicationRowData(id: id, citeKey: "Key2026", title: "T", dateAdded: date, dateModified: date, einkState: .uploaded)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(b, c)
        XCTAssertEqual(b.hashValue, c.hashValue)
    }

    // MARK: Store-side helpers

    func testMirrorRecordAndStatusSnapshotHaveDefaults() {
        var snapshot = EInkStatusSnapshot()
        XCTAssertFalse(snapshot.isConfigured)
        XCTAssertFalse(snapshot.showsIndividualControls)
        XCTAssertEqual(snapshot.counts.marked, 0)
        snapshot.markerDeviceId = "dev"
        XCTAssertTrue(snapshot.showsIndividualControls)

        let json = snapshot.jsonDictionary()
        XCTAssertEqual(json["configured"] as? Bool, false)
        XCTAssertEqual(json["shows_individual_controls"] as? Bool, true)
        XCTAssertEqual(json["marker_device_id"] as? String, "dev")
        XCTAssertNotNil(json["counts"] as? [String: Any])
        XCTAssertTrue(json["last_sync_ms"] is NSNull)
    }
}
