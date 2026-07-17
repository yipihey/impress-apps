//
//  ConsoleView.swift
//  ImpressLogging
//
//  Shared in-app console for viewing log entries across all impress apps.
//

import SwiftUI

// MARK: - Shared Formatter

private let consoleTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

// MARK: - Console Mode

/// The Console window can display either the live log stream or a live
/// performance-metrics table. Both are read-only observations.
private enum ConsoleMode: String, CaseIterable, Identifiable {
    case logs = "Logs"
    case performance = "Performance"
    var id: String { rawValue }
}

// MARK: - Console View

public struct ConsoleView: View {

    // MARK: - Configuration

    private let appName: String

    // MARK: - State

    @State private var logStore = LogStore.shared
    @State private var searchText = ""
    @State private var showDebug = true
    @State private var showInfo = true
    @State private var showWarning = true
    @State private var showError = true
    @State private var autoScroll = true
    @State private var selection: Set<LogEntry.ID> = []
    @State private var mode: ConsoleMode = .logs

    // MARK: - Init

    public init(appName: String = "impress") {
        self.appName = appName
    }

    // MARK: - Computed

    private var enabledLevels: Set<LogLevel> {
        var levels = Set<LogLevel>()
        if showDebug { levels.insert(.debug) }
        if showInfo { levels.insert(.info) }
        if showWarning { levels.insert(.warning) }
        if showError { levels.insert(.error) }
        return levels
    }

    private var filteredEntries: [LogEntry] {
        logStore.filteredEntries(levels: enabledLevels, searchText: searchText)
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            modeBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
                #if os(macOS)
                .background(Color(nsColor: .windowBackgroundColor))
                #endif

            switch mode {
            case .logs:
                logsContent
            case .performance:
                PerformanceTabView()
            }
        }
        .frame(minWidth: 600, minHeight: 300)
    }

    // MARK: - Mode Bar

    private var modeBar: some View {
        Picker("", selection: $mode) {
            ForEach(ConsoleMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
    }

    // MARK: - Logs Content

    private var logsContent: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                #if os(macOS)
                .background(Color(nsColor: .windowBackgroundColor))
                #endif

            Divider()

            if filteredEntries.isEmpty {
                emptyState
            } else {
                logList
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                FilterToggle(label: "Debug", color: .secondary, isOn: $showDebug)
                FilterToggle(label: "Info", color: .blue, isOn: $showInfo)
                FilterToggle(label: "Warn", color: .orange, isOn: $showWarning)
                FilterToggle(label: "Error", color: .red, isOn: $showError)
            }

            Spacer()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            #if os(macOS)
            .background(Color(nsColor: .textBackgroundColor))
            #endif
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Divider()
                .frame(height: 20)

            Toggle(isOn: $autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Auto-scroll to bottom")

            Button {
                copySelectedEntries()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(selection.isEmpty)
            .help("Copy selected (\(selection.count))")
            .keyboardShortcut("c", modifiers: .command)

            Button {
                logStore.clear()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear log")

            Button {
                exportLog()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export log")
        }
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries, selection: $selection) { entry in
                ConsoleRowView(entry: entry)
                    .id(entry.id)
            }
            .listStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .onChange(of: filteredEntries.count) { oldValue, newValue in
                if autoScroll, let last = filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .contextMenu {
                Button("Copy Selected") {
                    copySelectedEntries()
                }
                .disabled(selection.isEmpty)

                Button("Select All") {
                    selection = Set(filteredEntries.map { $0.id })
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No log entries")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Logs will appear here as you use the app")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func exportLog() {
        #if os(macOS)
        let content = logStore.export(levels: enabledLevels, searchText: searchText)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(appName)-log-\(Date().ISO8601Format()).txt"

        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }

    private func copySelectedEntries() {
        guard !selection.isEmpty else { return }

        let selectedEntries = filteredEntries.filter { selection.contains($0.id) }

        let text = selectedEntries.map { entry in
            let time = consoleTimeFormatter.string(from: entry.timestamp)
            let level = entry.level.rawValue.uppercased()
            return "\(time) [\(level)] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Filter Toggle

public struct FilterToggle: View {
    let label: String
    let color: Color
    @Binding var isOn: Bool

    public init(label: String, color: Color, isOn: Binding<Bool>) {
        self.label = label
        self.color = color
        self._isOn = isOn
    }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isOn ? color.opacity(0.2) : Color.clear)
                .foregroundStyle(isOn ? color : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isOn ? color : Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Console Row View

public struct ConsoleRowView: View {
    let entry: LogEntry

    public init(entry: LogEntry) {
        self.entry = entry
    }

    private var timeString: String {
        consoleTimeFormatter.string(from: entry.timestamp)
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeString)
                .foregroundStyle(.secondary)
                .frame(width: 65, alignment: .leading)

            Text(entry.level.rawValue.uppercased())
                .foregroundStyle(entry.level.color)
                .frame(width: 55, alignment: .leading)

            Text(entry.category)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(entry.message)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Performance Tab

/// Live view of `PerfMetrics.shared` — one row per operation bucket showing
/// call count, latency percentiles, main-thread share, and budget breaches.
/// Bottlenecks (budget breaches, high main-thread share) are highlighted so
/// the user watching the Console can see them without leaving the app.
public struct PerformanceTabView: View {

    @State private var snapshot: PerfSnapshot = PerfMetrics.shared.snapshot()
    @State private var autoRefresh = true

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                #if os(macOS)
                .background(Color(nsColor: .windowBackgroundColor))
                #endif

            Divider()

            if snapshot.buckets.isEmpty {
                emptyState
            } else {
                table
            }
        }
        // Refresh while visible; the loop ends when the view disappears (the
        // `.task` is cancelled), so it never runs in the background.
        .task(id: autoRefresh) {
            guard autoRefresh else { return }
            while !Task.isCancelled {
                snapshot = PerfMetrics.shared.snapshot()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("\(snapshot.buckets.count) buckets")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let slowest = snapshot.slowestBucket, slowest.maxMillis > 0 {
                Text("slowest: \(slowest.name) \(fmt(slowest.maxMillis))ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle(isOn: $autoRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .toggleStyle(.button)
            .help("Auto-refresh (1s)")

            Button {
                snapshot = PerfMetrics.shared.snapshot()
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }
            .help("Refresh now")

            Button {
                PerfMetrics.shared.reset()
                snapshot = PerfMetrics.shared.snapshot()
            } label: {
                Image(systemName: "trash")
            }
            .help("Reset counters (budgets preserved)")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            cell("Operation", width: 120, align: .leading, bold: true)
            cell("Count", width: 60, align: .trailing, bold: true)
            cell("mean", width: 70, align: .trailing, bold: true)
            cell("p50", width: 70, align: .trailing, bold: true)
            cell("p95", width: 70, align: .trailing, bold: true)
            cell("max", width: 70, align: .trailing, bold: true)
            cell("main%", width: 55, align: .trailing, bold: true)
            cell("budget", width: 70, align: .trailing, bold: true)
            cell("breaches", width: 70, align: .trailing, bold: true)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
    }

    private var table: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(snapshot.buckets, id: \.name) { b in
                HStack(spacing: 8) {
                    cell(b.name, width: 120, align: .leading)
                    cell("\(b.count)", width: 60, align: .trailing)
                    cell(fmt(b.meanMillis), width: 70, align: .trailing)
                    cell(fmt(b.p50Millis), width: 70, align: .trailing)
                    cell(fmt(b.p95Millis), width: 70, align: .trailing)
                    cell(fmt(b.maxMillis), width: 70, align: .trailing)
                    cell(pct(b.mainThreadShare), width: 55, align: .trailing,
                         color: b.mainThreadShare > 0.5 ? .orange : .primary)
                    cell(b.budgetMillis.map { fmt($0) } ?? "—", width: 70, align: .trailing)
                    cell(b.breachCount == 0 ? "0" : "\(b.breachCount)", width: 70,
                         align: .trailing, color: b.breachCount > 0 ? .red : .primary)
                }
                .padding(.vertical, 1)
            }
            .listStyle(.plain)
            .font(.system(.body, design: .monospaced))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No performance samples yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Timings appear as operations run (compile, search, store, …)")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Cell helpers

    private func cell(_ text: String, width: CGFloat, align: Alignment,
                      bold: Bool = false, color: Color = .primary) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(color)
            .frame(width: width, alignment: align == .leading ? .leading : .trailing)
    }

    private func fmt(_ ms: Double) -> String { String(format: "%.1f", ms) }
    private func pct(_ share: Double) -> String { String(format: "%.0f%%", share * 100) }
}
