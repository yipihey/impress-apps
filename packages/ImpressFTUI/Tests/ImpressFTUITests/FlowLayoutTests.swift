//
//  FlowLayoutTests.swift
//  ImpressFTUITests
//
//  Regression pin for the single-wide-chip overflow (2026-09-06): FlowLayout
//  wraps only BETWEEN subviews, so a lone subview wider than the container
//  used to be measured and placed at its ideal width — one long oMLX model
//  name pushed its chip (and the chip's remove button) past the sheet edge.
//  The layout must clamp such a subview to the container width so its
//  content truncates inside the bounds instead of escaping them.
//

import SwiftUI
import Testing

@testable import ImpressFTUI

@MainActor
struct FlowLayoutTests {

    /// Render the layout at a constrained width and measure what it reports.
    /// ImageRenderer honors the layout's own sizeThatFits, so an overflowing
    /// implementation yields an image wider than the proposal.
    private func renderedWidth(of view: some View, proposedWidth: CGFloat) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: proposedWidth, height: nil)
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            Issue.record("ImageRenderer produced no image")
            return .infinity
        }
        return CGFloat(image.width)
    }

    @Test func aSubviewWiderThanTheContainerIsClampedNotOverflowed() {
        let longName = String(repeating: "NVIDIA Nemotron 3.5 Lightning 30B A3B 4bit ", count: 4)
        let view = FlowLayout(spacing: 4) {
            Text(longName).lineLimit(1).font(.caption)
        }
        let width = renderedWidth(of: view, proposedWidth: 220)
        // A couple of points of rendering slack; the pre-fix layout reported
        // the text's ideal width (well over 700 points).
        #expect(width <= 224, "over-wide subview escaped the container: \(width)pt")
    }

    @Test func normalChipsStillWrapBetweenSubviews() {
        let view = FlowLayout(spacing: 4) {
            ForEach(0..<6, id: \.self) { i in
                Text("chip \(i)").font(.caption)
            }
        }
        let narrow = renderedWidth(of: view, proposedWidth: 120)
        #expect(narrow <= 124, "wrapped chips must stay within the container: \(narrow)pt")
    }
}
