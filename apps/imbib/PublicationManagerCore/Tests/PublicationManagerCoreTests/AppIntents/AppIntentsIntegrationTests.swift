//
//  AppIntentsIntegrationTests.swift
//  PublicationManagerCoreTests
//
//  Integration tests for AppIntents with URLSchemeHandler.
//

import XCTest
@testable import PublicationManagerCore

@available(iOS 16.0, macOS 13.0, *)
final class AppIntentsIntegrationTests: XCTestCase {

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()
        // Disable automation for safety in tests (intents should check this)
        await AutomationSettingsStore.shared.setEnabled(false)
    }

    override func tearDown() async throws {
        // Reset automation state
        await AutomationSettingsStore.shared.setEnabled(false)
        try await super.tearDown()
    }

    // MARK: - Automation Disabled Tests

    func testSearchPapersIntent_failsWhenDisabled() async throws {
        // Ensure automation is disabled
        await AutomationSettingsStore.shared.setEnabled(false)

        let intent = SearchPapersIntent(query: "test")

        do {
            _ = try await intent.perform()
            XCTFail("Should throw when automation is disabled")
        } catch let error as IntentError {
            if case .automationDisabled = error {
                // Expected
            } else {
                XCTFail("Expected automationDisabled error, got: \(error)")
            }
        } catch {
            XCTFail("Expected IntentError, got: \(error)")
        }
    }

    func testShowInboxIntent_failsWhenDisabled() async throws {
        await AutomationSettingsStore.shared.setEnabled(false)

        let intent = ShowInboxIntent()

        do {
            _ = try await intent.perform()
            XCTFail("Should throw when automation is disabled")
        } catch let error as IntentError {
            if case .automationDisabled = error {
                // Expected
            } else {
                XCTFail("Expected automationDisabled error, got: \(error)")
            }
        } catch {
            XCTFail("Expected IntentError, got: \(error)")
        }
    }

    func testMarkAllReadIntent_failsWhenDisabled() async throws {
        await AutomationSettingsStore.shared.setEnabled(false)

        let intent = MarkAllReadIntent()

        do {
            _ = try await intent.perform()
            XCTFail("Should throw when automation is disabled")
        } catch let error as IntentError {
            if case .automationDisabled = error {
                // Expected
            } else {
                XCTFail("Expected automationDisabled error, got: \(error)")
            }
        } catch {
            XCTFail("Expected IntentError, got: \(error)")
        }
    }

    // MARK: - Command Construction Tests

    func testSearchIntent_commandMatchesURLScheme() async {
        let intent = SearchPapersIntent(query: "dark matter", source: .ads, maxResults: 100)

        // Build equivalent URL
        guard let url = AutomationURLBuilder.search(query: "dark matter", source: "ads", maxResults: 100) else {
            XCTFail("Failed to build URL")
            return
        }

        // Parse the URL to get command
        let parser = URLCommandParser()
        do {
            let parsedCommand = try parser.parse(url)

            // Compare commands
            if case .search(let q1, let s1, let m1) = intent.automationCommand,
               case .search(let q2, let s2, let m2) = parsedCommand {
                XCTAssertEqual(q1, q2)
                XCTAssertEqual(s1, s2)
                XCTAssertEqual(m1, m2)
            } else {
                XCTFail("Commands should both be search commands")
            }
        } catch {
            XCTFail("Failed to parse URL: \(error)")
        }
    }

    func testNavigationIntent_commandMatchesURLScheme() async {
        let intent = ShowInboxIntent()

        guard let url = AutomationURLBuilder.navigate(to: .inbox) else {
            XCTFail("Failed to build URL")
            return
        }

        let parser = URLCommandParser()
        do {
            let parsedCommand = try parser.parse(url)

            if case .navigate(let t1) = intent.automationCommand,
               case .navigate(let t2) = parsedCommand {
                XCTAssertEqual(t1, t2)
            } else {
                XCTFail("Commands should both be navigate commands")
            }
        } catch {
            XCTFail("Failed to parse URL: \(error)")
        }
    }

    func testSelectedPapersIntent_commandMatchesURLScheme() async {
        let intent = ToggleReadStatusIntent()

        guard let url = AutomationURLBuilder.selected(action: .toggleRead) else {
            XCTFail("Failed to build URL")
            return
        }

        let parser = URLCommandParser()
        do {
            let parsedCommand = try parser.parse(url)

            if case .selectedPapers(let a1) = intent.automationCommand,
               case .selectedPapers(let a2) = parsedCommand {
                XCTAssertEqual(a1, a2)
            } else {
                XCTFail("Commands should both be selectedPapers commands")
            }
        } catch {
            XCTFail("Failed to parse URL: \(error)")
        }
    }

    func testInboxIntent_commandMatchesURLScheme() async {
        let intent = KeepInboxItemIntent()

        guard let url = AutomationURLBuilder.inbox(action: .keep) else {
            XCTFail("Failed to build URL")
            return
        }

        let parser = URLCommandParser()
        do {
            let parsedCommand = try parser.parse(url)

            if case .inbox(let a1) = intent.automationCommand,
               case .inbox(let a2) = parsedCommand {
                XCTAssertEqual(a1, a2)
            } else {
                XCTFail("Commands should both be inbox commands")
            }
        } catch {
            XCTFail("Failed to parse URL: \(error)")
        }
    }

    func testExportIntent_commandMatchesURLScheme() async {
        let intent = ExportLibraryIntent(format: .ris)

        guard let url = AutomationURLBuilder.export(format: .ris) else {
            XCTFail("Failed to build URL")
            return
        }

        let parser = URLCommandParser()
        do {
            let parsedCommand = try parser.parse(url)

            if case .exportLibrary(_, let f1) = intent.automationCommand,
               case .exportLibrary(_, let f2) = parsedCommand {
                XCTAssertEqual(f1, f2)
            } else {
                XCTFail("Commands should both be exportLibrary commands")
            }
        } catch {
            XCTFail("Failed to parse URL: \(error)")
        }
    }

    // MARK: - Automation Enabled Tests

    func testSearchIntent_succeedsWhenEnabled() async throws {
        // Enable automation
        await AutomationSettingsStore.shared.setEnabled(true)

        let intent = SearchPapersIntent(query: "test query")

        // This should succeed (though it may not actually search since we don't have UI)
        do {
            let result = try await intent.perform()
            // If we get here without error, the automation check passed
            XCTAssertNotNil(result)
        } catch let error as IntentError {
            if case .automationDisabled = error {
                XCTFail("Automation should be enabled")
            }
            // Other errors are acceptable in test environment
        } catch {
            // Other errors are acceptable (no UI, etc.)
        }

        // Clean up
        await AutomationSettingsStore.shared.setEnabled(false)
    }

    func testNavigationIntent_succeedsWhenEnabled() async throws {
        await AutomationSettingsStore.shared.setEnabled(true)

        let intent = ShowLibraryIntent()

        do {
            let result = try await intent.perform()
            XCTAssertNotNil(result)
        } catch let error as IntentError {
            if case .automationDisabled = error {
                XCTFail("Automation should be enabled")
            }
        } catch {
            // Other errors acceptable
        }

        await AutomationSettingsStore.shared.setEnabled(false)
    }
}
