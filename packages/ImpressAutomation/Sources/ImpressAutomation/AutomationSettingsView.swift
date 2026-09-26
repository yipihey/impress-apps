//
//  AutomationSettingsView.swift
//  ImpressAutomation
//
//  Shared settings view for automation API configuration — the one place
//  the six keys of `AutomationServerSettings` are edited (P0, SEC-4).
//

import SwiftUI

/// A reusable settings section for configuring the HTTP automation API.
///
/// Usage:
/// ```swift
/// AutomationSettingsSection(
///     httpEnabled: $httpEnabled,
///     httpPort: $httpPort,
///     logRequests: $logRequests,            // optional
///     allowNetworkAccess: $allowNetwork,    // optional: the network controls
///     networkAuthToken: $networkToken,      //   appear only when all three
///     networkBindAddress: $bindAddress      //   bindings are given
/// )
/// ```
public struct AutomationSettingsSection: View {
    @Binding var httpEnabled: Bool
    @Binding var httpPort: Int
    @Binding var logRequests: Bool
    @Binding var allowNetworkAccess: Bool
    @Binding var networkAuthToken: String
    @Binding var networkBindAddress: String

    private let showLogToggle: Bool
    private let showNetwork: Bool

    public init(
        httpEnabled: Binding<Bool>,
        httpPort: Binding<Int>,
        logRequests: Binding<Bool>? = nil,
        allowNetworkAccess: Binding<Bool>? = nil,
        networkAuthToken: Binding<String>? = nil,
        networkBindAddress: Binding<String>? = nil
    ) {
        self._httpEnabled = httpEnabled
        self._httpPort = httpPort
        if let logRequests {
            self._logRequests = logRequests
            self.showLogToggle = true
        } else {
            self._logRequests = .constant(false)
            self.showLogToggle = false
        }
        if let allowNetworkAccess, let networkAuthToken, let networkBindAddress {
            self._allowNetworkAccess = allowNetworkAccess
            self._networkAuthToken = networkAuthToken
            self._networkBindAddress = networkBindAddress
            self.showNetwork = true
        } else {
            self._allowNetworkAccess = .constant(false)
            self._networkAuthToken = .constant("")
            self._networkBindAddress = .constant("")
            self.showNetwork = false
        }
    }

    public var body: some View {
        Section("HTTP Automation API") {
            Toggle("Enable HTTP API", isOn: $httpEnabled)

            HStack {
                Text("Port")
                Spacer()
                TextField("Port", value: $httpPort, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
            .disabled(!httpEnabled)

            if showLogToggle {
                Toggle("Log API requests", isOn: $logRequests)
                    .disabled(!httpEnabled)
            }

            Text(
                "Loopback callers read this launch's token from the suite container and send it on every non-GET; a GET needs none."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if showNetwork {
            Section("Network access") {
                Toggle("Accept connections from the network", isOn: $allowNetworkAccess)
                    .disabled(!httpEnabled)
                    .onChange(of: allowNetworkAccess) { _, on in
                        if on, networkAuthToken.isEmpty {
                            networkAuthToken = HTTPAuthPolicy.generateToken()
                        }
                    }

                HStack {
                    Text("Bind address")
                    Spacer()
                    TextField("100.x.y.z", text: $networkBindAddress)
                        .frame(width: 180)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                }
                .disabled(!httpEnabled || !allowNetworkAccess)

                HStack(alignment: .firstTextBaseline) {
                    Text("Token")
                    Spacer()
                    Text(networkAuthToken.isEmpty ? "—" : networkAuthToken)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Regenerate") {
                        networkAuthToken = HTTPAuthPolicy.generateToken()
                    }
                }
                .disabled(!httpEnabled || !allowNetworkAccess)

                Text(
                    "The server binds this one address and requires `Authorization: Bearer <token>` from every peer on it. It will not start with the toggle on and either field empty. A caller sets IMPRESS_APP_TOKEN to the token."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Convenience wrapper that uses AppStorage for simple apps — every key of
/// `AutomationServerSettings.Keys`, which `AutomationServerSettings.load`
/// reads back.
///
/// For apps with their own settings record (imbib's `AutomationSettings`),
/// use `AutomationSettingsSection` directly with custom bindings.
public struct SimpleAutomationSettingsView: View {
    @AppStorage(AutomationServerSettings.Keys.enabled) private var httpEnabled = true
    @AppStorage(AutomationServerSettings.Keys.port) private var httpPort: Int = 23100
    @AppStorage(AutomationServerSettings.Keys.logRequests) private var logRequests = true
    @AppStorage(AutomationServerSettings.Keys.allowNetworkAccess) private var allowNetworkAccess = false
    @AppStorage(AutomationServerSettings.Keys.networkAuthToken) private var networkAuthToken = ""
    @AppStorage(AutomationServerSettings.Keys.networkBindAddress) private var networkBindAddress = ""

    public init(defaultPort: Int = 23100) {
        _httpPort = AppStorage(wrappedValue: defaultPort, AutomationServerSettings.Keys.port)
    }

    public var body: some View {
        Form {
            AutomationSettingsSection(
                httpEnabled: $httpEnabled,
                httpPort: $httpPort,
                logRequests: $logRequests,
                allowNetworkAccess: $allowNetworkAccess,
                networkAuthToken: $networkAuthToken,
                networkBindAddress: $networkBindAddress
            )
        }
        .formStyle(.grouped)
    }
}
