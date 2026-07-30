// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS) since Stage 5c.
//
// It was gated by the GUI-meld Phase 1 header copied verbatim, and by an
// `import AppKit` that nothing in the body used: the whole pane is plain
// SwiftUI over cross-platform chassis types (`MailStoreReader`,
// `MessageRowData`, `DetailTab`, `RelatedItemsSection`, `TagChip`,
// `FlowLayout`, `ImbibImpressStore.events`). impart-iOS renders THIS pane —
// not an app-side clone — which is what keeps the two platforms' message
// detail from drifting the way imbib's publication detail did before Stage 5b.
//
//  MessageDetailPane.swift
//  PublicationManagerCore
//
//  The tabbed message detail (Stage 2-A): the standard chassis detail
//  experience for an `email-message` item, mirroring FigureDetailPane's tab
//  host — Info / Source / View, from MessageRecordKind.descriptor.
//
//  - Info: headers (from/to/cc/date/subject/message_id), thread membership
//    (tap another thread message to switch the pane to it), flags/tags.
//  - Source: the raw plain-text body, monospaced + selectable (payload body
//    is plain text after Stage 0 — impart's mirror stores textBody).
//  - View (DetailTab.pdf relabeled): the body nicely typeset — SwiftUI Text
//    at a comfortable reading measure. Deliberately NO WebKit in PMC
//    (renderer-hygiene rule in scripts/check-chassis-deps.sh); HTML mail
//    rendering stays in impart's classic window.
//

import SwiftUI
import ImpressFTUI
import ImpressRustCore

public struct MessageDetailPane: View {

    let messageID: UUID
    @Binding var selectedTab: DetailTab

    /// Top clearance for the tab picker (the section host reclaims the
    /// toolbar band with `.ignoresSafeArea(.top)` — same as figures).
    let topInset: CGFloat

    /// The message the pane currently shows. Starts as `messageID` and can
    /// diverge when the user taps a sibling in the Info tab's thread list —
    /// list selection (which owns `messageID`) is untouched by that local
    /// navigation.
    @State private var displayedID: UUID?
    @State private var row: MessageRowData?
    /// The displayed message's thread, oldest first (empty = no thread_id).
    @State private var threadRows: [MessageRowData] = []

    public init(
        messageID: UUID,
        selectedTab: Binding<DetailTab>,
        topInset: CGFloat = 0
    ) {
        self.messageID = messageID
        self._selectedTab = selectedTab
        self.topInset = topInset
    }

    /// All message tabs are unconditionally available (info/source/view) —
    /// the context carries no gating fields for this kind.
    private var tabContext: RecordTabContext { RecordTabContext() }

    private var availableTabs: [DetailTab] {
        MessageRecordKind.descriptor.availableTabs(for: tabContext)
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabPicker
                .padding(.top, topInset)
            Divider()
            content
        }
        .onChange(of: messageID, initial: true) { _, id in
            displayedID = id
            loadDisplayed(id: id)
            let coerced = MessageRecordKind.descriptor.coercedTab(selectedTab, for: tabContext)
            if coerced != selectedTab { selectedTab = coerced }
        }
        .task(id: messageID) {
            // Refresh the snapshot when the displayed message mutates
            // elsewhere in-process (star/flag/tag via the generic ops).
            for await event in ImbibImpressStore.shared.events.subscribe() {
                if case .itemsMutated(_, let ids) = event,
                   let current = displayedID, ids.contains(current) {
                    loadDisplayed(id: current)
                }
            }
        }
    }

    private func loadDisplayed(id: UUID) {
        row = MailStoreReader.shared.fetchMessage(id: id.uuidString)
            .flatMap { MessageRowData(from: $0) }
        if let threadID = row?.threadID {
            threadRows = MailStoreReader.shared.fetchThread(threadID: threadID)
                .compactMap { MessageRowData(from: $0) }
        } else {
            threadRows = []
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(availableTabs) { tab in
                // The message "PDF" tab is really the typeset-body surface —
                // label it "View".
                Label(tab == .pdf ? "View" : tab.label,
                      systemImage: tab == .pdf ? "text.justify.left" : tab.icon).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .info:
            infoTab
        case .source:
            sourceTab
        case .pdf:
            viewTab
        case .notes, .bibtex:
            // Not part of the message tab set; coerced away on entry.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Info tab

    @ViewBuilder
    private var infoTab: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(row.titleText)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .textSelection(.enabled)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        infoRow("From", row.from.isEmpty ? "—" : row.from)
                        if !row.to.isEmpty {
                            infoRow("To", row.to.joined(separator: ", "))
                        }
                        if !row.cc.isEmpty {
                            infoRow("Cc", row.cc.joined(separator: ", "))
                        }
                        infoRow("Date", row.messageDate.formatted(date: .abbreviated, time: .shortened))
                        if let messageID = row.messageIDHeader {
                            infoRow("Message-ID", messageID, monospaced: true)
                        }
                    }

                    if threadRows.count > 1 {
                        Divider()
                        threadSection
                    }

                    // ADR-0022 D8 (G5): typed edges — the task a message
                    // produced, the paper it references. Distinct from the
                    // thread list above, which is `thread_id` equality, not
                    // an edge. Renders nothing when there are none.
                    RelatedItemsSection(itemID: displayedID ?? messageID)

                    if row.flag != nil || !row.tagDisplays.isEmpty {
                        Divider()
                    }
                    if let flag = row.flag {
                        HStack(spacing: 6) {
                            Image(systemName: "flag.fill")
                                .foregroundStyle(flag.color.displayColor)
                            Text(flag.color.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !row.tagDisplays.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(row.tagDisplays) { tag in
                                TagChip(tag: tag)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Message Unavailable",
                systemImage: "envelope",
                description: Text("This message could not be read from the store.")
            )
        }
    }

    /// Thread membership: every message sharing the displayed message's
    /// thread_id, oldest first; tapping a sibling switches the pane to it
    /// (the A3 thread view — no list expand/collapse in v1).
    private var threadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thread — \(threadRows.count) messages")
                .font(.headline)
            ForEach(threadRows) { member in
                Button {
                    displayedID = member.id
                    loadDisplayed(id: member.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: member.id == displayedID
                            ? "circle.inset.filled" : "circle")
                            .font(.caption)
                            .foregroundStyle(member.id == displayedID
                                ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.headerText)
                                .fontWeight(member.id == displayedID ? .semibold : .regular)
                            Text(member.messageDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
    }

    // MARK: Source tab (raw body, monospaced)

    @ViewBuilder
    private var sourceTab: some View {
        if let row {
            ScrollView {
                Text(row.body.isEmpty ? "(empty body)" : row.body)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        } else {
            emptyBody
        }
    }

    // MARK: View tab (typeset body — honest v1: plain text, no WebKit)

    @ViewBuilder
    private var viewTab: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(row.titleText)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .textSelection(.enabled)
                    Text("\(row.headerText) · \(row.messageDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text(row.body.isEmpty ? "(empty body)" : row.body)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                // Comfortable reading measure (~680pt), centered.
                .frame(maxWidth: 680, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        } else {
            emptyBody
        }
    }

    private var emptyBody: some View {
        ContentUnavailableView(
            "Message Unavailable",
            systemImage: "envelope",
            description: Text("This message could not be read from the store.")
        )
    }
}
