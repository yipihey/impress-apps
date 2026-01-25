//
//  Color+Hex.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-14.
//

import SwiftUI

// MARK: - Color Hex Extension

public extension Color {

    /// Initialize a Color from a hex string
    /// Supports formats: "#RRGGBB", "RRGGBB", "#RRGGBBAA", "RRGGBBAA"
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let length = hexSanitized.count

        switch length {
        case 6: // RRGGBB
            let r = Double((rgb & 0xFF0000) >> 16) / 255.0
            let g = Double((rgb & 0x00FF00) >> 8) / 255.0
            let b = Double(rgb & 0x0000FF) / 255.0
            self.init(red: r, green: g, blue: b)

        case 8: // RRGGBBAA
            let r = Double((rgb & 0xFF000000) >> 24) / 255.0
            let g = Double((rgb & 0x00FF0000) >> 16) / 255.0
            let b = Double((rgb & 0x0000FF00) >> 8) / 255.0
            let a = Double(rgb & 0x000000FF) / 255.0
            self.init(red: r, green: g, blue: b, opacity: a)

        default:
            return nil
        }
    }

    /// Convert Color to hex string (format: "#RRGGBB")
    var hexString: String {
        #if os(macOS)
        let cgColor = NSColor(self).cgColor
        guard let components = cgColor.components,
              components.count >= 3 else {
            return "#000000"
        }
        #else
        let cgColor = UIColor(self).cgColor
        guard let components = cgColor.components,
              components.count >= 3 else {
            return "#000000"
        }
        #endif

        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)

        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Convert Color to hex string with alpha (format: "#RRGGBBAA")
    var hexStringWithAlpha: String {
        #if os(macOS)
        let cgColor = NSColor(self).cgColor
        guard let components = cgColor.components else {
            return "#000000FF"
        }
        #else
        let cgColor = UIColor(self).cgColor
        guard let components = cgColor.components else {
            return "#000000FF"
        }
        #endif

        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components.count >= 3 ? components[2] * 255 : 0)
        let a = Int(components.count >= 4 ? components[3] * 255 : 255)

        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}

// MARK: - Hex String Utilities

public extension String {

    /// Check if string is a valid hex color
    var isValidHexColor: Bool {
        var hexSanitized = self.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        let validLengths = [6, 8]
        guard validLengths.contains(hexSanitized.count) else {
            return false
        }

        return hexSanitized.allSatisfy { $0.isHexDigit }
    }
}

// MARK: - Color Manipulation

public extension Color {

    /// Lighten the color by a percentage (0.0-1.0)
    func lightened(by percentage: Double) -> Color {
        return self.adjusted(by: abs(percentage))
    }

    /// Darken the color by a percentage (0.0-1.0)
    func darkened(by percentage: Double) -> Color {
        return self.adjusted(by: -abs(percentage))
    }

    private func adjusted(by percentage: Double) -> Color {
        #if os(macOS)
        guard let nsColor = NSColor(self).usingColorSpace(.deviceRGB) else {
            return self
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let newBrightness = max(0, min(1, brightness + CGFloat(percentage)))
        return Color(NSColor(hue: hue, saturation: saturation, brightness: newBrightness, alpha: alpha))
        #else
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        UIColor(self).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let newBrightness = max(0, min(1, brightness + CGFloat(percentage)))
        return Color(UIColor(hue: hue, saturation: saturation, brightness: newBrightness, alpha: alpha))
        #endif
    }

    /// Mix this color with another color
    func mixed(with other: Color, amount: Double) -> Color {
        #if os(macOS)
        guard let color1 = NSColor(self).usingColorSpace(.deviceRGB),
              let color2 = NSColor(other).usingColorSpace(.deviceRGB) else {
            return self
        }

        let r1 = color1.redComponent
        let g1 = color1.greenComponent
        let b1 = color1.blueComponent
        let a1 = color1.alphaComponent

        let r2 = color2.redComponent
        let g2 = color2.greenComponent
        let b2 = color2.blueComponent
        let a2 = color2.alphaComponent

        let mixAmount = CGFloat(max(0, min(1, amount)))
        let r = r1 + (r2 - r1) * mixAmount
        let g = g1 + (g2 - g1) * mixAmount
        let b = b1 + (b2 - b1) * mixAmount
        let a = a1 + (a2 - a1) * mixAmount

        return Color(NSColor(red: r, green: g, blue: b, alpha: a))
        #else
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0

        UIColor(self).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(other).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

        let mixAmount = CGFloat(max(0, min(1, amount)))
        let r = r1 + (r2 - r1) * mixAmount
        let g = g1 + (g2 - g1) * mixAmount
        let b = b1 + (b2 - b1) * mixAmount
        let a = a1 + (a2 - a1) * mixAmount

        return Color(UIColor(red: r, green: g, blue: b, alpha: a))
        #endif
    }
}
