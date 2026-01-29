//
//  AIDataAssistant.swift
//  Implore
//
//  AI assistant for data analysis tasks in implore.
//

import Foundation
import ImpressAI
import OSLog

private let logger = Logger(subsystem: "com.implore.app", category: "aiDataAssistant")

// MARK: - Data Assistant

/// AI assistant for data analysis tasks in implore.
///
/// Features:
/// - Formula generation: Generate mathematical formulas from descriptions
/// - Data interpretation: Describe statistical patterns and insights
/// - Calculation explanation: Explain complex calculations
@MainActor
@Observable
public final class AIDataAssistant {

    /// Shared singleton instance.
    public static let shared = AIDataAssistant()

    private let providerManager: AIProviderManager
    private let categoryManager: AITaskCategoryManager
    private let executor: AIMultiModelExecutor

    /// Whether the assistant is currently processing.
    public private(set) var isProcessing = false

    /// Last error message, if any.
    public var errorMessage: String?

    public init(
        providerManager: AIProviderManager = .shared,
        categoryManager: AITaskCategoryManager = .shared,
        executor: AIMultiModelExecutor = .shared
    ) {
        self.providerManager = providerManager
        self.categoryManager = categoryManager
        self.executor = executor
    }

    // MARK: - Formula Generation

    /// Generate a mathematical formula from a description.
    ///
    /// - Parameters:
    ///   - description: Natural language description of the desired formula
    ///   - context: Additional context (e.g., variable names, constraints)
    /// - Returns: Generated formula with explanation
    public func generateFormula(
        description: String,
        context: String? = nil
    ) async throws -> FormulaResult {
        isProcessing = true
        defer { isProcessing = false }

        let systemPrompt = """
        You are a mathematical formula assistant. Generate formulas based on descriptions.

        For each formula, provide:
        1. The formula in standard mathematical notation
        2. The formula in a format suitable for computation (e.g., Python/Excel syntax)
        3. Variable definitions
        4. Brief explanation
        5. Example calculation

        Format as JSON:
        {
            "formula_math": "The formula in mathematical notation",
            "formula_code": "The formula in code syntax",
            "variables": [
                {"name": "x", "description": "Description of x"}
            ],
            "explanation": "Brief explanation of the formula",
            "example": {
                "inputs": {"x": 5},
                "result": 25,
                "calculation": "5^2 = 25"
            }
        }
        """

        var content = "Generate a formula for: \(description)"
        if let context = context {
            content += "\n\nContext: \(context)"
        }

        let request = AICompletionRequest(
            messages: [AIMessage(role: .user, text: content)],
            systemPrompt: systemPrompt,
            maxTokens: 1000
        )

        do {
            let result = try await executor.executePrimary(request, categoryId: "data.generate")

            guard let response = result, let text = response.text else {
                throw AIDataError.noResponse
            }

            let formula = try parseFormulaResult(text, description: description)
            logger.debug("Generated formula for: \(description)")
            return formula
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Data Interpretation

    /// Interpret statistical data and describe patterns.
    ///
    /// - Parameters:
    ///   - data: The data to interpret (as a formatted string)
    ///   - dataType: Type of data (e.g., "time series", "distribution")
    ///   - question: Specific question about the data (optional)
    /// - Returns: Interpretation with insights
    public func interpretData(
        data: String,
        dataType: String? = nil,
        question: String? = nil
    ) async throws -> DataInterpretation {
        isProcessing = true
        defer { isProcessing = false }

        let systemPrompt = """
        You are a data analysis assistant. Interpret the given data and provide insights.

        Analyze the data for:
        1. Key patterns and trends
        2. Statistical summary (mean, median, range, etc. if applicable)
        3. Anomalies or outliers
        4. Recommendations or next steps

        Format as JSON:
        {
            "summary": "Brief overall summary",
            "patterns": ["pattern 1", "pattern 2"],
            "statistics": {
                "mean": 10.5,
                "median": 10,
                "range": "5-15"
            },
            "anomalies": ["anomaly description"],
            "insights": ["insight 1", "insight 2"],
            "recommendations": ["recommendation 1"]
        }
        """

        var content = "Interpret this data:\n\(data)"
        if let dataType = dataType {
            content += "\n\nData type: \(dataType)"
        }
        if let question = question {
            content += "\n\nSpecific question: \(question)"
        }

        let request = AICompletionRequest(
            messages: [AIMessage(role: .user, text: content)],
            systemPrompt: systemPrompt,
            maxTokens: 1500
        )

        do {
            let result = try await executor.executePrimary(request, categoryId: "data.interpret")

            guard let response = result, let text = response.text else {
                throw AIDataError.noResponse
            }

            let interpretation = try parseDataInterpretation(text)
            logger.debug("Interpreted data successfully")
            return interpretation
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Calculation Explanation

    /// Explain a calculation step by step.
    ///
    /// - Parameters:
    ///   - expression: The calculation expression
    ///   - values: Variable values for the calculation
    /// - Returns: Step-by-step explanation
    public func explainCalculation(
        expression: String,
        values: [String: Double] = [:]
    ) async throws -> CalculationExplanation {
        isProcessing = true
        defer { isProcessing = false }

        let systemPrompt = """
        You are a calculation tutor. Explain calculations step by step.

        For each calculation:
        1. Break down into individual steps
        2. Explain the order of operations
        3. Show intermediate results
        4. Provide the final answer

        Format as JSON:
        {
            "expression": "The original expression",
            "steps": [
                {"step": 1, "operation": "description", "result": "intermediate result"}
            ],
            "final_result": "The final answer",
            "notes": ["Any important notes"]
        }
        """

        var content = "Explain this calculation: \(expression)"
        if !values.isEmpty {
            let valuesStr = values.map { "\($0.key) = \($0.value)" }.joined(separator: ", ")
            content += "\n\nWith values: \(valuesStr)"
        }

        let request = AICompletionRequest(
            messages: [AIMessage(role: .user, text: content)],
            systemPrompt: systemPrompt,
            maxTokens: 1000
        )

        do {
            let result = try await executor.executePrimary(request, categoryId: "data.interpret")

            guard let response = result, let text = response.text else {
                throw AIDataError.noResponse
            }

            let explanation = try parseCalculationExplanation(text, expression: expression)
            logger.debug("Explained calculation: \(expression)")
            return explanation
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Unit Conversion

    /// Suggest and explain unit conversions.
    ///
    /// - Parameters:
    ///   - value: The value to convert
    ///   - fromUnit: Source unit
    ///   - toUnit: Target unit (optional, will suggest if not provided)
    /// - Returns: Conversion result with explanation
    public func convertUnits(
        value: Double,
        fromUnit: String,
        toUnit: String? = nil
    ) async throws -> UnitConversionResult {
        isProcessing = true
        defer { isProcessing = false }

        let systemPrompt = """
        You are a unit conversion assistant. Convert values between units accurately.

        Provide:
        1. The converted value
        2. The conversion factor used
        3. Brief explanation of the conversion

        Format as JSON:
        {
            "original_value": 100,
            "original_unit": "meters",
            "converted_value": 328.084,
            "converted_unit": "feet",
            "conversion_factor": 3.28084,
            "formula": "meters × 3.28084 = feet",
            "explanation": "Brief explanation"
        }
        """

        var content = "Convert \(value) \(fromUnit)"
        if let toUnit = toUnit {
            content += " to \(toUnit)"
        } else {
            content += " (suggest appropriate conversions)"
        }

        let request = AICompletionRequest(
            messages: [AIMessage(role: .user, text: content)],
            systemPrompt: systemPrompt,
            maxTokens: 500
        )

        do {
            let result = try await executor.executePrimary(request, categoryId: "data.generate")

            guard let response = result, let text = response.text else {
                throw AIDataError.noResponse
            }

            let conversion = try parseUnitConversion(text, originalValue: value, originalUnit: fromUnit)
            logger.debug("Converted \(value) \(fromUnit)")
            return conversion
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Parsing Helpers

    private func parseFormulaResult(_ text: String, description: String) throws -> FormulaResult {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8) else {
            throw AIDataError.parseError("Failed to parse response")
        }

        do {
            let decoded = try JSONDecoder().decode(FormulaJSON.self, from: data)
            return FormulaResult(
                description: description,
                formulaMath: decoded.formula_math ?? "",
                formulaCode: decoded.formula_code ?? "",
                variables: decoded.variables?.map { FormulaVariable(name: $0.name, description: $0.description) } ?? [],
                explanation: decoded.explanation ?? "",
                example: decoded.example.map { FormulaExample(inputs: $0.inputs ?? [:], result: $0.result ?? 0, calculation: $0.calculation ?? "") }
            )
        } catch {
            // Fall back to raw text
            return FormulaResult(
                description: description,
                formulaMath: text,
                formulaCode: "",
                variables: [],
                explanation: "",
                example: nil
            )
        }
    }

    private func parseDataInterpretation(_ text: String) throws -> DataInterpretation {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8) else {
            throw AIDataError.parseError("Failed to parse response")
        }

        do {
            let decoded = try JSONDecoder().decode(InterpretationJSON.self, from: data)
            return DataInterpretation(
                summary: decoded.summary ?? "",
                patterns: decoded.patterns ?? [],
                statistics: decoded.statistics ?? [:],
                anomalies: decoded.anomalies ?? [],
                insights: decoded.insights ?? [],
                recommendations: decoded.recommendations ?? []
            )
        } catch {
            return DataInterpretation(
                summary: text,
                patterns: [],
                statistics: [:],
                anomalies: [],
                insights: [],
                recommendations: []
            )
        }
    }

    private func parseCalculationExplanation(_ text: String, expression: String) throws -> CalculationExplanation {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8) else {
            throw AIDataError.parseError("Failed to parse response")
        }

        do {
            let decoded = try JSONDecoder().decode(ExplanationJSON.self, from: data)
            return CalculationExplanation(
                expression: expression,
                steps: decoded.steps?.map { CalculationStep(step: $0.step, operation: $0.operation, result: $0.result) } ?? [],
                finalResult: decoded.final_result ?? "",
                notes: decoded.notes ?? []
            )
        } catch {
            return CalculationExplanation(
                expression: expression,
                steps: [],
                finalResult: text,
                notes: []
            )
        }
    }

    private func parseUnitConversion(_ text: String, originalValue: Double, originalUnit: String) throws -> UnitConversionResult {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8) else {
            throw AIDataError.parseError("Failed to parse response")
        }

        do {
            let decoded = try JSONDecoder().decode(ConversionJSON.self, from: data)
            return UnitConversionResult(
                originalValue: originalValue,
                originalUnit: originalUnit,
                convertedValue: decoded.converted_value ?? 0,
                convertedUnit: decoded.converted_unit ?? "",
                conversionFactor: decoded.conversion_factor ?? 1,
                formula: decoded.formula ?? "",
                explanation: decoded.explanation ?? ""
            )
        } catch {
            return UnitConversionResult(
                originalValue: originalValue,
                originalUnit: originalUnit,
                convertedValue: 0,
                convertedUnit: "",
                conversionFactor: 1,
                formula: "",
                explanation: text
            )
        }
    }

    private func extractJSON(from text: String) -> String {
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }
}

// MARK: - Result Types

/// Result of formula generation.
public struct FormulaResult: Sendable {
    public let description: String
    public let formulaMath: String
    public let formulaCode: String
    public let variables: [FormulaVariable]
    public let explanation: String
    public let example: FormulaExample?
}

/// Variable in a formula.
public struct FormulaVariable: Sendable {
    public let name: String
    public let description: String
}

/// Example calculation for a formula.
public struct FormulaExample: Sendable {
    public let inputs: [String: Double]
    public let result: Double
    public let calculation: String
}

/// Interpretation of data.
public struct DataInterpretation: Sendable {
    public let summary: String
    public let patterns: [String]
    public let statistics: [String: AnyCodable]
    public let anomalies: [String]
    public let insights: [String]
    public let recommendations: [String]
}

/// Step-by-step calculation explanation.
public struct CalculationExplanation: Sendable {
    public let expression: String
    public let steps: [CalculationStep]
    public let finalResult: String
    public let notes: [String]
}

/// Single step in a calculation.
public struct CalculationStep: Sendable {
    public let step: Int
    public let operation: String
    public let result: String
}

/// Result of unit conversion.
public struct UnitConversionResult: Sendable {
    public let originalValue: Double
    public let originalUnit: String
    public let convertedValue: Double
    public let convertedUnit: String
    public let conversionFactor: Double
    public let formula: String
    public let explanation: String
}

/// Type-erased codable value for statistics.
public struct AnyCodable: Sendable, Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let string = value as? String {
            try container.encode(string)
        }
    }
}

// MARK: - JSON Decoding Types

private struct FormulaJSON: Decodable {
    let formula_math: String?
    let formula_code: String?
    let variables: [VariableJSON]?
    let explanation: String?
    let example: ExampleJSON?
}

private struct VariableJSON: Decodable {
    let name: String
    let description: String
}

private struct ExampleJSON: Decodable {
    let inputs: [String: Double]?
    let result: Double?
    let calculation: String?
}

private struct InterpretationJSON: Decodable {
    let summary: String?
    let patterns: [String]?
    let statistics: [String: AnyCodable]?
    let anomalies: [String]?
    let insights: [String]?
    let recommendations: [String]?
}

private struct ExplanationJSON: Decodable {
    let expression: String?
    let steps: [StepJSON]?
    let final_result: String?
    let notes: [String]?
}

private struct StepJSON: Decodable {
    let step: Int
    let operation: String
    let result: String
}

private struct ConversionJSON: Decodable {
    let converted_value: Double?
    let converted_unit: String?
    let conversion_factor: Double?
    let formula: String?
    let explanation: String?
}

// MARK: - Errors

/// Errors that can occur during AI data operations.
public enum AIDataError: LocalizedError {
    case noResponse
    case parseError(String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .noResponse:
            return "No response from AI provider"
        case .parseError(let detail):
            return "Failed to parse response: \(detail)"
        case .notConfigured:
            return "AI is not configured. Please add an API key in Settings."
        }
    }
}
