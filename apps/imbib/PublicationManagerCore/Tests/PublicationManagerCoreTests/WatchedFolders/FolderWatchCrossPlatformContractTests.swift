//
//  FolderWatchCrossPlatformContractTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 D6 + the chassis split rule — the STRUCTURAL half.
//
//  A macOS test cannot prove "compiles on iOS"; the imbib-iOS build does that.
//  What a macOS test CAN prove is that nobody re-gated a contract file, which
//  is the failure mode `ChassisCrossPlatformContractTests` was written for and
//  which the watched-folder surface is unusually exposed to: it is a
//  macOS-first feature (D6), so the reflex when something does not compile on
//  iOS will be to wrap the file rather than to split it.
//
//  Deliberately its own suite rather than three new lines in
//  `ChassisCrossPlatformContractTests`: that file is a shared seam and W0 is
//  editing the same tree. The assertions are the same shape and use the same
//  `ChassisSourceRoots` resolver.
//
//  Deliberately NOT `#if os(macOS)`-gated itself: it is a test ABOUT the
//  cross-platform contract.
//

import XCTest

@testable import PublicationManagerCore

final class FolderWatchCrossPlatformContractTests: XCTestCase {

    /// Data and policy. iOS links every one of these: the filters, the states,
    /// the row model, the batching, the bookmark store and the service's own
    /// policy compile and run there, and iOS gets a service that answers
    /// `scanOnDemand` honestly instead of a service that does not exist.
    private static let crossPlatformFiles = [
        "Chassis/WatchedFolders/FileDiscoveryFilter.swift",
        "Chassis/WatchedFolders/WatchedFolderState.swift",
        "Chassis/WatchedFolders/WatchedFolderTypes.swift",
        "Chassis/WatchedFolders/WatchedFolderRowState.swift",
        "Chassis/WatchedFolders/DirectoryScanner.swift",
        "Chassis/WatchedFolders/SpotlightAvailabilityProbe.swift",
        "Chassis/WatchedFolders/WatchedFolderBookmarkStore.swift",
        "Chassis/WatchedFolders/FolderDiscoveryEngine.swift",
        "Chassis/WatchedFolders/FolderWatchService.swift",
    ]

    /// The two files that genuinely link a macOS-only API. The split is only
    /// worth anything if the macOS half really is separate.
    private static let gatedFiles = [
        "Chassis/WatchedFolders/FolderDiscoveryEngine+Spotlight.swift",
        "Chassis/WatchedFolders/FSEventsDirectoryWatcher.swift",
        "Chassis/WatchedFolders/CompositeFolderDiscoveryEngine.swift",
    ]

    func testTheDataAndPolicyFilesAreNotWrappedInAMacOSGate() throws {
        for relativePath in Self.crossPlatformFiles {
            let text = try ChassisSourceRoots.text(of: relativePath)
            let firstCode = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(String.init) ?? ""
            XCTAssertFalse(
                firstCode.hasPrefix("#if os(macOS)"),
                """
                \(relativePath) is wrapped in `#if os(macOS)`. ADR-0023 D6 makes the \
                ENGINES macOS-only, not the vocabulary: iOS still renders watched-folder \
                rows, still persists bookmarks and still reports `scanOnDemand`. If a \
                genuinely macOS-only symbol landed here, SPLIT the file the way \
                FolderDiscoveryEngine+Spotlight.swift is split.
                """)
        }
    }

    func testThePlatformEnginesStayGated() throws {
        for relativePath in Self.gatedFiles {
            let text = try ChassisSourceRoots.text(of: relativePath)
            XCTAssertTrue(
                text.hasPrefix("#if os(macOS)"),
                "\(relativePath) must stay macOS-gated; if it stopped being gated, "
                    + "NSMetadataQuery or FSEvents leaked onto iOS")
        }
    }

    func testTheCrossPlatformFilesNameNoMacOSOnlyAPI() throws {
        // A cheaper, earlier signal than the iOS build: these symbols cannot
        // appear outside a gated companion.
        let forbidden = ["NSMetadataQuery", "FSEventStream", "import AppKit", "import CoreServices"]
        for relativePath in Self.crossPlatformFiles {
            let text = try ChassisSourceRoots.text(of: relativePath)
            // Comments legitimately discuss both engines by name, so only look
            // at lines that are not comments.
            let code = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter {
                    let trimmed = $0.trimmingCharacters(in: .whitespaces)
                    return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
                        && !trimmed.hasPrefix("*")
                }
                .joined(separator: "\n")
            for symbol in forbidden {
                XCTAssertFalse(
                    code.contains(symbol),
                    "\(relativePath) names \(symbol) outside a comment; it belongs in a "
                        + "gated companion")
            }
        }
    }

    /// The behavioural half: the vocabulary resolves without any engine.
    func testTheVocabularyResolvesWithNoEngineAtAll() async {
        let service = await FolderWatchService(
            bookmarks: WatchedFolderBookmarkStore(
                userDefaults: UserDefaults(suiteName: "test.contract.\(UUID().uuidString)")!,
                broker: .scratch()),
            engines: .none,
            startupGate: .immediate)
        let registration = WatchedFolderRegistration(
            url: FileManager.default.temporaryDirectory,
            filters: [FileDiscoveryFilter(id: "bibtex", filenameExtensions: ["bib"])])
        let row = await service.add(registration)

        XCTAssertEqual(row.displayName, registration.displayName)
        XCTAssertEqual(row.state, .scanOnDemand)
        XCTAssertNotNil(row.sidebarNode(kind: .publication).id)
    }
}
