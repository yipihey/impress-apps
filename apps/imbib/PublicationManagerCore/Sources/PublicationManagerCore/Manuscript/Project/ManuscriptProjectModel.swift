//
//  ManuscriptProjectModel.swift
//  PublicationManagerCore
//
//  A manuscript as a project, for the GUI (ADR-0030). The rows are
//  `manuscript-file@1.0.0` items read straight from the shared store
//  (`SharedStore.manuscriptProjectSnapshot`); the questions — what is
//  unresolved, what is stale — come from the Rust engine
//  (`projectGraphJSON`). This model holds one manuscript's tree, hands the
//  compile controller the files it needs, and refreshes on the store events
//  the manuscript's rows produce. A manuscript with no file rows is a
//  one-file project and the model says so (`isProject == false`), so every
//  caller keeps the single-source path it has today.
//

import CryptoKit
import Foundation
import ImprintCore
import ImpressKit
import ImpressLogging
import ImpressRustCore
import ImpressStoreKit
import OSLog

/// One file row, as the GUI sees it.
public struct ManuscriptProjectFile: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let role: String
    public let kind: String
    public let format: String?
    public let content: String?
    public let inBlobStore: Bool
    public let contentHash: String
    public let size: Int
    public let derivedFrom: String?
    public let derivedFromHash: String?
    public let buildJSON: String?
    public let bibSourceJSON: String?
    public let modifiedMs: Int64?

    public var isText: Bool { kind == "text" }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    public var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    init(_ row: SharedProjectFile) {
        id = UUID(uuidString: row.id) ?? UUID()
        path = row.path
        role = row.role
        kind = row.kind
        format = row.format
        content = row.content
        inBlobStore = row.inBlobStore
        contentHash = row.contentHash
        size = Int(row.size)
        derivedFrom = row.derivedFrom
        derivedFromHash = row.derivedFromHash
        buildJSON = row.buildJson
        bibSourceJSON = row.bibSourceJson
        modifiedMs = row.modifiedMs
    }
}

/// The graph as the panel shows it: only the parts a person acts on.
public struct ManuscriptProjectGraph: Sendable {
    public struct Diagnostic: Identifiable, Hashable, Sendable {
        public let severity: String
        public let code: String
        public let message: String
        public let file: String?
        public let line: Int?
        public var id: String { "\(severity)|\(code)|\(file ?? "")|\(line ?? 0)|\(message)" }
    }
    public let reachable: Set<String>
    public let unreferenced: [String]
    public let diagnostics: [Diagnostic]
    public let staleSources: Set<String>

    public static let empty = ManuscriptProjectGraph(
        reachable: [], unreferenced: [], diagnostics: [], staleSources: [])

    /// Errors and warnings for one file.
    public func diagnostics(for path: String) -> [Diagnostic] {
        diagnostics.filter { $0.file == path && $0.severity != "info" }
    }

    public var hasErrors: Bool { diagnostics.contains { $0.severity == "error" } }
}

@MainActor
@Observable
public final class ManuscriptProjectModel {

    public let manuscriptID: UUID
    public private(set) var entryPath: String = ""
    public private(set) var entryHash: String = ""
    public private(set) var format: String = "typst"
    public private(set) var files: [ManuscriptProjectFile] = []
    public private(set) var projectVersion: Int = 0
    public private(set) var targetsJSON: String?
    public private(set) var graph: ManuscriptProjectGraph = .empty
    public private(set) var lastError: String?

    /// Whether the manuscript has grown beyond one file.
    public var isProject: Bool { projectVersion >= 1 || !files.isEmpty }

    /// A panel's own message in the model's error line.
    public func lastErrorHint(_ message: String) { lastError = message }

    @ObservationIgnored private var store: SharedStore?
    @ObservationIgnored private var openAttempted = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    private static var models: [UUID: ManuscriptProjectModel] = [:]

    /// Every model this process has loaded (the manuscripts with an open
    /// editor or panel) — what an intent that names only a file row can
    /// search.
    public static var loaded: [ManuscriptProjectModel] { Array(models.values) }

    /// The loaded model holding a file row with `fileID`, and the row.
    public static func locate(fileID: UUID) -> (model: ManuscriptProjectModel, file: ManuscriptProjectFile)? {
        for model in models.values {
            if let file = model.files.first(where: { $0.id == fileID }) {
                return (model, file)
            }
        }
        return nil
    }

    /// One model per manuscript for the process; refreshes on its store events.
    public static func shared(for manuscriptID: UUID) -> ManuscriptProjectModel {
        if let existing = models[manuscriptID] { return existing }
        let model = ManuscriptProjectModel(manuscriptID: manuscriptID)
        models[manuscriptID] = model
        model.reload()
        model.observeStore()
        return model
    }

    public init(manuscriptID: UUID, store: SharedStore? = nil) {
        self.manuscriptID = manuscriptID
        self.store = store
    }

    // MARK: - Store access

    private func handle() -> SharedStore? {
        if let store { return store }
        if openAttempted { return nil }
        openAttempted = true
        do {
            try SharedWorkspace.ensureDirectoryExists()
            let s = try SharedStore.open(path: SharedWorkspace.databaseURL.path)
            store = s
            return s
        } catch {
            Logger.library.warningCapture(
                "project model: could not open SharedStore: \(error.localizedDescription)",
                category: "manuscripts")
            return nil
        }
    }

    private func observeStore() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in ImbibImpressStore.shared.events.subscribe() {
                guard let self else { return }
                switch event {
                case .structural:
                    self.reload()
                case .itemsMutated(_, let ids):
                    // A file row's id is derived from its path, so a mutation
                    // may name the row or the manuscript; either is ours.
                    let mine = Set(self.files.map(\.id)).union([self.manuscriptID])
                    if !ids.isDisjoint(with: mine) {
                        self.reload()
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: - Reads

    /// Re-read the tree and re-derive the graph. Display: logs what it found.
    public func reload() {
        guard let store = handle() else { return }
        do {
            let snapshot = try store.manuscriptProjectSnapshot(manuscriptId: manuscriptID.uuidString.lowercased())
            entryPath = snapshot.entryPath
            entryHash = snapshot.entryHash
            format = snapshot.format
            projectVersion = Int(snapshot.projectVersion)
            targetsJSON = snapshot.targetsJson
            snapshotWorkingCopyPath = snapshot.workingCopyPath.flatMap { $0.isEmpty ? nil : $0 }
            files = snapshot.files.map(ManuscriptProjectFile.init)
            lastError = nil
            graph = deriveGraph(entryText: snapshot.entryText)
            Logger.library.debugCapture(
                "project \(manuscriptID): entry=\(entryPath) files=\(files.count) "
                    + "version=\(projectVersion) diagnostics=\(graph.diagnostics.count)",
                category: "manuscripts")
        } catch {
            lastError = error.localizedDescription
            Logger.library.warningCapture(
                "project \(manuscriptID): snapshot failed: \(error.localizedDescription)",
                category: "manuscripts")
        }
    }

    /// The bytes of a file (inline text or the blob).
    public func bytes(of path: String) -> Data? {
        guard let store = handle() else { return nil }
        return try? store.manuscriptProjectFileBytes(
            manuscriptId: manuscriptID.uuidString.lowercased(), path: path)
    }

    /// Every file the compiler should see, with `overrides` (path → live
    /// text) replacing stored text — the entry is included from `entryText`.
    public func compileFiles(entryText: String, overrides: [String: String] = [:]) -> [TreeRenderFile] {
        var out: [TreeRenderFile] = [TreeRenderFile(path: entryPath, role: "main", text: overrides[entryPath] ?? entryText)]
        for file in files {
            if let live = overrides[file.path] {
                out.append(TreeRenderFile(
                    path: file.path, role: file.role, text: live,
                    buildJSON: file.buildJSON, derivedFrom: file.derivedFrom, derivedFromHash: file.derivedFromHash))
            } else if file.isText, let text = file.content {
                out.append(TreeRenderFile(
                    path: file.path, role: file.role, text: text,
                    buildJSON: file.buildJSON, derivedFrom: file.derivedFrom, derivedFromHash: file.derivedFromHash))
            } else if let data = bytes(of: file.path) {
                if file.isText, let text = String(data: data, encoding: .utf8) {
                    out.append(TreeRenderFile(
                        path: file.path, role: file.role, text: text,
                        buildJSON: file.buildJSON, derivedFrom: file.derivedFrom, derivedFromHash: file.derivedFromHash))
                } else {
                    out.append(TreeRenderFile(
                        path: file.path, role: file.role, bytes: data,
                        buildJSON: file.buildJSON, derivedFrom: file.derivedFrom, derivedFromHash: file.derivedFromHash))
                }
            }
        }
        return out
    }

    /// The path of the implicit bibliography a citing Typst manuscript gets
    /// without a `.bib` row of its own — the one-file convention the
    /// citation seam has served since it shipped (ADR-0030 P2 keeps it).
    public static let implicitBibliographyPath = "bibliography.bib"

    /// Projected `.bib` files as the text the compiler should see. `cited`
    /// projections — the implicit `bibliography.bib`, and any row declaring
    /// `{"kind":"cited"}` — are resolved here through the citation seam
    /// (every `@key` in the tree's text, exported from the library); other
    /// projections compile as their stored text (the headless verbs resolve
    /// `collection`/`library`/`keys` through imbib's store).
    public func resolvedBibliographies(entryText: String? = nil) -> [TreeRenderBibliography] {
        var out: [TreeRenderBibliography] = []
        let cited = citedBibliography(entryText: entryText)
        var hasOwnImplicit = false
        for file in files where file.role == "bibliography" {
            if file.path == Self.implicitBibliographyPath { hasOwnImplicit = true }
            let isCited = file.bibSourceJSON?.contains("\"cited\"") ?? false
            if isCited, let cited {
                out.append(TreeRenderBibliography(path: file.path, text: cited))
            } else if file.bibSourceJSON != nil,
                      let text = file.content ?? bytes(of: file.path).flatMap({ String(data: $0, encoding: .utf8) }) {
                out.append(TreeRenderBibliography(path: file.path, text: text))
            }
        }
        if !hasOwnImplicit, let cited {
            out.append(TreeRenderBibliography(path: Self.implicitBibliographyPath, text: cited))
        }
        return out
    }

    /// Every `@key` across the tree's text (the live entry when given),
    /// exported from the library through the host's citation seam; nil
    /// when nothing cites, no seam is installed, or nothing resolves.
    private func citedBibliography(entryText: String?) -> String? {
        var text = entryText ?? RustStoreAdapter.shared.getManuscriptDetail(id: manuscriptID)?.bodyContent ?? ""
        for file in files where file.isText && file.role != "bibliography" {
            if let content = file.content {
                text += "\n" + content
            }
        }
        guard text.contains("@") else { return nil }
        let keys = ImprintCore.extractCiteKeys(source: text)
        guard !keys.isEmpty, let seam = ManuscriptEditorEnvironment.shared.citationSearch else { return nil }
        let bib = seam.bibliography(forKeys: keys)
        Logger.library.debugCapture(
            "project \(manuscriptID): \(keys.count) cite key(s) → \(bib?.count ?? 0)ch BibTeX for the cited projection",
            category: "manuscripts")
        return bib
    }

    /// Bibliography rows that project (carry a `bib_source_json`), which the
    /// app resolves into text before a compile. Until the projection verb
    /// is reachable in-process, a projected row compiles as its own text
    /// (the `cited` projection is what the single-source `bibSource` path
    /// already assembles for `bibliography.bib`).
    public var projectedBibliographies: [ManuscriptProjectFile] {
        files.filter { $0.role == "bibliography" && $0.bibSourceJSON != nil }
    }

    private func deriveGraph(entryText: String) -> ManuscriptProjectGraph {
        let json = projectGraphJSON(files: compileFiles(entryText: entryText), entryPath: entryPath, format: format)
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .empty }
        let reachable = Set((raw["reachable"] as? [String]) ?? [])
        let unreferenced = (raw["unreferenced"] as? [String]) ?? []
        let diagnostics: [ManuscriptProjectGraph.Diagnostic] = ((raw["diagnostics"] as? [[String: Any]]) ?? []).map { d in
            ManuscriptProjectGraph.Diagnostic(
                severity: (d["severity"] as? String) ?? "info",
                code: (d["code"] as? String) ?? "",
                message: (d["message"] as? String) ?? "",
                file: d["file"] as? String,
                line: (d["line"] as? Int))
        }
        let stale = Set(((raw["steps"] as? [[String: Any]]) ?? []).compactMap { step -> String? in
            let staleOutputs = (step["stale_outputs"] as? [String]) ?? []
            let missing = (step["missing_outputs"] as? [String]) ?? []
            return (staleOutputs.isEmpty && missing.isEmpty) ? nil : step["source"] as? String
        })
        return ManuscriptProjectGraph(
            reachable: reachable, unreferenced: unreferenced, diagnostics: diagnostics, staleSources: stale)
    }

    // MARK: - Writes (through the one Rust writer)

    @discardableResult
    public func putText(path: String, text: String, role: String? = nil) -> ManuscriptProjectFile? {
        guard let store = handle() else { return nil }
        do {
            let row = try store.manuscriptProjectPutText(
                manuscriptId: manuscriptID.uuidString.lowercased(), path: path, role: role,
                text: text, author: "user:local")
            Logger.library.infoCapture("project put \(path) (\(text.utf8.count) bytes)", category: "manuscripts")
            reload()
            ImbibImpressStore.shared.postMutation(structural: false, affectedIDs: [manuscriptID], kind: .otherField)
            return ManuscriptProjectFile(row)
        } catch {
            lastError = error.localizedDescription
            Logger.library.warningCapture("project put \(path) failed: \(error.localizedDescription)", category: "manuscripts")
            return nil
        }
    }

    @discardableResult
    public func putBytes(path: String, data: Data, role: String? = nil, mimeType: String? = nil) -> ManuscriptProjectFile? {
        guard let store = handle() else { return nil }
        do {
            let row = try store.manuscriptProjectPutBytes(
                manuscriptId: manuscriptID.uuidString.lowercased(), path: path, role: role,
                bytes: data, mimeType: mimeType, author: "user:local")
            Logger.library.infoCapture("project put \(path) (\(data.count) bytes, binary)", category: "manuscripts")
            reload()
            ImbibImpressStore.shared.postMutation(structural: false, affectedIDs: [manuscriptID], kind: .otherField)
            return ManuscriptProjectFile(row)
        } catch {
            lastError = error.localizedDescription
            Logger.library.warningCapture("project put \(path) failed: \(error.localizedDescription)", category: "manuscripts")
            return nil
        }
    }

    /// Import a file from disk: text stays text, everything else is bytes.
    @discardableResult
    public func importFile(at url: URL, as path: String? = nil) -> ManuscriptProjectFile? {
        guard let data = try? Data(contentsOf: url) else {
            lastError = "could not read \(url.lastPathComponent)"
            return nil
        }
        let target = path ?? url.lastPathComponent
        return putBytes(path: target, data: data)
    }

    public func delete(path: String) {
        guard let store = handle() else { return }
        do {
            _ = try store.manuscriptProjectDeleteFile(manuscriptId: manuscriptID.uuidString.lowercased(), path: path)
            Logger.library.infoCapture("project delete \(path)", category: "manuscripts")
            reload()
            ImbibImpressStore.shared.postMutation(structural: false, affectedIDs: [manuscriptID], kind: .otherField)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func move(from: String, to: String) {
        guard let store = handle() else { return }
        do {
            _ = try store.manuscriptProjectMoveFile(
                manuscriptId: manuscriptID.uuidString.lowercased(), from: from, to: to, author: "user:local")
            Logger.library.infoCapture("project move \(from) → \(to)", category: "manuscripts")
            reload()
            ImbibImpressStore.shared.postMutation(structural: false, affectedIDs: [manuscriptID], kind: .otherField)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func setEntry(path: String) {
        guard let store = handle() else { return }
        do {
            _ = try store.manuscriptProjectSetEntry(
                manuscriptId: manuscriptID.uuidString.lowercased(), path: path, author: "user:local")
            reload()
            ImbibImpressStore.shared.postMutation(structural: false, affectedIDs: [manuscriptID], kind: .otherField)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Targets and builds (ADR-0030 P4)

    /// One buildable output of the tree, from `targets_json` (the implicit
    /// `main` target when none is declared).
    public struct Target: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let entry: String
        public let engine: String
    }

    /// The declared targets, or the implicit one.
    public var targets: [Target] {
        let implicitEngine: String
        switch format {
        case "latex": implicitEngine = "tectonic"
        case "markdown": implicitEngine = "markdown"
        case "typst": implicitEngine = "typst"
        default: implicitEngine = "none"
        }
        let implicit = Target(id: "main", name: "main", entry: entryPath, engine: implicitEngine)
        guard let json = targetsJSON, let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !raw.isEmpty
        else { return [implicit] }
        return raw.compactMap { t in
            guard let id = t["id"] as? String, !id.isEmpty else { return nil }
            return Target(
                id: id,
                name: (t["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                entry: (t["entry"] as? String) ?? entryPath,
                engine: (t["engine"] as? String) ?? implicitEngine)
        }
    }

    /// A recorded build, as the Build panel lists it.
    public struct Build: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let targetID: String
        public let engine: String
        /// running | ok | failed | cancelled
        public let status: String
        public let startedMs: Int64
        public let durationMs: Int64?
        public let message: String
        public let outputsJSON: String?
        public let stepsJSON: String?
        public let diagnosticsJSON: String?

        public var pdfPath: String? {
            guard let json = outputsJSON, let data = json.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return nil }
            return raw.first { ($0["kind"] as? String) == "pdf" }?["path"] as? String
        }
    }

    public private(set) var builds: [Build] = []
    /// The report of the last build this process ran.
    public private(set) var lastReport: TreeBuildReport?
    public private(set) var isBuilding = false

    /// Where a build of `targetID` works and writes: previews and explicit
    /// builds get separate directories so a preview never prunes a build.
    public func workDirectory(targetID: String?, preview: Bool) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent("impress/imprint/project-build", isDirectory: true)
            .appendingPathComponent(manuscriptID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(preview ? "preview" : (targetID ?? "main"), isDirectory: true)
    }

    /// Re-read the recorded builds (newest first).
    public func reloadBuilds() {
        guard let store = handle() else { return }
        let rows = (try? store.manuscriptProjectBuilds(manuscriptId: manuscriptID.uuidString.lowercased(), limit: 20)) ?? []
        builds = rows.map {
            Build(
                id: UUID(uuidString: $0.id) ?? UUID(),
                targetID: $0.targetId, engine: $0.engine, status: $0.status,
                startedMs: $0.startedMs, durationMs: $0.durationMs, message: $0.message ?? "",
                outputsJSON: $0.outputsJson, stepsJSON: $0.stepsJson, diagnosticsJSON: $0.diagnosticsJson)
        }
    }

    /// Build a target through the Rust engine and record it: a
    /// `manuscript-build` row (running → ok/failed), the files figure steps
    /// produced written as rows derived from their source, the PDF kept in
    /// the build directory. Mutation, save and display are each logged.
    @discardableResult
    public func build(targetID: String? = nil, allowShell: Bool = false, entryOverride: String? = nil) async -> TreeBuildReport? {
        guard !isBuilding else { return nil }
        guard let store = handle() else { return nil }
        reload()
        let target = targets.first { $0.id == (targetID ?? "") } ?? targets.first
        guard let target else { return nil }
        let id = manuscriptID.uuidString.lowercased()
        let entryText = RustStoreAdapter.shared.getManuscriptDetail(id: manuscriptID)?.bodyContent ?? ""
        let files = compileFiles(entryText: entryOverride ?? entryText)
        let workDir = workDirectory(targetID: target.id, preview: false)
        isBuilding = true
        defer { isBuilding = false }
        Logger.library.infoCapture(
            "project build \(target.id) (\(target.engine)) of \(manuscriptID): \(files.count) file(s), shell=\(allowShell)",
            category: "manuscripts")

        // The row first, so a crash mid-build leaves a `running` record.
        let startedMs = Int64(Date().timeIntervalSince1970 * 1000)
        var record: [String: Any] = [
            "target_id": target.id, "engine": target.engine, "status": "running",
            "input_stamp": "", "started_ms": startedMs, "allow_shell": allowShell,
        ]
        var buildID: String?
        if let json = try? JSONSerialization.data(withJSONObject: record), let text = String(data: json, encoding: .utf8) {
            buildID = try? store.manuscriptProjectRecordBuild(manuscriptId: id, recordJson: text, author: "user:local").id
        }

        let report = await TypstRenderer().buildTree(
            files: files, entryPath: entryPath, format: format,
            targetsJSON: targetsJSON, targetID: target.id, workDir: workDir,
            allowShell: allowShell, entryOverride: nil,
            bibliographies: resolvedBibliographies(entryText: entryOverride ?? entryText))
        lastReport = report

        // What the steps produced becomes rows derived from their source.
        var producedRows = 0
        for p in report.produced {
            let role = files.first { $0.path == p.path }?.role ?? "output"
            if putBytes(path: p.path, data: p.bytes, role: role) != nil,
               (try? store.manuscriptProjectRecordDerived(
                    manuscriptId: id, output: p.path, source: p.derivedFrom, inputHash: p.derivedFromHash)) != nil {
                producedRows += 1
            }
        }

        // Finish the row with the outcome.
        if let buildID {
            let outputs: [[String: Any]] = report.outputs.map {
                ["kind": $0.kind, "name": $0.name, "path": $0.path, "size": $0.size]
            }
            let steps: [[String: Any]] = report.steps.map {
                var d: [String: Any] = [
                    "source": $0.source, "runner": $0.runner, "status": $0.status.rawValue,
                    "message": $0.message, "duration_ms": $0.durationMs, "outputs": $0.outputs,
                ]
                if let c = $0.command { d["command"] = c }
                return d
            }
            let diagnostics: [[String: Any]] = report.diagnostics.map {
                var d: [String: Any] = ["severity": $0.severity.rawValue, "code": $0.code, "message": $0.message]
                if let f = $0.file { d["file"] = f }
                if let l = $0.line { d["line"] = l }
                return d
            }
            let encode: (Any) -> String? = { obj in
                (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) }
            }
            record["status"] = report.isSuccess ? "ok" : "failed"
            record["finished_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
            record["duration_ms"] = Int64(report.durationMs)
            record["message"] = report.message
            if let o = encode(outputs) { record["outputs_json"] = o }
            if let s = encode(steps) { record["steps_json"] = s }
            if let d = encode(diagnostics) { record["diagnostics_json"] = d }
            if let text = encode(record) {
                do {
                    _ = try store.manuscriptProjectFinishBuild(manuscriptId: id, buildId: buildID, recordJson: text)
                } catch {
                    Logger.library.warningCapture("project build: could not finish row \(buildID): \(error.localizedDescription)", category: "manuscripts")
                }
            }
        }
        Logger.library.infoCapture(
            "project build \(target.id): \(report.isSuccess ? "ok" : "failed") in \(report.durationMs) ms — \(report.message); \(report.steps.count) step(s), \(producedRows) produced row(s), \(report.outputs.count) output(s)",
            category: "manuscripts")
        reload()
        reloadBuilds()
        ImbibImpressStore.shared.postMutation(structural: false, affectedIDs: [manuscriptID], kind: .otherField)
        Logger.library.debugCapture("project builds listed: \(builds.count)", category: "manuscripts")
        return report
    }

    // MARK: - Figures (ADR-0030 D13)

    /// Every figure source, in path order.
    public var figures: [ManuscriptProjectFile] {
        files.filter { $0.role == "figure-source" }
    }

    /// The rows a figure source made (`derived_from == path`).
    public func outputs(of figure: ManuscriptProjectFile) -> [ManuscriptProjectFile] {
        files.filter { $0.derivedFrom == figure.path }
    }

    /// `veusz | lilaq | typst | implore | impress-plot | script`, from the
    /// row's name and text (Rust decides).
    public func figureKind(of file: ManuscriptProjectFile) -> String? {
        ImprintCore.figureKind(of: file.path, text: file.content)
    }

    /// A new figure of `kind` at `path` (the kind's extension added when
    /// missing): the starter text as a `figure-source` row and its build
    /// spec. Refuses an existing path.
    @discardableResult
    public func newFigure(kind: String, path: String) -> ManuscriptProjectFile? {
        guard let template = figureTemplate(kind: kind, path: path) else {
            lastError = "unknown figure kind \(kind)"
            return nil
        }
        if files.contains(where: { $0.path == template.path }) {
            lastError = "\(template.path) exists; choose another name"
            return nil
        }
        guard let store = handle() else { return nil }
        let id = manuscriptID.uuidString.lowercased()
        do {
            _ = try store.manuscriptProjectPutText(
                manuscriptId: id, path: template.path, role: "figure-source", text: template.text, author: "user:local")
            let row = try store.manuscriptProjectSetFileField(
                manuscriptId: id, path: template.path, field: "build_json", value: template.buildJSON)
            Logger.library.infoCapture(
                "project figure \(template.path) (\(kind)) created with \(template.buildJSON)", category: "manuscripts")
            lastError = nil
            reload()
            ImbibImpressStore.shared.postMutation(structural: false, affectedIDs: [manuscriptID], kind: .otherField)
            return ManuscriptProjectFile(row)
        } catch {
            lastError = error.localizedDescription
            Logger.library.warningCapture("project figure \(template.path) failed: \(error.localizedDescription)", category: "manuscripts")
            return nil
        }
    }

    /// Declare how a figure source is built (`build_json`).
    @discardableResult
    public func setBuildJSON(path: String, json: String?) -> ManuscriptProjectFile? {
        guard let store = handle() else { return nil }
        do {
            let row = try store.manuscriptProjectSetFileField(
                manuscriptId: manuscriptID.uuidString.lowercased(), path: path, field: "build_json", value: json)
            reload()
            ImbibImpressStore.shared.postMutation(structural: false, affectedIDs: [manuscriptID], kind: .otherField)
            return ManuscriptProjectFile(row)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Replace a figure source's text (the inspector's Save, an external
    /// editor's write) — the graph then reads its outputs as stale.
    @discardableResult
    public func updateFigureSource(path: String, text: String) -> ManuscriptProjectFile? {
        putText(path: path, text: text, role: "figure-source")
    }

    /// The last preview per figure, by content hash — a look costs one
    /// render per edit, not one per redraw.
    @ObservationIgnored private var previewCache: [String: (hash: String, svg: String)] = [:]
    public private(set) var renderingFigure: String?

    /// Render one figure's step through the Rust engine. `record` writes the
    /// outputs as rows derived from the source (the panel's Render); a
    /// preview (`record == false`) only returns the SVG. Native kinds render
    /// in memory; Veusz and scripts run in the figures work directory.
    @discardableResult
    public func renderFigure(path: String, force: Bool, allowShell: Bool, record: Bool) async -> TreeFigureRender? {
        guard let figure = files.first(where: { $0.path == path }) else { return nil }
        if !record, let cached = previewCache[path], cached.hash == inputsHash(of: figure) {
            return TreeFigureRender(
                isSuccess: true, path: path, runner: "", status: "fresh", message: "cached preview",
                svg: cached.svg, produced: [], log: "", durationMs: 0)
        }
        let entryText = RustStoreAdapter.shared.getManuscriptDetail(id: manuscriptID)?.bodyContent ?? ""
        let treeFiles = compileFiles(entryText: entryText)
        let workDir = workDirectory(targetID: "figures", preview: !record)
        renderingFigure = path
        defer { renderingFigure = nil }
        Logger.library.infoCapture(
            "project figure render \(path) (force=\(force), record=\(record))", category: "manuscripts")
        let r = await TypstRenderer().renderFigure(
            files: treeFiles, entryPath: entryPath, format: format, path: path,
            workDir: workDir, allowShell: allowShell, force: force || !record)
        if r.isSuccess, let svg = r.svg {
            previewCache[path] = (inputsHash(of: figure), svg)
        }
        if record, !r.produced.isEmpty {
            var rows = 0
            for p in r.produced {
                let role = files.first { $0.path == p.path }?.role ?? "output"
                if putBytes(path: p.path, data: p.bytes, role: role) != nil,
                   let store = handle(),
                   (try? store.manuscriptProjectRecordDerived(
                        manuscriptId: manuscriptID.uuidString.lowercased(), output: p.path,
                        source: p.derivedFrom, inputHash: p.derivedFromHash)) != nil {
                    rows += 1
                }
            }
            Logger.library.infoCapture(
                "project figure \(path): \(r.status) in \(r.durationMs) ms — \(r.message); \(rows) output row(s)",
                category: "manuscripts")
            reload()
        } else if !r.isSuccess {
            lastError = r.message
            Logger.library.warningCapture("project figure \(path): \(r.message)", category: "manuscripts")
        }
        return r
    }

    /// The bytes a step reads: the source's hash plus its declared inputs'.
    private func inputsHash(of figure: ManuscriptProjectFile) -> String {
        var parts = [figure.contentHash]
        if let json = figure.buildJSON, let data = json.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inputs = raw["inputs"] as? [String] {
            for input in inputs {
                parts.append(files.first { $0.path == input }?.contentHash ?? "")
            }
        }
        return parts.joined(separator: "|")
    }

    /// The snippet that places a figure's first output in this manuscript's
    /// grammar.
    public func placementSnippet(for figure: ManuscriptProjectFile) -> String? {
        let output = outputs(of: figure).first?.path
            ?? (figure.buildJSON.flatMap { json -> String? in
                guard let data = json.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return (raw["outputs"] as? [String])?.first
            })
        guard let output else { return nil }
        let caption = figure.name.split(separator: ".").first.map(String.init) ?? figure.name
        switch format {
        case "latex":
            return "\\begin{figure}\n  \\centering\n  \\includegraphics[width=\\linewidth]{\(output)}\n  \\caption{\(caption)}\n  \\label{fig:\(caption)}\n\\end{figure}"
        case "markdown":
            return "![\(caption)](\(output))"
        default:
            return "#figure(\n  image(\"\(output)\", width: 80%),\n  caption: [\(caption)],\n) <fig:\(caption)>"
        }
    }

    // MARK: - External editors (Veusz, lilook) over a working copy of one figure

    @ObservationIgnored private var externalEdits: [String: ExternalEdit] = [:]

    private final class ExternalEdit {
        let url: URL
        var source: DispatchSourceFileSystemObject?
        var descriptor: Int32 = -1
        init(url: URL) { self.url = url }
        deinit {
            source?.cancel()
            if descriptor >= 0 { close(descriptor) }
        }
    }

    /// Write one figure source (and the data it declares) into the figures
    /// work directory and hand back the file's URL for an external editor;
    /// every save there is checked back into the row (Rust's staleness then
    /// asks for a re-render). Idempotent per path.
    public func beginExternalEdit(path: String) -> URL? {
        guard let figure = files.first(where: { $0.path == path }) else { return nil }
        let root = workDirectory(targetID: "figures", preview: false)
        var paths = [path]
        if let json = figure.buildJSON, let data = json.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inputs = raw["inputs"] as? [String] {
            paths.append(contentsOf: inputs)
        }
        paths.append(contentsOf: files.filter { $0.role == "data" }.map(\.path))
        var written = 0
        for p in Set(paths) {
            guard let row = files.first(where: { $0.path == p }) else { continue }
            let url = root.appendingPathComponent(p)
            guard let bytes = row.content?.data(using: .utf8) ?? bytes(of: p) else { continue }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? Data(contentsOf: url)) != bytes {
                    try bytes.write(to: url, options: .atomic)
                    written += 1
                }
            } catch {
                lastError = "could not write \(p): \(error.localizedDescription)"
                return nil
            }
        }
        let url = root.appendingPathComponent(path)
        Logger.library.infoCapture(
            "project figure \(path): working copy at \(url.path) (\(written) file(s) written); watching for the editor's saves",
            category: "manuscripts")
        watchExternalEdit(path: path, url: url)
        return url
    }

    private func watchExternalEdit(path: String, url: URL) {
        externalEdits[path] = nil
        let edit = ExternalEdit(url: url)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        edit.descriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self, weak edit] in
            guard let self, let edit else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                // Editors that write-and-rename: re-open the new inode.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.checkInExternalEdit(path: path, url: edit.url)
                    self?.watchExternalEdit(path: path, url: edit.url)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.checkInExternalEdit(path: path, url: edit.url)
            }
        }
        source.resume()
        edit.source = source
        externalEdits[path] = edit
    }

    /// The editor saved: the row takes the file's bytes (a text row as text).
    private func checkInExternalEdit(path: String, url: URL) {
        guard let row = files.first(where: { $0.path == path }), let data = try? Data(contentsOf: url) else { return }
        if row.isText, let text = String(data: data, encoding: .utf8) {
            if text == row.content { return }
            Logger.library.infoCapture("project figure \(path): checked in \(text.count) chars from the editor", category: "manuscripts")
            putText(path: path, text: text, role: row.role)
        } else {
            Logger.library.infoCapture("project figure \(path): checked in \(data.count) bytes from the editor", category: "manuscripts")
            putBytes(path: path, data: data, role: row.role)
        }
        previewCache[path] = nil
    }

    /// Stop watching a figure's working copy.
    public func endExternalEdit(path: String) {
        externalEdits[path] = nil
    }

    // MARK: - Working copies (ADR-0030 D11)

    /// Where the project is checked out, when it is.
    public var workingCopyPath: String? {
        snapshotWorkingCopyPath
    }
    @ObservationIgnored private var snapshotWorkingCopyPath: String?

    /// Materialise every file into `directory` and remember it as the
    /// working copy (Git, a shell, Veusz and lilook edit there).
    @discardableResult
    public func checkOut(to directory: URL) -> Bool {
        guard let store = handle() else { return false }
        let entryText = RustStoreAdapter.shared.getManuscriptDetail(id: manuscriptID)?.bodyContent ?? ""
        var written = 0
        for file in compileFiles(entryText: entryText) {
            let url = directory.appendingPathComponent(file.path)
            let bytes = file.text?.data(using: .utf8) ?? file.bytes ?? Data()
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? Data(contentsOf: url)) != bytes {
                    try bytes.write(to: url, options: .atomic)
                    written += 1
                }
            } catch {
                lastError = "could not write \(file.path): \(error.localizedDescription)"
                return false
            }
        }
        do {
            try store.manuscriptProjectSetWorkingCopy(
                manuscriptId: manuscriptID.uuidString.lowercased(), path: directory.path, author: "user:local")
        } catch {
            lastError = error.localizedDescription
            return false
        }
        Logger.library.infoCapture("project checked out to \(directory.path): \(written) file(s) written", category: "manuscripts")
        reload()
        return true
    }

    /// What differs between the rows and the working copy.
    public struct WorkingCopyStatus: Sendable {
        public let changed: [String]
        public let added: [String]
        public let missing: [String]
        public var isClean: Bool { changed.isEmpty && added.isEmpty && missing.isEmpty }
    }

    public func workingCopyStatus() -> WorkingCopyStatus? {
        guard let path = workingCopyPath else { return nil }
        let dir = URL(fileURLWithPath: path)
        let plan = Self.plan(forDirectory: dir, entryOverride: entryPath)
        guard plan.ok else {
            lastError = plan.message
            return nil
        }
        let entryHash = self.entryHash
        var changed: [String] = [], added: [String] = [], missing: [String] = []
        var seen = Set<String>()
        for file in plan.files {
            seen.insert(file.path)
            if file.path == entryPath {
                if file.text.map({ sha256Hex($0) }) != entryHash { changed.append(file.path) }
                continue
            }
            guard let row = files.first(where: { $0.path == file.path }) else {
                added.append(file.path)
                continue
            }
            let hash = file.text.map { sha256Hex($0) } ?? file.bytes.map { sha256Hex($0) } ?? ""
            if hash != row.contentHash { changed.append(file.path) }
        }
        if !seen.contains(entryPath) { missing.append(entryPath) }
        for row in files where !seen.contains(row.path) { missing.append(row.path) }
        return WorkingCopyStatus(changed: changed.sorted(), added: added.sorted(), missing: missing.sorted())
    }

    /// Bring the working copy's changes in: the entry through the document,
    /// the rest as rows keeping their roles. Returns the paths checked in.
    @discardableResult
    public func checkIn(paths only: [String]? = nil) -> [String] {
        guard let path = workingCopyPath, let status = workingCopyStatus() else { return [] }
        let dir = URL(fileURLWithPath: path)
        let plan = Self.plan(forDirectory: dir, entryOverride: entryPath)
        var done: [String] = []
        for p in (status.changed + status.added).sorted() where only == nil || only!.contains(p) {
            guard let file = plan.files.first(where: { $0.path == p }) else { continue }
            if p == entryPath {
                guard let text = file.text else { continue }
                let heads = RustStoreAdapter.shared.manuscriptCollabHeads(id: manuscriptID)
                if RustStoreAdapter.shared.commitManuscriptBody(id: manuscriptID, body: text, baseHeads: heads) != nil {
                    done.append(p)
                }
                continue
            }
            let role = files.first { $0.path == p }?.role ?? file.role
            if let text = file.text {
                if putText(path: p, text: text, role: role) != nil { done.append(p) }
            } else if let bytes = file.bytes {
                if putBytes(path: p, data: bytes, role: role) != nil { done.append(p) }
            }
        }
        Logger.library.infoCapture("project check-in from \(path): \(done.count) file(s)", category: "manuscripts")
        ManuscriptSessionRegistry.shared.refreshAllLiveSessions()
        return done
    }

    private func sha256Hex(_ text: String) -> String { sha256Hex(Data(text.utf8)) }
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Import a directory (ADR-0030 P3)

    /// Read a directory as a tree — nothing written. The plan is Rust's
    /// (`project_import_directory_plan`): build residue skipped, roles from
    /// the extension and then from use, the entry guessed with its reason.
    public static func plan(forDirectory url: URL, entryOverride: String? = nil) -> ImportedTreePlan {
        importDirectoryPlan(at: url, entryOverride: entryOverride)
    }

    /// Import a directory into THIS manuscript. Refuses a directory written
    /// in another grammar: the format lives on the manuscript row, and the
    /// app decides that (File ▸ Import Folder as Manuscript…).
    @discardableResult
    public func importDirectory(at url: URL) -> ImportedTreePlan? {
        let plan = Self.plan(forDirectory: url)
        return importDirectory(plan: plan) ? plan : nil
    }

    /// The plan's files become rows through the one writer, the entry path
    /// is declared, and the entry's text goes through the document
    /// (`commitManuscriptBody`) so an open editor merges rather than loses.
    /// Additive: rows the directory does not have stay.
    @discardableResult
    public func importDirectory(plan: ImportedTreePlan) -> Bool {
        guard plan.ok else {
            lastError = plan.message
            Logger.library.warningCapture("project import failed: \(plan.message)", category: "manuscripts")
            return false
        }
        reload()
        if plan.format != format {
            lastError = "the folder is \(plan.format); this manuscript is \(format) — use Import Folder as Manuscript"
            Logger.library.warningCapture("project import refused: \(lastError ?? "")", category: "manuscripts")
            return false
        }
        guard let store = handle() else { return false }
        let id = manuscriptID.uuidString.lowercased()
        Logger.library.infoCapture(
            "project import: \(plan.files.count) file(s) into \(manuscriptID), entry \(plan.entryPath) (\(plan.entryReason)), \(plan.skipped.count) skipped",
            category: "manuscripts")
        do {
            // The entry first: a row at its path from an earlier import gives
            // way, then the path is declared (it must not be a row).
            if files.contains(where: { $0.path == plan.entryPath }) {
                _ = try store.manuscriptProjectDeleteFile(manuscriptId: id, path: plan.entryPath)
            }
            if plan.entryPath != entryPath {
                _ = try store.manuscriptProjectSetEntry(manuscriptId: id, path: plan.entryPath, author: "user:local")
            }
            var written = 0
            for file in plan.files where file.path != plan.entryPath {
                if let text = file.text {
                    _ = try store.manuscriptProjectPutText(
                        manuscriptId: id, path: file.path, role: file.role, text: text, author: "user:local")
                } else if let bytes = file.bytes {
                    _ = try store.manuscriptProjectPutBytes(
                        manuscriptId: id, path: file.path, role: file.role, bytes: bytes,
                        mimeType: nil, author: "user:local")
                }
                written += 1
            }
            // The entry's text, through the document.
            if let text = plan.entry?.text {
                let heads = RustStoreAdapter.shared.manuscriptCollabHeads(id: manuscriptID)
                guard RustStoreAdapter.shared.commitManuscriptBody(id: manuscriptID, body: text, baseHeads: heads) != nil
                else {
                    lastError = "the entry's text could not be committed"
                    Logger.library.warningCapture("project import: body commit failed for \(manuscriptID)", category: "manuscripts")
                    reload()
                    return false
                }
            }
            Logger.library.infoCapture(
                "project import wrote \(written) row(s) + the entry into \(manuscriptID)", category: "manuscripts")
            lastError = nil
            reload()
            ImbibImpressStore.shared.postMutation(structural: false, affectedIDs: [manuscriptID], kind: .otherField)
            ManuscriptSessionRegistry.shared.refreshAllLiveSessions()
            return true
        } catch {
            lastError = error.localizedDescription
            Logger.library.warningCapture("project import failed: \(error.localizedDescription)", category: "manuscripts")
            reload()
            return false
        }
    }
}
