//
//  ConsoleView.swift
//  ImpressLogging
//
//  Shared in-app console for viewing log entries across all impress apps.
//
//  ## Cross-platform since Stage 5b (2026-07-30)
//
//  This file compiled on iOS before, but two of its three actions were
//  `#if os(macOS)` bodies — so on iOS, Copy did nothing and Export did
//  nothing — and it opened at `minWidth: 600`. imbib-iOS therefore shipped
//  `IOSConsoleView`, a 310-line second console with its own filter chips, its
//  own row view and its own export. It also had NO Performance tab, so the
//  `PerfMetrics` surface the suite reads bottlenecks from was macOS-only.
//
//  Everything except the TOOLBAR and the ROW LAYOUT is now genuinely shared:
//  the filter/search state, the level toggles, the entry list, the empty
//  state, the export text, the copy text and the parameterized export
//  filename. Those two are `#if` islands, for the reason the settings work
//  gave for `SettingsForm`: a dense pointer toolbar with four toggles, a
//  search field and three icon buttons does not fit a phone, and a row of
//  fixed-width columns does not either. iOS gets the chip row + search bar +
//  overflow menu it shipped, and the two-line row that made long messages
//  readable at that width.
//
//  Presentation stays a per-platform renderer, like the settings surface:
//  macOS puts `ConsoleView` in a `Window`, iOS presents `ConsoleScreen`
//  (NavigationStack + Done) as a sheet.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

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
    #if os(iOS)
    /// Temp file backing the share sheet (iOS export).
    @State private var exportedFile: ConsoleExportFile?
    #endif

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
        #if os(macOS)
        // Window metrics. A phone has no window to size, and 600pt of minimum
        // width on an iPhone clipped the console off screen.
        .frame(minWidth: 600, minHeight: 300)
        #else
        .sheet(item: $exportedFile) { file in
            ConsoleShareSheet(items: [file.url])
        }
        #endif
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

    // MARK: - Toolbar (the one platform island)

    #if os(macOS)

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                levelToggles
            }

            Spacer()

            searchField
                .frame(width: 150)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor))
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

    #else

    /// iOS: the chip row + entry count, the search field on its own line, and
    /// the three actions in an overflow menu — the arrangement `IOSConsoleView`
    /// shipped, because four toggles plus a search field plus three icon
    /// buttons do not fit an iPhone's width.
    private var toolbar: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    levelToggles

                    Spacer()

                    Text("\(filteredEntries.count) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 8) {
                searchField
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Menu {
                    Button {
                        autoScroll.toggle()
                    } label: {
                        Label(
                            autoScroll ? "Auto-scroll On" : "Auto-scroll Off",
                            systemImage: autoScroll ? "checkmark" : "")
                    }

                    Divider()

                    Button {
                        copyAllEntries()
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }

                    Button {
                        exportLog()
                    } label: {
                        Label("Share Logs", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button(role: .destructive) {
                        logStore.clear()
                    } label: {
                        Label("Clear Logs", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    #endif

    // MARK: - Toolbar pieces (shared)

    @ViewBuilder
    private var levelToggles: some View {
        FilterToggle(label: "Debug", color: .secondary, isOn: $showDebug)
        FilterToggle(label: "Info", color: .blue, isOn: $showInfo)
        FilterToggle(label: "Warn", color: .orange, isOn: $showWarning)
        FilterToggle(label: "Error", color: .red, isOn: $showError)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $searchText)
                .textFieldStyle(.plain)
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
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            list
                .listStyle(.plain)
                #if os(macOS)
                .font(.system(.body, design: .monospaced))
                #else
                .font(.system(.caption, design: .monospaced))
                #endif
                .onChange(of: filteredEntries.count) { _, _ in
                    if autoScroll, let last = filteredEntries.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
        }
    }

    #if os(macOS)

    private var list: some View {
        List(filteredEntries, selection: $selection) { entry in
            ConsoleRowView(entry: entry)
                .id(entry.id)
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

    #else

    /// iOS has no pointer multi-select outside edit mode, so a `selection:`
    /// list would offer a Copy Selected that can never have a selection (the
    /// `RecordTriageNewTagPrompt` rule: omit the affordance). Per-row copy is
    /// the long-press menu; Copy All is in the overflow menu.
    private var list: some View {
        List {
            ForEach(filteredEntries) { entry in
                ConsoleRowView(entry: entry)
                    .id(entry.id)
                    .listRowInsets(
                        EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .contextMenu {
                        Button {
                            copyToClipboard(Self.plainText(for: [entry]))
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
            }
        }
    }

    #endif

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

    /// The export filename, parameterized by `appName` on BOTH platforms.
    ///
    /// imbib-iOS's own console hardcoded `"imbib-log-…"`, which is exactly the
    /// drift the `appName` parameter exists to prevent.
    var exportFilename: String {
        "\(appName)-log-\(Date().ISO8601Format()).txt"
    }

    private func exportLog() {
        let content = logStore.export(levels: enabledLevels, searchText: searchText)

        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = exportFilename

        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
        #else
        // iOS has no save panel: write the same text to a temp file and hand it
        // to the share sheet. Before this, Export was a no-op body on iOS.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(exportFilename)
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            exportedFile = ConsoleExportFile(url: tempURL)
        } catch {
            logStore.log(
                level: .error, category: "console",
                message: "Export failed: \(error.localizedDescription)")
        }
        #endif
    }

    private func copySelectedEntries() {
        guard !selection.isEmpty else { return }
        let selectedEntries = filteredEntries.filter { selection.contains($0.id) }
        copyToClipboard(Self.plainText(for: selectedEntries))
    }

    private func copyAllEntries() {
        copyToClipboard(logStore.export(levels: enabledLevels, searchText: searchText))
    }

    /// One entry per line, `HH:mm:ss [LEVEL] [category] message` — the format
    /// both consoles produced.
    static func plainText(for entries: [LogEntry]) -> String {
        entries.map { entry in
            let time = consoleTimeFormatter.string(from: entry.timestamp)
            let level = entry.level.rawValue.uppercased()
            return "\(time) [\(level)] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Share Sheet (iOS)

#if os(iOS)
/// The exported log file, as an `Identifiable` so `.sheet(item:)` owns its own
/// presentation state (rather than a `.constant` binding SwiftUI cannot clear).
private struct ConsoleExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// `UIActivityViewController` wrapper for the console's export.
private struct ConsoleShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

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

    #if os(macOS)

    /// Fixed-width columns — a table read with a pointer at window width.
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

    #else

    /// Two lines: metadata above, message below. At iPhone width the column
    /// layout left ~90pt for the message, which is where imbib-iOS's own row
    /// view came from — it is kept, as the layout, not as a second console.
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(timeString)
                    .foregroundStyle(.secondary)

                Text(entry.level.rawValue.uppercased())
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(entry.level.color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(entry.level.color.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(entry.category)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text(entry.message)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    #endif
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
        // The header is narrower than the window (fixed-width cells), and its
        // enclosing VStack centers by default — which floated the titles into
        // the middle of a wide window while the List rows below stayed
        // leading-aligned, so no column lined up with its title. Pin it to
        // the same edge as the rows.
        .frame(maxWidth: .infinity, alignment: .leading)
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
                // Rows must share the header's exact 12pt leading inset, so
                // zero the List's own (version-dependent) row insets and
                // apply the same padding the header uses.
                .padding(.horizontal, 12)
                .listRowInsets(EdgeInsets())
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
