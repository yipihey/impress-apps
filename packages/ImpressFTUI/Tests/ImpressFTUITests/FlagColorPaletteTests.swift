//
//  FlagColorPaletteTests.swift
//  ImpressFTUITests
//
//  The guard on the ONE cross-platform `FlagColor` → colour mapping.
//
//  Written after the imprint-iOS sidebar shipped four flag rows that all
//  rendered in the default tint: there was no mapping on that path at all,
//  while three other call sites each carried their own private switch. The
//  failure mode to keep out is subtler than "wrong colour", though — it is
//  the one `ImpressSyntaxTheme.impressDefault` shipped, where a table was
//  `[:]` on the UIKit branch and every perfectly correct call site rendered
//  nothing. So these tests do not check hex literals; they check that on
//  WHICHEVER platform they are compiled for, every case resolves to a real,
//  distinct, non-placeholder colour.
//
//  Run on both platforms:
//    swift test                                     (macOS / AppKit)
//    xcodebuild test -scheme ImpressFTUI-Package \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro'   (UIKit)
//

import Testing
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import ImpressFTUI

@Suite("Flag Colour Palette")
struct FlagColorPaletteTests {

    /// sRGB components of a SwiftUI `Color`, resolved through the platform's
    /// own colour type — i.e. through the very bridge `displayColor` uses.
    private func rgba(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double)? {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (Double(r), Double(g), Double(b), Double(a))
        #elseif canImport(AppKit)
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return (Double(c.redComponent), Double(c.greenComponent),
                Double(c.blueComponent), Double(c.alphaComponent))
        #else
        return nil
        #endif
    }

    /// Opaque black is what `impressHexComponents` returns for an
    /// unparseable hex — the "the table was empty / the string was junk"
    /// signature. No flag colour may equal it.
    private func isParseFallback(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Bool {
        c.r == 0 && c.g == 0 && c.b == 0 && c.a == 1
    }

    // MARK: - The mapping exists at all

    @Test("every FlagColor has a config with parseable light and dark hexes")
    func everyCaseHasAConfig() {
        for flag in FlagColor.allCases {
            let config = flag.defaultConfig
            #expect(config.lightHex.count == 6, "\(flag) light hex is not RRGGBB")
            #expect(config.darkHex.count == 6, "\(flag) dark hex is not RRGGBB")
            #expect(!config.semanticLabel.isEmpty, "\(flag) has no semantic label")
            #expect(!flag.displayName.isEmpty, "\(flag) has no display name")
        }
        // The derived table cannot be `[:]` — but assert it, because that is
        // the exact shape of the bug this file exists for.
        #expect(FlagColorConfig.defaults.count == FlagColor.allCases.count)
        #expect(!FlagColorConfig.defaults.isEmpty)
    }

    // MARK: - The mapping resolves to a REAL colour on THIS platform

    @Test("displayColor resolves to a non-default colour for every case")
    func displayColorIsNeverTheFallback() throws {
        for flag in FlagColor.allCases {
            let resolved = try #require(rgba(flag.displayColor),
                                        "\(flag).displayColor did not resolve on this platform")
            #expect(!isParseFallback(resolved),
                    "\(flag).displayColor resolved to the parse-failure black")
            #expect(resolved.a > 0, "\(flag).displayColor is transparent")
        }
    }

    @Test("light and dark variants both resolve, and differ from each other")
    func bothSchemesResolve() throws {
        for flag in FlagColor.allCases {
            let light = try #require(rgba(flag.displayColor(for: .light)))
            let dark = try #require(rgba(flag.displayColor(for: .dark)))
            #expect(!isParseFallback(light), "\(flag) light is the fallback black")
            #expect(!isParseFallback(dark), "\(flag) dark is the fallback black")
            #expect(light != dark, "\(flag) has no dark-mode variant")
        }
    }

    @Test("the four flags are mutually distinguishable")
    func casesAreDistinct() throws {
        var seen: [String: FlagColor] = [:]
        for flag in FlagColor.allCases {
            let c = try #require(rgba(flag.displayColor(for: .light)))
            let key = "\(c.r)-\(c.g)-\(c.b)"
            #expect(seen[key] == nil,
                    "\(flag) renders identically to \(String(describing: seen[key]))")
            seen[key] = flag
        }
    }

    @Test("red is red, amber is amber, blue is blue, gray is neutral")
    func coloursAreTheColoursTheyClaim() throws {
        // Not hex assertions (those may be re-tuned) but the semantics the
        // user reported missing: "red, amber, blue, grey".
        let red = try #require(rgba(FlagColor.red.displayColor(for: .light)))
        #expect(red.r > red.g && red.r > red.b, "red is not dominated by its red channel")

        let amber = try #require(rgba(FlagColor.amber.displayColor(for: .light)))
        #expect(amber.r > amber.b && amber.g > amber.b, "amber is not warm")

        let blue = try #require(rgba(FlagColor.blue.displayColor(for: .light)))
        #expect(blue.b > blue.r && blue.b > blue.g, "blue is not dominated by its blue channel")

        let gray = try #require(rgba(FlagColor.gray.displayColor(for: .light)))
        #expect(abs(gray.r - gray.g) < 0.02 && abs(gray.g - gray.b) < 0.02,
                "gray is not neutral")
        #expect(gray.r > 0.1 && gray.r < 0.9, "gray is black or white, not grey")
    }

    // MARK: - Stored values parse back into the mapping

    @Test("stored flag_color strings map back onto the palette")
    func storedValuesParse() {
        for flag in FlagColor.allCases {
            #expect(FlagColor(storedValue: flag.rawValue) == flag)
            #expect(FlagColor(storedValue: flag.rawValue.uppercased()) == flag)
        }
        // British spelling appears in the store's snapshot maintainer and in
        // PublicationSource; a colour that fails to parse is a lost flag.
        #expect(FlagColor(storedValue: "grey") == .gray)
        #expect(FlagColor(storedValue: " Red ") == .red)
        #expect(FlagColor(storedValue: nil) == nil)
        #expect(FlagColor(storedValue: "") == nil)
        #expect(FlagColor(storedValue: "chartreuse") == nil)
    }
}
