import UniformTypeIdentifiers

/// Custom UTType declarations for the Impress suite.
///
/// Hierarchy:
/// ```
/// public.data
///   com.impress.artifact              — base for all impress artifacts
///     com.impress.paper-reference     — UUID + citeKey + title
///     com.impress.document-reference  — UUID + title
///     com.impress.figure-reference    — UUID + format
///     com.impress.conversation-ref    — UUID + subject
///   com.impress.bibtex-entry          — full BibTeX (conforms to public.text)
///   com.impress.citation-key          — just a cite key string
/// ```
extension UTType {
    /// Base type for all Impress artifacts.
    public static let impressArtifact = UTType(
        exportedAs: "com.impress.artifact",
        conformingTo: .data
    )

    /// A lightweight cross-app paper reference (UUID + citeKey + title).
    public static let impressPaperReference = UTType(
        exportedAs: "com.impress.paper-reference",
        conformingTo: .impressArtifact
    )

    /// A cross-app document reference (UUID + title).
    public static let impressDocumentReference = UTType(
        exportedAs: "com.impress.document-reference",
        conformingTo: .impressArtifact
    )

    /// A cross-app figure reference (UUID + format).
    public static let impressFigureReference = UTType(
        exportedAs: "com.impress.figure-reference",
        conformingTo: .impressArtifact
    )

    /// A cross-app conversation reference (UUID + subject).
    public static let impressConversationReference = UTType(
        exportedAs: "com.impress.conversation-ref",
        conformingTo: .impressArtifact
    )

    /// A full BibTeX entry (conforms to public.text for plain-text fallback).
    public static let impressBibTeXEntry = UTType(
        exportedAs: "com.impress.bibtex-entry",
        conformingTo: .text
    )

    /// A single citation key string.
    public static let impressCitationKey = UTType(
        exportedAs: "com.impress.citation-key",
        conformingTo: .text
    )
}
