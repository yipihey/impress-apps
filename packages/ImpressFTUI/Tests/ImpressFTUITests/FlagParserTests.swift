import Testing
@testable import ImpressFTUI

@Suite("Flag Command Parser")
struct FlagParserTests {

    @Test("Single color character")
    func singleColor() {
        let flag = parseFlagCommand("r")
        #expect(flag == PublicationFlag(color: .red, style: .solid, length: .full))
    }

    @Test("Color with dash style")
    func colorWithDash() {
        let flag = parseFlagCommand("a-")
        #expect(flag?.color == .amber)
        #expect(flag?.style == .dashed)
        #expect(flag?.length == .full)
    }

    @Test("Color with dot style and half length")
    func colorDotHalf() {
        let flag = parseFlagCommand("b.h")
        #expect(flag?.color == .blue)
        #expect(flag?.style == .dotted)
        #expect(flag?.length == .half)
    }

    @Test("Full shorthand a-h")
    func amberDashedHalf() {
        let flag = parseFlagCommand("a-h")
        #expect(flag == PublicationFlag(color: .amber, style: .dashed, length: .half))
    }

    @Test("Gray solid quarter")
    func graySolidQuarter() {
        let flag = parseFlagCommand("gq")
        #expect(flag?.color == .gray)
        #expect(flag?.length == .quarter)
    }

    @Test("Invalid input returns nil")
    func invalidInput() {
        #expect(parseFlagCommand("") == nil)
        #expect(parseFlagCommand("x") == nil)
        #expect(parseFlagCommand("z-h") == nil)
    }

    @Test("Case insensitive")
    func caseInsensitive() {
        let flag = parseFlagCommand("R")
        #expect(flag?.color == .red)
    }
}
