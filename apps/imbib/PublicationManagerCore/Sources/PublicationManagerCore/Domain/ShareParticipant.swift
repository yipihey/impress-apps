//
//  ShareParticipant.swift
//  PublicationManagerCore
//
//  Domain type for CloudKit share participants.
//

import Foundation

/// A participant in a shared library via CloudKit.
public struct ShareParticipant: Identifiable, Hashable, Sendable {

    /// Unique identifier for this participant.
    public let id: String

    /// The participant's display name (from CKUserIdentity).
    public let displayName: String?

    /// The participant's email address (if available).
    public let emailAddress: String?

    /// Permission level for this participant.
    public let permission: Permission

    /// Acceptance status of the share invitation.
    public let acceptanceStatus: AcceptanceStatus

    /// Whether this participant is the share owner.
    public let isOwner: Bool

    /// Whether this is the current user.
    public let isCurrentUser: Bool

    // MARK: - Permission

    public enum Permission: String, Sendable, CaseIterable {
        case readOnly
        case readWrite
    }

    // MARK: - Acceptance Status

    public enum AcceptanceStatus: String, Sendable, CaseIterable {
        case pending
        case accepted
        case removed
        case unknown
    }

    // MARK: - Display

    /// Display-friendly name, falling back to email or "Unknown".
    public var displayLabel: String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        if let emailAddress, !emailAddress.isEmpty {
            return emailAddress
        }
        return "Unknown"
    }

    /// Initials for avatar display.
    public var initials: String {
        let name = displayName ?? emailAddress ?? "?"
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}
