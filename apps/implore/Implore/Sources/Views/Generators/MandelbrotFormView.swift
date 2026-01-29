import SwiftUI
import ImploreCore

/// Custom form view for Mandelbrot set generator with interactive zoom and presets
struct MandelbrotFormView: View {
    var formState: GeneratorFormState
    @State private var selectedPreset: MandelbrotPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Preview with click-to-zoom
            MandelbrotPreview(
                centerX: formState.floatValue(for: "center_x"),
                centerY: formState.floatValue(for: "center_y"),
                zoom: formState.floatValue(for: "zoom"),
                onZoom: { newX, newY, newZoom in
                    formState.setFloat(newX, for: "center_x")
                    formState.setFloat(newY, for: "center_y")
                    formState.setFloat(newZoom, for: "zoom")
                }
            )

            // Presets
            Section {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(MandelbrotPreset.allPresets, id: \.name) { preset in
                            PresetButton(preset: preset, isSelected: selectedPreset?.name == preset.name) {
                                applyPreset(preset)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            } header: {
                Text("Presets")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Divider()

            // Manual controls
            Section {
                VStack(spacing: 12) {
                    // Center X
                    ParameterRow(label: "Center X") {
                        HStack {
                            Slider(
                                value: formState.floatBinding(for: "center_x"),
                                in: -3...3
                            )
                            TextField(
                                "",
                                value: formState.floatBinding(for: "center_x"),
                                format: .number.precision(.fractionLength(6))
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        }
                    }

                    // Center Y
                    ParameterRow(label: "Center Y") {
                        HStack {
                            Slider(
                                value: formState.floatBinding(for: "center_y"),
                                in: -2...2
                            )
                            TextField(
                                "",
                                value: formState.floatBinding(for: "center_y"),
                                format: .number.precision(.fractionLength(6))
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        }
                    }

                    // Zoom (logarithmic slider)
                    ParameterRow(label: "Zoom") {
                        HStack {
                            Slider(
                                value: logZoomBinding,
                                in: -1...15
                            )
                            Text(zoomLabel)
                                .monospacedDigit()
                                .frame(width: 80, alignment: .trailing)
                        }
                    }

                    // Max iterations
                    ParameterRow(label: "Iterations") {
                        Picker("", selection: formState.intBinding(for: "max_iterations")) {
                            Text("100").tag(Int64(100))
                            Text("500").tag(Int64(500))
                            Text("1000").tag(Int64(1000))
                            Text("2000").tag(Int64(2000))
                            Text("5000").tag(Int64(5000))
                        }
                        .pickerStyle(.segmented)
                    }

                    // Resolution
                    ParameterRow(label: "Resolution") {
                        Picker("", selection: formState.intBinding(for: "resolution")) {
                            Text("256").tag(Int64(256))
                            Text("512").tag(Int64(512))
                            Text("1024").tag(Int64(1024))
                            Text("2048").tag(Int64(2048))
                        }
                        .pickerStyle(.segmented)
                    }
                }
            } header: {
                Text("Parameters")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
        }
        .accessibilityIdentifier("generator.mandelbrotForm")
    }

    private var logZoomBinding: Binding<Double> {
        Binding(
            get: { log10(max(formState.floatValue(for: "zoom"), 0.1)) },
            set: { formState.setFloat(pow(10, $0), for: "zoom") }
        )
    }

    private var zoomLabel: String {
        let zoom = formState.floatValue(for: "zoom")
        if zoom >= 1e9 {
            return String(format: "%.1e", zoom)
        } else if zoom >= 1000 {
            return String(format: "%.0f", zoom)
        } else {
            return String(format: "%.1f", zoom)
        }
    }

    private func applyPreset(_ preset: MandelbrotPreset) {
        selectedPreset = preset
        formState.setFloat(preset.centerX, for: "center_x")
        formState.setFloat(preset.centerY, for: "center_y")
        formState.setFloat(preset.zoom, for: "zoom")
        formState.setInt(Int64(preset.iterations), for: "max_iterations")
    }
}

/// Interactive Mandelbrot preview with click-to-zoom
struct MandelbrotPreview: View {
    let centerX: Double
    let centerY: Double
    let zoom: Double
    let onZoom: (Double, Double, Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Placeholder for actual Mandelbrot rendering
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [.black, .blue, .purple, .orange, .yellow],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))

                VStack {
                    Image(systemName: "sparkles")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.5))

                    Text("Click to zoom")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                // Crosshair
                Path { path in
                    let mid = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    path.move(to: CGPoint(x: mid.x - 10, y: mid.y))
                    path.addLine(to: CGPoint(x: mid.x + 10, y: mid.y))
                    path.move(to: CGPoint(x: mid.x, y: mid.y - 10))
                    path.addLine(to: CGPoint(x: mid.x, y: mid.y + 10))
                }
                .stroke(.white.opacity(0.5), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { event in
                        handleTap(at: event.location, in: geometry.size)
                    }
            )
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func handleTap(at point: CGPoint, in size: CGSize) {
        // Convert tap location to complex plane coordinates
        let aspect = size.width / size.height
        let width = 4.0 / zoom * aspect
        let height = 4.0 / zoom

        let relX = (point.x / size.width - 0.5) * width
        let relY = (point.y / size.height - 0.5) * height

        let newX = centerX + relX
        let newY = centerY - relY // Y is inverted
        let newZoom = zoom * 2.0 // 2x zoom on click

        onZoom(newX, newY, newZoom)
    }
}

/// Named presets for interesting Mandelbrot locations
struct MandelbrotPreset {
    let name: String
    let centerX: Double
    let centerY: Double
    let zoom: Double
    let iterations: Int

    static let allPresets: [MandelbrotPreset] = [
        MandelbrotPreset(name: "Overview", centerX: -0.5, centerY: 0, zoom: 1, iterations: 100),
        MandelbrotPreset(name: "Seahorse Valley", centerX: -0.745, centerY: 0.113, zoom: 50, iterations: 500),
        MandelbrotPreset(name: "Elephant Valley", centerX: 0.275, centerY: 0.006, zoom: 100, iterations: 500),
        MandelbrotPreset(name: "Triple Spiral", centerX: -0.088, centerY: 0.654, zoom: 2000, iterations: 1000),
        MandelbrotPreset(name: "Mini Mandelbrot", centerX: -1.7685, centerY: 0.0, zoom: 1000, iterations: 1000),
        MandelbrotPreset(name: "Deep Zoom", centerX: -0.743643887, centerY: 0.131825904, zoom: 1e6, iterations: 2000),
    ]
}

/// Preset button
struct PresetButton: View {
    let preset: MandelbrotPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(preset.name)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Helper for parameter rows
struct ParameterRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

#Preview {
    MandelbrotFormView(formState: GeneratorFormState())
        .padding()
        .frame(width: 350)
}
