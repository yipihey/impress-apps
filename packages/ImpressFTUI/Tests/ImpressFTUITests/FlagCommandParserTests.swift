import Testing
@testable import ImpressFTUI

@Suite("Flag Command Parser")
struct FlagCommandParserTests {

    // MARK: - Single color (defaults: solid, full)

    @Test("Single 'r' parses to red/solid/full")
    func singleRed() {
        let flag = parseFlagCommand("r")
        #expect(flag != nil)
        #expect(flag?.color == .red)
        #expect(flag?.style == .solid)
        #expect(flag?.length == .full)
    }

    @Test("Single 'a' parses to amber/solid/full")
    func singleAmber() {
        let flag = parseFlagCommand("a")
        #expect(flag?.color == .amber)
        #expect(flag?.style == .solid)
        #expect(flag?.length == .full)
    }

    @Test("Single 'b' parses to blue/solid/full")
    func singleBlue() {
        let flag = parseFlagCommand("b")
        #expect(flag?.color == .blue)
    }

    @Test("Single 'g' parses to gray/solid/full")
    func singleGray() {
        let flag = parseFlagCommand("g")
        #expect(flag?.color == .gray)
    }

    // MARK: - Color + style

    @Test("'r-' parses to red/dashed")
    func redDashed() {
        let flag = parseFlagCommand("r-")
        #expect(flag?.color == .red)
        #expect(flag?.style == .dashed)
        #expect(flag?.length == .full)
    }

    @Test("'r.' parses to red/dotted")
    func redDotted() {
        let flag = parseFlagCommand("r.")
        #expect(flag?.color == .red)
        #expect(flag?.style == .dotted)
    }

    @Test("'rs' parses to red/solid (explicit)")
    func redSolidExplicit() {
        let flag = parseFlagCommand("rs")
        #expect(flag?.color == .red)
        #expect(flag?.style == .solid)
    }

    // MARK: - Color + length (skipping style)

    @Test("'rh' parses to red/solid/half")
    func redHalf() {
        let flag = parseFlagCommand("rh")
        #expect(flag?.color == .red)
        #expect(flag?.style == .solid)
        #expect(flag?.length == .half)
    }

    @Test("'rq' parses to red/solid/quarter")
    func redQuarter() {
        let flag = parseFlagCommand("rq")
        #expect(flag?.color == .red)
        #expect(flag?.length == .quarter)
    }

    // MARK: - Color + style + length

    @Test("'a-h' parses to amber/dashed/half")
    func amberDashedHalf() {
        let flag = parseFlagCommand("a-h")
        #expect(flag?.color == .amber)
        #expect(flag?.style == .dashed)
        #expect(flag?.length == .half)
    }

    @Test("'b.q' parses to blue/dotted/quarter")
    func blueDottedQuarter() {
        let flag = parseFlagCommand("b.q")
        #expect(flag?.color == .blue)
        #expect(flag?.style == .dotted)
        #expect(flag?.length == .quarter)
    }

    // MARK: - Case insensitivity

    @Test("Uppercase 'R' parses same as lowercase")
    func caseInsensitive() {
        let upper = parseFlagCommand("R")
        let lower = parseFlagCommand("r")
        #expect(upper?.color == lower?.color)
        #expect(upper?.style == lower?.style)
        #expect(upper?.length == lower?.length)
    }

    @Test("Mixed case 'A-H' parses correctly")
    func mixedCase() {
        let flag = parseFlagCommand("A-H")
        #expect(flag?.color == .amber)
        #expect(flag?.style == .dashed)
        #expect(flag?.length == .half)
    }

    // MARK: - Invalid inputs

    @Test("Empty string returns nil")
    func emptyString() {
        #expect(parseFlagCommand("") == nil)
    }

    @Test("Invalid color character returns nil")
    func invalidColor() {
        #expect(parseFlagCommand("x") == nil)
        #expect(parseFlagCommand("z") == nil)
    }
}
