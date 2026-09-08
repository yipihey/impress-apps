//
//  MailStyleLeadingMarker.swift
//  ImpressMailStyle
//
//  A small glyph an item can show in the row's indicator column, under the
//  unread dot and the star. imbib uses it for the reMarkable mirror state of
//  a paper (queued / on tablet / awaiting PDF / …); other apps' items keep
//  the default `nil` and render exactly as before.
//
//  The marker is DATA — an SF Symbol name, a named tint and an accessibility
//  label — so the row stays free of any app's domain enum. The producing app
//  maps its own state onto one of these.
//

import SwiftUI

public struct MailStyleLeadingMarker: Hashable, Sendable {

    /// The palette an item may pick from. Named rather than a raw `Color`
    /// so the marker stays `Hashable`/`Sendable` and so every app's markers
    /// share one small set of meanings (secondary = pending, green = done,
    /// orange = needs attention, red = failed).
    public enum Tint: String, Hashable, Sendable, CaseIterable {
        case secondary
        case accent
        case blue
        case green
        case orange
        case red
        case yellow

        public var color: Color {
            switch self {
            case .secondary: return .secondary
            case .accent: return .accentColor
            case .blue: return .blue
            case .green: return .green
            case .orange: return .orange
            case .red: return .red
            case .yellow: return .yellow
            }
        }
    }

    /// SF Symbol name.
    public let systemImage: String
    public let tint: Tint
    /// Read by VoiceOver in place of the glyph (e.g. "On reMarkable").
    public let accessibilityLabel: String

    public init(systemImage: String, tint: Tint, accessibilityLabel: String) {
        self.systemImage = systemImage
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
    }
}
