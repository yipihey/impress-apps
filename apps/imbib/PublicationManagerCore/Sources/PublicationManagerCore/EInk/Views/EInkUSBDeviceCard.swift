//
//  EInkUSBDeviceCard.swift
//  PublicationManagerCore
//
//  The Settings › E-Ink card for the reMarkable over USB (ADR-025 P8): the
//  one place the device RECORD (`imbib/eink-device`) is edited. Every write
//  goes through `einkConfigureDevice` and then tells the running services
//  (`EInkServices.shared.settingsChanged()`), so the monitor re-reads the
//  device list and the coordinator gets a nudge; nothing here touches
//  UserDefaults (the legacy keys were migrated into the record, P7).
//
//  Reads: the record (`EInkMirrorModel.shared.status`), the connection dot
//  (`EInkServices.shared.monitor`, `@Observable`), the folder checklist
//  (`einkFolderChecklist`, a cheap store read that never talks to the
//  tablet — "Check again" re-reads it after the user created folders on the
//  device; the tablet's folder list is refreshed by the next sync).
//
//  The card's LOGIC — what the checklist says and in which order, what the
//  mode picker means, which counters show — lives in `EInkFolderChecklist`
//  and `EInkUSBDevicePaneModel`, plain values with unit tests; the view
//  only renders them.
//

import ImpressLogging
import OSLog
import SwiftUI

// MARK: - Folder checklist

/// The folders the tablet lacks, as the pane presents them: parents first
/// (the USB interface cannot create folders, so the user creates them on
/// the device in exactly this order), with a copyable plain-text rendering.
public struct EInkFolderChecklist: Sendable, Equatable {

    public struct Line: Sendable, Equatable, Hashable, Identifiable {
        /// The full path, top level first.
        public let path: [String]
        /// How many marked papers wait for this folder.
        public let publications: Int

        public var id: String { path.joined(separator: "/") }
        public var depth: Int { max(0, path.count - 1) }
        public var name: String { path.last ?? "" }
        public var parentPath: String { path.dropLast().joined(separator: " › ") }
        public var displayPath: String { path.joined(separator: " › ") }
    }

    public let lines: [Line]

    public init(_ needs: [EInkFolderNeed]) {
        // Parents first, then siblings by name — a stable order the user can
        // follow top to bottom on the tablet. Rust already lists parents
        // before children; sorting by (depth, path) pins it regardless.
        lines = needs
            .map { Line(path: $0.path, publications: $0.publications) }
            .sorted { lhs, rhs in
                if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                return lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
            }
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// Papers waiting on any of the folders (a paper waits on its deepest
    /// missing folder only, so the sum does not double count).
    public var waitingPublications: Int { lines.reduce(0) { $0 + $1.publications } }

    /// What "Copy" puts on the pasteboard: one folder per line, indented by
    /// depth, top level first — a to-do list for the tablet's file browser.
    public var copyText: String {
        lines.map { line in
            let indent = String(repeating: "  ", count: line.depth)
            let count = line.publications == 1 ? "1 paper" : "\(line.publications) papers"
            return "\(indent)\(line.name)  (\(line.displayPath); \(count))"
        }
        .joined(separator: "\n")
    }
}

// MARK: - Pane model

/// The pane's read model over the status snapshot: which record the card
/// edits, whether the checklist applies, which counters show.
public struct EInkUSBDevicePaneModel: Sendable, Equatable {

    public enum MirrorMode: String, CaseIterable, Sendable, Identifiable {
        /// Every paper with a local PDF or ePUB is mirrored; rows carry no marker.
        case all
        /// Only marked papers; rows carry the marker and the verbs apply.
        case individual

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all: return "Mirror everything with a PDF or ePUB"
            case .individual: return "Only papers I choose"
            }
        }
    }

    public struct Counter: Sendable, Equatable, Identifiable {
        public let label: String
        public let value: Int
        public let systemImage: String
        public var id: String { label }
    }

    public let device: EInkDeviceRecord
    public let counts: EInkCountsSnapshot
    public let lastSyncAt: Date?
    public let lastError: String?

    public init(device: EInkDeviceRecord, counts: EInkCountsSnapshot, lastSyncAt: Date?, lastError: String?) {
        self.device = device
        self.counts = counts
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
    }

    /// The USB device the card edits: the default device when it is USB,
    /// else the first enabled USB device, else any USB device.
    public static func usbDevice(in status: EInkStatusSnapshot?) -> EInkDeviceRecord? {
        guard let status else { return nil }
        let usb = EInkUSBTransport.rustName
        if let device = status.defaultDevice, device.transport == usb { return device }
        return status.devices.first { $0.transport == usb && $0.enabled }
            ?? status.devices.first { $0.transport == usb }
    }

    public init?(status: EInkStatusSnapshot?) {
        guard let status, let device = Self.usbDevice(in: status) else { return nil }
        self.init(device: device, counts: status.counts, lastSyncAt: status.lastSyncAt, lastError: status.lastError ?? device.lastError)
    }

    public var mode: MirrorMode { MirrorMode(rawValue: device.mirrorMode) ?? .individual }

    /// The checklist only applies while the tablet cannot create folders for
    /// us: with the `rmdoc` strategy the sync creates them itself.
    public var showsFolderChecklist: Bool { device.folderStrategy != "rmdoc" }

    /// The six counters, in the order the pane shows them.
    public var counters: [Counter] {
        [
            Counter(label: "Queued", value: counts.queued, systemImage: EInkMirrorState.queued.systemImage),
            Counter(label: "On tablet", value: counts.uploaded, systemImage: EInkMirrorState.uploaded.systemImage),
            Counter(label: "Awaiting PDF", value: counts.awaitingSource, systemImage: EInkMirrorState.awaitingSource.systemImage),
            Counter(label: "Awaiting folder", value: counts.awaitingFolder, systemImage: EInkMirrorState.awaitingFolder.systemImage),
            Counter(label: "Stale", value: counts.stale, systemImage: EInkMirrorState.stale.systemImage),
            Counter(label: "Failed", value: counts.failed, systemImage: EInkMirrorState.failed.systemImage),
        ]
    }

    /// The mode picker's footer: what a marker means and how to set one.
    public static func modeFooter(for mode: MirrorMode) -> String {
        switch mode {
        case .all:
            return "Every paper with a PDF or ePUB on this Mac is kept on the tablet. Rows show no marker; papers without a file are skipped, not queued."
        case .individual:
            return "Marked papers show the reMarkable marker in the list. Mark or unmark the selection with e, ⌃⌘E, the context menu, or Paper › Mirror to reMarkable."
        }
    }
}

// MARK: - Card

/// The USB device card. Owns no state of its own beyond the fields being
/// edited; the record is the truth and is re-read after every write.
public struct EInkUSBDeviceCard: View {

    @State private var model = EInkMirrorModel.shared
    @State private var checklist = EInkFolderChecklist([])
    @State private var rootFolderDraft = ""
    @State private var isProbing = false
    @State private var isRemoving = false
    @State private var showRemoveConfirmation = false
    @State private var lastActionMessage: String?

    /// Presents the "Import from reMarkable" browser.
    private let onImportFromTablet: () -> Void

    public init(onImportFromTablet: @escaping () -> Void = {
        NotificationCenter.default.post(name: .showEInkImportBrowser, object: nil)
    }) {
        self.onImportFromTablet = onImportFromTablet
    }

    private var pane: EInkUSBDevicePaneModel? { EInkUSBDevicePaneModel(status: model.status) }

    public var body: some View {
        if let pane {
            connectionSection(pane)
            modeSection(pane)
            foldersSection(pane)
            if pane.showsFolderChecklist {
                checklistSection(pane)
            }
            statusSection(pane)
            importSection(pane)
            removeSection(pane)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func connectionSection(_ pane: EInkUSBDevicePaneModel) -> some View {
        Section {
            HStack(spacing: 10) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.device.name)
                        .fontWeight(.semibold)
                    Text(connectionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    checkNow()
                } label: {
                    if isProbing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check now")
                    }
                }
                .disabled(isProbing)
                .accessibilityLabel("Check the USB connection now")
            }
            .padding(.vertical, 2)

            Toggle("Enabled", isOn: Binding(
                get: { pane.device.enabled },
                set: { value in write(pane.device.id) { $0.enabled = value } }
            ))
        } header: {
            Text("reMarkable (USB)")
        } footer: {
            Text("Connect the cable and turn on Settings › Storage › USB web interface on the tablet at \(pane.device.baseURL.isEmpty ? "http://10.11.99.1" : pane.device.baseURL). imbib reads and writes documents over the cable — no password, nothing through reMarkable's servers.")
        }
    }

    @ViewBuilder
    private func modeSection(_ pane: EInkUSBDevicePaneModel) -> some View {
        Section {
            Picker("Mirror", selection: Binding(
                get: { pane.mode },
                set: { newMode in write(pane.device.id) { $0.mirrorMode = newMode.rawValue } }
            )) {
                ForEach(EInkUSBDevicePaneModel.MirrorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .modifier(MirrorModePickerStyle())
            .labelsHidden()
        } header: {
            Text("What is mirrored")
        } footer: {
            Text(EInkUSBDevicePaneModel.modeFooter(for: pane.mode))
        }
    }

    @ViewBuilder
    private func foldersSection(_ pane: EInkUSBDevicePaneModel) -> some View {
        Section {
            HStack {
                TextField("Root folder on the tablet", text: $rootFolderDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRootFolder(pane) }
                if rootFolderDraft.trimmingCharacters(in: .whitespaces) != pane.device.rootFolderName {
                    Button("Apply") { commitRootFolder(pane) }
                }
            }
            Toggle("Mirror library and collection folders", isOn: Binding(
                get: { pane.device.mirrorCollections },
                set: { value in write(pane.device.id) { $0.mirrorCollections = value } }
            ))
        } header: {
            Text("Folders")
        } footer: {
            Text(pane.device.mirrorCollections
                 ? "Papers land in \(pane.device.rootFolderName) › Library › Collection on the tablet, mirroring the sidebar."
                 : "Every paper lands directly in \(pane.device.rootFolderName) on the tablet.")
        }
        .onAppear { rootFolderDraft = pane.device.rootFolderName }
        .onChange(of: pane.device.rootFolderName) { _, newValue in rootFolderDraft = newValue }
    }

    @ViewBuilder
    private func checklistSection(_ pane: EInkUSBDevicePaneModel) -> some View {
        Section {
            if checklist.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("Every folder the mirrored papers need exists on the tablet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(checklist.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.name)
                            if !line.parentPath.isEmpty {
                                Text("in \(line.parentPath)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(line.publications == 1 ? "1 paper" : "\(line.publications) papers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, CGFloat(line.depth) * 14)
                }
            }
            HStack {
                Button("Check again") { reloadChecklist(pane) }
                if !checklist.isEmpty {
                    Button("Copy list") { copyChecklist() }
                }
            }
        } header: {
            Text("Folders to create on the tablet")
        } footer: {
            Text("The USB interface cannot create folders. Create these on the tablet, parents first, then Check again — the waiting papers are sent on the next sync.")
        }
        .task(id: pane.device.id) { reloadChecklist(pane) }
    }

    @ViewBuilder
    private func statusSection(_ pane: EInkUSBDevicePaneModel) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(pane.counters) { counter in
                    HStack(spacing: 6) {
                        Image(systemName: counter.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text("\(counter.value)")
                            .monospacedDigit()
                            .fontWeight(.medium)
                        Text(counter.label)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(.vertical, 2)

            HStack {
                if let last = pane.lastSyncAt {
                    Text("Last sync \(last.formatted(.relative(presentation: .named)))")
                } else {
                    Text("Never synced")
                }
                Spacer()
                Button {
                    syncNow()
                } label: {
                    if model.isSyncing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Syncing…")
                        }
                    } else {
                        Text("Sync now")
                    }
                }
                .disabled(model.isSyncing || !pane.device.enabled)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let error = pane.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let lastActionMessage {
                Text(lastActionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Status")
        }
    }

    @ViewBuilder
    private func importSection(_ pane: EInkUSBDevicePaneModel) -> some View {
        Section {
            Toggle("Keep the annotated PDF", isOn: Binding(
                get: { pane.device.importAnnotatedPDF },
                set: { value in write(pane.device.id) { $0.importAnnotatedPDF = value } }
            ))
            Toggle("Import highlights", isOn: Binding(
                get: { pane.device.importHighlights },
                set: { value in write(pane.device.id) { $0.importHighlights = value } }
            ))
            Toggle("Read handwriting (OCR)", isOn: Binding(
                get: { pane.device.runOCR },
                set: { value in write(pane.device.id) { $0.runOCR = value } }
            ))
            Toggle("Import typed text", isOn: Binding(
                get: { pane.device.importTypedText },
                set: { value in write(pane.device.id) { $0.importTypedText = value } }
            ))
            Toggle("Import automatically when the tablet connects", isOn: Binding(
                get: { pane.device.autoImportOnConnect },
                set: { value in write(pane.device.id) { $0.autoImportOnConnect = value } }
            ))
            HStack {
                Button("Import annotations now") { importNow() }
                    .disabled(model.isSyncing || !pane.device.enabled)
                Button("Import from reMarkable…") { onImportFromTablet() }
                    .disabled(!pane.device.enabled)
            }
        } header: {
            Text("What comes back")
        } footer: {
            Text("Highlights, typed text and read handwriting become annotations on the paper (author “reMarkable”), listed in the Notes tab. The annotated PDF is kept beside the original, never written into it. “Import from reMarkable…” brings in notebooks and PDFs you put on the tablet yourself.")
        }
    }

    @ViewBuilder
    private func removeSection(_ pane: EInkUSBDevicePaneModel) -> some View {
        Section {
            Button("Remove reMarkable…", role: .destructive) { showRemoveConfirmation = true }
                .disabled(isRemoving)
                .confirmationDialog(
                    "Remove the reMarkable and forget which papers are mirrored?",
                    isPresented: $showRemoveConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) { remove(pane) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Nothing on the tablet is deleted. Imported annotations stay on the papers.")
                }
        }
    }

    // MARK: Connection

    private var isConnected: Bool { EInkServices.shared.monitor?.isConnected ?? false }

    private var connectionColor: Color {
        if model.isSyncing { return .blue }
        return isConnected ? .green : .secondary
    }

    private var connectionText: String {
        if model.isSyncing { return "Syncing…" }
        if isConnected {
            if let at = EInkServices.shared.monitor?.lastProbeAt {
                return "Connected · checked \(at.formatted(.relative(presentation: .named)))"
            }
            return "Connected"
        }
        if let at = EInkServices.shared.monitor?.lastProbeAt {
            return "Not connected · checked \(at.formatted(.relative(presentation: .named)))"
        }
        return "Not connected"
    }

    // MARK: Actions

    private func checkNow() {
        isProbing = true
        Task {
            let reachable: Bool
            if let monitor = EInkServices.shared.monitor {
                reachable = await monitor.probeNow()
            } else {
                reachable = await RustStoreAdapter.shared.einkReachable()
            }
            Logger.library.infoCapture("eink.pane check now → reachable=\(reachable)", category: "eink")
            isProbing = false
            lastActionMessage = reachable ? "The tablet answered." : "No answer over USB. Is the cable in and the USB web interface on?"
        }
    }

    /// Change one or more fields on the record, then tell the services.
    private func write(_ deviceId: String, _ change: (inout EInkDeviceConfigInput) -> Void) {
        var input = EInkDeviceConfigInput(id: deviceId)
        change(&input)
        commit(input)
    }

    private func commit(_ input: EInkDeviceConfigInput) {
        guard RustStoreAdapter.shared.einkConfigureDevice(input) != nil else {
            lastActionMessage = "The change could not be saved; see the Console (category eink)."
            return
        }
        lastActionMessage = nil
        Task { await EInkServices.shared.settingsChanged() }
    }

    private func commitRootFolder(_ pane: EInkUSBDevicePaneModel) {
        let name = rootFolderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != pane.device.rootFolderName else {
            rootFolderDraft = pane.device.rootFolderName
            return
        }
        write(pane.device.id) { $0.rootFolderName = name }
    }

    private func reloadChecklist(_ pane: EInkUSBDevicePaneModel) {
        let needs = RustStoreAdapter.shared.einkFolderChecklist(deviceId: pane.device.id)
        checklist = EInkFolderChecklist(needs)
        Logger.library.infoCapture(
            "eink.pane checklist: \(checklist.lines.count) folder(s) missing, \(checklist.waitingPublications) paper(s) waiting",
            category: "eink")
    }

    private func copyChecklist() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(checklist.copyText, forType: .string)
        #endif
        lastActionMessage = "Folder list copied."
    }

    private func syncNow() {
        Logger.library.infoCapture("eink.pane sync now", category: "eink")
        Task { await EInkServices.shared.coordinator?.nudge(.manual) }
    }

    private func importNow() {
        Logger.library.infoCapture("eink.pane import annotations now", category: "eink")
        Task { await EInkServices.shared.coordinator?.nudge(.importOnly) }
    }

    private func remove(_ pane: EInkUSBDevicePaneModel) {
        isRemoving = true
        let id = pane.device.id
        let removed = RustStoreAdapter.shared.einkRemoveDevice(id: id)
        Logger.library.infoCapture("eink.pane removed device \(id): \(removed) mirror row(s) dropped", category: "eink")
        Task {
            await EInkServices.shared.settingsChanged()
            isRemoving = false
        }
    }
}

// MARK: - Adding the device

public enum EInkUSBDeviceCreation {

    /// The record a fresh "Add reMarkable (USB)" writes: USB transport,
    /// individual mode, the tablet's default address, every import switch
    /// on, enabled. Pure so the defaults are pinned by a test.
    public static func defaultInput(name: String = "reMarkable") -> EInkDeviceConfigInput {
        var input = EInkDeviceConfigInput()
        input.name = name
        input.transport = EInkUSBTransport.rustName
        input.mirrorMode = "individual"
        input.rootFolderName = "imbib"
        input.mirrorCollections = true
        input.importAnnotatedPDF = true
        input.importHighlights = true
        input.importInk = true
        input.importTypedText = true
        input.runOCR = true
        input.autoImportOnConnect = true
        input.enabled = true
        return input
    }

    /// Create the record and wake the services. Returns the record, or nil
    /// when the store refused (logged under `eink`).
    @MainActor
    public static func addUSBDevice() async -> EInkDeviceRecord? {
        guard let record = RustStoreAdapter.shared.einkConfigureDevice(defaultInput()) else { return nil }
        await EInkServices.shared.settingsChanged()
        return record
    }
}

/// Radio buttons on macOS (the two modes read as a choice, not a menu);
/// the platform default on iOS, which has no radio group.
private struct MirrorModePickerStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.pickerStyle(.radioGroup)
        #else
        content.pickerStyle(.inline)
        #endif
    }
}
