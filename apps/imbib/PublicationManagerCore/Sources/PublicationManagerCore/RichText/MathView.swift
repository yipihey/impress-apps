//
//  MathView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import SwiftUI
import SwiftMath

// MARK: - MathView

/// A SwiftUI view that renders LaTeX mathematical expressions using SwiftMath.
///
/// Usage:
/// ```swift
/// MathView(latex: "E = mc^2")
/// MathView(latex: "\\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}", fontSize: 18)
/// ```
public struct MathView: View {

    // MARK: - Properties

    /// The LaTeX string to render
    public let latex: String

    /// Font size for the rendered equation (default: 16)
    public var fontSize: CGFloat

    /// Text color for the equation
    public var textColor: Color

    /// Text alignment
    public var textAlignment: MTTextAlignment

    /// Label mode (display vs text style)
    public var labelMode: MTMathUILabelMode

    // MARK: - Initialization

    public init(
        latex: String,
        fontSize: CGFloat = 16,
        textColor: Color = .primary,
        textAlignment: MTTextAlignment = .left,
        labelMode: MTMathUILabelMode = .text
    ) {
        self.latex = latex
        self.fontSize = fontSize
        self.textColor = textColor
        self.textAlignment = textAlignment
        self.labelMode = labelMode
    }

    // MARK: - Body

    public var body: some View {
        MathViewRepresentable(
            latex: latex,
            fontSize: fontSize,
            textColor: textColor,
            textAlignment: textAlignment,
            labelMode: labelMode
        )
    }
}

// MARK: - Platform-Specific Representable

#if os(macOS)

/// macOS implementation using NSViewRepresentable
struct MathViewRepresentable: NSViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let textColor: Color
    let textAlignment: MTTextAlignment
    let labelMode: MTMathUILabelMode

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        configureLabel(label)
        // Force layout calculation for accurate intrinsic size
        label.invalidateIntrinsicContentSize()
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        configureLabel(label)
        // Force layout calculation when content changes
        label.invalidateIntrinsicContentSize()
    }

    /// Report intrinsic content size to SwiftUI for proper layout in WrappingHStack
    @MainActor
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
        // Ensure the size is calculated with current content
        nsView.invalidateIntrinsicContentSize()
        let size = nsView.intrinsicContentSize
        // Add small buffer to prevent clipping
        return CGSize(width: size.width + 1, height: size.height)
    }

    private func configureLabel(_ label: MTMathUILabel) {
        label.latex = latex
        label.fontSize = fontSize
        label.textColor = NSColor(textColor)
        label.textAlignment = textAlignment
        label.labelMode = labelMode
    }
}

#else

/// iOS implementation using UIViewRepresentable
struct MathViewRepresentable: UIViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let textColor: Color
    let textAlignment: MTTextAlignment
    let labelMode: MTMathUILabelMode

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        configureLabel(label)
        // Force layout calculation for accurate intrinsic size
        label.invalidateIntrinsicContentSize()
        return label
    }

    func updateUIView(_ label: MTMathUILabel, context: Context) {
        configureLabel(label)
        // Force layout calculation when content changes
        label.invalidateIntrinsicContentSize()
    }

    /// Report intrinsic content size to SwiftUI for proper layout in WrappingHStack
    @MainActor
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
        // Ensure the size is calculated with current content
        uiView.invalidateIntrinsicContentSize()
        let size = uiView.intrinsicContentSize
        // Add small buffer to prevent clipping
        return CGSize(width: size.width + 1, height: size.height)
    }

    private func configureLabel(_ label: MTMathUILabel) {
        label.latex = latex
        label.fontSize = fontSize
        label.textColor = UIColor(textColor)
        label.textAlignment = textAlignment
        label.labelMode = labelMode
    }
}

#endif

// MARK: - Display Math View

/// A variant of MathView for display-style (centered, larger) equations.
/// Use for block equations ($$...$$).
public struct DisplayMathView: View {
    public let latex: String
    public var fontSize: CGFloat
    public var textColor: Color

    public init(
        latex: String,
        fontSize: CGFloat = 20,
        textColor: Color = .primary
    ) {
        self.latex = latex
        self.fontSize = fontSize
        self.textColor = textColor
    }

    public var body: some View {
        MathView(
            latex: latex,
            fontSize: fontSize,
            textColor: textColor,
            textAlignment: .center,
            labelMode: .display
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Inline Math View

/// A variant of MathView for inline-style equations.
/// Use for inline equations ($...$).
public struct InlineMathView: View {
    public let latex: String
    public var fontSize: CGFloat
    public var textColor: Color

    public init(
        latex: String,
        fontSize: CGFloat = 14,
        textColor: Color = .primary
    ) {
        self.latex = latex
        self.fontSize = fontSize
        self.textColor = textColor
    }

    public var body: some View {
        MathView(
            latex: latex,
            fontSize: fontSize,
            textColor: textColor,
            textAlignment: .left,
            labelMode: .text
        )
        // Ensure the view uses its natural size and doesn't get compressed
        .fixedSize()
        // Add horizontal padding so math doesn't touch adjacent text
        .padding(.horizontal, 2)
        // Provide baseline alignment guide for proper inline text alignment.
        // The baseline is approximately 80% down from the top for math expressions,
        // matching typical text baseline positioning.
        .alignmentGuide(.firstTextBaseline) { d in
            d.height * 0.8
        }
    }
}

// MARK: - Preview

#Preview("Inline Math") {
    VStack(alignment: .leading, spacing: 16) {
        Text("Inline equations:")
        HStack {
            Text("The equation")
            InlineMathView(latex: "E = mc^2")
            Text("is famous.")
        }

        HStack {
            Text("Where")
            InlineMathView(latex: "\\alpha = \\frac{1}{137}")
            Text("is the fine structure constant.")
        }
    }
    .padding()
}

#Preview("Display Math") {
    VStack(spacing: 20) {
        Text("Display equations:")

        DisplayMathView(latex: "\\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}")

        DisplayMathView(latex: "\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}")

        DisplayMathView(latex: "\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}")
    }
    .padding()
}

#Preview("Greek Letters") {
    VStack(alignment: .leading, spacing: 12) {
        InlineMathView(latex: "\\alpha, \\beta, \\gamma, \\delta, \\epsilon")
        InlineMathView(latex: "\\Gamma, \\Delta, \\Theta, \\Lambda, \\Sigma")
        InlineMathView(latex: "\\nabla \\cdot \\vec{E} = \\frac{\\rho}{\\epsilon_0}")
    }
    .padding()
}
