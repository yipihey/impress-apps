//
//  EInkSettingsView.swift
//  PublicationManagerCore
//
//  Settings › E-Ink (ADR-025 P8). The reMarkable over USB is the engine's
//  device: its record lives in the store (`imbib/eink-device`) and the pane
//  edits it through `EInkUSBDeviceCard`. Adding a reMarkable creates that
//  record with USB defaults — no transport picker, no credential, nothing
//  through reMarkable's servers.
//
//  The other kinds (Supernote, Kindle Scribe) and the reMarkable's legacy
//  transports (local network, folder, cloud) keep the `EInkDeviceManager` /
//  `EInkSettingsStore` device list they had, below the card. The generic
//  auto-sync / organisation / annotation sections that once sat under it
//  were retired in P9: the USB device's answers to those questions are on
//  its record, the migration (P7) removed the legacy keys they read, and
//  nothing that still runs honoured them — the pane must never show two
//  answers to one question.
//
//  Pane id, title, symbol and subtitle are declared in
//  `AppSettingsConfiguration.imbib` and pinned by
//  `SettingsSurfacePhase2ContractTests`; nothing here names them.
//

import ImpressKit
import ImpressLogging
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.imbib.app", category: "einkSettings")

// MARK: - Settings View

/// Settings view for configuring E-Ink device integration.
public struct EInkSettingsView: View {
    @State private var settings = EInkSettingsStore.shared
    @State private var deviceManager = EInkDeviceManager.shared
    @State private var einkModel = EInkMirrorModel.shared
    @State private var deviceInfoList: [DeviceRowInfo] = []
    @State private var activeDeviceID: String?
    @State private var showingAddDevice = false
    @State private var selectedDeviceForConfig: String?
    /// Presents the reMarkable cloud / local-network connect sheet.
    @State private var showingRemarkableConnect = false
    @State private var showingImportBrowser = false
    @State private var isAddingUSB = false
    @State private var errorMessage: String?

    public init() {}

    /// The USB device record the card edits, if any.
    private var usbDevice: EInkDeviceRecord? { EInkUSBDevicePaneModel.usbDevice(in: einkModel.status) }

    /// Legacy (non-engine) devices still registered in memory.
    private var legacyDevices: [DeviceRowInfo] {
        deviceInfoList.filter { !($0.deviceType == .remarkable && $0.syncMethod == .usb) }
    }

    public var body: some View {
        Form {
            if usbDevice != nil {
                EInkUSBDeviceCard(onImportFromTablet: { showingImportBrowser = true })
            } else {
                addRemarkableSection
            }

            otherDevicesSection
        }
        .formStyle(.grouped)
        .task {
            await refreshDeviceInfo()
            await einkModel.refresh()
        }
        .sheet(isPresented: $showingImportBrowser) {
            EInkImportBrowserView(isPresented: $showingImportBrowser)
        }
        .sheet(isPresented: $showingRemarkableConnect) {
            NavigationStack {
                RemarkableSettingsView()
                    .navigationTitle("Connect reMarkable")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingRemarkableConnect = false }
                        }
                    }
            }
            .impressResizableSheet(minWidth: 520, minHeight: 460)
        }
        .sheet(isPresented: $showingAddDevice) {
            AddDeviceSheet(onAdd: { deviceType, syncMethod in
                showingAddDevice = false
                Task {
                    await addDevice(type: deviceType, method: syncMethod)
                }
            })
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            if let message = errorMessage {
                Text(message)
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedDeviceForConfig != nil },
            set: { if !$0 { selectedDeviceForConfig = nil } }
        )) {
            if let deviceID = selectedDeviceForConfig {
                DeviceConfigurationSheet(deviceID: deviceID)
            }
        }
    }

    // MARK: - Add reMarkable (USB)

    private var addRemarkableSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.portrait")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No reMarkable configured")
                        .fontWeight(.semibold)
                    Text("Keep papers on the tablet over the USB cable and bring their highlights and notes back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    addUSBDevice()
                } label: {
                    if isAddingUSB {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add reMarkable (USB)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAddingUSB)
            }
            .padding(.vertical, 4)
        } header: {
            Text("reMarkable")
        } footer: {
            Text("Connect the cable and turn on Settings › Storage › USB web interface on the tablet. No account, no password, nothing through reMarkable's servers.")
        }
    }

    private func addUSBDevice() {
        isAddingUSB = true
        Task {
            let record = await EInkUSBDeviceCreation.addUSBDevice()
            isAddingUSB = false
            if let record {
                Logger.library.infoCapture("eink.pane added USB device \(record.id)", category: "eink")
                await refreshDeviceInfo()
            } else {
                errorMessage = "The reMarkable could not be added; see the Console (category eink)."
            }
        }
    }

    // MARK: - Device Info Loading

    private func refreshDeviceInfo() async {
        var infos: [DeviceRowInfo] = []
        for device in deviceManager.registeredDevices {
            let info = await DeviceRowInfo.from(device)
            infos.append(info)
        }
        deviceInfoList = infos
        activeDeviceID = await deviceManager.activeDevice?.deviceID
    }

    // MARK: - Other Devices Section

    private var otherDevicesSection: some View {
        Section {
            ForEach(legacyDevices) { info in
                DeviceRow(
                    deviceInfo: info,
                    isActive: activeDeviceID == info.id,
                    settings: settings.settings(for: info.id),
                    onSelect: { selectDevice(info.id) },
                    onConfigure: { selectedDeviceForConfig = info.id }
                )
            }

            Button {
                showingAddDevice = true
            } label: {
                Label("Add Device…", systemImage: "plus.circle")
            }
        } header: {
            Text("Other Devices")
        } footer: {
            Text("Supernote and Kindle Scribe, and a reMarkable over the local network, a synced folder or the cloud. The USB reMarkable above is the only device the mirror engine speaks to.")
        }
    }

    // MARK: - Actions

    private func selectDevice(_ deviceID: String) {
        Task {
            do {
                try await deviceManager.selectDevice(deviceID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addDevice(type: EInkDeviceType, method: EInkSyncMethod) async {
        do {
            switch type {
            case .remarkable:
                try await addRemarkableDevice(method: method)
            case .supernote:
                try await addSupernoteDevice(method: method)
            case .kindleScribe:
                try await addKindleScribeDevice(method: method)
            }
            await refreshDeviceInfo()
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
            logger.error("Failed to add device: \(error)")
        }
    }

    private func addRemarkableDevice(method: EInkSyncMethod) async throws {
        switch method {
        case .usb:
            // The engine's device: a store record with USB defaults.
            guard let record = await EInkUSBDeviceCreation.addUSBDevice() else {
                throw EInkError.deviceNotFound("The reMarkable record could not be created")
            }
            logger.info("Added reMarkable USB device record: \(record.id)")

        case .wifi:
            // SFTP to the tablet on this network. The address and password go
            // in the reMarkable panel, which the sheet below leads with.
            let backend = RemarkableWiFiBackend()
            await MainActor.run { RemarkableBackendManager.shared.registerBackend(backend) }
            let adapter = await RemarkableDeviceAdapter(backend: backend, syncMethod: .wifi)
            await deviceManager.registerDevice(adapter)
            let deviceID = await adapter.deviceID
            await MainActor.run {
                settings.updateSettings(for: deviceID) { deviceSettings in
                    deviceSettings.deviceType = .remarkable
                    deviceSettings.syncMethod = .wifi
                    deviceSettings.displayName = "reMarkable (Local Network)"
                    deviceSettings.isAuthenticated = false
                }
                settings.activeDeviceID = deviceID
                showingRemarkableConnect = true
            }
            try? await deviceManager.selectDevice(deviceID)
            logger.info("Added reMarkable local-network device: \(deviceID)")

        case .cloudApi:
            let cloudBackend = RemarkableCloudBackend()
            await MainActor.run {
                RemarkableBackendManager.shared.registerBackend(cloudBackend)
            }
            let adapter = await RemarkableDeviceAdapter(backend: cloudBackend, syncMethod: .cloudApi)
            await deviceManager.registerDevice(adapter)

            // Pairing is a two-step flow that needs a one-time code from the
            // researcher's signed-in browser, so it cannot run here: show the
            // connect sheet instead, or drive it headless with
            // POST /api/remarkable/connect.
            await MainActor.run { showingRemarkableConnect = true }

            let deviceID = await adapter.deviceID
            await MainActor.run {
                settings.updateSettings(for: deviceID) { deviceSettings in
                    deviceSettings.deviceType = .remarkable
                    deviceSettings.syncMethod = .cloudApi
                    deviceSettings.displayName = "reMarkable Cloud"
                    deviceSettings.isAuthenticated = false
                }
                settings.activeDeviceID = deviceID
            }
            try await deviceManager.selectDevice(deviceID)
            logger.info("Added reMarkable Cloud device: \(deviceID)")

        case .folderSync:
            // Folder sync needs a folder first; the configuration sheet asks.
            let deviceID = "remarkable-local-\(UUID().uuidString.prefix(8))"
            await MainActor.run {
                settings.updateSettings(for: deviceID) { deviceSettings in
                    deviceSettings.deviceType = .remarkable
                    deviceSettings.syncMethod = .folderSync
                    deviceSettings.displayName = "reMarkable (Folder Sync)"
                }
            }
            selectedDeviceForConfig = deviceID
            logger.info("Added reMarkable folder sync device, awaiting configuration")

        default:
            throw EInkError.unsupportedSyncMethod(method)
        }
    }

    private func addSupernoteDevice(method: EInkSyncMethod) async throws {
        let deviceID = "supernote-\(UUID().uuidString.prefix(8))"

        let device = SupernoteDevice(
            deviceID: deviceID,
            displayName: "Supernote",
            folderPath: nil  // Will be configured via sheet
        )
        await deviceManager.registerDevice(device)

        await MainActor.run {
            settings.updateSettings(for: deviceID) { deviceSettings in
                deviceSettings.deviceType = .supernote
                deviceSettings.syncMethod = method
                deviceSettings.displayName = "Supernote"
            }
        }

        logger.info("Added Supernote device: \(deviceID)")

        await MainActor.run {
            selectedDeviceForConfig = deviceID
        }
    }

    private func addKindleScribeDevice(method: EInkSyncMethod) async throws {
        let deviceID = "kindle-scribe-\(UUID().uuidString.prefix(8))"

        let device: KindleScribeDevice
        switch method {
        case .usb:
            device = KindleScribeDevice(
                deviceID: deviceID,
                displayName: "Kindle Scribe",
                mountPath: nil  // Will be configured via sheet
            )
        case .email:
            device = KindleScribeDevice(
                deviceID: deviceID,
                displayName: "Kindle Scribe",
                email: ""  // Will be configured via sheet
            )
        default:
            throw EInkError.unsupportedSyncMethod(method)
        }

        await deviceManager.registerDevice(device)

        await MainActor.run {
            settings.updateSettings(for: deviceID) { deviceSettings in
                deviceSettings.deviceType = .kindleScribe
                deviceSettings.syncMethod = method
                deviceSettings.displayName = "Kindle Scribe"
            }
        }

        logger.info("Added Kindle Scribe device: \(deviceID)")

        await MainActor.run {
            selectedDeviceForConfig = deviceID
        }
    }
}

// MARK: - Device Row Info

/// Snapshot of device info for UI display (avoids actor isolation issues).
struct DeviceRowInfo: Identifiable {
    let id: String  // deviceID
    let displayName: String
    let deviceType: EInkDeviceType
    let syncMethod: EInkSyncMethod

    /// Create from an EInkDevice (must be called in async context).
    static func from(_ device: any EInkDevice) async -> DeviceRowInfo {
        DeviceRowInfo(
            id: await device.deviceID,
            displayName: await device.displayName,
            deviceType: await device.deviceType,
            syncMethod: await device.syncMethod
        )
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    let deviceInfo: DeviceRowInfo
    let isActive: Bool
    let settings: EInkDeviceSettings
    let onSelect: () -> Void
    let onConfigure: () -> Void

    var body: some View {
        HStack {
            Image(systemName: deviceInfo.deviceType.iconName)
                .font(.title2)
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(deviceInfo.displayName)
                        .fontWeight(isActive ? .semibold : .regular)

                    if isActive {
                        Text("Active")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(deviceInfo.syncMethod.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let lastSync = settings.lastSyncDate {
                        Text("Last sync: \(lastSync, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button(action: onConfigure) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)

            if !isActive {
                Button("Select", action: onSelect)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add Device Sheet

struct AddDeviceSheet: View {
    let onAdd: (EInkDeviceType, EInkSyncMethod) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedType: EInkDeviceType = .remarkable
    /// USB is the reMarkable's default: the only transport that needs no
    /// credential, and the one the mirror engine speaks (ADR-025).
    @State private var selectedMethod: EInkSyncMethod = .usb

    var body: some View {
        NavigationStack {
            Form {
                Section("Device Type") {
                    Picker("Type", selection: $selectedType) {
                        ForEach(EInkDeviceType.allCases, id: \.self) { type in
                            HStack {
                                Image(systemName: type.iconName)
                                Text(type.displayName)
                            }
                            .tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Sync Method") {
                    Picker("Method", selection: $selectedMethod) {
                        ForEach(selectedType.supportedSyncMethods, id: \.self) { method in
                            VStack(alignment: .leading) {
                                Text(method.displayName)
                                Text(method.methodDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(method)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Add Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(selectedType, selectedMethod)
                    }
                }
            }
        }
        .impressResizableSheet(minWidth: 400, minHeight: 400)
        .onChange(of: selectedType) { _, newType in
            // Reset method if not supported
            if !newType.supportedSyncMethods.contains(selectedMethod) {
                selectedMethod = newType.supportedSyncMethods.first ?? .usb
            }
        }
    }
}

// MARK: - Device Configuration Sheet

struct DeviceConfigurationSheet: View {
    let deviceID: String
    @State private var settings: EInkDeviceSettings

    @Environment(\.dismiss) private var dismiss
    @State private var folderPath: String = ""
    @State private var email: String = ""
    @State private var isAuthenticating = false

    init(deviceID: String) {
        self.deviceID = deviceID
        _settings = State(wrappedValue: EInkSettingsStore.shared.settings(for: deviceID))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let deviceType = settings.deviceType {
                    Section("Device") {
                        LabeledContent("Type", value: deviceType.displayName)
                        if let method = settings.syncMethod {
                            LabeledContent("Sync Method", value: method.displayName)
                        }
                    }
                }

                // Folder sync mirrors a directory some other tool fills.
                if settings.syncMethod == .folderSync || (settings.syncMethod == .usb && settings.deviceType == .kindleScribe) {
                    Section {
                        TextField("Folder path", text: $folderPath)
                            .textFieldStyle(.roundedBorder)

                        Button("Choose Folder...") {
                            chooseFolder()
                        }
                    } header: {
                        Text("Folder Location")
                    } footer: {
                        Text(settings.deviceType == .kindleScribe
                             ? "The Kindle's documents folder while it is mounted over USB."
                             : "Point this at a directory another tool keeps in step with the tablet. To reach a reMarkable directly, use Add reMarkable (USB) instead.")
                    }
                }

                if settings.syncMethod == .email {
                    Section("Send-to-Kindle") {
                        TextField("Kindle email address", text: $email)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.emailAddress)
                    }
                }

                if settings.syncMethod == .cloudApi {
                    Section("Authentication") {
                        if settings.isAuthenticated {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Connected")
                            }

                            Button("Disconnect", role: .destructive) {
                                disconnect()
                            }
                        } else {
                            Button {
                                authenticate()
                            } label: {
                                if isAuthenticating {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Connect")
                                }
                            }
                            .disabled(isAuthenticating)
                        }
                    }
                }
            }
            .navigationTitle("Configure Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                }
            }
        }
        .impressResizableSheet(minWidth: 400, minHeight: 300)
        .onAppear {
            folderPath = settings.localFolderPath ?? ""
            email = settings.sendToEmail ?? ""
        }
    }

    private func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
        #endif
    }

    private func authenticate() {
        isAuthenticating = true
        Task {
            // The cloud pairing flow lives in RemarkableSettingsView.
            isAuthenticating = false
        }
    }

    private func disconnect() {
        Task { @MainActor in
            EInkSettingsStore.shared.clearCredentials(for: deviceID)
            var updatedSettings = settings
            updatedSettings.isAuthenticated = false
            settings = updatedSettings
        }
    }

    private func save() {
        Task {
            await MainActor.run {
                EInkSettingsStore.shared.updateSettings(for: deviceID) { deviceSettings in
                    deviceSettings.localFolderPath = folderPath.isEmpty ? nil : folderPath
                    deviceSettings.sendToEmail = email.isEmpty ? nil : email
                }
            }

            if let device = await MainActor.run(body: { EInkDeviceManager.shared.device(withID: deviceID) }) {
                if !folderPath.isEmpty {
                    let folderURL = URL(fileURLWithPath: folderPath)
                    if let supernote = device as? SupernoteDevice {
                        await supernote.configure(folderPath: folderURL)
                    } else if let kindle = device as? KindleScribeDevice {
                        await kindle.configureUSB(mountPath: folderURL)
                    }
                }
                if !email.isEmpty, let kindle = device as? KindleScribeDevice {
                    await kindle.configureEmail(address: email)
                }
            }

            await MainActor.run {
                dismiss()
            }
        }
    }
}

// MARK: - Previews

#Preview("EInkSettingsView") {
    EInkSettingsView()
        .frame(width: 500, height: 600)
}

#Preview("Add Device Sheet") {
    AddDeviceSheet { _, _ in }
}
