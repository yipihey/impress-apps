import XCTest
@testable import ImpressAI

/// The model picker's row selection is pure so the settings pane can never
/// hide a model: helpers only on request, the filter matches name or id, and
/// the model in effect stays visible whatever the filter says.
final class AIModelPickerListTests: XCTestCase {
    private let models: [AIModel] = [
        AIModel(id: "mlx-community--Qwen3.5-4B-4bit", name: "Qwen3.5 4B 4bit"),
        AIModel(id: "mlx-community--Llama-3.2-3B-Instruct-bf16", name: "Llama 3.2 3B Instruct bf16"),
        AIModel(id: "MarkItDown", name: "MarkItDown", isHelper: true),
    ]

    func testHelpersAreListedOnlyOnRequest() {
        let hidden = AIModelPickerList.visibleModels(models, showHelpers: false, query: "", selection: nil)
        XCTAssertEqual(hidden.map(\.id), ["mlx-community--Qwen3.5-4B-4bit", "mlx-community--Llama-3.2-3B-Instruct-bf16"])
        let shown = AIModelPickerList.visibleModels(models, showHelpers: true, query: "", selection: nil)
        XCTAssertEqual(shown.count, 3)
    }

    func testFilterMatchesFriendlyNameOrRawId() {
        let byName = AIModelPickerList.visibleModels(models, showHelpers: false, query: "llama", selection: nil)
        XCTAssertEqual(byName.map(\.id), ["mlx-community--Llama-3.2-3B-Instruct-bf16"])
        let byId = AIModelPickerList.visibleModels(models, showHelpers: false, query: "qwen3.5-4b", selection: nil)
        XCTAssertEqual(byId.map(\.id), ["mlx-community--Qwen3.5-4B-4bit"])
    }

    func testTheSelectedModelSurvivesAnyFilter() {
        let visible = AIModelPickerList.visibleModels(
            models, showHelpers: false, query: "llama", selection: "mlx-community--Qwen3.5-4B-4bit")
        XCTAssertEqual(Set(visible.map(\.id)), ["mlx-community--Qwen3.5-4B-4bit", "mlx-community--Llama-3.2-3B-Instruct-bf16"])
    }

    func testSummaryCountsUsableModelsAndHiddenHelpers() {
        XCTAssertEqual(AIModelPickerList.summary(models: models, refreshedAt: nil), "2 models · 1 helper hidden")
    }
}
