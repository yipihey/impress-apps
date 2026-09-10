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

    @ObservationIgnored private var store: SharedStore?
    @ObservationIgnored private var openAttempted = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    private static var models: [UUID: ManuscriptProjectModel] = [:]

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

    /// Projected `.bib` rows as the text the compiler should see. Until the
    /// projection resolves in-process, a projected row compiles as its own
    /// stored text (the verbs resolve `cited`/`collection`/`library` rows
    /// through imbib's store).
    public func resolvedBibliographies() -> [TreeRenderBibliography] {
        projectedBibliographies.compactMap { file in
            guard let text = file.content ?? bytes(of: file.path).flatMap({ String(data: $0, encoding: .utf8) })
            else { return nil }
            return TreeRenderBibliography(path: file.path, text: text)
        }
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
            allowShell: allowShell, entryOverride: nil, bibliographies: resolvedBibliographies())
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
