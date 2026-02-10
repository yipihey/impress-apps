//
//  MailStyleEnvironment.swift
//  ImpressMailStyle
//

import SwiftUI

// MARK: - Mail Style Colors Environment Key

private struct MailStyleColorsKey: EnvironmentKey {
    static let defaultValue: any MailStyleColorScheme = DefaultMailStyleColors()
}

// MARK: - Mail Style Font Scale Environment Key

private struct MailStyleFontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

// MARK: - Environment Extensions

public extension EnvironmentValues {
    /// The current mail-style color scheme for row rendering
    var mailStyleColors: any MailStyleColorScheme {
        get { self[MailStyleColorsKey.self] }
        set { self[MailStyleColorsKey.self] = newValue }
    }

    /// Font scale factor for mail-style rows (default 1.0)
    var mailStyleFontScale: Double {
        get { self[MailStyleFontScaleKey.self] }
        set { self[MailStyleFontScaleKey.self] = newValue }
    }
}
