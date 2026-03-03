//
//  AutomationSettingsView.swift
//  ImpressAutomation
//
//  Shared settings view for automation API configuration.
//

import SwiftUI

/// A reusable settings section for configuring the HTTP automation API.
///
/// Usage:
/// ```swift
/// AutomationSettingsSection(
///     httpEnabled: $httpEnabled,
///     httpPort: $httpPort,
///     logRequests: $logRequests  // optional
/// )
/// ```
public struct AutomationSettingsSection: View {
    @Binding var httpEnabled: Bool
    @Binding var httpPort: Int
    @Binding var logRequests: Bool

    private let showLogToggle: Bool

    public init(
        httpEnabled: Binding<Bool>,
        httpPort: Binding<Int>,
        logRequests: Binding<Bool>? = nil
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
        }
    }
}

/// Convenience wrapper that uses AppStorage for simple apps.
///
/// For apps with more complex automation settings (like imbib with its
/// `AutomationSettingsStore`), use `AutomationSettingsSection` directly
/// with custom bindings.
public struct SimpleAutomationSettingsView: View {
    @AppStorage("httpAutomationEnabled") private var httpEnabled = true
    @AppStorage("httpAutomationPort") private var httpPort: Int

    private let defaultPort: Int

    public init(defaultPort: Int = 23100) {
        self.defaultPort = defaultPort
        // AppStorage needs the default set in the property wrapper,
        // but we parameterize via init for different apps
        _httpPort = AppStorage(wrappedValue: defaultPort, "httpAutomationPort")
    }

    public var body: some View {
        Form {
            AutomationSettingsSection(
                httpEnabled: $httpEnabled,
                httpPort: $httpPort
            )
        }
        .formStyle(.grouped)
    }
}
