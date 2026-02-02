//
//  EInkSettingsView.swift
//  PublicationManagerCore
//
//  Settings interface for configuring E-Ink device integration.
//

import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "einkSettings")

// MARK: - Settings View

/// Settings view for configuring E-Ink device integration.
public struct EInkSettingsView: View {
    @State private var settings = EInkSettingsStore.shared
    @State private var deviceManager = EInkDeviceManager.shared
    @State private var deviceInfoList: [DeviceRowInfo] = []
    @State private var activeDeviceID: String?
    @State private var showingAddDevice = false
    @State private var selectedDeviceForConfig: String?
    @State private var authCode: String?
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        Form {
            // Device list
            devicesSection

            // Global sync options
            if deviceManager.isAnyDeviceAvailable {
                syncOptionsSection
                organizationSection
                annotationOptionsSection
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshDeviceInfo()
        }
        .sheet(isPresented: $showingAddDevice) {
            AddDeviceSheet(onAdd: { deviceType, syncMethod in
                showingAddDevice = false
                Task {
                    await addDevice(type: deviceType, method: syncMethod)
                }
            })
        }
        .alert("Authentication Code", isPresented: .constant(authCode != nil)) {
            Button("Copy") {
                if let code = authCode {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    #endif
                }
                authCode = nil
            }
            Button("Cancel", role: .cancel) {
                authCode = nil
            }
        } message: {
            if let code = authCode {
                Text("Enter this code at your device's website:\n\n\(code)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .einkShowAuthCode)) { notification in
            if let code = notification.userInfo?["code"] as? String {
                authCode = code
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remarkableShowAuthCode)) { notification in
            if let code = notification.userInfo?["code"] as? String {
                authCode = code
            }
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

    // MARK: - Devices Section

    private var devicesSection: some View {
        Section {
            if deviceInfoList.isEmpty {
                ContentUnavailableView(
                    "No Devices",
                    systemImage: "rectangle.portrait",
                    description: Text("Add an E-Ink device to sync your papers")
                )
            } else {
                ForEach(deviceInfoList) { info in
                    DeviceRow(
                        deviceInfo: info,
                        isActive: activeDeviceID == info.id,
                        settings: settings.settings(for: info.id),
                        onSelect: { selectDevice(info.id) },
                        onConfigure: { selectedDeviceForConfig = info.id }
                    )
                }
            }

            Button {
                showingAddDevice = true
            } label: {
                Label("Add Device", systemImage: "plus.circle")
            }
        } header: {
            Text("E-Ink Devices")
        } footer: {
            Text("Connect reMarkable, Supernote, or Kindle Scribe tablets")
        }
    }

    // MARK: - Sync Options Section

    private var syncOptionsSection: some View {
        Section {
            Toggle("Auto-sync when available", isOn: $settings.autoSyncEnabled)

            if settings.autoSyncEnabled {
                Picker("Sync interval", selection: $settings.syncInterval) {
                    Text("Every 15 minutes").tag(TimeInterval(900))
                    Text("Every 30 minutes").tag(TimeInterval(1800))
                    Text("Every hour").tag(TimeInterval(3600))
                    Text("Every 4 hours").tag(TimeInterval(14400))
                    Text("Daily").tag(TimeInterval(86400))
                }
            }

            Picker("Conflict resolution", selection: $settings.conflictResolution) {
                ForEach(EInkConflictResolution.allCases, id: \.self) { resolution in
                    Text(resolution.displayName).tag(resolution)
                }
            }
        } header: {
            Text("Sync Options")
        }
    }

    // MARK: - Organization Section

    private var organizationSection: some View {
        Section {
            TextField("Root folder name", text: $settings.rootFolderName)
                .textFieldStyle(.roundedBorder)

            Toggle("Create folders by collection", isOn: $settings.createFoldersByCollection)

            Toggle("Create Reading Queue folder", isOn: $settings.useReadingQueueFolder)
        } header: {
            Text("Organization")
        } footer: {
            Text("How papers are organized on your E-Ink device")
        }
    }

    // MARK: - Annotation Options Section

    private var annotationOptionsSection: some View {
        Section {
            Picker("Import mode", selection: $settings.annotationImportMode) {
                ForEach(AnnotationImportMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Toggle("Import highlights", isOn: $settings.importHighlights)

            Toggle("Import handwritten notes", isOn: $settings.importInkNotes)

            if settings.importInkNotes {
                Toggle("Enable OCR for handwriting", isOn: $settings.enableOCR)
            }
        } header: {
            Text("Annotation Import")
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
        case .cloudApi:
            // Create cloud backend
            let cloudBackend = RemarkableCloudBackend()

            // Register with RemarkableBackendManager
            await MainActor.run {
                RemarkableBackendManager.shared.registerBackend(cloudBackend)
            }

            // Create and register EInk adapter
            let adapter = await RemarkableDeviceAdapter(backend: cloudBackend, syncMethod: .cloudApi)
            await deviceManager.registerDevice(adapter)

            // Start authentication flow
            try await cloudBackend.authenticate()

            // Store device settings
            let deviceID = await adapter.deviceID
            await MainActor.run {
                settings.updateSettings(for: deviceID) { deviceSettings in
                    deviceSettings.deviceType = .remarkable
                    deviceSettings.syncMethod = .cloudApi
                    deviceSettings.displayName = "reMarkable Cloud"
                    deviceSettings.isAuthenticated = true
                }
                settings.activeDeviceID = deviceID
            }

            // Select as active device
            try await deviceManager.selectDevice(deviceID)

            logger.info("Added reMarkable Cloud device: \(deviceID)")

        case .folderSync:
            // For folder sync, we need to prompt for folder selection first
            // This is handled by the configuration sheet after initial add
            let deviceID = "remarkable-local-\(UUID().uuidString.prefix(8))"
            await MainActor.run {
                settings.updateSettings(for: deviceID) { deviceSettings in
                    deviceSettings.deviceType = .remarkable
                    deviceSettings.syncMethod = .folderSync
                    deviceSettings.displayName = "reMarkable (Folder Sync)"
                }
            }
            // Open configuration sheet to choose folder
            selectedDeviceForConfig = deviceID
            logger.info("Added reMarkable folder sync device, awaiting configuration")

        case .usb:
            // USB is similar to folder sync
            let deviceID = "remarkable-usb-\(UUID().uuidString.prefix(8))"
            await MainActor.run {
                settings.updateSettings(for: deviceID) { deviceSettings in
                    deviceSettings.deviceType = .remarkable
                    deviceSettings.syncMethod = .usb
                    deviceSettings.displayName = "reMarkable (USB)"
                }
            }
            selectedDeviceForConfig = deviceID
            logger.info("Added reMarkable USB device, awaiting configuration")

        default:
            throw EInkError.unsupportedSyncMethod(method)
        }
    }

    private func addSupernoteDevice(method: EInkSyncMethod) async throws {
        let deviceID = "supernote-\(UUID().uuidString.prefix(8))"

        // Create and register the device
        let device = SupernoteDevice(
            deviceID: deviceID,
            displayName: "Supernote",
            folderPath: nil  // Will be configured via sheet
        )
        await deviceManager.registerDevice(device)

        // Store device settings
        await MainActor.run {
            settings.updateSettings(for: deviceID) { deviceSettings in
                deviceSettings.deviceType = .supernote
                deviceSettings.syncMethod = method
                deviceSettings.displayName = "Supernote"
            }
        }

        logger.info("Added Supernote device: \(deviceID)")

        // Show configuration sheet to choose folder
        await MainActor.run {
            selectedDeviceForConfig = deviceID
        }
    }

    private func addKindleScribeDevice(method: EInkSyncMethod) async throws {
        let deviceID = "kindle-scribe-\(UUID().uuidString.prefix(8))"

        // Create device based on sync method
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

        // Register the device
        await deviceManager.registerDevice(device)

        // Store device settings
        await MainActor.run {
            settings.updateSettings(for: deviceID) { deviceSettings in
                deviceSettings.deviceType = .kindleScribe
                deviceSettings.syncMethod = method
                deviceSettings.displayName = "Kindle Scribe"
            }
        }

        logger.info("Added Kindle Scribe device: \(deviceID)")

        // Show configuration sheet
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
            // Device icon
            Image(systemName: deviceInfo.deviceType.iconName)
                .font(.title2)
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: 32)

            // Device info
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

            // Actions
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
    @State private var selectedMethod: EInkSyncMethod = .cloudApi

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
        .frame(minWidth: 400, minHeight: 400)
        .onChange(of: selectedType) { _, newType in
            // Reset method if not supported
            if !newType.supportedSyncMethods.contains(selectedMethod) {
                selectedMethod = newType.supportedSyncMethods.first ?? .cloudApi
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

                if settings.syncMethod == .folderSync || settings.syncMethod == .usb {
                    Section("Folder Location") {
                        TextField("Folder path", text: $folderPath)
                            .textFieldStyle(.roundedBorder)

                        Button("Choose Folder...") {
                            chooseFolder()
                        }
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
        .frame(minWidth: 400, minHeight: 300)
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
        // Trigger authentication flow
        Task {
            // Authentication logic would go here
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
            // Update settings store
            await MainActor.run {
                EInkSettingsStore.shared.updateSettings(for: deviceID) { deviceSettings in
                    deviceSettings.localFolderPath = folderPath.isEmpty ? nil : folderPath
                    deviceSettings.sendToEmail = email.isEmpty ? nil : email
                }
            }

            // Configure the actual device
            if let device = await MainActor.run(body: { EInkDeviceManager.shared.device(withID: deviceID) }) {
                if !folderPath.isEmpty {
                    let folderURL = URL(fileURLWithPath: folderPath)
                    // Configure based on device type
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
