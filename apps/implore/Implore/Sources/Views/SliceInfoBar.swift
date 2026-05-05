import SwiftUI

/// Minimal info bar showing current slice parameters and value range.
/// Monospace, dark background, Tufte-style minimal.
struct SliceInfoBar: View {
    let viewerState: RgViewerState

    private var quantityLabel: String {
        viewerState.quantity.replacingOccurrences(of: "_", with: " ")
    }

    var body: some View {
        HStack(spacing: 16) {
            // Quantity
            InfoChip(label: "Q", value: quantityLabel)

            // Axis + position
            InfoChip(
                label: viewerState.axis.uppercased(),
                value: "\(viewerState.slicePosition)/\(viewerState.info.gridSize - 1)"
            )

            // Value range
            if let slice = viewerState.currentSlice {
                InfoChip(
                    label: "range",
                    value: "[\(formatted(slice.minValue)), \(formatted(slice.maxValue))]"
                )
            }

            // Grid size
            InfoChip(label: "grid", value: "\(viewerState.info.gridSize)\u{00B3}")

            // Colormap
            InfoChip(label: "cmap", value: viewerState.colormap)

            Spacer()

            // Keyboard hints
            Text("[ ] nav  q qty  a axis  c cmap")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.85))
    }

    private func formatted(_ v: Float) -> String {
        if abs(v) < 0.01 || abs(v) >= 1e4 {
            return String(format: "%.2e", v)
        }
        return String(format: "%.3f", v)
    }
}

/// A single label:value chip in the info bar.
private struct InfoChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.system(.caption, design: .monospaced))
    }
}
