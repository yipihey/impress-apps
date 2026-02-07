import AppIntents

/// Shared figure export format enum used across Impress suite App Intents.
@available(macOS 14.0, iOS 17.0, *)
public enum FigureFormat: String, AppEnum, Sendable {
    case png
    case svg
    case typst
    case pdf

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Figure Format"
    }

    public static var caseDisplayRepresentations: [FigureFormat: DisplayRepresentation] {
        [
            .png: "PNG",
            .svg: "SVG",
            .typst: "Typst",
            .pdf: "PDF"
        ]
    }
}
