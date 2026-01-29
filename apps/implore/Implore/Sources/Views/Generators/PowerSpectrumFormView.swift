import SwiftUI
import ImploreCore

/// Custom form view for Power Spectrum generator with polynomial editor and preview
struct PowerSpectrumFormView: View {
    var formState: GeneratorFormState
    @State private var showingPolynomialEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Power spectrum preview
            PowerSpectrumPreview(coefficients: formState.vecValue(for: "coefficients"))

            // Quick presets
            Section {
                HStack(spacing: 8) {
                    ForEach(noisePresets, id: \.name) { preset in
                        Button(preset.name) {
                            formState.setVec(preset.coefficients, for: "coefficients")
                        }
                        .buttonStyle(.bordered)
                        .tint(preset.color)
                    }
                }
            } header: {
                HStack {
                    Text("Noise Color")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Button("Custom...") {
                        showingPolynomialEditor = true
                    }
                    .font(.caption)
                }
            }

            Divider()

            // Current polynomial display
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Power Spectrum:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(polynomialFormula)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            } header: {
                Text("Spectrum Formula")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Divider()

            // Other parameters
            Section {
                VStack(spacing: 12) {
                    // Resolution
                    ParameterRow(label: "Resolution") {
                        Picker("", selection: formState.intBinding(for: "resolution")) {
                            Text("64").tag(Int64(64))
                            Text("128").tag(Int64(128))
                            Text("256").tag(Int64(256))
                            Text("512").tag(Int64(512))
                            Text("1024").tag(Int64(1024))
                        }
                        .pickerStyle(.segmented)
                    }

                    // Seed
                    ParameterRow(label: "Seed") {
                        HStack {
                            TextField("", value: formState.intBinding(for: "seed"), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)

                            Button("Random") {
                                formState.setInt(Int64.random(in: 0...99999), for: "seed")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // Scale
                    ParameterRow(label: "Output Scale") {
                        HStack {
                            Slider(
                                value: formState.floatBinding(for: "scale"),
                                in: 0.01...10,
                                step: 0.1
                            )
                            Text(String(format: "%.2f", formState.floatValue(for: "scale")))
                                .monospacedDigit()
                                .frame(width: 50)
                        }
                    }
                }
            } header: {
                Text("Generation Parameters")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
        }
        .sheet(isPresented: $showingPolynomialEditor) {
            PolynomialEditorSheet(
                coefficients: formState.vecValue(for: "coefficients"),
                onSave: { newCoeffs in
                    formState.setVec(newCoeffs, for: "coefficients")
                }
            )
        }
        .accessibilityIdentifier("generator.powerSpectrumForm")
    }

    private var polynomialFormula: String {
        let coeffs = formState.vecValue(for: "coefficients")
        if coeffs.isEmpty {
            return "P(k) = constant"
        }

        var terms: [String] = []
        for (i, c) in coeffs.enumerated() {
            if abs(c) < 0.001 { continue }
            let sign = c >= 0 ? (terms.isEmpty ? "" : " + ") : " - "
            let absC = abs(c)
            let coeff = absC == 1.0 && i > 0 ? "" : String(format: "%.2f", absC)

            if i == 0 {
                terms.append("\(sign)\(String(format: "%.2f", c))")
            } else if i == 1 {
                terms.append("\(sign)\(coeff)log(k)")
            } else {
                terms.append("\(sign)\(coeff)log(k)^\(i)")
            }
        }

        return "log P(k) = \(terms.isEmpty ? "0" : terms.joined())"
    }

    private var noisePresets: [NoisePreset] {
        [
            NoisePreset(name: "White", coefficients: [0.0], color: .gray),
            NoisePreset(name: "Pink", coefficients: [0.0, -1.0], color: .pink),
            NoisePreset(name: "Red", coefficients: [0.0, -2.0], color: .red),
            NoisePreset(name: "Blue", coefficients: [0.0, 1.0], color: .blue),
            NoisePreset(name: "Violet", coefficients: [0.0, 2.0], color: .purple),
        ]
    }
}

struct NoisePreset {
    let name: String
    let coefficients: [Double]
    let color: Color
}

/// Preview of the power spectrum in log-log space
struct PowerSpectrumPreview: View {
    let coefficients: [Double]

    private let plotSize = CGSize(width: 280, height: 150)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                // Grid
                PowerSpectrumGrid()

                // Spectrum line
                Path { path in
                    let points = computePoints()
                    guard !points.isEmpty else { return }

                    path.move(to: points[0])
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(gradientForSpectrum(), lineWidth: 2)

                // Axis labels
                VStack {
                    HStack {
                        Text("P")
                            .font(.system(size: 10, design: .serif))
                            .italic()
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Text("k")
                            .font(.system(size: 10, design: .serif))
                            .italic()
                    }
                }
                .padding(4)
                .foregroundStyle(.secondary)
            }
            .frame(width: plotSize.width, height: plotSize.height)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Text("Power Spectrum (log-log)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func computePoints() -> [CGPoint] {
        let numPoints = 100
        let logKMin = -1.0
        let logKMax = 3.0
        let logPMin = -10.0
        let logPMax = 10.0

        return (0..<numPoints).map { i in
            let t = Double(i) / Double(numPoints - 1)
            let logK = logKMin + t * (logKMax - logKMin)

            // Evaluate polynomial
            var logP = 0.0
            var xPower = 1.0
            for coeff in coefficients {
                logP += coeff * xPower
                xPower *= logK
            }

            // Map to screen coordinates
            let x = t * plotSize.width
            let normalizedP = (logP - logPMin) / (logPMax - logPMin)
            let y = plotSize.height * (1 - CGFloat(normalizedP.clamped(to: 0...1)))

            return CGPoint(x: x, y: y)
        }
    }

    private func gradientForSpectrum() -> LinearGradient {
        // Determine color based on slope (first non-zero coefficient after constant)
        let slope = coefficients.count > 1 ? coefficients[1] : 0.0

        let color: Color
        if slope < -1.5 {
            color = .red
        } else if slope < -0.5 {
            color = .pink
        } else if slope < 0.5 {
            color = .gray
        } else if slope < 1.5 {
            color = .blue
        } else {
            color = .purple
        }

        return LinearGradient(
            colors: [color.opacity(0.8), color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct PowerSpectrumGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                // Vertical grid lines
                for i in 0...4 {
                    let x = geometry.size.width * CGFloat(i) / 4
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }

                // Horizontal grid lines
                for i in 0...4 {
                    let y = geometry.size.height * CGFloat(i) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(.tertiary.opacity(0.5), lineWidth: 0.5)
        }
    }
}

#Preview {
    PowerSpectrumFormView(formState: GeneratorFormState())
        .padding()
        .frame(width: 350)
}
