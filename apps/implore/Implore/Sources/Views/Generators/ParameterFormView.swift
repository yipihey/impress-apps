import SwiftUI
import ImploreCore

/// Generic form builder from ParameterSpec array
struct ParameterFormView: View {
    let specs: [ParameterSpec]
    var formState: GeneratorFormState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(specs, id: \.name) { spec in
                ParameterField(spec: spec, formState: formState)
            }
        }
    }
}

/// Dispatcher to type-specific controls
struct ParameterField: View {
    let spec: ParameterSpec
    var formState: GeneratorFormState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Label with optional tooltip
            HStack {
                Text(spec.label)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if let description = spec.description {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(description)
                }
            }

            // Type-specific control
            Group {
                switch spec.paramType {
                case .float:
                    FloatParameterView(spec: spec, formState: formState)
                case .int:
                    IntParameterView(spec: spec, formState: formState)
                case .bool:
                    BoolParameterView(spec: spec, formState: formState)
                case .string:
                    StringParameterView(spec: spec, formState: formState)
                case .vec2:
                    Vec2ParameterView(spec: spec, formState: formState)
                case .vec3:
                    Vec3ParameterView(spec: spec, formState: formState)
                case .range(_, _):
                    RangeParameterView(spec: spec, formState: formState)
                case .choice(let options):
                    ChoiceParameterView(spec: spec, options: options, formState: formState)
                case .color:
                    ColorParameterView(spec: spec, formState: formState)
                case .polynomial:
                    PolynomialParameterView(spec: spec, formState: formState)
                }
            }

            // Validation error
            if let error = formState.validationErrors[spec.name] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityIdentifier("parameter.\(spec.name)")
    }
}

/// Float parameter with slider and text field
struct FloatParameterView: View {
    let spec: ParameterSpec
    var formState: GeneratorFormState

    var body: some View {
        let binding = formState.floatBinding(for: spec.name)
        let min = spec.constraints?.min ?? 0
        let max = spec.constraints?.max ?? 100
        let step = spec.constraints?.step ?? ((max - min) / 100)

        HStack {
            Slider(value: binding, in: min...max, step: step)
                .frame(maxWidth: .infinity)

            TextField("", value: binding, format: .number.precision(.fractionLength(2...4)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Int parameter with stepper (optional power-of-2 picker)
struct IntParameterView: View {
    let spec: ParameterSpec
    var formState: GeneratorFormState

    private var isPowerOfTwo: Bool {
        spec.constraints?.powerOfTwo ?? false
    }

    var body: some View {
        let binding = formState.intBinding(for: spec.name)

        if isPowerOfTwo {
            // Power-of-2 picker
            Picker(selection: binding) {
                ForEach([8, 16, 32, 64, 128, 256, 512, 1024, 2048], id: \.self) { value in
                    Text("\(value)").tag(Int64(value))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
        } else {
            // Regular stepper
            let min = Int64(spec.constraints?.min ?? 0)
            let max = Int64(spec.constraints?.max ?? 1000)
            let step = Int(spec.constraints?.step ?? 1)

            HStack {
                Stepper(value: binding, in: min...max, step: step) {
                    Text("\(binding.wrappedValue)")
                        .monospacedDigit()
                }
            }
        }
    }
}

/// Bool parameter toggle
struct BoolParameterView: View {
    let spec: ParameterSpec
    var formState: GeneratorFormState

    var body: some View {
        Toggle(isOn: formState.boolBinding(for: spec.name)) {
            EmptyView()
        }
        .toggleStyle(.switch)
    }
}

/// String parameter text field
struct StringParameterView: View {
    let spec: ParameterSpec
    var formState: GeneratorFormState

    var body: some View {
        TextField("", text: formState.stringBinding(for: spec.name))
            .textFieldStyle(.roundedBorder)
    }
}

/// Vec2 parameter with two fields
struct Vec2ParameterView: View {
    let spec: ParameterSpec
    var formState: GeneratorFormState
    @State private var x: Double = 0
    @State private var y: Double = 0

    var body: some View {
        HStack {
            Text("X:")
                .font(.caption)
            TextField("X", value: $x, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)

            Text("Y:")
                .font(.caption)
            TextField("Y", value: $y, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
        }
        .onAppear {
            let vec = formState.vecValue(for: spec.name)
            if vec.count >= 2 {
                x = vec[0]
                y = vec[1]
            }
        }
        .onChange(of: x) { _, newX in
            formState.setVec([newX, y], for: spec.name)
        }
        .onChange(of: y) { _, newY in
            formState.setVec([x, newY], for: spec.name)
        }
    }
}

/// Vec3 parameter with three fields
struct Vec3ParameterView: View {
    let spec: ParameterSpec
    var formState: GeneratorFormState
    @State private var x: Double = 0
    @State private var y: Double = 0
    @State private var z: Double = 0

    var body: some View {
        HStack {
            Text("X:")
                .font(.caption)
            TextField("X", value: $x, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)

            Text("Y:")
                .font(.caption)
            TextField("Y", value: $y, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)

            Text("Z:")
                .font(.caption)
            TextField("Z", value: $z, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
        }
        .onAppear {
            let vec = formState.vecValue(for: spec.name)
            if vec.count >= 3 {
                x = vec[0]
                y = vec[1]
                z = vec[2]
            }
        }
        .onChange(of: x) { _, newX in
            formState.setVec([newX, y, z], for: spec.name)
        }
        .onChange(of: y) { _, newY in
            formState.setVec([x, newY, z], for: spec.name)
        }
        .onChange(of: z) { _, newZ in
            formState.setVec([x, y, newZ], for: spec.name)
        }
    }
}

/// Range parameter
struct RangeParameterView: View {
    let spec: ParameterSpec
    var formState: GeneratorFormState
    @State private var minVal: Double = 0
    @State private var maxVal: Double = 1

    var body: some View {
        HStack {
            Text("Min:")
                .font(.caption)
            TextField("Min", value: $minVal, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)

            Text("Max:")
                .font(.caption)
            TextField("Max", value: $maxVal, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
        }
        .onAppear {
            let vec = formState.vecValue(for: spec.name)
            if vec.count >= 2 {
                minVal = vec[0]
                maxVal = vec[1]
            }
        }
        .onChange(of: minVal) { _, newMin in
            formState.setVec([newMin, maxVal], for: spec.name)
        }
        .onChange(of: maxVal) { _, newMax in
            formState.setVec([minVal, newMax], for: spec.name)
        }
    }
}

/// Choice parameter dropdown
struct ChoiceParameterView: View {
    let spec: ParameterSpec
    let options: [String]
    var formState: GeneratorFormState

    var body: some View {
        Picker(selection: formState.stringBinding(for: spec.name)) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
    }
}

/// Color parameter with color picker
struct ColorParameterView: View {
    let spec: ParameterSpec
    var formState: GeneratorFormState
    @State private var color: Color = .white

    var body: some View {
        ColorPicker("", selection: $color, supportsOpacity: true)
            .labelsHidden()
            .onAppear {
                let vec = formState.vecValue(for: spec.name)
                if vec.count >= 4 {
                    color = Color(
                        red: vec[0],
                        green: vec[1],
                        blue: vec[2],
                        opacity: vec[3]
                    )
                }
            }
            .onChange(of: color) { _, newColor in
                if let components = newColor.cgColor?.components {
                    let rgba = components.count >= 4
                        ? [Double(components[0]), Double(components[1]), Double(components[2]), Double(components[3])]
                        : [Double(components[0]), Double(components[0]), Double(components[0]), 1.0]
                    formState.setVec(rgba, for: spec.name)
                }
            }
    }
}

/// Polynomial parameter with button to open editor sheet
struct PolynomialParameterView: View {
    let spec: ParameterSpec
    var formState: GeneratorFormState
    @State private var showingEditor = false

    var body: some View {
        HStack {
            Text(polynomialDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button("Edit...") {
                showingEditor = true
            }
            .buttonStyle(.bordered)
        }
        .sheet(isPresented: $showingEditor) {
            PolynomialEditorSheet(
                coefficients: formState.vecValue(for: spec.name),
                onSave: { newCoeffs in
                    formState.setVec(newCoeffs, for: spec.name)
                }
            )
        }
    }

    private var polynomialDescription: String {
        let coeffs = formState.vecValue(for: spec.name)
        if coeffs.isEmpty {
            return "No coefficients"
        }

        var terms: [String] = []
        for (i, c) in coeffs.enumerated() {
            if c == 0 { continue }
            let sign = c >= 0 ? (terms.isEmpty ? "" : "+") : ""
            let coeff = String(format: "%.2f", c)
            if i == 0 {
                terms.append("\(sign)\(coeff)")
            } else if i == 1 {
                terms.append("\(sign)\(coeff)x")
            } else {
                terms.append("\(sign)\(coeff)x^\(i)")
            }
        }

        return terms.isEmpty ? "0" : terms.joined(separator: " ")
    }
}

#Preview {
    let specs = [
        ParameterSpec(
            name: "frequency",
            label: "Frequency",
            paramType: .float,
            defaultValue: .float(4.0),
            constraints: ParameterConstraints(min: 0.1, max: 64.0, step: 0.1, positive: true, powerOfTwo: false),
            description: "Base frequency of the pattern"
        ),
        ParameterSpec(
            name: "resolution",
            label: "Resolution",
            paramType: .int,
            defaultValue: .int(256),
            constraints: ParameterConstraints(min: 8, max: 2048, step: nil, positive: true, powerOfTwo: true),
            description: "Output resolution"
        ),
        ParameterSpec(
            name: "animate",
            label: "Animate",
            paramType: .bool,
            defaultValue: .bool(false),
            constraints: nil,
            description: "Enable animation"
        ),
        ParameterSpec(
            name: "function",
            label: "Function",
            paramType: .choice(options: ["sin(x)*cos(y)", "x²+y²", "exp(-(x²+y²))"]),
            defaultValue: .string("sin(x)*cos(y)"),
            constraints: nil,
            description: "Mathematical function"
        ),
    ]

    let formState = GeneratorFormState()

    ParameterFormView(specs: specs, formState: formState)
        .padding()
        .frame(width: 300)
}
