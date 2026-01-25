//
//  AbstractRenderer.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import SwiftUI

// MARK: - Abstract Renderer

/// Renders scientific abstracts with full LaTeX support via SwiftMath.
///
/// Provides proper equation rendering:
/// - Fractions (\frac{}{})
/// - Square roots (\sqrt{})
/// - Integrals, sums, limits
/// - Greek letters
/// - Subscripts and superscripts
///
/// Usage:
/// ```swift
/// AbstractRenderer(text: abstract)
/// AbstractRenderer(text: abstract, fontSize: 16)
/// ```
public struct AbstractRenderer: View {

    // MARK: - Properties

    /// The abstract text to render
    public let text: String

    /// Font size for text content
    public var fontSize: CGFloat

    /// Text color
    public var textColor: Color

    // MARK: - Parsed Content

    private let segments: [AbstractSegment]

    // MARK: - Initialization

    public init(
        text: String,
        fontSize: CGFloat = 14,
        textColor: Color = .primary
    ) {
        self.text = text
        self.fontSize = fontSize
        self.textColor = textColor
        self.segments = AbstractParser.parse(text)
    }

    // MARK: - Body

    public var body: some View {
        // Use a flow layout for inline rendering
        // spacing: 0 because text words include trailing spaces and math has padding
        WrappingHStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                segmentView(segment)
            }
        }
    }

    // MARK: - Segment Rendering

    @ViewBuilder
    private func segmentView(_ segment: AbstractSegment) -> some View {
        switch segment {
        case .text(let str):
            // Split text into words for wrapping
            ForEach(Array(str.split(separator: " ", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, word in
                Text(String(word) + " ")
                    .font(.system(size: fontSize))
                    .foregroundStyle(textColor)
            }

        case .inlineMath(let latex):
            InlineMathView(latex: latex, fontSize: fontSize, textColor: textColor)

        case .displayMath(let latex):
            // Display math gets its own line
            DisplayMathView(latex: latex, fontSize: fontSize + 2, textColor: textColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }
}

// MARK: - Wrapping HStack

/// A layout that wraps content horizontally like text with proper baseline alignment.
struct WrappingHStack: Layout {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat = 0           // Horizontal spacing between elements
    var lineSpacing: CGFloat = 4       // Vertical spacing between lines

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)

        for (index, subview) in subviews.enumerated() {
            if index < result.positions.count {
                let position = result.positions[index]
                subview.place(
                    at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                    proposal: ProposedViewSize(subview.sizeThatFits(.unspecified))
                )
            }
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity

        // First pass: determine line breaks and line properties
        struct LineInfo {
            var startIndex: Int
            var endIndex: Int
            var maxBaseline: CGFloat  // Maximum baseline value (distance from top to baseline)
            var maxHeight: CGFloat
            var maxBelowBaseline: CGFloat  // Maximum distance below baseline
        }

        var lines: [LineInfo] = []
        var currentLineStart = 0
        var currentX: CGFloat = 0

        // Calculate sizes and baselines for all subviews
        var sizes: [CGSize] = []
        var baselines: [CGFloat] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            sizes.append(size)

            // Get the baseline value using dimensions for alignment guide access
            let baseline: CGFloat
            if alignment == .firstTextBaseline {
                let dimensions = subview.dimensions(in: .unspecified)
                let baselineValue = dimensions[VerticalAlignment.firstTextBaseline]
                // If baseline is at the bottom (equals height), use 80% as a reasonable fallback
                baseline = (baselineValue >= size.height) ? size.height * 0.8 : baselineValue
            } else {
                baseline = size.height * 0.5  // center alignment fallback
            }
            baselines.append(baseline)
        }

        // Group subviews into lines
        for (index, size) in sizes.enumerated() {
            // Check if we need to wrap
            if currentX + size.width > maxWidth && currentX > 0 {
                // Finalize current line
                let lineIndices = currentLineStart..<index
                var maxBaseline: CGFloat = 0
                var maxHeight: CGFloat = 0
                var maxBelowBaseline: CGFloat = 0

                for i in lineIndices {
                    let baseline = baselines[i]
                    let height = sizes[i].height
                    maxBaseline = max(maxBaseline, baseline)
                    maxHeight = max(maxHeight, height)
                    maxBelowBaseline = max(maxBelowBaseline, height - baseline)
                }

                lines.append(LineInfo(
                    startIndex: currentLineStart,
                    endIndex: index,
                    maxBaseline: maxBaseline,
                    maxHeight: maxHeight,
                    maxBelowBaseline: maxBelowBaseline
                ))

                currentLineStart = index
                currentX = 0
            }

            currentX += size.width + spacing
        }

        // Finalize last line
        if currentLineStart < subviews.count {
            let lineIndices = currentLineStart..<subviews.count
            var maxBaseline: CGFloat = 0
            var maxHeight: CGFloat = 0
            var maxBelowBaseline: CGFloat = 0

            for i in lineIndices {
                let baseline = baselines[i]
                let height = sizes[i].height
                maxBaseline = max(maxBaseline, baseline)
                maxHeight = max(maxHeight, height)
                maxBelowBaseline = max(maxBelowBaseline, height - baseline)
            }

            lines.append(LineInfo(
                startIndex: currentLineStart,
                endIndex: subviews.count,
                maxBaseline: maxBaseline,
                maxHeight: maxHeight,
                maxBelowBaseline: maxBelowBaseline
            ))
        }

        // Second pass: calculate positions with proper baseline alignment
        var positions: [CGPoint] = Array(repeating: .zero, count: subviews.count)
        var currentY: CGFloat = 0
        var totalWidth: CGFloat = 0

        for line in lines {
            var lineX: CGFloat = 0
            // Line height is the sum of max baseline and max below-baseline
            let lineHeight = line.maxBaseline + line.maxBelowBaseline

            for index in line.startIndex..<line.endIndex {
                let size = sizes[index]
                let baseline = baselines[index]

                // Align based on baseline: position the top of the view such that
                // its baseline aligns with the line's baseline
                let yOffset = line.maxBaseline - baseline
                positions[index] = CGPoint(x: lineX, y: currentY + yOffset)

                lineX += size.width + spacing
            }

            totalWidth = max(totalWidth, lineX)
            currentY += lineHeight + lineSpacing
        }

        let totalHeight = currentY - lineSpacing  // Remove trailing line spacing

        return (CGSize(width: totalWidth, height: max(0, totalHeight)), positions)
    }
}

// MARK: - Convenience Extension

public extension View {
    /// Renders abstract text with LaTeX support.
    func abstractText(_ text: String, fontSize: CGFloat = 14) -> some View {
        AbstractRenderer(text: text, fontSize: fontSize)
    }
}

// MARK: - Preview

#Preview("Simple Abstract") {
    ScrollView {
        AbstractRenderer(
            text: """
            We present observations of the H$\\alpha$ emission line in the spectrum of the star. \
            The measured flux is $F = 10^{-15}$ erg s$^{-1}$ cm$^{-2}$. \
            Using the standard relation $L = 4\\pi d^2 F$, we derive the luminosity.
            """
        )
        .padding()
    }
}

#Preview("MathML Abstract") {
    ScrollView {
        AbstractRenderer(
            text: """
            We report the detection of a signal-to-noise ratio of <inline-formula><mml:math><mml:mi>S</mml:mi><mml:mo>/</mml:mo><mml:mi>N</mml:mi></mml:math></inline-formula> = 5 \
            in the <inline-formula><mml:math><mml:msup><mml:mi>H</mml:mi><mml:mn>2</mml:mn></mml:msup></mml:math></inline-formula> line.
            """
        )
        .padding()
    }
}

#Preview("Complex Math") {
    ScrollView {
        AbstractRenderer(
            text: """
            The quadratic formula is $$x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}$$ which gives the roots of any quadratic equation.
            """
        )
        .padding()
    }
}

#Preview("Greek Letters") {
    AbstractRenderer(
        text: "The fine structure constant $\\alpha \\approx 1/137$ determines the strength of electromagnetic interactions."
    )
    .padding()
}

#Preview("ArXiv Abstract - 2601.08933") {
    ScrollView {
        AbstractRenderer(
            text: """
            This study aims at using Sunyaev-Zel'dovich (SZ) data to test four different functional forms for the cluster pressure profile: generalized Navarro-Frenk-White (gNFW), $\\beta$-model, polytropic, and exponential. A set of 3496 ACT-DR4 galaxy clusters, spanning the mass range $\\[10^{14},10^{15.1}\\]\\,\\text{M}_{\\odot}$ and the redshift range $\\[0,2\\]$, is stacked on the ACT-DR6 Compton parameter $y$ map over $\\sim13,000\\,\\text{deg}^2$.
            """
        )
        .padding()
    }
    .padding()
}
