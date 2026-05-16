import AppIntents
import Foundation

// MARK: - List Veusz Plots

@available(macOS 14.0, iOS 17.0, *)
public struct ListVeuszPlotsIntent: AppIntent {
    public static var title: LocalizedStringResource = "List Veusz Plots"
    public static var description = IntentDescription(
        "List Veusz plots tracked by a manuscript.",
        categoryName: "Plots"
    )

    @Parameter(title: "Document", description: "Limit to plots in this document (optional)")
    public var document: DocumentEntity?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("List Veusz plots in \(\.$document)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[VeuszPlotEntity]> {
        guard let service = await ImprintIntentServiceLocator.service else {
            throw ImprintIntentError.automationDisabled
        }
        let plots = try await service.listVeuszPlots(documentID: document?.id)
        return .result(value: plots)
    }
}

// MARK: - Open Veusz Plot

@available(macOS 14.0, iOS 17.0, *)
public struct OpenVeuszPlotIntent: AppIntent {
    public static var title: LocalizedStringResource = "Open Veusz Plot"
    public static var description = IntentDescription(
        "Open a Veusz plot's .vsz source in the Veusz GUI for editing.",
        categoryName: "Plots"
    )

    @Parameter(title: "Plot")
    public var plot: VeuszPlotEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$plot) in Veusz")
    }

    public func perform() async throws -> some IntentResult {
        guard let service = await ImprintIntentServiceLocator.service else {
            throw ImprintIntentError.automationDisabled
        }
        try await service.openVeuszPlot(plotID: plot.id)
        return .result()
    }
}

// MARK: - Render Veusz Plot

@available(macOS 14.0, iOS 17.0, *)
public struct RenderVeuszPlotIntent: AppIntent {
    public static var title: LocalizedStringResource = "Re-render Veusz Plot"
    public static var description = IntentDescription(
        "Re-render a Veusz plot's .vsz to its rendered output (SVG/PNG/PDF).",
        categoryName: "Plots"
    )

    @Parameter(title: "Plot")
    public var plot: VeuszPlotEntity

    @Parameter(title: "Format", description: "Optional override (svg, png, or pdf). Defaults to the plot's preferred format.")
    public var format: String?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Re-render \(\.$plot)") {
            \.$format
        }
    }

    public func perform() async throws -> some IntentResult {
        guard let service = await ImprintIntentServiceLocator.service else {
            throw ImprintIntentError.automationDisabled
        }
        try await service.renderVeuszPlot(plotID: plot.id, format: format)
        return .result()
    }
}

// MARK: - Insert Veusz Plot

@available(macOS 14.0, iOS 17.0, *)
public struct InsertVeuszPlotIntent: AppIntent {
    public static var title: LocalizedStringResource = "Insert Veusz Plot"
    public static var description = IntentDescription(
        "Insert a figure block referencing a Veusz plot's rendered output at the document's cursor.",
        categoryName: "Plots"
    )

    @Parameter(title: "Plot")
    public var plot: VeuszPlotEntity

    @Parameter(title: "Document")
    public var document: DocumentEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Insert \(\.$plot) into \(\.$document)")
    }

    public func perform() async throws -> some IntentResult {
        guard let service = await ImprintIntentServiceLocator.service else {
            throw ImprintIntentError.automationDisabled
        }
        try await service.insertVeuszPlot(plotID: plot.id, documentID: document.id)
        return .result()
    }
}

// MARK: - Create Veusz Plot

@available(macOS 14.0, iOS 17.0, *)
public struct CreateVeuszPlotIntent: AppIntent {
    public static var title: LocalizedStringResource = "Create Veusz Plot"
    public static var description = IntentDescription(
        "Create a new Veusz plot inside a manuscript and open it in Veusz.",
        categoryName: "Plots"
    )

    @Parameter(title: "Document")
    public var document: DocumentEntity

    @Parameter(title: "Plot Name", description: "Name for the new plot (used as the .vsz filename)")
    public var name: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Create plot \(\.$name) in \(\.$document)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<VeuszPlotEntity> {
        guard let service = await ImprintIntentServiceLocator.service else {
            throw ImprintIntentError.automationDisabled
        }
        let plot = try await service.createVeuszPlot(documentID: document.id, name: name)
        return .result(value: plot)
    }
}
