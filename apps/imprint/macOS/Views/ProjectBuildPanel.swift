//
//  ProjectBuildPanel.swift
//  imprint
//
//  The Build inspector (ADR-0030 P4): pick a target, build it, read what
//  happened — the figure steps (ran / fresh / skipped / failed), the
//  engine's diagnostics naming the file they belong to, the outputs, the
//  log — and the recorded builds. Every build goes through
//  `ManuscriptProjectModel.build`, which runs the Rust engine and records
//  the `manuscript-build` row; previews never run shell steps, an explicit
//  build does when asked.
//

#if os(macOS)
import AppKit
import ImpressKit
import ImprintCore
import PublicationManagerCore
import SwiftUI

struct ProjectBuildSidePanel: ManuscriptSidePanel {
    let id = "build"
    let label = "Build"
    let systemImage = "hammer"

    func makeView(_ context: ManuscriptPanelContext) -> AnyView {
        AnyView(ProjectBuildPanel(manuscriptID: context.manuscriptID, liveSource: context.source))
    }
}

extension Notification.Name {
    /// File ▸ Build Manuscript (⌥⌘B): the mounted Build panel builds the
    /// default target of the front manuscript.
    static let buildManuscript = Notification.Name("imprint.buildManuscript")
}

struct ProjectBuildPanel: View {
    let manuscriptID: UUID
    let liveSource: Binding<String>

    @State private var model: ManuscriptProjectModel
    @State private var targetID: String = ""
    @State private var allowShell = false
    @State private var showLog = false

    init(manuscriptID: UUID, liveSource: Binding<String>) {
        self.manuscriptID = manuscriptID
        self.liveSource = liveSource
        _model = State(initialValue: ManuscriptProjectModel.shared(for: manuscriptID))
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let report = model.lastReport {
                        reportSection(report)
                    } else if let last = model.builds.first {
                        lastRecordedSection(last)
                    } else {
                        Text("No build yet. Build compiles the target from the store — every file of the project — and records the outcome.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !model.builds.isEmpty {
                        historySection
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            model.reloadBuilds()
            if targetID.isEmpty { targetID = model.targets.first?.id ?? "main" }
        }
        .onNotifications([
            (.buildManuscript, { _ in Task { await runBuild() } }),
        ])
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Target", selection: $targetID) {
                    ForEach(model.targets) { target in
                        Text("\(target.name) · \(target.engine)").tag(target.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer()
                Button {
                    Task { await runBuild() }
                } label: {
                    if model.isBuilding {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Build", systemImage: "hammer.fill")
                    }
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(model.isBuilding)
                .help("Build this target from the store and record it (⌥⌘B)")
            }
            Toggle("Run shell figure steps", isOn: $allowShell)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Figure sources with a `shell` runner execute their declared command in the build directory")
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func reportSection(_ report: TreeBuildReport) -> some View {
        HStack(spacing: 6) {
            Image(systemName: report.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(report.isSuccess ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.message).font(.callout).lineLimit(3)
                Text("\(report.engine) · \(report.durationMs) ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let pdf = report.pdfOutput {
                Button("Open PDF") { NSWorkspace.shared.open(pdf.url) }
                    .controlSize(.small)
            }
        }

        if !report.steps.isEmpty {
            Text("Figure steps").font(.caption).foregroundStyle(.secondary)
            ForEach(report.steps) { step in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: stepIcon(step.status))
                        .foregroundStyle(stepColor(step.status))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(step.source) · \(step.runner)").font(.caption)
                        Text(step.message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        if let command = step.command {
                            Text(command).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
            }
        }

        let problems = report.diagnostics.filter { $0.severity != .info }
        if !problems.isEmpty {
            Text("Diagnostics").font(.caption).foregroundStyle(.secondary)
            ForEach(problems.prefix(40)) { d in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: d.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(d.severity == .error ? .red : .orange)
                        .frame(width: 14)
                    Text(d.summaryLine).font(.caption2).textSelection(.enabled)
                }
            }
            if problems.count > 40 {
                Text("… and \(problems.count - 40) more").font(.caption2).foregroundStyle(.secondary)
            }
        }

        if !report.outputs.isEmpty {
            Text("Outputs").font(.caption).foregroundStyle(.secondary)
            ForEach(report.outputs) { out in
                HStack {
                    Text(out.name).font(.caption2.monospaced())
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(out.size), countStyle: .file))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([out.url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                }
            }
        }

        DisclosureGroup("Log", isExpanded: $showLog) {
            Text(report.log.isEmpty ? "(nothing ran)" : report.log)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func lastRecordedSection(_ build: ManuscriptProjectModel.Build) -> some View {
        HStack(spacing: 6) {
            Image(systemName: build.status == "ok" ? "checkmark.circle" : "xmark.octagon")
                .foregroundStyle(build.status == "ok" ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(build.message).font(.callout).lineLimit(3)
                Text("last recorded build · \(build.engine) · \(dateLabel(build.startedMs))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let path = build.pdfPath, FileManager.default.fileExists(atPath: path) {
                Button("Open PDF") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .controlSize(.small)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recorded builds").font(.caption).foregroundStyle(.secondary)
            ForEach(model.builds.prefix(10)) { build in
                HStack(spacing: 6) {
                    Circle()
                        .fill(build.status == "ok" ? Color.green : (build.status == "running" ? Color.orange : Color.red))
                        .frame(width: 6, height: 6)
                    Text("\(build.targetID) · \(build.engine)").font(.caption2)
                    Spacer()
                    Text(dateLabel(build.startedMs)).font(.caption2).foregroundStyle(.tertiary)
                    if let ms = build.durationMs {
                        Text("\(ms) ms").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func runBuild() async {
        // The buffer may be ahead of the store: build what the author sees.
        let live = liveSource.wrappedValue
        let override = live.isEmpty ? nil : live
        await model.build(targetID: targetID, allowShell: allowShell, entryOverride: override)
    }

    private func stepIcon(_ status: TreeStepReport.Status) -> String {
        switch status {
        case .ran: return "checkmark.circle.fill"
        case .fresh: return "checkmark.circle"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func stepColor(_ status: TreeStepReport.Status) -> Color {
        switch status {
        case .ran: return .green
        case .fresh: return .secondary
        case .skipped: return .orange
        case .failed: return .red
        }
    }

    private func dateLabel(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
#endif
