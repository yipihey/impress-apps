import Testing
import SwiftUI
@testable import ImpressFTUI

@Suite("Tag Models")
struct TagModelsTests {

    // MARK: - TagDisplayData

    @Test("resolvedColor uses colorLight for light scheme")
    func resolvedColorLight() {
        let tag = TagDisplayData(id: UUID(), path: "test", leaf: "test", colorLight: "FF0000", colorDark: "00FF00")
        let color = tag.resolvedColor(for: .light)
        #expect(color != nil)
    }

    @Test("resolvedColor uses colorDark for dark scheme")
    func resolvedColorDark() {
        let tag = TagDisplayData(id: UUID(), path: "test", leaf: "test", colorLight: "FF0000", colorDark: "00FF00")
        let color = tag.resolvedColor(for: .dark)
        #expect(color != nil)
    }

    @Test("resolvedColor returns nil when hex is nil")
    func resolvedColorNil() {
        let tag = TagDisplayData(id: UUID(), path: "test", leaf: "test", colorLight: nil, colorDark: nil)
        #expect(tag.resolvedColor(for: .light) == nil)
        #expect(tag.resolvedColor(for: .dark) == nil)
    }

    // MARK: - TagPathStyle

    @Test("TagPathStyle display names are correct")
    func pathStyleDisplayNames() {
        #expect(TagPathStyle.full.displayName == "Full Path")
        #expect(TagPathStyle.leafOnly.displayName == "Leaf Only")
        #expect(TagPathStyle.truncated.displayName == "Truncated")
    }

    @Test("TagPathStyle has 3 cases")
    func pathStyleCases() {
        #expect(TagPathStyle.allCases.count == 3)
    }

    // MARK: - TagDisplayStyle

    @Test("TagDisplayStyle default is dots with maxVisible 5")
    func displayStyleDefault() {
        let style = TagDisplayStyle.default
        if case .dots(let maxVisible) = style {
            #expect(maxVisible == 5)
        } else {
            Issue.record("Default style should be .dots")
        }
    }

    // MARK: - Default Tag Colors

    @Test("defaultTagColors has 8 entries")
    func tagColorCount() {
        #expect(defaultTagColors.count == 8)
    }

    @Test("All default tag colors have 6-char hex strings")
    func tagColorHexFormat() {
        for (light, dark) in defaultTagColors {
            #expect(light.count == 6)
            #expect(dark.count == 6)
        }
    }

    @Test("defaultTagColor returns deterministic color for same input")
    func tagColorDeterministic() {
        let color1 = defaultTagColor(for: "methods/sims/hydro")
        let color2 = defaultTagColor(for: "methods/sims/hydro")
        #expect(color1.light == color2.light)
        #expect(color1.dark == color2.dark)
    }

    // MARK: - TagCompletion

    @Test("TagCompletion stores all fields")
    func tagCompletionInit() {
        let id = UUID()
        let completion = TagCompletion(
            id: id, path: "a/b/c", leaf: "c", depth: 2,
            useCount: 5, colorLight: "FF0000"
        )
        #expect(completion.id == id)
        #expect(completion.path == "a/b/c")
        #expect(completion.leaf == "c")
        #expect(completion.depth == 2)
        #expect(completion.useCount == 5)
        #expect(completion.colorLight == "FF0000")
        #expect(completion.colorDark == nil)
    }
}
