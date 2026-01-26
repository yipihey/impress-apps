import Foundation
import ImploreCore
import SwiftUI

/// Observable state for generator parameter forms.
///
/// This class manages the current parameter values and provides
/// bindings for SwiftUI form controls.
@MainActor
public final class GeneratorFormState: ObservableObject {
    /// Parameter values keyed by name
    @Published private var values: [String: ParameterValue] = [:]

    /// The parameter specifications for the current generator
    @Published public private(set) var specs: [ParameterSpec] = []

    /// The generator ID this form is for
    @Published public private(set) var generatorId: String?

    /// Validation errors for parameters
    @Published public private(set) var validationErrors: [String: String] = [:]

    public init() {}

    /// Configure the form for a specific generator
    public func configure(for metadata: GeneratorMetadata) {
        generatorId = metadata.id
        specs = metadata.parameters
        values = [:]
        validationErrors = [:]

        // Initialize with default values
        for spec in specs {
            values[spec.name] = spec.defaultValue
        }
    }

    /// Reset to default values
    public func resetToDefaults() {
        validationErrors = [:]
        for spec in specs {
            values[spec.name] = spec.defaultValue
        }
    }

    /// Get the current parameters as JSON
    public func toJson() -> String {
        var dict: [String: Any] = [:]

        for (name, value) in values {
            switch value {
            case .float(let v):
                dict[name] = ["Float": v]
            case .int(let v):
                dict[name] = ["Int": v]
            case .bool(let v):
                dict[name] = ["Bool": v]
            case .string(let v):
                dict[name] = ["String": v]
            case .vec(let v):
                dict[name] = ["Vec": v]
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return json
    }

    // MARK: - Value Accessors

    public func floatValue(for name: String) -> Double {
        if case .float(let v) = values[name] {
            return v
        }
        if case .int(let v) = values[name] {
            return Double(v)
        }
        return 0.0
    }

    public func intValue(for name: String) -> Int64 {
        if case .int(let v) = values[name] {
            return v
        }
        if case .float(let v) = values[name] {
            return Int64(v)
        }
        return 0
    }

    public func boolValue(for name: String) -> Bool {
        if case .bool(let v) = values[name] {
            return v
        }
        return false
    }

    public func stringValue(for name: String) -> String {
        if case .string(let v) = values[name] {
            return v
        }
        return ""
    }

    public func vecValue(for name: String) -> [Double] {
        if case .vec(let v) = values[name] {
            return v
        }
        return []
    }

    // MARK: - Value Setters

    public func setFloat(_ value: Double, for name: String) {
        values[name] = .float(value)
        validateParameter(name)
    }

    public func setInt(_ value: Int64, for name: String) {
        values[name] = .int(value)
        validateParameter(name)
    }

    public func setBool(_ value: Bool, for name: String) {
        values[name] = .bool(value)
    }

    public func setString(_ value: String, for name: String) {
        values[name] = .string(value)
    }

    public func setVec(_ value: [Double], for name: String) {
        values[name] = .vec(value)
    }

    // MARK: - Bindings

    public func floatBinding(for name: String) -> Binding<Double> {
        Binding(
            get: { self.floatValue(for: name) },
            set: { self.setFloat($0, for: name) }
        )
    }

    public func intBinding(for name: String) -> Binding<Int64> {
        Binding(
            get: { self.intValue(for: name) },
            set: { self.setInt($0, for: name) }
        )
    }

    public func boolBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { self.boolValue(for: name) },
            set: { self.setBool($0, for: name) }
        )
    }

    public func stringBinding(for name: String) -> Binding<String> {
        Binding(
            get: { self.stringValue(for: name) },
            set: { self.setString($0, for: name) }
        )
    }

    // MARK: - Validation

    private func validateParameter(_ name: String) {
        guard let spec = specs.first(where: { $0.name == name }),
              let constraints = spec.constraints,
              let value = values[name] else {
            validationErrors.removeValue(forKey: name)
            return
        }

        var error: String?

        // Check float/int constraints
        if let floatVal = extractFloat(from: value) {
            if let min = constraints.min, floatVal < min {
                error = "Value must be at least \(min)"
            } else if let max = constraints.max, floatVal > max {
                error = "Value must be at most \(max)"
            } else if constraints.positive && floatVal <= 0 {
                error = "Value must be positive"
            }
        }

        // Check power of two constraint
        if constraints.powerOfTwo, case .int(let intVal) = value {
            if intVal <= 0 || (intVal & (intVal - 1)) != 0 {
                error = "Value must be a power of 2"
            }
        }

        if let error = error {
            validationErrors[name] = error
        } else {
            validationErrors.removeValue(forKey: name)
        }
    }

    private func extractFloat(from value: ParameterValue) -> Double? {
        switch value {
        case .float(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    /// Check if the form has validation errors
    public var hasErrors: Bool {
        !validationErrors.isEmpty
    }
}
