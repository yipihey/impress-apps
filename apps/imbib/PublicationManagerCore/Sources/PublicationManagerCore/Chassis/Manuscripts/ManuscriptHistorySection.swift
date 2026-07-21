#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  ManuscriptHistorySection.swift
//  PublicationManagerCore
//
//  Info-pane "History" section (GUI-meld plan §4/§History): the fine-grained
//  operation timeline from the SharedStore operations_for surface. Consecutive
//  body edits collapse into one row ("Edited body · N saves · date range");
//  metadata ops (title/status/authors/flag/tag) render individually. Replaces
//  imprint's stub VersionHistoryView.

import SwiftUI
import ImpressRustCore

public struct ManuscriptHistorySection: View {

    let manuscriptID: UUID

    @State private var entries: [HistoryEntry] = []
    @State private var expanded = false

    public init(manuscriptID: UUID) {
        self.manuscriptID = manuscriptID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("History")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if !entries.isEmpty {
                    Button(expanded ? "Collapse" : "Show all") { expanded.toggle() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if entries.isEmpty {
                Text("No history yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(visibleEntries) { entry in
                    entryRow(entry)
                }
            }
        }
        .task(id: manuscriptID) { reload() }
    }

    private var visibleEntries: [HistoryEntry] {
        expanded ? entries : Array(entries.prefix(6))
    }

    private func entryRow(_ entry: HistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
    }

    private func reload() {
        let ops = RustStoreAdapter.shared.manuscriptOperations(id: manuscriptID)
        entries = Self.collapse(ops)
    }

    // MARK: - Collapsing

    struct HistoryEntry: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let icon: String
    }

    /// Collapse consecutive body-edit ops into a single summary row; render
    /// everything else individually. Ops arrive oldest-first; we present
    /// newest-first.
    static func collapse(_ ops: [SharedOperationRow]) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        var runStart: SharedOperationRow?
        var runEnd: SharedOperationRow?
        var runCount = 0

        func flushRun() {
            guard let start = runStart, let end = runEnd, runCount > 0 else { return }
            let dates = dateRange(from: start.dateMs, to: end.dateMs)
            let label = runCount == 1 ? "Edited body" : "Edited body · \(runCount) saves"
            out.append(HistoryEntry(title: label, subtitle: dates, icon: "square.and.pencil"))
            runStart = nil; runEnd = nil; runCount = 0
        }

        for op in ops {
            if op.isBodyEdit {
                if runStart == nil { runStart = op }
                runEnd = op
                runCount += 1
            } else {
                flushRun()
                out.append(metadataEntry(op))
            }
        }
        flushRun()
        return out.reversed()
    }

    private static func metadataEntry(_ op: SharedOperationRow) -> HistoryEntry {
        let when = Date(timeIntervalSince1970: TimeInterval(op.dateMs) / 1000.0)
        let dateStr = when.formatted(.dateTime.month().day().hour().minute())
        let (title, icon): (String, String)
        if op.fieldNames.contains("current_revision_ref") {
            (title, icon) = ("Saved a version", "clock.arrow.circlepath")
        } else if op.fieldNames.contains("status") {
            (title, icon) = ("Changed status", "flag")
        } else if op.fieldNames.contains("title") {
            (title, icon) = ("Renamed", "textformat")
        } else if !op.fieldNames.isEmpty {
            (title, icon) = ("Edited \(op.fieldNames.joined(separator: ", "))", "pencil")
        } else {
            (title, icon) = (op.opType.replacingOccurrences(of: "_", with: " ").capitalized, "circle")
        }
        return HistoryEntry(title: title, subtitle: dateStr, icon: icon)
    }

    private static func dateRange(from: Int64, to: Int64) -> String {
        let a = Date(timeIntervalSince1970: TimeInterval(from) / 1000.0)
        let b = Date(timeIntervalSince1970: TimeInterval(to) / 1000.0)
        let cal = Calendar.current
        if cal.isDate(a, inSameDayAs: b) {
            return a.formatted(.dateTime.month().day().year())
        }
        return "\(a.formatted(.dateTime.month().day())) – \(b.formatted(.dateTime.month().day().year()))"
    }
}
#endif
