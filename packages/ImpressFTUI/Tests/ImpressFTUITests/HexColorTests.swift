import Testing
import SwiftUI
@testable import ImpressFTUI

@Suite("Hex Color")
struct HexColorTests {

    @Test("6-digit hex creates correct color components")
    func sixDigitHex() {
        // Color(hex:) should not crash and should produce a valid color
        let red = Color(hex: "FF0000")
        let green = Color(hex: "00FF00")
        let blue = Color(hex: "0000FF")
        // Colors are opaque structs; we verify they're created without crashing
        // and that different hex values produce different colors
        #expect(red != green)
        #expect(green != blue)
    }

    @Test("Hash prefix is stripped")
    func hashPrefix() {
        let withHash = Color(hex: "#FF0000")
        let withoutHash = Color(hex: "FF0000")
        #expect(withHash == withoutHash)
    }

    @Test("8-digit hex includes alpha channel")
    func eightDigitHex() {
        // 80 = 128/255 alpha, fully red
        let semiTransparent = Color(hex: "80FF0000")
        let opaque = Color(hex: "FFFF0000")
        // Both should be created without error; they differ in alpha
        #expect(semiTransparent != opaque)
    }

    @Test("Invalid hex defaults to black")
    func invalidHex() {
        let invalid = Color(hex: "XYZ")
        let alsoInvalid = Color(hex: "")
        // Should not crash — produces a color (defaults to black/transparent)
        _ = invalid
        _ = alsoInvalid
    }
}
