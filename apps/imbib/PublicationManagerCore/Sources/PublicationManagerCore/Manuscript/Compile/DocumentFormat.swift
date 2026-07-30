import Foundation
import ImbibRustCore

/// The manuscript source formats the suite understands, providing
/// format-specific constants for editing, preview, and citation insertion.
///
/// GUI-meld Phase 3: moved from the imprint app target into PublicationManagerCore
/// so the shared compile/edit stack (`ManuscriptCompileController`,
/// `SourceEditorView`) has a common format type in both imbib and imprint.
///
/// Stage 7 item 4: the *grammar* moved to Rust. This type used to carry eight
/// `switch self` statements — one per property — plus two `detect` heuristics.
/// All ten now read `impress_core::manuscript_format::MANUSCRIPT_FORMAT_GRAMMAR`
/// through `manuscriptFormatGrammar()`, one row per format, so a format's
/// behaviour is legible in one place and adding a format is one table row plus
/// one enum case here (see `DocumentFormatGrammar`). The public surface — the
/// cases and every property signature — is unchanged; there are dozens of call
/// sites and they should not have to care.
///
/// Cite-key *parsing* is not here and must not come here: finding `@key` /
/// `\cite{key}` in existing text is `imprint_core::citations::{extract, hit}`,
/// reachable from Swift as `citeKeyHits(source:syntax:)`. The `citationInsert`
/// affixes below are the editor-side *insertion* strings only.
public enum DocumentFormat: String, CaseIterable, Codable, Sendable {
    case typst
    case latex
    case markdown
    case plaintext

    /// How the non-source pane renders this format.
    public enum PreviewKind: String, Sendable {
        /// Compile the source (Typst in-process / LaTeX via tectonic) to PDF.
        case compiledPDF
        /// Render the live source with MarkdownUI — no compile step.
        case renderedMarkdown
        /// No rendered state (plain text) — the Preview tab is hidden.
        case none
    }

    /// This format's row of the Rust grammar table.
    var grammar: DocumentFormatGrammar.Row {
        DocumentFormatGrammar.row(for: rawValue)
    }

    public var previewKind: PreviewKind { grammar.previewKind }

    /// Whether this format has ANY rendered counterpart to the source — the
    /// single source of truth for showing/hiding a preview affordance
    /// (segmented control, split-view toggle, Preview tab). Plain text has
    /// none, so the affordance must not appear at all.
    public var hasPreview: Bool { grammar.hasPreview }

    /// Whether the preview is produced by a compile pass (Typst/LaTeX → PDF).
    /// Formats that render live from the buffer (Markdown) or have no preview
    /// at all must never schedule a compile.
    public var requiresCompile: Bool { grammar.requiresCompile }

    public var fileExtension: String { grammar.fileExtension }

    public var mainFileName: String { grammar.mainFileName }

    public var displayName: String { grammar.displayName }

    /// Line-comment prefix; nil disables comment toggling (Markdown has no
    /// line comments; plain text has no syntax at all).
    public var commentPrefix: String? { grammar.commentPrefix }

    /// Citation insertion delimiters; nil disables citation insert.
    /// Markdown uses the pandoc `@key` convention.
    public var citationInsert: (prefix: String, suffix: String)? { grammar.citationInsert }

    /// Bold wrapping; nil disables the Bold command.
    public var boldWrap: (prefix: String, suffix: String)? { grammar.boldWrap }

    /// Italic wrapping; nil disables the Italic command.
    public var italicWrap: (prefix: String, suffix: String)? { grammar.italicWrap }

    /// Default auto-compile/preview debounce in milliseconds.
    /// LaTeX compilation is heavy; Markdown re-renders are cheap.
    public var defaultDebounceMs: Int { Int(grammar.defaultDebounceMs) }

    /// Detect format from source content heuristics, optionally using the
    /// manuscript title as a hint (titles are often file names: "ADR-11.md").
    ///
    /// Used as the fallback when a stored `format` is missing or unrecognized —
    /// blindly assuming Typst there sends Markdown bodies into the Typst
    /// compiler, whose first complaint is `expected expression` on `# Heading`.
    public static func detect(from source: String, title: String? = nil) -> DocumentFormat {
        DocumentFormat(rawValue: detectManuscriptFormat(source: source, title: title)) ?? .typst
    }

    /// Detect format from a file extension string (without dot).
    public static func detect(fromExtension ext: String) -> DocumentFormat? {
        manuscriptFormatForExtension(ext: ext).flatMap(DocumentFormat.init(rawValue:))
    }
}

// MARK: - Cached Rust grammar table

/// The Rust grammar table, fetched once and cached.
///
/// Every value in it is a compile-time constant on the Rust side, so one FFI
/// call at first access is the whole cost — there is nothing to invalidate.
enum DocumentFormatGrammar {

    /// One format's grammar, as a Swift value type so the cache is `Sendable`
    /// without depending on how UniFFI happens to annotate its records.
    struct Row: Sendable {
        let id: String
        let displayName: String
        let previewKind: DocumentFormat.PreviewKind
        let hasPreview: Bool
        let requiresCompile: Bool
        let fileExtension: String
        let mainFileName: String
        let extensions: [String]
        let commentPrefix: String?
        let citationInsert: (prefix: String, suffix: String)?
        let boldWrap: (prefix: String, suffix: String)?
        let italicWrap: (prefix: String, suffix: String)?
        let defaultDebounceMs: UInt32

        /// The row used when the Rust table has no entry for a format — a case
        /// added here without a table row. Grammar-free rather than
        /// Typst-shaped: no comment toggle, no citation insert, no wrapping,
        /// no preview. A missing row should make the editor plainly inert, not
        /// quietly apply the wrong syntax to the wrong language.
        static func unknown(id: String) -> Row {
            Row(
                id: id,
                displayName: id.capitalized,
                previewKind: .none,
                hasPreview: false,
                requiresCompile: false,
                fileExtension: id,
                mainFileName: "main.\(id)",
                extensions: [id],
                commentPrefix: nil,
                citationInsert: nil,
                boldWrap: nil,
                italicWrap: nil,
                defaultDebounceMs: 0
            )
        }
    }

    /// Keyed by format id (== `DocumentFormat.rawValue`).
    private static let rows: [String: Row] = {
        let table = manuscriptFormatGrammar()
        var byID: [String: Row] = [:]
        for descriptor in table {
            byID[descriptor.id] = Row(
                id: descriptor.id,
                displayName: descriptor.displayName,
                previewKind: DocumentFormat.PreviewKind(rawValue: descriptor.previewKind) ?? .none,
                hasPreview: descriptor.hasPreview,
                requiresCompile: descriptor.requiresCompile,
                fileExtension: descriptor.fileExtension,
                mainFileName: descriptor.mainFileName,
                extensions: descriptor.extensions,
                commentPrefix: descriptor.commentPrefix,
                citationInsert: descriptor.citationInsert.map { ($0.prefix, $0.suffix) },
                boldWrap: descriptor.boldWrap.map { ($0.prefix, $0.suffix) },
                italicWrap: descriptor.italicWrap.map { ($0.prefix, $0.suffix) },
                defaultDebounceMs: descriptor.defaultDebounceMs
            )
        }
        assert(
            Set(byID.keys) == Set(DocumentFormat.allCases.map(\.rawValue)),
            "DocumentFormat and the Rust grammar table diverged: "
                + "swift=\(DocumentFormat.allCases.map(\.rawValue).sorted()) "
                + "rust=\(byID.keys.sorted())"
        )
        return byID
    }()

    static func row(for id: String) -> Row {
        rows[id] ?? .unknown(id: id)
    }

    /// The table in `DocumentFormat.allCases` order — for tests and for any
    /// surface that wants to enumerate formats without going through the enum.
    static var allRows: [Row] {
        DocumentFormat.allCases.map { row(for: $0.rawValue) }
    }
}
