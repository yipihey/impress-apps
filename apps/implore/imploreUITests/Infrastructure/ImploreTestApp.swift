//
//  ImploreTestApp.swift
//  imploreUITests
//
//  App launcher specifically configured for implore UI tests.
//

import XCTest
import ImpressTestKit

/// Test app launch configuration specific to implore
enum ImploreTestApp {

    // MARK: - Launch Arguments

    /// Launch argument to skip welcome screen
    static let skipWelcomeArg = "--skip-welcome"

    /// Launch argument to load sample dataset
    static let sampleDatasetArg = "--sample-dataset"

    // MARK: - Launch Methods

    /// Launch implore with default test configuration
    @discardableResult
    static func launch(
        resetState: Bool = true,
        mockServices: Bool = true,
        skipWelcome: Bool = false,
        sampleDataset: Bool = false
    ) -> XCUIApplication {
        var additionalArgs: [String] = []

        if skipWelcome {
            additionalArgs.append(skipWelcomeArg)
        }

        if sampleDataset {
            additionalArgs.append(sampleDatasetArg)
        }

        return TestApp.launch(
            resetState: resetState,
            mockServices: mockServices,
            accessibilityEnabled: false,
            additionalArguments: additionalArgs
        )
    }

    /// Launch implore for accessibility testing
    @discardableResult
    static func launchForAccessibility() -> XCUIApplication {
        return TestApp.launchForAccessibility()
    }

    /// Launch implore with a sample dataset loaded
    @discardableResult
    static func launchWithSampleDataset() -> XCUIApplication {
        return launch(skipWelcome: true, sampleDataset: true)
    }

    /// Launch implore showing welcome screen
    @discardableResult
    static func launchWithWelcomeScreen() -> XCUIApplication {
        return launch(skipWelcome: false, sampleDataset: false)
    }
}

// MARK: - Test Data Sets

/// Predefined test data sets for implore
enum ImploreTestDataSet: String {
    /// No dataset - shows welcome screen
    case none = "none"

    /// Small CSV dataset
    case smallCSV = "small-csv"

    /// Large dataset for performance tests
    case large = "large"

    /// 3D dataset
    case threeDimensional = "3d"

    /// Dataset with many fields
    case manyFields = "many-fields"
}
