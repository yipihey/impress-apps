//
//  FlagStripe.swift
//  ImpressFTUI
//

import SwiftUI

// MARK: - Flag Stripe

/// A 4pt vertical stripe rendered at the leading edge of a publication row.
///
/// Supports solid, dashed, and dotted styles with configurable length fraction.
public struct FlagStripe: View {

    public let flag: PublicationFlag?
    public var rowHeight: CGFloat = 44

    @Environment(\.colorScheme) private var colorScheme

    public init(flag: PublicationFlag?, rowHeight: CGFloat = 44) {
        self.flag = flag
        self.rowHeight = rowHeight
    }

    public var body: some View {
        if let flag {
            stripeView(for: flag)
                .frame(width: 4)
                .frame(height: rowHeight * flag.length.fraction, alignment: .top)
                .frame(height: rowHeight, alignment: .top)
        } else {
            Color.clear
                .frame(width: 4, height: rowHeight)
        }
    }

    @ViewBuilder
    private func stripeView(for flag: PublicationFlag) -> some View {
        let color = colorScheme == .dark ? flag.color.defaultDarkColor : flag.color.defaultLightColor

        switch flag.style {
        case .solid:
            RoundedRectangle(cornerRadius: 2)
                .fill(color)

        case .dashed:
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .mask {
                    DashedPattern()
                }

        case .dotted:
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .mask {
                    DottedPattern()
                }
        }
    }
}

// MARK: - Dashed Pattern

/// Vertical dashed pattern mask.
private struct DashedPattern: View {
    var body: some View {
        GeometryReader { geo in
            let dashHeight: CGFloat = 4
            let gapHeight: CGFloat = 3
            let count = Int(geo.size.height / (dashHeight + gapHeight)) + 1

            VStack(spacing: gapHeight) {
                ForEach(0..<count, id: \.self) { _ in
                    Rectangle()
                        .frame(height: dashHeight)
                }
            }
        }
    }
}

// MARK: - Dotted Pattern

/// Vertical dotted pattern mask.
private struct DottedPattern: View {
    var body: some View {
        GeometryReader { geo in
            let dotSize: CGFloat = 3
            let gapHeight: CGFloat = 4
            let count = Int(geo.size.height / (dotSize + gapHeight)) + 1

            VStack(spacing: gapHeight) {
                ForEach(0..<count, id: \.self) { _ in
                    Circle()
                        .frame(width: dotSize, height: dotSize)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Preview

#Preview("Flag Stripes") {
    HStack(spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
            Text("Solid Full").font(.caption)
            FlagStripe(flag: .simple(.red), rowHeight: 60)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Dashed Half").font(.caption)
            FlagStripe(flag: PublicationFlag(color: .amber, style: .dashed, length: .half), rowHeight: 60)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Dotted Quarter").font(.caption)
            FlagStripe(flag: PublicationFlag(color: .blue, style: .dotted, length: .quarter), rowHeight: 60)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("No Flag").font(.caption)
            FlagStripe(flag: nil, rowHeight: 60)
        }
    }
    .padding()
}
