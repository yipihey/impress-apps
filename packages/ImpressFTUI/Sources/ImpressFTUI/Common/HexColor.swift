//
//  HexColor.swift
//  ImpressFTUI
//

import SwiftUI

#if canImport(UIKit)
import UIKit
/// The platform colour type, so one hex→colour path serves AppKit and UIKit
/// (same shape as `ImpressColor` in ImpressSyntaxHighlight). It exists because
/// SwiftUI has no *dynamic* `Color` initialiser: an appearance-aware colour
/// has to be built from `UIColor`/`NSColor` and wrapped.
public typealias ImpressPlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias ImpressPlatformColor = NSColor
#endif

// MARK: - Hex parsing

/// sRGB components of a hex string ("#RRGGBB", "RRGGBB" or "AARRGGBB").
/// The ONE parse; `Color(hex:)` and `ImpressPlatformColor.impressHex(_:)`
/// both go through it.
public func impressHexComponents(
    _ hex: String
) -> (red: Double, green: Double, blue: Double, alpha: Double) {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)

    let a, r, g, b: UInt64
    switch hex.count {
    case 6: // RGB
        (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
    case 8: // ARGB
        (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
    default:
        (a, r, g, b) = (255, 0, 0, 0)
    }

    return (Double(r) / 255, Double(g) / 255, Double(b) / 255, Double(a) / 255)
}

public extension Color {

    /// Create a Color from a hex string (e.g., "#FF0000" or "FF0000").
    init(hex: String) {
        let c = impressHexComponents(hex)
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}

#if canImport(UIKit) || canImport(AppKit)
public extension ImpressPlatformColor {

    /// Platform colour from a hex string — the bridge a dynamic
    /// (light/dark-aware) colour needs on both platforms.
    static func impressHex(_ hex: String) -> ImpressPlatformColor {
        let c = impressHexComponents(hex)
        return ImpressPlatformColor(
            red: CGFloat(c.red),
            green: CGFloat(c.green),
            blue: CGFloat(c.blue),
            alpha: CGFloat(c.alpha))
    }
}
#endif
