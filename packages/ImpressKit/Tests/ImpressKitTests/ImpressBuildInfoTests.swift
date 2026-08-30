//
//  ImpressBuildInfoTests.swift
//  ImpressKitTests
//
//  The build stamp exists to answer one question — "is the app I am looking
//  at the code I just built?" — so the property that matters is that it
//  reports the BINARY'S OWN age, not a constant, and not the moment it was
//  asked.
//

import XCTest

@testable import ImpressKit

final class ImpressBuildInfoTests: XCTestCase {

    /// The stamp must come from the executable on disk. In a test process
    /// that is the xctest bundle's binary, which was linked moments ago — so
    /// it must exist, and it must not be in the future.
    func testBuildDateComesFromTheBinaryOnDisk() throws {
        let buildDate = try XCTUnwrap(
            ImpressBuildInfo.buildDate,
            "no build date — neither the executable nor the bundle could be stat'd")
        XCTAssertLessThanOrEqual(
            buildDate, Date().addingTimeInterval(60),
            "the build date is in the future; it is not reading a real file's mtime")
    }

    /// It is a snapshot of the binary, not a clock: asking twice must give
    /// the same answer. (A stamp that drifted would report "built seconds
    /// ago" forever, which is exactly the reassuring lie this replaces.)
    func testBuildDateIsStableAcrossReads() throws {
        let first = try XCTUnwrap(ImpressBuildInfo.buildDate)
        Thread.sleep(forTimeInterval: 0.05)
        let second = try XCTUnwrap(ImpressBuildInfo.buildDate)
        XCTAssertEqual(first, second)
    }

    /// The one-line summary is what goes in logs, status endpoints and bug
    /// reports, so it must name the app and carry the date.
    func testSummaryCarriesTheNameAndTheDate() {
        let summary = ImpressBuildInfo.summary
        XCTAssertTrue(summary.contains("built"), "summary omits the build stamp: \(summary)")
        XCTAssertFalse(
            summary.contains("built unknown"),
            "the build date could not be read in a normal test process: \(summary)")
        XCTAssertFalse(summary.hasPrefix(" "), "summary omits the app name: \(summary)")
    }

    /// `commit` is optional infrastructure for a later build-time injection;
    /// until something writes `ImpressGitCommit`, it must be absent rather
    /// than an empty string that renders as "[]" in the About panel.
    func testCommitIsAbsentRatherThanEmpty() {
        if let commit = ImpressBuildInfo.commit {
            XCTAssertFalse(commit.isEmpty)
        }
    }
}
