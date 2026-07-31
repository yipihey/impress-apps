//
//  AppearanceModifier.swift
//  ImpressTheme
//
//  ADR-0022 D9 finding 5, closed: the one line that APPLIES the appearance
//  preference.
//
//  ImpressTheme has always owned the two ends of this preference — the enum
//  (`AppearanceMode`, with its `colorScheme` mapping) and the picker
//  (`AppearanceSettingsSection`, which the chassis settings builtin presents).
//  What it did not export was the middle: the modifier that reads the stored
//  key and hands SwiftUI a `preferredColorScheme`. So each app wrote its own —
//  imprint's, impart's and finally impress's were byte-identical, and each one
//  re-derived the string→ColorScheme mapping this package already publishes.
//  imprint-iOS wrote a fourth copy inline, because macOS's was `#if os(macOS)`
//  end to end and iOS could not reach it.
//
//  Deriving the mapping twice is the actual hazard, not the line count. The
//  hand-rolled `switch appearanceMode { case "light": … default: nil }` is a
//  SECOND spelling of `AppearanceMode.colorScheme` over raw strings, and a
//  fourth mode added to the enum would silently fall to `default` — that is,
//  to System — in every app, with the picker offering it and nothing applying
//  it. Reading through the enum makes that impossible: an unknown mode is
//  unrepresentable rather than mis-handled.
//
//  THE STORAGE KEY IS `appearanceMode`, unprefixed, and it is not moving. It is
//  what all four hand-written copies read, what `SettingsSectionRegistry`'s
//  builtin appearance pane WRITES, and what `PaneLayoutState.appAppearance`
//  mirrors. Renaming it would silently reset every existing user's preference,
//  which reads as "my settings were lost" rather than as a bug
//  (`ImprintSettingsPersistenceTests` pins it for exactly that reason).
//
//  CROSS-PLATFORM. `preferredColorScheme` is SwiftUI on both platforms, and the
//  key is the same on both, so this is un-gated — which is the half of the
//  finding imprint-iOS's inline copy existed to work around.
//

import SwiftUI

/// Applies the user's stored appearance preference (`system` / `light` /
/// `dark`) to a view tree.
///
/// Prefer `View.withAppearance()`.
public struct AppearanceModifier: ViewModifier {

    /// The suite-wide key. Declared here so there is one declaration to find,
    /// and `public` so a test can assert an app reads THIS one rather than
    /// re-typing the string.
    public static let storageKey = "appearanceMode"

    /// Typed, not `String`. The three hand-written copies stored a raw string
    /// and re-derived the mapping; going through `AppearanceMode` reuses the
    /// `colorScheme` property this package already ships, so the enum and the
    /// application of the enum cannot disagree.
    ///
    /// `@AppStorage` falls back to the default for a value that is not a valid
    /// raw value, which is byte-identical to the old copies' `default: nil`
    /// arm — an unrecognised stored string meant "system" then and means
    /// "system" now.
    @AppStorage(AppearanceModifier.storageKey) private var mode: AppearanceMode = .system

    public init() {}

    public func body(content: Content) -> some View {
        content.preferredColorScheme(mode.colorScheme)
    }
}

public extension View {
    /// Apply the user's appearance preference (system/light/dark).
    ///
    /// Attach it to a scene's root view. It is deliberately NOT applied inside
    /// `ChassisRootView`: an app's auxiliary windows (editors, previews, the
    /// shortcuts sheet) want the same preference and never go through the
    /// chassis root, so the modifier belongs at each scene's root where the app
    /// can see every one of them.
    func withAppearance() -> some View {
        modifier(AppearanceModifier())
    }
}
