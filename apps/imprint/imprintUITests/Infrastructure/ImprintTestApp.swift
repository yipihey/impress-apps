//
//  ImprintTestApp.swift
//  imprintUITests
//
//  App launcher specifically configured for imprint UI tests.
//

import XCTest
import ImpressTestKit

/// Test app launch configuration specific to imprint
enum ImprintTestApp {

    // MARK: - Launch Arguments

    /// Launch argument to skip onboarding
    static let skipOnboardingArg = "--skip-onboarding"

    /// Launch argument to use sample document
    static let sampleDocumentArg = "--sample-document"

    // MARK: - Launch Methods

    /// Launch imprint with default test configuration
    @discardableResult
    static func launch(
        resetState: Bool = true,
        mockServices: Bool = true,
        skipOnboarding: Bool = true,
        sampleDocument: Bool = false
    ) -> XCUIApplication {
        var additionalArgs: [String] = []

        if skipOnboarding {
            additionalArgs.append(skipOnboardingArg)
        }

        if sampleDocument {
            additionalArgs.append(sampleDocumentArg)
        }

        return TestApp.launch(
            resetState: resetState,
            mockServices: mockServices,
            accessibilityEnabled: false,
            additionalArguments: additionalArgs
        )
    }

    /// Launch imprint for accessibility testing
    @discardableResult
    static func launchForAccessibility() -> XCUIApplication {
        return TestApp.launchForAccessibility()
    }

    /// Launch imprint with a sample document loaded
    @discardableResult
    static func launchWithSampleDocument() -> XCUIApplication {
        return launch(sampleDocument: true)
    }

    /// Launch imprint with compiled PDF available
    @discardableResult
    static func launchWithCompiledDocument() -> XCUIApplication {
        let app = launch(sampleDocument: true)
        // Wait for document to load
        _ = app.waitForIdle()

        // Compile the document
        app.typeKey("b", modifierFlags: .command)

        // Wait for compilation
        let compileButton = app[ImprintAccessibilityID.Toolbar.compileButton]
        _ = compileButton.waitForExistence(timeout: 5)

        return app
    }
}

// MARK: - Test Data Sets

/// Predefined test data sets for imprint
enum ImprintTestDataSet: String {
    /// Empty document
    case empty = "empty"

    /// Simple Typst document
    case simple = "simple"

    /// Document with citations
    case withCitations = "with-citations"

    /// Long document for performance tests
    case long = "long"

    /// Document with errors
    case withErrors = "with-errors"
}
