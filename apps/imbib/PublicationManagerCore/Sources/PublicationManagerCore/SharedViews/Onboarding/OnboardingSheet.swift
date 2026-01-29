//
//  OnboardingSheet.swift
//  PublicationManagerCore
//
//  Main container for the onboarding flow.
//

import SwiftUI

/// Main container view for the onboarding flow.
///
/// Presents a multi-step wizard that guides users through:
/// 1. Library proxy setup
/// 2. Database preference (OpenAlex or ADS)
/// 3. ADS API key configuration (only if ADS selected)
/// 4. Completion confirmation
public struct OnboardingSheet: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss
    private let onboardingManager = OnboardingManager.shared

    // MARK: - State

    @State private var hasADSKey = false
    @State private var isCheckingCredentials = true
    @State private var preferredDatabase: PreferredDatabase = .openAlex

    // MARK: - Body

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            progressIndicator
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            // Step content
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 500, idealWidth: 550, maxWidth: 600)
        .frame(minHeight: 450, idealHeight: 500, maxHeight: 600)
        .interactiveDismissDisabled(onboardingManager.currentStep != .complete)
        .task {
            await checkExistingCredentials()
        }
    }

    // MARK: - Progress Indicator

    private var progressIndicator: some View {
        HStack(spacing: 12) {
            ForEach(0..<OnboardingStep.configurationStepCount, id: \.self) { index in
                let step = OnboardingStep(rawValue: index) ?? .adsAPIKey
                let isCurrent = onboardingManager.currentStep.rawValue == index
                let isCompleted = onboardingManager.currentStep.rawValue > index

                HStack(spacing: 8) {
                    // Step circle
                    ZStack {
                        Circle()
                            .fill(stepCircleColor(isCurrent: isCurrent, isCompleted: isCompleted))
                            .frame(width: 28, height: 28)

                        if isCompleted {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(isCurrent ? .white : .secondary)
                        }
                    }

                    // Step title
                    Text(step.title)
                        .font(.subheadline)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                }

                // Connector line
                if index < OnboardingStep.configurationStepCount - 1 {
                    Rectangle()
                        .fill(isCompleted ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 40, height: 2)
                }
            }
        }
        .padding(.horizontal)
    }

    private func stepCircleColor(isCurrent: Bool, isCompleted: Bool) -> Color {
        if isCompleted {
            return .accentColor
        } else if isCurrent {
            return .accentColor
        } else {
            return Color.secondary.opacity(0.2)
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch onboardingManager.currentStep {
        case .libraryProxy:
            ProxySetupStepView(
                onSkip: { onboardingManager.nextStep() },
                onContinue: { onboardingManager.nextStep() }
            )

        case .databasePreference:
            DatabasePreferenceStepView(
                selection: $preferredDatabase,
                onContinue: {
                    // Save preference immediately
                    Task {
                        await savePreferredDatabase()
                    }

                    // If OpenAlex, skip ADS step; if ADS, show ADS step
                    if preferredDatabase == .openAlex {
                        onboardingManager.currentStep = .complete
                    } else {
                        onboardingManager.nextStep()
                    }
                }
            )

        case .adsAPIKey:
            ADSSetupStepView(
                hasExistingKey: hasADSKey,
                onSkip: { onboardingManager.nextStep() },
                onContinue: { onboardingManager.nextStep() }
            )

        case .complete:
            OnboardingCompleteView(
                onFinish: {
                    onboardingManager.completeOnboarding()
                    dismiss()
                }
            )
        }
    }

    // MARK: - Helpers

    private func checkExistingCredentials() async {
        hasADSKey = await CredentialManager.shared.hasCredential(for: "ads", type: .apiKey)
        isCheckingCredentials = false
    }

    private func savePreferredDatabase() async {
        let source: EnrichmentSource = preferredDatabase == .openAlex ? .openalex : .ads
        await EnrichmentSettingsStore.shared.updatePreferredSource(source)
    }
}

// MARK: - Onboarding Complete View

/// Final step showing completion message and start button.
struct OnboardingCompleteView: View {

    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)

            // Title
            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            // Description
            Text("You can always change these settings later\nin Preferences.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Start button
            Button {
                onFinish()
            } label: {
                Text("Start Using imbib")
                    .font(.headline)
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 16)

            Spacer()
            Spacer()
        }
        .padding(32)
    }
}

// MARK: - Preview

#Preview {
    OnboardingSheet()
}
