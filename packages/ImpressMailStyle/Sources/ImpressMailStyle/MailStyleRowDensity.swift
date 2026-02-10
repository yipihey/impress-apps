//
//  MailStyleRowDensity.swift
//  ImpressMailStyle
//

import Foundation

/// Controls vertical spacing in mail-style list rows.
///
/// Raw values match imbib's `RowDensity` for seamless bridging.
public enum MailStyleRowDensity: String, Codable, CaseIterable, Sendable {
    case compact
    case `default`
    case spacious

    /// Vertical padding for rows
    public var rowPadding: CGFloat {
        switch self {
        case .compact: return 4
        case .default: return 8
        case .spacious: return 12
        }
    }

    /// Spacing between content lines
    public var contentSpacing: CGFloat {
        switch self {
        case .compact: return 1
        case .default: return 2
        case .spacious: return 4
        }
    }
}
