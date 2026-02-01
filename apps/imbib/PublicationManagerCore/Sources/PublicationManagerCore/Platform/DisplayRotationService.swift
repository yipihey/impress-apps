//
//  DisplayRotationService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-31.
//

#if os(macOS)
import AppKit
import OSLog

/// Service for rotating displays using the displayplacer CLI tool.
///
/// displayplacer is a third-party utility that provides display configuration
/// capabilities not available through macOS public APIs.
///
/// Install via Homebrew: `brew install displayplacer`
///
/// This service is macOS-only as iOS does not support display rotation.
public actor DisplayRotationService {
    // MARK: - Singleton

    public static let shared = DisplayRotationService()

    // MARK: - Types

    /// Information about a connected display.
    public struct DisplayInfo: Sendable, Identifiable {
        public let id: String
        public let resolution: String
        public let hertz: Int
        public let colorDepth: Int
        public let scaling: Bool
        public let origin: String  // e.g., "(1728,468)"
        public let rotation: Int
        public let isMain: Bool
        public let enabled: Bool

        public var rotationLabel: String {
            switch rotation {
            case 0: return "0° (Landscape)"
            case 90: return "90° (Portrait Right)"
            case 180: return "180° (Landscape Flipped)"
            case 270: return "270° (Portrait Left)"
            default: return "\(rotation)°"
            }
        }

        /// Generate displayplacer argument string preserving all settings except rotation.
        /// Adjusts origin to keep the display center in the same logical position.
        func displayplacerArgument(withRotation newRotation: Int) -> String {
            var parts = ["id:\(id)"]
            parts.append("res:\(resolution)")
            parts.append("hz:\(hertz)")
            parts.append("color_depth:\(colorDepth)")
            parts.append("enabled:\(enabled)")
            parts.append("scaling:\(scaling ? "on" : "off")")

            // Calculate adjusted origin to keep center in same position
            let adjustedOrigin = calculateAdjustedOrigin(forRotation: newRotation)
            parts.append("origin:\(adjustedOrigin)")
            parts.append("degree:\(newRotation)")
            return parts.joined(separator: " ")
        }

        /// Calculate new origin to keep display center in same logical position after rotation.
        private func calculateAdjustedOrigin(forRotation newRotation: Int) -> String {
            // Parse current origin "(x,y)"
            let originClean = origin.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let coords = originClean.split(separator: ",")
            guard coords.count == 2,
                  let originX = Int(coords[0]),
                  let originY = Int(coords[1]) else {
                return origin // Return original if parsing fails
            }

            // Parse resolution "WxH"
            let resParts = resolution.split(separator: "x")
            guard resParts.count == 2,
                  let width = Int(resParts[0]),
                  let height = Int(resParts[1]) else {
                return origin
            }

            // Determine current dimensions based on current rotation
            let currentWidth: Int
            let currentHeight: Int
            if rotation == 90 || rotation == 270 {
                // Currently rotated - width/height are swapped from resolution
                currentWidth = height
                currentHeight = width
            } else {
                currentWidth = width
                currentHeight = height
            }

            // Calculate current center
            let centerX = originX + currentWidth / 2
            let centerY = originY + currentHeight / 2

            // Determine new dimensions based on new rotation
            let newWidth: Int
            let newHeight: Int
            if newRotation == 90 || newRotation == 270 {
                newWidth = height
                newHeight = width
            } else {
                newWidth = width
                newHeight = height
            }

            // Calculate new origin to keep center in same place
            let newOriginX = centerX - newWidth / 2
            let newOriginY = centerY - newHeight / 2

            return "(\(newOriginX),\(newOriginY))"
        }
    }

    /// Errors that can occur during rotation operations.
    public enum RotationError: LocalizedError {
        case sandboxed
        case displayplacerNotInstalled
        case displayNotFound
        case rotationFailed(String)
        case parseError(String)

        public var errorDescription: String? {
            switch self {
            case .sandboxed:
                return "Display rotation requires running outside the App Sandbox."
            case .displayplacerNotInstalled:
                return "displayplacer is not installed. Install via: brew install displayplacer"
            case .displayNotFound:
                return "Could not find the display to rotate."
            case .rotationFailed(let message):
                return "Failed to rotate display: \(message)"
            case .parseError(let message):
                return "Failed to parse display information: \(message)"
            }
        }
    }

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.imbib", category: "DisplayRotation")
    private var cachedDisplayplacerPath: String?

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Check if the app is running in a sandbox.
    public var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Check if displayplacer is installed and available.
    /// Returns false if sandboxed (can't execute external binaries).
    public func isAvailable() async -> Bool {
        if isSandboxed {
            logger.info("App is sandboxed - display rotation unavailable")
            return false
        }
        return await findDisplayplacerPath() != nil
    }

    /// Get the display ID for rotation.
    ///
    /// Prefers external displays over the built-in display since rotating
    /// the built-in display is rarely desired and may cause issues.
    @MainActor
    public func getDisplayID(for window: NSWindow?) async -> String? {
        do {
            let displays = try await parseDisplayList()

            guard !displays.isEmpty else {
                logger.warning("No displays found from displayplacer")
                return nil
            }

            // Prefer external display (non-main) for rotation
            if let external = displays.first(where: { !$0.isMain }) {
                logger.debug("Using external display for rotation: \(external.id)")
                return external.id
            }

            // Fall back to first display (likely built-in)
            logger.debug("No external display found, using: \(displays[0].id)")
            return displays.first?.id

        } catch {
            logger.error("Failed to get display ID: \(error.localizedDescription)")
            return nil
        }
    }

    /// Get current rotation for a display (0, 90, 180, or 270).
    public func getRotation(displayID: String) async -> Int {
        do {
            let displays = try await parseDisplayList()
            return displays.first { $0.id == displayID }?.rotation ?? 0
        } catch {
            logger.error("Failed to get rotation: \(error.localizedDescription)")
            return 0
        }
    }

    /// Get all connected displays.
    public func getDisplays() async throws -> [DisplayInfo] {
        try await parseDisplayList()
    }

    /// Set rotation for a display, preserving all other display settings (resolution, position, etc.).
    ///
    /// - Parameters:
    ///   - displayID: The display ID from displayplacer.
    ///   - degrees: Rotation in degrees (0, 90, 180, or 270).
    public func setRotation(displayID: String, degrees: Int) async throws {
        guard let path = await findDisplayplacerPath() else {
            throw RotationError.displayplacerNotInstalled
        }

        // Validate degrees
        let validDegrees = [0, 90, 180, 270]
        guard validDegrees.contains(degrees) else {
            throw RotationError.rotationFailed("Invalid rotation: \(degrees). Must be 0, 90, 180, or 270.")
        }

        // Get current display configuration to preserve all settings
        let displays = try await parseDisplayList()
        guard let display = displays.first(where: { $0.id == displayID }) else {
            throw RotationError.displayNotFound
        }

        logger.info("Setting display \(displayID) rotation to \(degrees)° (preserving origin: \(display.origin))")

        // Build full argument preserving all settings except rotation
        let argument = display.displayplacerArgument(withRotation: degrees)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [argument]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw RotationError.rotationFailed(errorString.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            logger.info("Successfully rotated display \(displayID) to \(degrees)°")

        } catch let error as RotationError {
            throw error
        } catch {
            throw RotationError.rotationFailed(error.localizedDescription)
        }
    }

    /// Cycle rotation to the next orientation (0 → 90 → 180 → 270 → 0).
    public func cycleRotation(displayID: String) async throws {
        let current = await getRotation(displayID: displayID)
        let next = (current + 90) % 360
        try await setRotation(displayID: displayID, degrees: next)
    }

    // MARK: - Private Methods

    /// Find the path to displayplacer executable.
    private func findDisplayplacerPath() async -> String? {
        if let cached = cachedDisplayplacerPath {
            return cached
        }

        // Common paths where displayplacer might be installed
        let searchPaths = [
            "/opt/homebrew/bin/displayplacer",    // Apple Silicon Homebrew
            "/usr/local/bin/displayplacer",       // Intel Homebrew
            "/opt/local/bin/displayplacer"        // MacPorts
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                cachedDisplayplacerPath = path
                logger.debug("Found displayplacer at: \(path)")
                return path
            }
        }

        // Try `which` as fallback
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["displayplacer"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    cachedDisplayplacerPath = path
                    logger.debug("Found displayplacer via which: \(path)")
                    return path
                }
            }
        } catch {
            logger.debug("which displayplacer failed: \(error.localizedDescription)")
        }

        logger.info("displayplacer not found - display rotation unavailable")
        return nil
    }

    /// Parse output from `displayplacer list` to get display information.
    private func parseDisplayList() async throws -> [DisplayInfo] {
        guard let path = await findDisplayplacerPath() else {
            throw RotationError.displayplacerNotInstalled
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["list"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw RotationError.parseError(errorString)
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: outputData, encoding: .utf8) else {
                throw RotationError.parseError("Invalid output encoding")
            }

            return parseDisplayplacerOutput(output)

        } catch let error as RotationError {
            throw error
        } catch {
            throw RotationError.parseError(error.localizedDescription)
        }
    }

    /// Parse the displayplacer list output format.
    ///
    /// Example output:
    /// ```
    /// Persistent screen id: 37D8832A-2D66-02CA-B9F7-8F30A301B230
    /// Contextual screen id: 1
    /// Serial screen id: s4251086178
    /// Type: 27 inch external screen
    /// Resolution: 2560x1440
    /// Hertz: 60
    /// Color Depth: 8
    /// Scaling: off
    /// Origin: (0,0) - main display
    /// Rotation: 0
    /// ```
    private func parseDisplayplacerOutput(_ output: String) -> [DisplayInfo] {
        var displays: [DisplayInfo] = []
        var currentID: String?
        var currentResolution: String?
        var currentHertz: Int = 60
        var currentColorDepth: Int = 8
        var currentScaling: Bool = false
        var currentOrigin: String = "(0,0)"
        var currentRotation: Int = 0
        var currentEnabled: Bool = true
        var isMain = false

        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Persistent screen id:") {
                // Save previous display if complete
                if let id = currentID, let resolution = currentResolution {
                    displays.append(DisplayInfo(
                        id: id,
                        resolution: resolution,
                        hertz: currentHertz,
                        colorDepth: currentColorDepth,
                        scaling: currentScaling,
                        origin: currentOrigin,
                        rotation: currentRotation,
                        isMain: isMain,
                        enabled: currentEnabled
                    ))
                }

                // Start new display with defaults
                currentID = trimmed.replacingOccurrences(of: "Persistent screen id:", with: "").trimmingCharacters(in: .whitespaces)
                currentResolution = nil
                currentHertz = 60
                currentColorDepth = 8
                currentScaling = false
                currentOrigin = "(0,0)"
                currentRotation = 0
                currentEnabled = true
                isMain = false

            } else if trimmed.hasPrefix("Resolution:") {
                currentResolution = trimmed.replacingOccurrences(of: "Resolution:", with: "").trimmingCharacters(in: .whitespaces)

            } else if trimmed.hasPrefix("Hertz:") {
                let hertzStr = trimmed.replacingOccurrences(of: "Hertz:", with: "").trimmingCharacters(in: .whitespaces)
                currentHertz = Int(hertzStr) ?? 60

            } else if trimmed.hasPrefix("Color Depth:") {
                let depthStr = trimmed.replacingOccurrences(of: "Color Depth:", with: "").trimmingCharacters(in: .whitespaces)
                currentColorDepth = Int(depthStr) ?? 8

            } else if trimmed.hasPrefix("Scaling:") {
                let scalingStr = trimmed.replacingOccurrences(of: "Scaling:", with: "").trimmingCharacters(in: .whitespaces).lowercased()
                currentScaling = scalingStr == "on"

            } else if trimmed.hasPrefix("Origin:") {
                // Handle "Origin: (1728,468)" or "Origin: (0,0) - main display"
                let originPart = trimmed.replacingOccurrences(of: "Origin:", with: "").trimmingCharacters(in: .whitespaces)
                // Extract just the coordinates part (before any dash)
                if let parenEnd = originPart.firstIndex(of: ")") {
                    currentOrigin = String(originPart[...parenEnd])
                }
                if originPart.contains("main display") {
                    isMain = true
                }

            } else if trimmed.hasPrefix("Enabled:") {
                let enabledStr = trimmed.replacingOccurrences(of: "Enabled:", with: "").trimmingCharacters(in: .whitespaces).lowercased()
                currentEnabled = enabledStr == "true"

            } else if trimmed.hasPrefix("Rotation:") {
                // Handle "Rotation: 0" or "Rotation: 0 - some extra text..."
                let rotationPart = trimmed.replacingOccurrences(of: "Rotation:", with: "").trimmingCharacters(in: .whitespaces)
                // Extract just the first number (before any dash or space with text)
                let rotationStr = rotationPart.components(separatedBy: CharacterSet(charactersIn: " -")).first ?? rotationPart
                currentRotation = Int(rotationStr) ?? 0
            }
        }

        // Don't forget the last display
        if let id = currentID, let resolution = currentResolution {
            displays.append(DisplayInfo(
                id: id,
                resolution: resolution,
                hertz: currentHertz,
                colorDepth: currentColorDepth,
                scaling: currentScaling,
                origin: currentOrigin,
                rotation: currentRotation,
                isMain: isMain,
                enabled: currentEnabled
            ))
        }

        logger.debug("Parsed \(displays.count) displays from displayplacer output")
        return displays
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when display rotation changes.
    static let displayRotationDidChange = Notification.Name("displayRotationDidChange")
}

#endif
