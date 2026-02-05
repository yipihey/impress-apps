//
//  LogCapture.swift
//  ImpressLogging
//
//  Shared OSLog capture methods and global logging convenience functions.
//  These bridge OSLog output to the in-app LogStore for console display.
//

import Foundation
import OSLog

/// Default logger used by global convenience functions.
/// Apps define their own Logger categories with app-specific subsystems.
private let defaultLogger = Logger(subsystem: "com.impress", category: "app")
private let timingLogger = Logger(subsystem: "com.impress", category: "performance")

// MARK: - Capturing Log Methods

public extension Logger {

    /// Log debug message and capture to LogStore
    func debugCapture(_ message: String, category: String) {
        debug("\(message)")
        captureToStore(level: .debug, category: category, message: message)
    }

    /// Log info message and capture to LogStore
    func infoCapture(_ message: String, category: String) {
        info("\(message)")
        captureToStore(level: .info, category: category, message: message)
    }

    /// Log warning message and capture to LogStore
    func warningCapture(_ message: String, category: String) {
        warning("\(message)")
        captureToStore(level: .warning, category: category, message: message)
    }

    /// Log error message and capture to LogStore
    func errorCapture(_ message: String, category: String) {
        error("\(message)")
        captureToStore(level: .error, category: category, message: message)
    }

    private func captureToStore(level: LogLevel, category: String, message: String) {
        Task { @MainActor in
            LogStore.shared.log(level: level, category: category, message: message)
        }
    }
}

// MARK: - Convenience Methods

public extension Logger {

    func entering(function: String = #function, category: String = "trace") {
        debugCapture("→ \(function)", category: category)
    }

    func exiting(function: String = #function, category: String = "trace") {
        debugCapture("← \(function)", category: category)
    }

    func httpRequest(_ method: String, url: URL) {
        infoCapture("HTTP \(method) \(url.absoluteString)", category: "network")
    }

    func httpResponse(_ statusCode: Int, url: URL, bytes: Int? = nil) {
        if let bytes = bytes {
            infoCapture("HTTP \(statusCode) \(url.absoluteString) (\(bytes) bytes)", category: "network")
        } else {
            infoCapture("HTTP \(statusCode) \(url.absoluteString)", category: "network")
        }
    }
}

// MARK: - Performance Timing

public extension Logger {

    /// Log a performance timing measurement
    func timing(_ operation: String, milliseconds: Double, count: Int? = nil) {
        let ms = String(format: "%.1f", milliseconds)
        if let count = count {
            infoCapture("⏱ \(operation): \(ms)ms (\(count) items)", category: "performance")
        } else {
            infoCapture("⏱ \(operation): \(ms)ms", category: "performance")
        }
    }
}

// MARK: - Global Logging Functions

/// Convenience functions for logging with automatic capture

public func logDebug(_ message: String, category: String = "app") {
    defaultLogger.debugCapture(message, category: category)
}

public func logInfo(_ message: String, category: String = "app") {
    defaultLogger.infoCapture(message, category: category)
}

public func logWarning(_ message: String, category: String = "app") {
    defaultLogger.warningCapture(message, category: category)
}

public func logError(_ message: String, category: String = "app") {
    defaultLogger.errorCapture(message, category: category)
}

// MARK: - Performance Measurement

/// Measure execution time of a synchronous block
public func measureTime<T>(_ operation: String, count: Int? = nil, _ block: () -> T) -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = block()
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    timingLogger.timing(operation, milliseconds: elapsed, count: count)
    return result
}

/// Measure execution time of an async block
public func measureTimeAsync<T>(_ operation: String, count: Int? = nil, _ block: () async -> T) async -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = await block()
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    timingLogger.timing(operation, milliseconds: elapsed, count: count)
    return result
}
