//
//  AutomationSettingsTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-09.
//

import XCTest
@testable import PublicationManagerCore

final class AutomationSettingsTests: XCTestCase {

    // MARK: - Default Settings

    func testDefaultSettings_disabledByDefault() {
        let settings = AutomationSettings.default
        XCTAssertFalse(settings.isEnabled)
    }

    func testDefaultSettings_loggingEnabledByDefault() {
        let settings = AutomationSettings.default
        XCTAssertTrue(settings.logRequests)
    }

    // MARK: - Initialization

    func testInit_customValues() {
        let settings = AutomationSettings(isEnabled: true, logRequests: false)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertFalse(settings.logRequests)
    }

    // MARK: - Equatable

    func testEquatable_equalSettings() {
        let settings1 = AutomationSettings(isEnabled: true, logRequests: true)
        let settings2 = AutomationSettings(isEnabled: true, logRequests: true)
        XCTAssertEqual(settings1, settings2)
    }

    func testEquatable_differentEnabled() {
        let settings1 = AutomationSettings(isEnabled: true, logRequests: true)
        let settings2 = AutomationSettings(isEnabled: false, logRequests: true)
        XCTAssertNotEqual(settings1, settings2)
    }

    func testEquatable_differentLogging() {
        let settings1 = AutomationSettings(isEnabled: true, logRequests: true)
        let settings2 = AutomationSettings(isEnabled: true, logRequests: false)
        XCTAssertNotEqual(settings1, settings2)
    }

    // MARK: - Codable

    func testCodable_roundTrip() throws {
        let original = AutomationSettings(isEnabled: true, logRequests: false)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AutomationSettings.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    func testCodable_jsonFormat() throws {
        let settings = AutomationSettings(isEnabled: true, logRequests: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(settings)
        let json = String(data: data, encoding: .utf8)

        XCTAssertEqual(json, #"{"isEnabled":true,"logRequests":true}"#)
    }

    // MARK: - AutomationResult

    func testAutomationResult_success() {
        let result = AutomationResult.success(command: "search")
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.command, "search")
        XCTAssertNil(result.error)
    }

    func testAutomationResult_successWithResult() {
        let result = AutomationResult.success(
            command: "search",
            result: ["count": AnyCodable(42)]
        )
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.command, "search")
        XCTAssertNotNil(result.result)
        XCTAssertEqual(result.result?["count"]?.value as? Int, 42)
    }

    func testAutomationResult_failure() {
        let result = AutomationResult.failure(command: "import", error: "File not found")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.command, "import")
        XCTAssertEqual(result.error, "File not found")
    }

    // MARK: - AnyCodable

    func testAnyCodable_string() throws {
        let original = AnyCodable("hello")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? String, "hello")
    }

    func testAnyCodable_int() throws {
        let original = AnyCodable(42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Int, 42)
    }

    func testAnyCodable_double() throws {
        let original = AnyCodable(3.14)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Double, 3.14)
    }

    func testAnyCodable_bool() throws {
        let original = AnyCodable(true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Bool, true)
    }

    func testAnyCodable_array() throws {
        let original = AnyCodable([1, 2, 3])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? [Int], [1, 2, 3])
    }

    func testAnyCodable_dictionary() throws {
        let original = AnyCodable(["key": "value"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual((decoded.value as? [String: String])?["key"], "value")
    }

    // MARK: - AutomationError

    func testAutomationError_disabled() {
        let error = AutomationError.disabled
        XCTAssertTrue(error.localizedDescription.contains("disabled"))
    }

    func testAutomationError_invalidScheme() {
        let error = AutomationError.invalidScheme("http")
        XCTAssertTrue(error.localizedDescription.contains("http"))
        XCTAssertTrue(error.localizedDescription.contains("imbib"))
    }

    func testAutomationError_missingCommand() {
        let error = AutomationError.missingCommand
        XCTAssertTrue(error.localizedDescription.contains("Missing"))
    }

    func testAutomationError_unknownCommand() {
        let error = AutomationError.unknownCommand("test")
        XCTAssertTrue(error.localizedDescription.contains("test"))
    }

    func testAutomationError_missingParameter() {
        let error = AutomationError.missingParameter("query")
        XCTAssertTrue(error.localizedDescription.contains("query"))
    }

    func testAutomationError_invalidParameter() {
        let error = AutomationError.invalidParameter("format", "xyz")
        XCTAssertTrue(error.localizedDescription.contains("format"))
        XCTAssertTrue(error.localizedDescription.contains("xyz"))
    }

    func testAutomationError_paperNotFound() {
        let error = AutomationError.paperNotFound("Einstein1905")
        XCTAssertTrue(error.localizedDescription.contains("Einstein1905"))
    }
}
