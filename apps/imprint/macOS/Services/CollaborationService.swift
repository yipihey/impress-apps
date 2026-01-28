//
//  CollaborationService.swift
//  imprint
//
//  Manages real-time collaboration state and presence tracking.
//  Bridges the Rust Automerge CRDT backend with Swift UI.
//

import Foundation
import SwiftUI
import Combine

// MARK: - Collaborator Presence

/// Represents a collaborator's presence in the document
public struct CollaboratorPresence: Identifiable, Equatable {
    public let id: String  // peer_id
    public var displayName: String
    public var cursorPosition: Int?
    public var selection: (start: Int, end: Int)?
    public var color: Color
    public var lastActive: Date
    public var isOnline: Bool

    public init(
        id: String,
        displayName: String,
        cursorPosition: Int? = nil,
        selection: (start: Int, end: Int)? = nil,
        color: Color,
        lastActive: Date = Date(),
        isOnline: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.cursorPosition = cursorPosition
        self.selection = selection
        self.color = color
        self.lastActive = lastActive
        self.isOnline = isOnline
    }

    public static func == (lhs: CollaboratorPresence, rhs: CollaboratorPresence) -> Bool {
        lhs.id == rhs.id &&
        lhs.displayName == rhs.displayName &&
        lhs.cursorPosition == rhs.cursorPosition &&
        lhs.selection?.start == rhs.selection?.start &&
        lhs.selection?.end == rhs.selection?.end &&
        lhs.isOnline == rhs.isOnline
    }
}

// MARK: - Collaboration Service

/// Service for managing real-time collaboration and presence.
///
/// Features:
/// - Track connected collaborators
/// - Broadcast local cursor/selection changes
/// - Receive remote presence updates
/// - Manage connection state
@MainActor
public final class CollaborationService: ObservableObject {

    // MARK: - Singleton

    public static let shared = CollaborationService()

    // MARK: - Published State

    /// Current collaborators in the session
    @Published public private(set) var collaborators: [CollaboratorPresence] = []

    /// Whether currently connected to a collaboration session
    @Published public private(set) var isConnected = false

    /// Connection status message
    @Published public private(set) var connectionStatus: ConnectionStatus = .disconnected

    /// Local user's peer ID
    @Published public private(set) var localPeerId: String = UUID().uuidString

    /// Local user's display name
    @AppStorage("collaboration.displayName") public var localDisplayName: String = NSFullUserName()

    /// Local user's cursor color
    @AppStorage("collaboration.cursorColor") private var cursorColorHex: String = "#8B5CF6"

    // MARK: - Private State

    private var presenceUpdateTimer: Timer?
    private var connectionTask: Task<Void, Never>?

    /// Predefined colors for collaborators
    private let collaboratorColors: [Color] = [
        .purple, .blue, .green, .orange, .pink, .teal, .indigo, .mint
    ]

    // MARK: - Initialization

    private init() {
        // Generate a stable peer ID based on device
        if let deviceId = getDeviceIdentifier() {
            localPeerId = deviceId
        }
    }

    // MARK: - Connection Management

    /// Connect to a collaboration session
    public func connect(documentId: String, serverUrl: String? = nil) async {
        connectionStatus = .connecting

        // TODO: Integrate with Rust collaboration backend
        // For now, simulate connection
        try? await Task.sleep(nanoseconds: 500_000_000)

        isConnected = true
        connectionStatus = .connected

        // Start presence heartbeat
        startPresenceHeartbeat()

        // Simulate some collaborators for demo
        addDemoCollaborators()
    }

    /// Disconnect from the collaboration session
    public func disconnect() {
        connectionTask?.cancel()
        presenceUpdateTimer?.invalidate()
        presenceUpdateTimer = nil

        collaborators.removeAll()
        isConnected = false
        connectionStatus = .disconnected
    }

    // MARK: - Presence Updates

    /// Update local cursor position (broadcasts to collaborators)
    public func updateLocalCursor(position: Int, selection: (Int, Int)? = nil) {
        guard isConnected else { return }

        // TODO: Send to Rust backend for broadcast
        // For now, this is a placeholder
        broadcastPresence(cursorPosition: position, selection: selection)
    }

    /// Receive presence update from a remote collaborator
    public func receivePresenceUpdate(
        peerId: String,
        displayName: String,
        cursorPosition: Int?,
        selection: (Int, Int)?,
        colorHex: String,
        isOnline: Bool
    ) {
        if let index = collaborators.firstIndex(where: { $0.id == peerId }) {
            // Update existing collaborator
            collaborators[index].cursorPosition = cursorPosition
            collaborators[index].selection = selection
            collaborators[index].lastActive = Date()
            collaborators[index].isOnline = isOnline
        } else if isOnline {
            // Add new collaborator
            let color = Color(hex: colorHex) ?? assignColor(for: peerId)
            let collaborator = CollaboratorPresence(
                id: peerId,
                displayName: displayName,
                cursorPosition: cursorPosition,
                selection: selection,
                color: color,
                isOnline: true
            )
            collaborators.append(collaborator)
        }

        // Remove offline collaborators after timeout
        cleanupStaleCollaborators()
    }

    // MARK: - Private Methods

    private func startPresenceHeartbeat() {
        presenceUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupStaleCollaborators()
            }
        }
    }

    private func cleanupStaleCollaborators() {
        let staleThreshold = Date().addingTimeInterval(-30) // 30 seconds
        collaborators.removeAll { !$0.isOnline || $0.lastActive < staleThreshold }
    }

    private func broadcastPresence(cursorPosition: Int, selection: (Int, Int)?) {
        // TODO: Send to Rust collaboration backend
        // This will integrate with automerge sync
    }

    private func assignColor(for peerId: String) -> Color {
        // Deterministic color based on peer ID hash
        let hash = abs(peerId.hashValue)
        return collaboratorColors[hash % collaboratorColors.count]
    }

    private func getDeviceIdentifier() -> String? {
        // Get a stable device identifier
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )

        defer { IOObjectRelease(platformExpert) }

        guard platformExpert != 0,
              let serialNumber = IORegistryEntryCreateCFProperty(
                platformExpert,
                kIOPlatformSerialNumberKey as CFString,
                kCFAllocatorDefault,
                0
              )?.takeRetainedValue() as? String else {
            return nil
        }

        // Hash it for privacy
        return String(serialNumber.hashValue)
    }

    // MARK: - Demo Data

    private func addDemoCollaborators() {
        // Add simulated collaborators for UI development
        #if DEBUG
        let demoCollaborators = [
            CollaboratorPresence(
                id: "demo-alice",
                displayName: "Alice Chen",
                cursorPosition: 150,
                selection: nil,
                color: .blue,
                isOnline: true
            ),
            CollaboratorPresence(
                id: "demo-bob",
                displayName: "Bob Smith",
                cursorPosition: 320,
                selection: (320, 380),
                color: .green,
                isOnline: true
            )
        ]
        collaborators = demoCollaborators
        #endif
    }
}

// MARK: - Connection Status

public enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error(String)

    public var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting..."
        case .error(let message): return "Error: \(message)"
        }
    }

    public var iconName: String {
        switch self {
        case .disconnected: return "wifi.slash"
        case .connecting, .reconnecting: return "wifi.exclamationmark"
        case .connected: return "wifi"
        case .error: return "exclamationmark.triangle"
        }
    }

    public var color: Color {
        switch self {
        case .disconnected: return .secondary
        case .connecting, .reconnecting: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        guard let components = NSColor(self).cgColor.components, components.count >= 3 else {
            return "#000000"
        }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
