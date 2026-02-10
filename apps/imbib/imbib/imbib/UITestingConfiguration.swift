//
//  UITestingConfiguration.swift
//  imbib
//
//  Stub for UI testing support. Reads launch arguments to configure test state.
//

import Foundation
import OSLog

enum UITestingConfiguration {
    private static let logger = Logger(subsystem: "com.imbib.app", category: "uitesting")

    /// Whether the app was launched in UI testing mode.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    /// Whether to reset state on launch (for clean-slate tests).
    static var shouldResetState: Bool {
        ProcessInfo.processInfo.arguments.contains("--reset-state")
    }

    /// Log the current UI testing configuration.
    static func logConfiguration() {
        logger.info("UI Testing mode active. resetState=\(shouldResetState)")
    }

    /// Seed test data if the --seed-test-data flag is present.
    static func seedTestDataIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("--seed-test-data") else { return }
        logger.info("UI Testing: seed test data requested (not yet implemented)")
    }
}
