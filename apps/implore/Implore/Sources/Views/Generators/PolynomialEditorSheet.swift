import SwiftUI

/// Interactive log-log polynomial editor for power spectrum control
struct PolynomialEditorSheet: View {
    let coefficients: [Double]
    let onSave: ([Double]) -> Void

    @Environment(\.dismiss) var dismiss
    @State private var editedCoeffs: [Double] = []
    @State private var previewPoints: [CGPoint] = []

    private let previewSize = CGSize(width: 300, height: 200)
    private let logRange: ClosedRange<Double> = -1...3 // log10(0.1) to log10(1000)

    var body: some View {
        VStack(spacing: 16) {
            Text("Polynomial Power Spectrum Editor")
                .font(.headline)

            // Preview plot (log-log space)
            ZStack {
                // Background grid
                GridOverlay()

                // Power spectrum curve
                Path { path in
                    guard !previewPoints.isEmpty else { return }
                    path.move(to: previewPoints[0])
                    for point in previewPoints.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(.blue, lineWidth: 2)

                // Axis labels
                VStack {
                    HStack {
                        Text("log P(k)")
                            .font(.caption2)
                            .rotationEffect(.degrees(-90))
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Text("log k")
                            .font(.caption2)
                    }
                }
                .padding(4)
            }
            .frame(width: previewSize.width, height: previewSize.height)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            // Coefficient list
            VStack(alignment: .leading, spacing: 8) {
                Text("Coefficients")
                    .font(.subheadline)
                    .fontWeight(.medium)

                ForEach(Array(editedCoeffs.enumerated()), id: \.offset) { index, coeff in
                    HStack {
                        Text(coefficientLabel(for: index))
                            .frame(width: 60, alignment: .trailing)
                            .foregroundStyle(.secondary)

                        Slider(value: binding(for: index), in: -10...10)
                            .frame(maxWidth: .infinity)

                        TextField("", value: binding(for: index), format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)

                        Button(action: { removeCoefficient(at: index) }) {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(editedCoeffs.count <= 1)
                    }
                }

                Button(action: addCoefficient) {
                    Label("Add Term", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }

            // Preset buttons
            HStack {
                ForEach(presets, id: \.name) { preset in
                    Button(preset.name) {
                        editedCoeffs = preset.coefficients
                        updatePreview()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Reset") {
                    editedCoeffs = coefficients
                    updatePreview()
                }

                Button("Apply") {
                    onSave(editedCoeffs)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            editedCoeffs = coefficients.isEmpty ? [-2.0, 0.0] : coefficients
            updatePreview()
        }
    }

    private func binding(for index: Int) -> Binding<Double> {
        Binding(
            get: { editedCoeffs.indices.contains(index) ? editedCoeffs[index] : 0 },
            set: { newValue in
                if editedCoeffs.indices.contains(index) {
                    editedCoeffs[index] = newValue
                    updatePreview()
                }
            }
        )
    }

    private func coefficientLabel(for index: Int) -> String {
        switch index {
        case 0: return "a\u{2080}:"
        case 1: return "a\u{2081}:"
        case 2: return "a\u{2082}:"
        case 3: return "a\u{2083}:"
        default: return "a\(index):"
        }
    }

    private func addCoefficient() {
        editedCoeffs.append(0.0)
        updatePreview()
    }

    private func removeCoefficient(at index: Int) {
        guard editedCoeffs.count > 1 else { return }
        editedCoeffs.remove(at: index)
        updatePreview()
    }

    private func updatePreview() {
        let numPoints = Int(previewSize.width)
        previewPoints = (0..<numPoints).map { i in
            let t = Double(i) / Double(numPoints - 1)
            let logK = logRange.lowerBound + t * (logRange.upperBound - logRange.lowerBound)
            let logP = evaluatePolynomial(at: logK)

            // Map to screen coordinates
            let x = CGFloat(i)
            let normalizedP = (logP - (-10)) / 20 // Assuming log P range of -10 to 10
            let y = previewSize.height * (1 - CGFloat(normalizedP.clamped(to: 0...1)))

            return CGPoint(x: x, y: y)
        }
    }

    private func evaluatePolynomial(at x: Double) -> Double {
        var result = 0.0
        var xPower = 1.0
        for coeff in editedCoeffs {
            result += coeff * xPower
            xPower *= x
        }
        return result
    }

    private var presets: [PolynomialPreset] {
        [
            PolynomialPreset(name: "White", coefficients: [0.0]),
            PolynomialPreset(name: "Pink", coefficients: [0.0, -1.0]),
            PolynomialPreset(name: "Red", coefficients: [0.0, -2.0]),
            PolynomialPreset(name: "Blue", coefficients: [0.0, 1.0]),
        ]
    }
}

struct PolynomialPreset {
    let name: String
    let coefficients: [Double]
}

/// Grid overlay for the preview plot
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let w = geometry.size.width
                let h = geometry.size.height

                // Vertical lines
                for i in 0...4 {
                    let x = w * CGFloat(i) / 4
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                }

                // Horizontal lines
                for i in 0...4 {
                    let y = h * CGFloat(i) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(.tertiary, lineWidth: 0.5)
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    PolynomialEditorSheet(
        coefficients: [-2.0, 0.0],
        onSave: { _ in }
    )
}
