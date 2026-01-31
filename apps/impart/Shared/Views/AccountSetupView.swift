//
//  AccountSetupView.swift
//  impart (Shared)
//
//  Account setup wizard for adding email accounts.
//

import SwiftUI
import MessageManagerCore

// MARK: - Account Setup View

/// Wizard for setting up a new email account.
public struct AccountSetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var step: SetupStep = .email
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var imapHost = ""
    @State private var imapPort: Int = 993
    @State private var smtpHost = ""
    @State private var smtpPort: Int = 587
    @State private var security: ConnectionSecurity = .tls
    @State private var isValidating = false
    @State private var validationComplete = false
    @State private var errorMessage: String?

    private var detectedProvider: EmailProvider {
        EmailProvider.detect(from: email)
    }

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Progress indicator
                ProgressView(value: step.progress)
                    .padding(.horizontal)

                // Step content
                Group {
                    switch step {
                    case .email:
                        emailStep
                    case .password:
                        passwordStep
                    case .settings:
                        settingsStep
                    case .validation:
                        validationStep
                    }
                }
                .padding()

                Spacer()

                // Error message
                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .foregroundStyle(.red)
                    }
                    .font(.callout)
                    .padding(.horizontal)
                }

                // Navigation buttons
                HStack {
                    if step != .email {
                        Button("Back") {
                            withAnimation { step = step.previous }
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    Button(step.nextButtonTitle) {
                        handleNext()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                }
                .padding()
            }
            .navigationTitle("Add Account")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 450, minHeight: 450)
        #endif
    }

    // MARK: - Steps

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter your email address")
                .font(.headline)

            Text("We'll try to automatically detect your email provider and configure the server settings.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Email", text: $email)
                #if os(iOS)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                #endif
                .textFieldStyle(.roundedBorder)

            if !email.isEmpty && detectedProvider != .custom {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(detectedProvider.displayName) account detected")
                        .foregroundStyle(.green)
                }
                .font(.callout)
            }
        }
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter your password")
                .font(.headline)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            if detectedProvider == .gmail {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Important for Gmail", systemImage: "info.circle")
                        .font(.callout.bold())

                    Text("For Gmail, you need to use an App Password instead of your regular password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("1. Go to your Google Account settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("2. Enable 2-Step Verification if not already enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("3. Create an App Password for 'Mail'")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if detectedProvider == .icloud {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Important for iCloud", systemImage: "info.circle")
                        .font(.callout.bold())

                    Text("For iCloud Mail, you need to generate an app-specific password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Visit appleid.apple.com to create one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var settingsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Settings")
                .font(.headline)

            if detectedProvider == .custom {
                Group {
                    TextField("Display Name", text: $displayName)
                        .textFieldStyle(.roundedBorder)

                    Divider()

                    Text("IMAP Settings")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("IMAP Host", text: $imapHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("Port", value: $imapPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }

                    Divider()

                    Text("SMTP Settings")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("SMTP Host", text: $smtpHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("Port", value: $smtpPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }

                    Picker("Security", selection: $security) {
                        ForEach(ConnectionSecurity.allCases, id: \.self) { sec in
                            Text(sec.displayName).tag(sec)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Using default settings for \(detectedProvider.displayName)")
                    }

                    TextField("Display Name (optional)", text: $displayName)
                        .textFieldStyle(.roundedBorder)

                    Text("Your display name will appear in the From field of emails you send.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var validationStep: some View {
        VStack(spacing: 24) {
            if isValidating {
                ProgressView()
                    .controlSize(.large)
                Text("Connecting to server...")
                    .font(.headline)
                Text("This may take a few moments.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if validationComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                Text("Account added successfully!")
                    .font(.headline)
                Text("Your email account is ready to use.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Logic

    private var canProceed: Bool {
        switch step {
        case .email:
            return isValidEmail(email)
        case .password:
            return !password.isEmpty
        case .settings:
            if detectedProvider == .custom {
                return !imapHost.isEmpty && !smtpHost.isEmpty
            }
            return true
        case .validation:
            return validationComplete
        }
    }

    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return email.range(of: emailRegex, options: .regularExpression) != nil
    }

    private func handleNext() {
        errorMessage = nil

        switch step {
        case .email:
            withAnimation { step = .password }
        case .password:
            withAnimation { step = .settings }
        case .settings:
            withAnimation { step = .validation }
            validateAccount()
        case .validation:
            dismiss()
        }
    }

    private func validateAccount() {
        isValidating = true
        errorMessage = nil

        Task {
            do {
                // Build account config
                let account = buildAccount()

                // Save password to keychain
                try KeychainService.shared.setPassword(password, for: account.id)

                // Test connection
                let provider = RustMailProvider(account: account)
                try await provider.connect()
                await provider.disconnect()

                // Save account to Core Data
                try await saveAccount(account)

                await MainActor.run {
                    isValidating = false
                    validationComplete = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isValidating = false
                    withAnimation { step = .settings }
                }
            }
        }
    }

    private func buildAccount() -> Account {
        let (imap, smtp): (IMAPSettings, SMTPSettings)

        if detectedProvider == .custom {
            imap = IMAPSettings(
                host: imapHost,
                port: UInt16(imapPort),
                security: security,
                username: email
            )
            smtp = SMTPSettings(
                host: smtpHost,
                port: UInt16(smtpPort),
                security: security == .tls ? .starttls : security,
                username: email
            )
        } else {
            (imap, smtp) = detectedProvider.defaultSettings(for: email)
        }

        return Account(
            email: email,
            displayName: displayName.isEmpty ? email : displayName,
            imapSettings: imap,
            smtpSettings: smtp
        )
    }

    private func saveAccount(_ account: Account) async throws {
        try await PersistenceController.shared.performBackgroundTask { context in
            let cdAccount = CDAccount(context: context)
            cdAccount.id = account.id
            cdAccount.email = account.email
            cdAccount.displayName = account.displayName
            cdAccount.imapHost = account.imapSettings.host
            cdAccount.imapPort = Int16(account.imapSettings.port)
            cdAccount.smtpHost = account.smtpSettings.host
            cdAccount.smtpPort = Int16(account.smtpSettings.port)
            cdAccount.isEnabled = true
            cdAccount.keychainItemId = account.id.uuidString
            try context.save()
        }
    }
}

// MARK: - Setup Step

private enum SetupStep: CaseIterable {
    case email, password, settings, validation

    var progress: Double {
        switch self {
        case .email: return 0.25
        case .password: return 0.5
        case .settings: return 0.75
        case .validation: return 1.0
        }
    }

    var nextButtonTitle: String {
        switch self {
        case .validation: return "Done"
        default: return "Continue"
        }
    }

    var previous: SetupStep {
        switch self {
        case .email: return .email
        case .password: return .email
        case .settings: return .password
        case .validation: return .settings
        }
    }
}

// MARK: - Email Provider Extension

extension EmailProvider {
    var displayName: String {
        switch self {
        case .gmail: return "Gmail"
        case .outlook: return "Outlook"
        case .icloud: return "iCloud"
        case .fastmail: return "Fastmail"
        case .custom: return "Custom"
        }
    }
}

// MARK: - Preview

#Preview {
    AccountSetupView()
}
