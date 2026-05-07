//
//  ManuscriptBundleManifest.swift
//  CounselEngine
//
//  Phase 8.2: Swift codable mirroring the Rust
//  `BundleManifest` defined in
//  `crates/impress-core/src/schemas/manuscript_bundle_manifest.rs`.
//
//  The manifest is the JSON sidecar that describes a manuscript stored as
//  a directory tree (`.tar.zst` archive). It lives at `manifest.json` in
//  the bundle root AND is mirrored into the `bundle_manifest_json` field
//  of `manuscript-submission@1.0.0` and `manuscript-revision@1.0.0`
//  payloads, so the UI/exporters can list a manuscript's files without
//  unpacking the archive.
//

import Foundation

/// Canonical schema identifier embedded in every manifest. Must match
/// `BUNDLE_MANIFEST_SCHEMA` in the Rust crate.
public let manuscriptBundleManifestSchema: String = "manuscript-bundle-manifest@1.0.0"

/// Per-entry role classification. Advisory — UI/exporters use this to
/// display icons and group files. The compile pipeline ignores it and
/// dispatches purely from `sourceFormat` + `compile.engine` + `mainSource`.
public enum BundleEntryRole: String, Codable, Sendable, CaseIterable {
    case main
    case bibliography
    case figure
    case supplement
    case chapter
    case aux
}

/// Source format of the main entry. Compile engines map to formats:
/// `typst` → typst engine, `tex` → pdflatex (via imprint's
/// LaTeXCompilationService), `markdown` and `html` are stored without
/// compile in v1.
public enum BundleSourceFormat: String, Codable, Sendable, CaseIterable {
    case tex
    case typst
    case markdown
    case html
}

/// The compile engine to use, if any.
///
/// LaTeX engine names mirror imprint's `LaTeXCompilationService.LaTeXEngine`
/// (`apps/imprint/macOS/Services/LaTeXCompilationService.swift`) so the
/// bundle compile route dispatches directly to that service without
/// translation. Compilation is owned by imprint; this enum names the
/// engine but does not implement it.
public enum BundleCompileEngine: String, Codable, Sendable, CaseIterable {
    case typst
    case pdflatex
    case xelatex
    case lualatex
    case latexmk
    /// Stored only; no compile attempted.
    case none
}

public struct BundleEntry: Codable, Hashable, Sendable {
    /// Path relative to the bundle root (POSIX, forward-slash).
    public let path: String
    /// Role classification (advisory).
    public let role: BundleEntryRole

    public init(path: String, role: BundleEntryRole) {
        self.path = path
        self.role = role
    }
}

public struct BundleCompileSpec: Codable, Hashable, Sendable {
    public let engine: BundleCompileEngine
    /// Engine-specific extra args. Pass-through; the compile dispatcher is
    /// responsible for sanitising. May be empty.
    public let extraArgs: [String]

    public init(engine: BundleCompileEngine, extraArgs: [String] = []) {
        self.engine = engine
        self.extraArgs = extraArgs
    }

    private enum CodingKeys: String, CodingKey {
        case engine
        case extraArgs = "extra_args"
    }
}

/// Errors a manifest can fail validation with. Surfaced at submission time
/// so malformed bundles never reach the snapshot stage.
public enum BundleManifestError: Error, LocalizedError, Sendable {
    case parseError(underlying: String)
    case schemaMismatch(expected: String, actual: String)
    case emptyMainSource
    case mainSourceNotInEntries(path: String)
    case emptyEntries
    case unsafePath(path: String)

    public var errorDescription: String? {
        switch self {
        case .parseError(let underlying):
            return "manifest JSON parse failed: \(underlying)"
        case .schemaMismatch(let expected, let actual):
            return "manifest schema mismatch: expected \(expected), got \(actual)"
        case .emptyMainSource:
            return "manifest main_source must be non-empty"
        case .mainSourceNotInEntries(let path):
            return "manifest main_source \"\(path)\" not present in entries list"
        case .emptyEntries:
            return "manifest entries list must be non-empty"
        case .unsafePath(let path):
            return "manifest entry path \"\(path)\" contains absolute or parent component"
        }
    }
}

public struct ManuscriptBundleManifest: Codable, Hashable, Sendable {
    /// Always `manuscriptBundleManifestSchema`.
    public let schema: String
    /// Relative path of the main source file inside the archive.
    public let mainSource: String
    public let sourceFormat: BundleSourceFormat
    /// All files included in the bundle. The canonical encoding sorts by
    /// `path` for determinism; readers should treat the order as advisory.
    public let entries: [BundleEntry]
    public let compile: BundleCompileSpec
    /// Globs that were excluded during packing (e.g. `*.aux`, `*.log`).
    /// Stored for audit / re-packing reproducibility.
    public let excludeGlobs: [String]

    public init(
        schema: String = manuscriptBundleManifestSchema,
        mainSource: String,
        sourceFormat: BundleSourceFormat,
        entries: [BundleEntry],
        compile: BundleCompileSpec,
        excludeGlobs: [String] = []
    ) {
        self.schema = schema
        self.mainSource = mainSource
        self.sourceFormat = sourceFormat
        self.entries = entries
        self.compile = compile
        self.excludeGlobs = excludeGlobs
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case mainSource = "main_source"
        case sourceFormat = "source_format"
        case entries
        case compile
        case excludeGlobs = "exclude_globs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try c.decode(String.self, forKey: .schema)
        self.mainSource = try c.decode(String.self, forKey: .mainSource)
        self.sourceFormat = try c.decode(BundleSourceFormat.self, forKey: .sourceFormat)
        self.entries = try c.decode([BundleEntry].self, forKey: .entries)
        self.compile = try c.decode(BundleCompileSpec.self, forKey: .compile)
        self.excludeGlobs = try c.decodeIfPresent([String].self, forKey: .excludeGlobs) ?? []
    }

    /// Parse + validate a manifest from JSON data.
    public static func parse(_ data: Data) throws -> ManuscriptBundleManifest {
        let manifest: ManuscriptBundleManifest
        do {
            manifest = try JSONDecoder().decode(ManuscriptBundleManifest.self, from: data)
        } catch {
            throw BundleManifestError.parseError(underlying: String(describing: error))
        }
        try manifest.validate()
        return manifest
    }

    /// Parse + validate a manifest from JSON string.
    public static func parse(_ json: String) throws -> ManuscriptBundleManifest {
        guard let data = json.data(using: .utf8) else {
            throw BundleManifestError.parseError(underlying: "invalid utf8")
        }
        return try parse(data)
    }

    /// Structural validation — independent of any archive contents.
    public func validate() throws {
        if schema != manuscriptBundleManifestSchema {
            throw BundleManifestError.schemaMismatch(
                expected: manuscriptBundleManifestSchema,
                actual: schema
            )
        }
        if mainSource.isEmpty {
            throw BundleManifestError.emptyMainSource
        }
        if entries.isEmpty {
            throw BundleManifestError.emptyEntries
        }
        if !entries.contains(where: { $0.path == mainSource }) {
            throw BundleManifestError.mainSourceNotInEntries(path: mainSource)
        }
        for entry in entries {
            if entry.path.hasPrefix("/") || entry.path.contains("..") {
                throw BundleManifestError.unsafePath(path: entry.path)
            }
        }
    }

    /// Encode to canonical JSON: sorted entries, sorted exclude globs,
    /// pretty-printed with sorted keys. Produces byte-identical output for
    /// byte-identical inputs so the bundle builder can rely on
    /// determinism.
    public func canonicalJSON() throws -> Data {
        let sorted = ManuscriptBundleManifest(
            schema: schema,
            mainSource: mainSource,
            sourceFormat: sourceFormat,
            entries: entries.sorted { $0.path < $1.path },
            compile: compile,
            excludeGlobs: excludeGlobs.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sorted)
    }

    /// Convenience: canonical JSON as a UTF-8 string.
    public func canonicalJSONString() throws -> String {
        let data = try canonicalJSON()
        return String(decoding: data, as: UTF8.self)
    }
}
