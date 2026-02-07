import AppIntents
import Foundation

// MARK: - List Figures

@available(macOS 14.0, *)
public struct ListFiguresIntent: AppIntent {
    public static var title: LocalizedStringResource = "List Figures"
    public static var description = IntentDescription(
        "List all figures in the implore library.",
        categoryName: "Figures"
    )

    @Parameter(title: "Dataset", description: "Filter by dataset name (optional)")
    public var dataset: String?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("List figures") {
            \.$dataset
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[FigureEntity]> {
        // TODO: Connect to LibraryManager
        return .result(value: [])
    }
}

// MARK: - Export Figure

@available(macOS 14.0, *)
public struct ExportFigureIntent: AppIntent {
    public static var title: LocalizedStringResource = "Export Figure"
    public static var description = IntentDescription(
        "Export a figure in the specified format.",
        categoryName: "Figures"
    )

    @Parameter(title: "Figure")
    public var figure: FigureEntity

    @Parameter(title: "Format", description: "The export format", default: .png)
    public var format: ImploreExportFormat

    @Parameter(title: "Width", description: "Width in pixels", default: 1200)
    public var width: Int

    @Parameter(title: "Height", description: "Height in pixels", default: 800)
    public var height: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$figure) as \(\.$format)") {
            \.$width
            \.$height
        }
    }

    public func perform() async throws -> some IntentResult {
        // TODO: Connect to figure export pipeline
        return .result()
    }
}

// MARK: - Create Figure

@available(macOS 14.0, *)
public struct CreateFigureIntent: AppIntent {
    public static var title: LocalizedStringResource = "Create Figure"
    public static var description = IntentDescription(
        "Create a new figure from a dataset.",
        categoryName: "Figures"
    )

    @Parameter(title: "Title", description: "Figure title")
    public var title: String

    @Parameter(title: "Dataset", description: "Dataset to visualize")
    public var dataset: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Create figure \(\.$title) from \(\.$dataset)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<FigureEntity> {
        // TODO: Connect to LibraryManager to create figure
        let figure = FigureEntity(id: UUID(), title: title, datasetName: dataset)
        return .result(value: figure)
    }
}

// MARK: - Open Figure

@available(macOS 14.0, *)
public struct OpenFigureIntent: AppIntent {
    public static var title: LocalizedStringResource = "Open Figure"
    public static var description = IntentDescription(
        "Open a figure in the implore viewer.",
        categoryName: "Figures"
    )

    @Parameter(title: "Figure")
    public var figure: FigureEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$figure)")
    }

    public func perform() async throws -> some IntentResult {
        // TODO: Post notification to navigate to figure
        return .result()
    }
}
