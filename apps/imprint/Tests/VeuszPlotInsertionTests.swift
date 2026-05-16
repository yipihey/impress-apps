import XCTest
@testable import imprint

final class VeuszPlotInsertionTests: XCTestCase {

    private let plot = VeuszPlotRef(
        displayName: "Pulse Profile",
        sourceRelativePath: "figures/pulse.vsz",
        renderedRelativePath: "figures/pulse.svg"
    )

    func testTypstBlockUsesRenderedPathAndCaption() {
        let snippet = VeuszPlotInsertion.block(for: plot, format: .typst)
        XCTAssertTrue(snippet.contains("#figure"))
        XCTAssertTrue(snippet.contains("image(\"figures/pulse.svg\""))
        XCTAssertTrue(snippet.contains("caption: [Pulse Profile]"))
    }

    func testLatexBlockUsesRenderedPathAndCaption() {
        let snippet = VeuszPlotInsertion.block(for: plot, format: .latex)
        XCTAssertTrue(snippet.contains("\\begin{figure}"))
        XCTAssertTrue(snippet.contains("\\includegraphics[width=0.8\\textwidth]{figures/pulse.svg}"))
        XCTAssertTrue(snippet.contains("\\caption{Pulse Profile}"))
        XCTAssertTrue(snippet.contains("\\end{figure}"))
    }

    func testTypstCaptionEscapesBracketsAndBackslashes() {
        let p = VeuszPlotRef(
            displayName: "Plot [bracketed] \\path",
            sourceRelativePath: "figures/x.vsz",
            renderedRelativePath: "figures/x.svg"
        )
        let snippet = VeuszPlotInsertion.block(for: p, format: .typst)
        XCTAssertTrue(snippet.contains("caption: [Plot [bracketed\\] \\\\path]"))
    }

    func testLatexCaptionEscapesSpecialCharacters() {
        let p = VeuszPlotRef(
            displayName: "100% of S&P {value} #1",
            sourceRelativePath: "figures/x.vsz",
            renderedRelativePath: "figures/x.svg"
        )
        let snippet = VeuszPlotInsertion.block(for: p, format: .latex)
        XCTAssertTrue(snippet.contains("\\caption{100\\% of S\\&P \\{value\\} \\#1}"),
                      "Got: \(snippet)")
    }

    func testNotificationNameIsStable() {
        XCTAssertEqual(
            VeuszPlotInsertion.notificationName.rawValue,
            "com.imprint.insertVeuszPlot"
        )
    }
}
